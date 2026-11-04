// Local queue of everything the phone records, until it's uploaded.
//
//   events.jsonl        events recorded since the last upload attempt (one JSON object per line)
//   outbox/*.jsonl      batches being uploaded (deleted once the Worker has them)
//   audio/*.m4a         finished 5-minute audio chunks waiting for upload (+ a .json sidecar with their metadata)
//
// Files use "complete until first unlock" protection, so the app can keep writing while the phone is locked.
import Foundation

let isoDay: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let fileStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

final class Store: @unchecked Sendable {
    static let shared = Store()

    let root: URL
    let audioDir: URL
    let outbox: URL
    private let eventsFile: URL
    private let q = DispatchQueue(label: "lifelog.store")
    private(set) var recorded = 0  // events recorded since launch (for the UI)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Lifelog", isDirectory: true)
        audioDir = root.appendingPathComponent("audio", isDirectory: true)
        outbox = root.appendingPathComponent("outbox", isDirectory: true)
        eventsFile = root.appendingPathComponent("events.jsonl")
        for d in [root, audioDir, outbox] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    /// Record one fact. `data` must be JSON-serializable.
    func log(_ kind: String, _ data: [String: Any] = [:], at ts: Date = Date()) {
        let ev: [String: Any] = ["id": UUID().uuidString, "ts": ts.timeIntervalSince1970, "kind": kind, "data": data]
        guard let line = try? JSONSerialization.data(withJSONObject: ev) else { return }
        q.async {
            if !FileManager.default.fileExists(atPath: self.eventsFile.path) {
                FileManager.default.createFile(atPath: self.eventsFile.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            if let h = try? FileHandle(forWritingTo: self.eventsFile) {
                h.seekToEndOfFile()
                h.write(line + Data([0x0A]))
                try? h.close()
            }
            self.recorded += 1
        }
        Log.line("\(kind) \(data.isEmpty ? "" : String(describing: data))")
    }

    /// Move the current events file into the outbox (so new events go to a fresh file) and list outbox batches.
    func rotate() -> [URL] {
        q.sync {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: eventsFile.path),
               (attrs[.size] as? Int ?? 0) > 0 {
                let dest = outbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jsonl")
                try? FileManager.default.moveItem(at: eventsFile, to: dest)
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func pendingAudio() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" && FileManager.default.fileExists(atPath: $0.appendingPathExtension("json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var pendingEventBatches: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).count
            + ((try? FileManager.default.attributesOfItem(atPath: eventsFile.path)) != nil ? 1 : 0)
    }
}

/// A small rolling debug log (Settings → "Recent activity"), not uploaded.
enum Log {
    nonisolated(unsafe) private static var lines: [String] = []
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func line(_ s: String) {
        lock.lock()
        lines.append("\(fmt.string(from: Date())) \(s)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        lock.unlock()
    }

    static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.reversed()
    }
}
