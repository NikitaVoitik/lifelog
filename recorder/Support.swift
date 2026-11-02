// Plumbing for the app: the shared config file, running the `lifelog` pipeline CLI,
// privacy permissions, start-at-login, formatting and the category palette.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - config.json (shared with the Python pipeline)

enum ConfigFile {
    static let url = rootDir.appendingPathComponent("config.json")

    /// the file as-is (used for writes)
    static func raw() -> [String: Any] {
        guard let d = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    /// the file, with the recorder's built-in defaults filled in for keys it doesn't mention yet
    static func load() -> [String: Any] {
        var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any]) ?? [:]
        for (k, v) in raw() { merged[k] = v }
        return merged
    }

    /// read-modify-write a single key so we never clobber keys the pipeline added meanwhile
    static func set(_ key: String, _ value: Any) {
        var obj = raw()
        obj[key] = value
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // holds the cloud token
    }
}

// MARK: - the pipeline CLI (pipeline/lifelog.py, installed to ~/Lifelog/bin)

enum CLI {
    /// install.sh writes PATH / python / CLAUDE_CONFIG_DIR here, so jobs work whether the app was started
    /// by launchd or from Finder (which give it a bare environment).
    static var installEnv: [String: String] {
        let url = rootDir.appendingPathComponent(".env.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }

    static var script: String? {
        if let s = ProcessInfo.processInfo.environment["LIFELOG_SCRIPT"], FileManager.default.fileExists(atPath: s) { return s }
        let installed = rootDir.appendingPathComponent("bin/lifelog.py").path
        return FileManager.default.fileExists(atPath: installed) ? installed : nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in installEnv where k != "PYTHON" { env[k] = v }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in extra where !parts.contains(p) { parts.append(p) }
        env["PATH"] = parts.joined(separator: ":")
        env["LIFELOG_DIR"] = rootDir.path
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    static var python: String {
        if let p = installEnv["PYTHON"], FileManager.default.isExecutableFile(atPath: p) { return p }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/python3"
    }

    /// Runs `lifelog <args>`; streams output lines to `onLine` and appends everything to logs/<log>.log.
    @discardableResult
    static func run(_ args: [String], log logName: String? = nil, qos: QualityOfService = .utility,
                    onLine: ((String) -> Void)? = nil, done: @escaping (Int32, String) -> Void) -> Process? {
        guard let script else {
            done(127, "The lifelog CLI isn't installed — run ./install.sh")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script] + args
        p.environment = environment
        p.qualityOfService = qos  // background-ish CPU/IO priority: keeps the laptop responsive
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        var logHandle: FileHandle?
        if let logName {
            let logURL = rootDir.appendingPathComponent("logs/\(logName).log")
            ensureDir(logURL.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            logHandle?.write("=== \(f.string(from: Date())) lifelog \(args.joined(separator: " "))\n".data(using: .utf8)!)
        }

        let lock = NSLock()
        var output = Data()
        var partial = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            logHandle?.write(chunk)
            lock.lock()
            output.append(chunk)
            if output.count > 64_000 { output = output.suffix(32_000) }
            partial += String(decoding: chunk, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            lock.unlock()
            if let onLine, let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                DispatchQueue.main.async { onLine(last.trimmingCharacters(in: .whitespaces)) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            logHandle?.write(rest)
            try? logHandle?.close()
            lock.lock()
            output.append(rest)
            let text = String(decoding: output, as: UTF8.self)
            lock.unlock()
            DispatchQueue.main.async { done(proc.terminationStatus, text) }
        }
        do {
            try p.run()
        } catch {
            done(126, "could not start \(python): \(error.localizedDescription)")
            return nil
        }
        return p
    }
}

// MARK: - privacy permissions

enum Permission: String, CaseIterable, Identifiable {
    case screen, accessibility, input, microphone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen & System Audio Recording"
        case .accessibility: return "Accessibility"
        case .input: return "Input Monitoring"
        case .microphone: return "Microphone"
        }
    }

    var why: String {
        switch self {
        case .screen: return "Screenshots of what you're doing, and the audio your Mac plays (calls, videos)."
        case .accessibility: return "Window titles and browser URLs — which chat, which tab."
        case .input: return "How much you type, click and scroll. Counts only, never which keys."
        case .microphone: return "Conversations near your laptop, transcribed on this Mac."
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "rectangle.dashed.badge.record"
        case .accessibility: return "macwindow"
        case .input: return "keyboard"
        case .microphone: return "mic"
        }
    }

    var pane: String {
        switch self {
        case .screen: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .input: return "Privacy_ListenEvent"
        case .microphone: return "Privacy_Microphone"
        }
    }

    /// Screen Recording and Input Monitoring are only picked up by a freshly started process.
    var needsRestart: Bool { self == .screen || self == .input }

    var granted: Bool {
        switch self {
        case .screen: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .input: return CGPreflightListenEventAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// First click shows the system prompt; after that macOS won't prompt again, so open the right Settings pane.
    func request(completion: @escaping () -> Void = {}) {
        let key = "asked.\(rawValue)"
        let askedBefore = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        switch self {
        case .microphone where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: completion) }
            return
        case .accessibility where !askedBefore:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .screen where !askedBefore:
            _ = CGRequestScreenCaptureAccess()
        case .input where !askedBefore:
            _ = CGRequestListenEventAccess()
        default:
            openSettings()
        }
        completion()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - start at login (the LaunchAgent install.sh registers; KeepAlive also restarts it after a crash)

enum LoginItem {
    static let label = "com.lifelog.recorder"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static var enabled: Bool {
        guard installed else { return false }
        let out = shell("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
        for line in out.split(separator: "\n") where line.contains("\"\(label)\"") {
            return !(line.contains("disabled") || line.contains("=> true"))
        }
        return true
    }

    static func set(_ on: Bool) {
        _ = shell("/bin/launchctl", [on ? "enable" : "disable", "gui/\(getuid())/\(label)"])
    }

    /// true when launchd started us (so a restart should go through launchd too)
    static var launchedByLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }
}

@discardableResult
func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

// MARK: - formatting

func fmtDuration(_ s: Double) -> String {
    let m = Int((s / 60).rounded())
    if m < 1 { return s > 0 ? "<1m" : "0m" }
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
}

func fmtAgo(_ d: Date?) -> String {
    guard let d else { return "never" }
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
    return f.string(from: d)
}

func fmtBytes(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

func fmtClock(_ ts: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

// MARK: - palette (same as the web timeline)

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ns(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

enum Category {
    static let all: [(name: String, label: String, color: Color)] = [
        ("coding & AI agents", "Coding & AI", Color(light: 0x2a78d6, dark: 0x3987e5)),
        ("communication", "Messages", Color(light: 0xeb6834, dark: 0xd95926)),
        ("voice & calls", "Talking", Color(light: 0x1baf7a, dark: 0x199e70)),
        ("social media", "Social", Color(light: 0xeda100, dark: 0xc98500)),
        ("entertainment", "Entertainment", Color(light: 0xe87ba4, dark: 0xd55181)),
        ("browsing & research", "Browsing", Color(light: 0x008300, dark: 0x008300)),
        ("writing & planning", "Writing", Color(light: 0x6250d6, dark: 0x9085e9)),
        ("other", "Other", Color(light: 0xe34948, dark: 0xe66767)),
        ("idle at desk", "Idle", Color(light: 0xb9b8b2, dark: 0x6b6b65)),
        ("away", "Away", Color(light: 0xdddcd6, dark: 0x45453f)),
        ("sleep", "Sleep", Color(light: 0x9db4d6, dark: 0x2e3f5c)),
    ]
    static func color(_ c: String) -> Color { all.first { $0.name == c }?.color ?? all[7].color }
    static func label(_ c: String) -> String { all.first { $0.name == c }?.label ?? c.capitalized }
}
