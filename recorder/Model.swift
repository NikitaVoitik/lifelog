// AppModel: everything the menu-bar UI shows, plus the scheduler that runs the pipeline
// (transcribe + Claude timeline every 30 min, R2/D1 upload every 10 min and whenever the Mac comes back online).

import AppKit
import AVFoundation
import Combine
import SwiftUI

struct Segment: Identifiable {
    let id: Int64
    let start: Double, end: Double
    let category: String, activity: String, detail: String
}

struct Voice: Identifiable {
    let id: Int64
    var name: String
    let seconds: Double
    let lastHeard: Double
    let sample: String
    var label: String { name.isEmpty ? "Voice #\(id)" : name }
}

struct JobState {
    var running = false
    var line = ""
    var lastRun: Date?
    var ok = true
    var message = ""
}

enum RecState: Equatable {
    case recording, paused(Date), asleep, needsPermission
}

final class AppModel: ObservableObject {
    let recorder: Recorder
    let network = NetworkWatcher()
    var db: DB { recorder.db }

    // live state (refreshed every second while the popover is open)
    @Published var state: RecState = .recording
    @Published var now = Context()
    @Published var screenOK = false
    @Published var micOK = false
    @Published var sysOK = false
    @Published var inputOK = false
    @Published var titlesOK = false
    @Published var micLevel: Double = 0
    @Published var framesToday = 0
    @Published var missingPermissions: [Permission] = []

    // today (refreshed every few seconds while open)
    @Published var atMacSeconds: Double = 0
    @Published var talkSeconds: Double = 0
    @Published var segments: [Segment] = []
    @Published var summary = ""
    @Published var pendingChunks = 0
    @Published var lastUpload: Date?
    @Published var uploadedBytes: Double = 0
    @Published var voices: [Voice] = []

    // pipeline jobs
    @Published var process = JobState()
    @Published var sync = JobState()

    // settings
    @Published private(set) var config: [String: Any] = [:]
    @Published var startAtLogin = false

    var visible = false { didSet { if visible { refreshAll() } } }
    private var liveTimer: Timer?
    private var slowTick = 0
    private var reloadWork: DispatchWorkItem?

    // menu-bar icon
    @Published var iconName = "record.circle"

    init(recorder: Recorder) {
        self.recorder = recorder
        config = ConfigFile.load()
        process.lastRun = UserDefaults.standard.object(forKey: "lastRun.process") as? Date
        sync.lastRun = UserDefaults.standard.object(forKey: "lastRun.sync") as? Date
        if process.lastRun == nil {  // first launch: first timeline ~2 min from now
            process.lastRun = Date().addingTimeInterval(-processInterval + 120)
        }
    }

