// Sends the queue to the Lifelog Worker: events as JSON batches, audio chunks into R2 (devices/iphone/audio/<day>/…).
// Runs every 5 minutes while the app is alive (it stays alive while the mic records), when the app opens, and from
// background refresh. Audio waits for Wi-Fi unless you allow cellular; events are tiny and go on any network.
import Foundation
import Network

final class Uploader: @unchecked Sendable {
    static let shared = Uploader()

    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var busy = false
    private let lock = NSLock()
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private(set) var lastSuccess: Date? = UserDefaults.standard.object(forKey: "lastUpload") as? Date
    private(set) var lastError: String?

    var audioOnCellular: Bool {
        get { UserDefaults.standard.bool(forKey: "audioOnCellular") }
        set { UserDefaults.standard.set(newValue, forKey: "audioOnCellular") }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] p in
            let was = self?.path?.status
            self?.path = p
            if p.status == .satisfied, was != .satisfied { self?.kick() }
        }
        monitor.start(queue: DispatchQueue(label: "lifelog.net"))
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.kick() }
    }

    func kick(completion: (() -> Void)? = nil) {
        Task.detached { await self.run(); completion?() }
    }

    func run() async {
        guard claim() else { return }
        defer { release() }
        guard !Secrets.url.isEmpty, !Secrets.token.isEmpty else { lastError = "not configured"; return }
        Sensors.shared.collectMotion()
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let motion/steps queries land in the events file
        do {
            try await uploadAudio()
            try await uploadEvents()
            lastSuccess = Date()
            lastError = nil
            UserDefaults.standard.set(lastSuccess, forKey: "lastUpload")
        } catch {
            lastError = error.localizedDescription
            Log.line("upload failed: \(error.localizedDescription)")
        }
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    private func release() { lock.lock(); busy = false; lock.unlock() }

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: URL(string: Secrets.url + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(Secrets.token)", forHTTPHeaderField: "authorization")
        r.setValue("LifelogPhone/1.0", forHTTPHeaderField: "user-agent")
        return r
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw NSError(domain: "lifelog", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(String(data: data.prefix(200), encoding: .utf8) ?? "")"])
        }
    }

    private func uploadEvents() async throws {
        for file in Store.shared.rotate() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let events = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            var i = 0
            while i < events.count {
                let batch = Array(events[i..<min(i + 1000, events.count)])
                var r = request("/api/phone/events", method: "POST")
                r.setValue("application/json", forHTTPHeaderField: "content-type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["device": Secrets.device, "deviceName": "iPhone",
                                                                           "events": batch])
                let (data, resp) = try await session.data(for: r)
                try check(resp, data)
                i += 1000
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func uploadAudio() async throws {
        let expensive = path?.isExpensive ?? true
        let constrained = path?.isConstrained ?? false
        for file in Store.shared.pendingAudio() {
            let side = file.appendingPathExtension("json")
            guard let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: side))) as? [String: Any],
                  let start = meta["start"] as? Double else { continue }
            let peak = meta["peak_db"] as? Double ?? -160
            var info = meta
            if peak < -50 {
                // nothing above the noise floor: don't spend bandwidth, but record that it was silent
                info["silent"] = true
                Store.shared.log("audio", info, at: Date(timeIntervalSince1970: start))
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: side)
                continue
            }
            if (expensive || constrained) && !audioOnCellular { continue }
            let day = isoDay.string(from: Date(timeIntervalSince1970: start))
            let rel = "audio/\(day)/\(file.lastPathComponent)"
            var r = request("/api/upload/\(Secrets.device)/\(rel)", method: "PUT")
            r.setValue("audio/mp4", forHTTPHeaderField: "content-type")
            let (data, resp) = try await session.upload(for: r, fromFile: file)
            try check(resp, data)
            info["key"] = "devices/\(Secrets.device)/\(rel)"
            info["bytes"] = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            Store.shared.log("audio", info, at: Date(timeIntervalSince1970: start))
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: side)
        }
    }
}