    func start() {
        recorder.start()
        network.onOnline = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.runSync(auto: true) }
        }
        network.start()
        startAtLogin = LoginItem.enabled
        refreshAll()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        liveTimer?.tolerance = 0.2
    }

    private func tick() {
        slowTick += 1
        if visible {
            refreshLive()
            if slowTick % 5 == 0 { refreshToday() }
        } else if slowTick % 5 == 0 {
            refreshLive()  // keeps the menu-bar icon honest
        }
        if slowTick % 30 == 0 { schedule() }
    }

    func refreshAll() {
        refreshLive()
        refreshToday()
        refreshVoices()
        config = ConfigFile.load()
    }

    // MARK: live

    func refreshLive() {
        let r = recorder
        missingPermissions = Permission.allCases.filter { p in
            if p == .microphone && !r.cfg.recordMic { return false }
            return !p.granted
        }
        if r.asleep { state = .asleep }
        else if r.paused, let until = r.pausedUntil { state = .paused(until) }
        else if !Permission.screen.granted { state = .needsPermission }
        else { state = .recording }
        now = r.lastCtx
        screenOK = r.screen.running
        micOK = r.mic.running
        sysOK = r.sys.running
        inputOK = r.input.active
        titlesOK = AXIsProcessTrusted()
        framesToday = r.screen.savedSession
        // -60 dB → 0, -10 dB → 1
        micLevel = r.micDB.map { max(0, min(1, (Double($0) + 60) / 50)) } ?? 0

        let icon: String
        switch state {
        case .recording: icon = missingPermissions.isEmpty ? "record.circle" : "exclamationmark.circle"
        case .paused, .asleep: icon = "pause.circle"
        case .needsPermission: icon = "exclamationmark.circle"
        }
        if icon != iconName { iconName = icon }
    }

    // MARK: today

    var dayStart: Double { Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }

    func refreshToday() {
        let ds = dayStart
        atMacSeconds = db.scalar("SELECT COUNT(*) FROM samples WHERE ts>=? AND locked=0 AND idle<300", [ds])
        talkSeconds = db.scalar("SELECT COALESCE(SUM(ts_end-ts_start),0) FROM transcripts WHERE ts_start>=?", [ds])
        segments = db.query("SELECT id, ts_start, ts_end, category, activity, COALESCE(detail,'') FROM segments WHERE ts_end>? ORDER BY ts_start", [ds])
            .compactMap { r in
                guard let id = r[0] as? Int64, let s = num(r[1]), let e = num(r[2]) else { return nil }
                return Segment(id: id, start: max(s, ds), end: e, category: r[3] as? String ?? "other",
                               activity: r[4] as? String ?? "", detail: r[5] as? String ?? "")
            }
        summary = (db.query("SELECT text FROM daily_summaries WHERE day=?", [dayString()]).first?.first as? String) ?? ""
        pendingChunks = Int(db.scalar("SELECT COUNT(*) FROM audio_chunks WHERE transcribed=0 AND ts_end IS NOT NULL"))
        if let row = db.query("SELECT MAX(uploaded), COALESCE(SUM(bytes),0) FROM uploads").first {
            lastUpload = num(row[0]).map { Date(timeIntervalSince1970: $0) }
            uploadedBytes = num(row[1]) ?? 0
        }
    }

    func refreshVoices() {
        voices = db.query("""
            SELECT v.id, COALESCE(v.name,''), COALESCE(v.seconds,0), COALESCE(v.last_heard,0),
                   COALESCE((SELECT text FROM transcripts t WHERE t.speaker_id=v.id ORDER BY t.ts_start DESC LIMIT 1), '')
            FROM voices v ORDER BY (lower(v.name)='me') DESC, v.seconds DESC
            """).compactMap { r in
            guard let id = r[0] as? Int64 else { return nil }
            return Voice(id: id, name: r[1] as? String ?? "", seconds: num(r[2]) ?? 0, lastHeard: num(r[3]) ?? 0, sample: r[4] as? String ?? "")
        }
    }

    /// awake time only — sleep isn't part of "where did my day go"
    var categoryTotals: [(category: String, seconds: Double)] {
        var t: [String: Double] = [:]
        for s in segments where s.category != "sleep" { t[s.category, default: 0] += max(0, s.end - s.start) }
        return t.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var timelineCoversUntil: Double? { segments.map(\.end).max() }
    var sleepSeconds: Double { segments.filter { $0.category == "sleep" }.reduce(0) { $0 + $1.end - $1.start } }
    var meEnrolled: Bool { voices.contains { $0.name.lowercased() == "me" } }

    // MARK: recording controls

    func pause(minutes: Int?) { recorder.pause(minutes: minutes); refreshLive() }
    func resume() { recorder.resume(); refreshLive() }

    // MARK: pipeline jobs

    var processInterval: Double { Double(int("processEveryMinutes", 30)) * 60 }
    var syncInterval: Double { Double(int("syncEveryMinutes", 10)) * 60 }
    var cloudConfigured: Bool { !str("cloudUrl").isEmpty && !str("cloudToken").isEmpty }
    var pipelineInstalled: Bool { CLI.script != nil }

    private func schedule() {
        let now = Date()
        if !process.running, now.timeIntervalSince(process.lastRun ?? .distantPast) >= processInterval {
            runProcess(auto: true)
        }
        if !sync.running, !process.running, now.timeIntervalSince(sync.lastRun ?? .distantPast) >= syncInterval {
            runSync(auto: true)
        }
    }

    func runProcess(auto: Bool = false) {
        guard !process.running, pipelineInstalled else { return }
        if auto && ProcessInfo.processInfo.isLowPowerModeEnabled { return }  // be gentle on battery
        process.running = true
        process.line = "Starting…"
        CLI.run(["process"], log: "process", onLine: { [weak self] l in self?.process.line = l }) { [weak self] code, out in
            guard let self else { return }
            self.finish(&self.process, key: "process", code: code, out: out)
            self.refreshAll()
            self.runSync(auto: true)
        }
    }

    func runSync(auto: Bool = false) {
        guard !sync.running, pipelineInstalled, cloudConfigured else { return }
        if auto {
            if !network.online { return }
            if network.expensive && !bool("syncOnExpensiveNetwork", false) { return }
        }
        sync.running = true
        sync.line = "Starting…"
        CLI.run(["sync"], log: "sync", onLine: { [weak self] l in self?.sync.line = l }) { [weak self] code, out in
            guard let self else { return }
            self.finish(&self.sync, key: "sync", code: code, out: out)
            self.refreshToday()
        }
    }

    private func finish(_ job: inout JobState, key: String, code: Int32, out: String) {
        job.running = false
        job.lastRun = Date()
        job.ok = code == 0
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        job.message = code == 0 ? "" : (lines.last ?? "exit code \(code)")
        job.line = ""
        UserDefaults.standard.set(job.lastRun, forKey: "lastRun.\(key)")
    }

    func openLog(_ name: String) {
        let url = rootDir.appendingPathComponent("logs/\(name).log")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : rootDir.appendingPathComponent("logs"))
    }

    // MARK: timeline

    func openTimeline() {
        let report = rootDir.appendingPathComponent("reports/\(dayString()).html")
        CLI.run(["report"], qos: .userInitiated) { _, _ in
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: report.path) ? report : rootDir)
        }
    }

    func openCloud() {
        var c = URLComponents(string: str("cloudUrl"))
        c?.queryItems = [URLQueryItem(name: "token", value: str("cloudToken"))]
        if let u = c?.url { NSWorkspace.shared.open(u) }
    }

    // MARK: voices

    func renameVoice(_ v: Voice, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != v.name else { return }
        CLI.run(["voices", "name", "\(v.id)", n], qos: .userInitiated) { [weak self] _, _ in self?.refreshVoices() }
    }

    func mergeVoice(_ v: Voice, into other: Voice) {
        CLI.run(["voices", "merge", "\(v.id)", "\(other.id)"], qos: .userInitiated) { [weak self] _, _ in self?.refreshVoices() }
    }

    // MARK: settings

    /// keys the Swift recorder reads; changing them restarts capture with the new values
    static let recorderKeys: Set<String> = ["screenshotFPS", "screenshotMaxWidth", "ocrInterval", "jpegQuality", "ocr", "recordMic",
                                            "preferBuiltInMic", "recordSystemAudio", "recordAudioWhenLocked", "excludedBundleIDs",
                                            "browserAppleScriptFallback"]

    func set(_ key: String, _ value: Any) {
        ConfigFile.set(key, value)
        config[key] = value
        if Self.recorderKeys.contains(key) {
            reloadWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.recorder.reloadConfig(); self?.refreshLive() }
            reloadWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        }
    }

    func binding<T>(_ key: String, _ def: T) -> Binding<T> {
        Binding(get: { [weak self] in (self?.config[key] as? T) ?? def }, set: { [weak self] v in self?.set(key, v) })
    }

    func bool(_ k: String, _ d: Bool) -> Bool { config[k] as? Bool ?? d }
    func int(_ k: String, _ d: Int) -> Int { (config[k] as? NSNumber)?.intValue ?? d }
    func str(_ k: String) -> String { config[k] as? String ?? "" }

    func setStartAtLogin(_ on: Bool) {
        LoginItem.set(on)
        startAtLogin = LoginItem.enabled
    }

    func restartApp() {
        if LoginItem.launchedByLaunchd {
            _ = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(LoginItem.label)"])
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

func num(_ v: Any?) -> Double? {
    switch v {
    case let x as Int64: return Double(x)
    case let x as Double: return x
    default: return nil
    }
}
