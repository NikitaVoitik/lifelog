// Lifelog recorder — records *everything* raw so an LLM can reconstruct where your time went later.
//
//  every 1s   : frontmost app, window title, browser URL, idle time, key/click/scroll/mouse counts (hardware
//               only; events other apps inject are counted separately as `synth`),
//               mic level, system-audio level, screen-locked flag            -> samples table
//  up to 1 fps: screenshot of the display under the mouse (only when it changed) + Apple Vision OCR every 10 s
//                                                                             -> media/<day>/screens, screenshots table
//  always     : microphone + system audio, 5-min AAC chunks (16 kHz mono)     -> media/<day>/audio, audio_chunks table
//
// Nothing is interpreted here. The pipeline (lifelog CLI) transcribes audio and asks Claude what happened;
// the menu-bar app (App.swift / UI.swift) schedules it and shows the results.

import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import ImageIO
import Network
import ScreenCaptureKit
import SQLite3
import UniformTypeIdentifiers
import Vision
import VideoToolbox

// MARK: - Utilities

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("[\(f.string(from: Date()))] \(msg)\n".data(using: .utf8)!)
}

let rootDir: URL = {
    if let env = ProcessInfo.processInfo.environment["LIFELOG_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Lifelog")
}()

func dayString(_ d: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

func ensureDir(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func relPath(_ url: URL) -> String {
    let root = rootDir.path.hasSuffix("/") ? rootDir.path : rootDir.path + "/"
    return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
}

// MARK: - Config

struct Config: Codable {
    var screenshotFPS: Double = 1                 // max frames/second; unchanged frames are never saved
    var screenshotMaxWidth: Int = 1920
    var ocrInterval: Double = 10                  // OCR one frame every N seconds (+ every app/tab switch)
    var jpegQuality: Double = 0.55
    var ocr: Bool = true
    var recordMic: Bool = true
    var preferBuiltInMic: Bool = true             // keeps AirPods in high-quality mode + captures the room
    var recordSystemAudio: Bool = true            // the other side of calls, videos, music
    var recordAudioWhenLocked: Bool = true
    var audioChunkSeconds: Double = 300
    var excludedBundleIDs: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    var browserAppleScriptFallback: Bool = true

    static func load() -> Config {
        let url = rootDir.appendingPathComponent("config.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let defaults = Config()
        guard let data = try? Data(contentsOf: url),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if let d = try? enc.encode(defaults) { try? d.write(to: url) }
            return defaults
        }
        // merge user keys over defaults so new options get sane values
        var merged = (try? JSONSerialization.jsonObject(with: enc.encode(defaults)) as? [String: Any]) ?? [:]
        for (k, v) in user { merged[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: merged),
           let cfg = try? JSONDecoder().decode(Config.self, from: d) {
            return cfg
        }
        log("config.json invalid, using defaults")
        return defaults
    }
}

// MARK: - SQLite

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let schemaSQL = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS samples(
  ts INTEGER PRIMARY KEY, app TEXT, bundle TEXT, title TEXT, url TEXT,
  idle REAL, keys INTEGER, clicks INTEGER, scroll INTEGER, mouse INTEGER,
  mic_db REAL, sys_db REAL, locked INTEGER);
CREATE TABLE IF NOT EXISTS screenshots(
  id INTEGER PRIMARY KEY, ts REAL, path TEXT, app TEXT, bundle TEXT, title TEXT, url TEXT,
  w INTEGER, h INTEGER, ocr TEXT);
CREATE INDEX IF NOT EXISTS screenshots_ts ON screenshots(ts);
CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(text);
CREATE TABLE IF NOT EXISTS audio_chunks(
  id INTEGER PRIMARY KEY, source TEXT, ts_start REAL, ts_end REAL, path TEXT,
  peak_db REAL, transcribed INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS audio_chunks_ts ON audio_chunks(ts_start);
CREATE TABLE IF NOT EXISTS events(ts REAL, kind TEXT, detail TEXT);
"""

final class DB {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            fatalError("cannot open db at \(path)")
        }
        sqlite3_busy_timeout(db, 10_000)
        exec(schemaSQL)
        // newer columns (the pipeline adds them too)
        let cols = Set(query("PRAGMA table_info(samples)").compactMap { $0.count > 1 ? $0[1] as? String : nil })
        if !cols.isEmpty && !cols.contains("synth") { exec("ALTER TABLE samples ADD COLUMN synth INTEGER") }
    }

    func exec(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            log("sqlite exec error: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Float: sqlite3_bind_double(stmt, idx, Double(v))
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(a!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("sqlite prepare error: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            log("sqlite step error: \(String(cString: sqlite3_errmsg(db)))")
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Rows as arrays of Int64 / Double / String / nil. Quietly returns [] if a table doesn't exist yet
    /// (the pipeline creates segments/voices/uploads on its first run).
    func query(_ sql: String, _ args: [Any?] = []) -> [[Any?]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rows: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, c)))
                default: row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalar(_ sql: String, _ args: [Any?] = []) -> Double {
        switch query(sql, args).first?.first ?? nil {
        case let v as Int64: return Double(v)
        case let v as Double: return v
        default: return 0
        }
    }

    func event(_ kind: String, _ detail: String = "") {
        run("INSERT INTO events(ts, kind, detail) VALUES(?,?,?)", [Date().timeIntervalSince1970, kind, detail])
        log("event: \(kind) \(detail)")
    }
}

// MARK: - Input activity (counts only — never which keys)
//
// Only events that came from real hardware count as "you". Anything another process injected with
// CGEvent.post (coding agents driving the cursor in UI tests, Tuck moving icons, automation tools) carries
// that process's PID in eventSourceUnixProcessID; hardware events carry 0. Injected events go into `synth`
// instead, and they don't reset the idle clock — otherwise an overnight agent test run looks like you
// clicking at the laptop for hours.

final class InputMonitor {
    private let lock = NSLock()
    private var keys = 0, clicks = 0, synth = 0
    private var scroll: Double = 0, mouse: Double = 0
    private var lastMouse: CGPoint?
    private var tap: CFMachPort?
    private var moveTap: CFMachPort?      // mouse moves/drags only; paused after each event it delivers (see handle)
    private var moveResumeScheduled = false
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var lastHuman: TimeInterval?   // systemUptime of the last hardware event the tap saw
    private var lastSynth: TimeInterval?   // … and of the last injected one
    var active: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        startedAt = ProcessInfo.processInfo.systemUptime
        // counted types + ones only used to know when you last touched anything (key-ups, modifiers, button-ups)
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        // Mouse moves come at up to ~120/s, and receiving each one through a tap (a mach message the window server
        // encodes and we decode) was the main thread's biggest cost. They get their own tap that switches itself off
        // for 200 ms after every event, so we see ≤5 moves a second; distance is the straight line between them.
        let moveTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        guard let t = makeTap(types) else { return false }
        tap = t
        moveTap = makeTap(moveTypes)
        return true
    }

    private func makeTap(_ types: [CGEventType]) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<InputMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                me.handle(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: refcon)
        else { return nil }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return t
    }

    /// called on the main run loop after each move event: pause the move tap for 200 ms
    private func throttleMoves() {
        guard let m = moveTap, !moveResumeScheduled else { return }
        CGEvent.tapEnable(tap: m, enable: false)
        moveResumeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let m = self.moveTap else { return }
            self.moveResumeScheduled = false
            CGEvent.tapEnable(tap: m, enable: true)
        }
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByUserInput && moveResumeScheduled {
            // that's us pausing the move tap (throttleMoves); just make sure the main tap is still on
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // "user input" here usually means macOS pulled Input Monitoring (e.g. after a rebuild changed the binary)
            log("input tap: disabled by \(type == .tapDisabledByTimeout ? "timeout" : "the system (check Input Monitoring)"), re-enabling")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            if let m = moveTap, !moveResumeScheduled { CGEvent.tapEnable(tap: m, enable: true) }
            return
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: throttleMoves()
        default: break
        }
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if e.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            lastSynth = now
            switch type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: synth += 1
            default: break
            }
            return
        }
        lastHuman = now
        switch type {
        case .keyUp, .flagsChanged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            break
        case .keyDown:
            if e.getIntegerValueField(.keyboardEventAutorepeat) == 0 { keys += 1 }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clicks += 1
        case .scrollWheel:
            let dy = abs(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = abs(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            scroll += dy + dx
        default:
            let p = e.location
            if let l = lastMouse { mouse += hypot(p.x - l.x, p.y - l.y) }
            lastMouse = p
        }
    }

    func drain() -> (keys: Int, clicks: Int, scroll: Int, mouse: Int, synth: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (keys, clicks, Int(scroll), Int(mouse), synth)
        keys = 0; clicks = 0; scroll = 0; mouse = 0; synth = 0
        return r
    }

    /// Seconds since *you* last touched the keyboard/mouse. The system HID idle clock is reset by injected
    /// events too, so when the most recent event was injected and nothing else happened after it, count from
    /// your last hardware event instead. Anything the tap can't see (trackpad gestures, other HID devices)
    /// still resets the system clock, and then that clock wins.
    func idleSeconds() -> Double {
        let hid = systemIdleSeconds()
        guard tap != nil else { return hid }
        lock.lock(); defer { lock.unlock() }
        guard let s = lastSynth, s > (lastHuman ?? -.infinity) else { return hid }
        let now = ProcessInfo.processInfo.systemUptime
        // the system's last event is no newer than the last injected one → it was the injected one
        guard hid >= now - s - 1.0 else { return hid }
        return max(hid, now - (lastHuman ?? startedAt))
    }
}

// MARK: - What's in front of you

struct Context: Equatable {
    var app = "", bundle = "", title = "", url = ""
    var pid: pid_t = 0
}

func axAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = axAttr(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

final class ContextProbe {
    private var manualAX = Set<pid_t>()
    private var urlCache: [String: (url: String, at: Double)] = [:]
    private var appleScriptDenied = Set<String>()
    private var browserBundles: Set<String> = []
    private var browsersRefreshed: Double = 0
    var useAppleScript = true

    private func isBrowser(_ bundle: String) -> Bool {
        let now = Date().timeIntervalSince1970
        if now - browsersRefreshed > 600 {
            browsersRefreshed = now
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            browserBundles = Set(apps.compactMap { Bundle(url: $0)?.bundleIdentifier })
            browserBundles.formUnion(["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                                      "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
                                      "net.imput.helium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                                      "org.mozilla.firefox", "app.zen-browser.zen", "ai.perplexity.comet",
                                      "com.openai.atlas", "org.chromium.Chromium", "com.kagi.kagimacOS"])
        }
        return browserBundles.contains(bundle)
    }

    func current() -> Context {
        var c = Context()
        guard let app = NSWorkspace.shared.frontmostApplication else { return c }
        c.app = app.localizedName ?? ""
        c.bundle = app.bundleIdentifier ?? ""
        c.pid = app.processIdentifier

        let axApp = AXUIElementCreateApplication(c.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        if !manualAX.contains(c.pid) {
            // makes Chromium / Electron apps expose their accessibility tree (titles, URLs)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAX.insert(c.pid)
        }
        if let win = axElement(axApp, kAXFocusedWindowAttribute) {
            c.title = (axAttr(win, kAXTitleAttribute) as? String) ?? ""
            if isBrowser(c.bundle) { c.url = browserURL(c, axApp: axApp, window: win) }
        }
        return c
    }

    private func browserURL(_ c: Context, axApp: AXUIElement, window: AXUIElement) -> String {
        let key = "\(c.pid)|\(c.title)"
        let now = Date().timeIntervalSince1970
        if let hit = urlCache[key], now - hit.at < 20 { return hit.url }
        var url = webAreaURL(axApp: axApp, window: window) ?? ""
        if url.isEmpty && useAppleScript { url = appleScriptURL(c.bundle) ?? "" }
        if urlCache.count > 500 { urlCache.removeAll() }
        urlCache[key] = (url, now)
        return url
    }

    private func urlString(_ v: AnyObject?) -> String? {
        guard let v else { return nil }
        if let u = v as? URL { return u.absoluteString }
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    private func webAreaURL(axApp: AXUIElement, window: AXUIElement) -> String? {
        // 1) walk up from the focused element (cheap when focus is inside the page)
        if var el = axElement(axApp, kAXFocusedUIElementAttribute) {
            for _ in 0..<40 {
                if (axAttr(el, kAXRoleAttribute) as? String) == "AXWebArea", let u = urlString(axAttr(el, "AXURL")) { return u }
                guard let p = axElement(el, kAXParentAttribute) else { break }
                el = p
            }
        }
        // 2) bounded breadth-first search of the window
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < 600 {
            let el = queue.removeFirst()
            visited += 1
            if (axAttr(el, kAXRoleAttribute) as? String) == "AXWebArea" {
                if let u = urlString(axAttr(el, "AXURL")) { return u }
                continue
            }
            if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }

    private func appleScriptURL(_ bundle: String) -> String? {
        if appleScriptDenied.contains(bundle) { return nil }
        let src: String
        switch bundle {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS":
            src = "tell application id \"\(bundle)\" to get URL of front document"
        case "org.mozilla.firefox", "app.zen-browser.zen":
            return nil
        default:
            src = "tell application id \"\(bundle)\" to get URL of active tab of front window"
        }
        var err: NSDictionary?
        let res = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 || code == -1728 || code == -2741 || code == -1708 { appleScriptDenied.insert(bundle) }
            return nil
        }
        return res?.stringValue
    }
}

func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) == 1)
}

/// System-wide HID idle — includes events other processes injected; prefer InputMonitor.idleSeconds()
func systemIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: - Screenshots (1–2 fps via a ScreenCaptureKit stream) + OCR

/// A low-rate SCStream on the display under the mouse. macOS only delivers a new frame when the screen
/// actually changed, the GPU does the downscale, and we drop near-identical frames — so a static screen costs ~nothing.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let db: DB
    private let cfg: Config
    private var stream: SCStream?
    private var starting = false
    private(set) var running = false
    private(set) var displayID: CGDirectDisplayID = 0
    var wantRunning = false
    private let frameQueue = DispatchQueue(label: "frames", qos: .utility)
    private let ocrQueue = DispatchQueue(label: "ocr", qos: .utility)

    // shared between main thread (tick) and frame queue
    private let lock = NSLock()
    private var ctx = Context()
    private var allowed = false
    private var forceNext = false
    private var lastThumb: [UInt8]?
    private var lastOCRAt: Double = 0
    private var ocrBusy = false
    private var ocrStartedAt: Double = 0
    private var ocrReq: VNRecognizeTextRequest?
    private var ocrFails = 0, ocrFailLoggedAt: Double = 0
    /// Explicit languages, not automaticallyDetectsLanguage: auto-detection loads an extra model that took 40–95 s per
    /// frame (and inside the recorder failed every time with an e5rt error), which silently stopped OCR from Nov 3 to Nov 4.
    static let ocrLanguages: [String] = {
        let supported = Set((try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [])
        return ["en-US", "ru-RU"].filter { supported.isEmpty || supported.contains($0) }
    }()
    private(set) var savedSession = 0
    private(set) var lastError: String?

    /// System audio rides on this same stream (capturesAudio) instead of a second SCStream: every live capture
    /// session makes macOS's privacy-indicator update slower, and each user screenshot waits for that update
    /// before grabbing pixels — a second stream cost ~0.5 s per ⌘⇧4/⌘⇧5 screenshot.
    private let audioSink: ChunkedAudioWriter?
    private let audioQueue = DispatchQueue(label: "sysaudio", qos: .utility)
    private var audioOn = false  // guarded by lock; toggled by SystemAudioRecorder (e.g. off while locked)

    init(db: DB, cfg: Config, audio: ChunkedAudioWriter? = nil) { self.db = db; self.cfg = cfg; self.audioSink = audio }

    func setAudio(_ on: Bool) {
        lock.withLock { audioOn = on }
        if !on { audioSink?.close() }
    }

    var audioActive: Bool { running && audioSink != nil && lock.withLock { audioOn } }

    /// called every second from the main tick
    func update(ctx: Context, allowed: Bool, switched: Bool) {
        lock.lock()
        self.ctx = ctx
        self.allowed = allowed
        if switched { forceNext = true }
        lock.unlock()
        if running, !starting, let d = Self.displayUnderMouse(), d != displayID { retarget() }
    }

    static func displayUnderMouse() -> CGDirectDisplayID? {
        let p = CGEvent(source: nil)?.location ?? .zero
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &count) == .success && count > 0 ? id : nil
    }

    private func makeFilterAndConfig() async throws -> (SCContentFilter, SCStreamConfiguration, CGDirectDisplayID) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw NSError(domain: "lifelog", code: 1, userInfo: [NSLocalizedDescriptionKey: "no displays"]) }
        let want = Self.displayUnderMouse()
        let display = content.displays.first { $0.displayID == want } ?? content.displays[0]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let conf = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        let pxW = Double(display.width) * scale, pxH = Double(display.height) * scale
        let w = min(Double(cfg.screenshotMaxWidth), pxW)
        conf.width = Int(w)
        conf.height = Int(pxH * w / pxW)
        let fps = max(0.1, min(cfg.screenshotFPS, 4))
        conf.minimumFrameInterval = CMTime(value: CMTimeValue(1000 / fps), timescale: 1000)
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.showsCursor = true
        if audioSink != nil {
            conf.capturesAudio = true
            conf.excludesCurrentProcessAudio = true
            // what the chunk writer stores anyway: macOS hands over 1/6 of the data and we skip resampling it
            conf.sampleRate = Int(ChunkedAudioWriter.sampleRate)
            conf.channelCount = 1
        } else {
            conf.capturesAudio = false
        }
        conf.queueDepth = 4
        return (filter, conf, display.displayID)
    }

    func start() {
        guard !running, !starting else { return }
        wantRunning = true
        starting = true
        Task {
            defer { DispatchQueue.main.async { self.starting = false } }
            do {
                let (filter, conf, did) = try await self.makeFilterAndConfig()
                let s = SCStream(filter: filter, configuration: conf, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                if self.audioSink != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue) }
                try await s.startCapture()
                if !self.wantRunning { try? await s.stopCapture(); return }
                self.stream = s
                self.displayID = did
                self.running = true
                self.lock.withLock { self.forceNext = true }
                log("screen: capturing display \(did) at \(conf.width)x\(conf.height), \(self.cfg.screenshotFPS) fps max")
            } catch {
                self.lastError = error.localizedDescription
                log("screen: start failed: \(error.localizedDescription)")
                self.scheduleRetry()
            }
        }
    }

    private func retarget() {
        guard let s = stream else { return }
        starting = true
        Task {
            defer { DispatchQueue.main.async { self.starting = false } }
            do {
                let (filter, conf, did) = try await self.makeFilterAndConfig()
                try await s.updateConfiguration(conf)
                try await s.updateContentFilter(filter)
                self.displayID = did
                self.lock.withLock { self.forceNext = true; self.lastThumb = nil }
            } catch {
                log("screen: retarget failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.wantRunning, !self.running else { return }
            self.start()
        }
    }

    func stop() {
        wantRunning = false
        let s = stream
        stream = nil
        running = false
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("screen: stream stopped: \(error.localizedDescription)")
        audioSink?.close()
        DispatchQueue.main.async {
            self.running = false
            self.stream = nil
            self.scheduleRetry()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard let sink = audioSink, lock.withLock({ audioOn }), let pcm = SystemAudioRecorder.pcm(sb) else { return }
            sink.append(pcm)
            return
        }
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer
        else { return }
        handleFrame(pb)
    }

    /// one delivered frame: drop it if nothing changed, else save a JPEG (+ OCR now and then). Also called by bench/.
    func handleFrame(_ pb: CVPixelBuffer) {
        lock.lock()
        let ctx = self.ctx, allowed = self.allowed, force = self.forceNext
        lock.unlock()
        guard allowed else { return }

        // decide from the raw pixels first: most delivered frames are dropped and never need a CGImage
        let thumb = Self.thumbnail(pb)
        if !force, let last = lastThumb, !Self.changed(thumb, last) { return }
        guard let img = Self.cpuImage(pb) else { return }
        lastThumb = thumb
        lock.lock(); forceNext = false; lock.unlock()

        let ts = Date().timeIntervalSince1970
        do {
            let url = try save(img, ts: ts)
            let id = db.run("INSERT INTO screenshots(ts,path,app,bundle,title,url,w,h) VALUES(?,?,?,?,?,?,?,?)",
                            [ts, relPath(url), ctx.app, ctx.bundle, ctx.title, ctx.url, img.width, img.height])
            savedSession += 1
            lastError = nil
            if ocrBusy && ts - ocrStartedAt > 60 {  // a hung Vision call would otherwise stop OCR for good
                log("ocr: stuck for \(Int(ts - ocrStartedAt)) s, cancelling")
                ocrReq?.cancel(); ocrStartedAt = ts
            }
            if cfg.ocr && !ocrBusy && (force || ts - lastOCRAt >= cfg.ocrInterval) {
                lastOCRAt = ts
                ocr(img, id: id)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveForTest(_ img: CGImage) throws -> URL { try save(img, ts: Date().timeIntervalSince1970) }

    private func save(_ img: CGImage, ts: Double) throws -> URL {
        let d = Date(timeIntervalSince1970: ts)
        let dir = rootDir.appendingPathComponent("media/\(dayString(d))/screens")
        ensureDir(dir)
        let f = DateFormatter()
        f.dateFormat = "HHmmss_SSS"
        let url = dir.appendingPathComponent("\(f.string(from: d)).jpg")
        // encode in memory and write once: straight to a file, ImageIO issues hundreds of small writes per frame
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "lifelog", code: 2)
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: cfg.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "lifelog", code: 3) }
        try data.write(to: url)
        return url
    }

    /// The frame as a CGImage over ordinary memory. ScreenCaptureKit's IOSurface is slow for the CPU to read in the
    /// scattered pattern the JPEG encoder and Vision use (it made encoding ~2.6x slower than from a copy); one
    /// sequential copy is cheaper. Keeps the frame's colour space so the JPEG is tagged as before.
    static func cpuImage(_ pb: CVPixelBuffer) -> CGImage? {
        var vtOut: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &vtOut)
        guard let vt = vtOut, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return vtOut }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(pb) else { return vt }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), srb = CVPixelBufferGetBytesPerRow(pb)
        let rb = w * 4
        guard let copy = CFDataCreateMutable(nil, rb * h) else { return vt }
        CFDataSetLength(copy, rb * h)
        let dst = CFDataGetMutableBytePtr(copy)!
        if srb == rb { memcpy(dst, src, rb * h) } else { for y in 0..<h { memcpy(dst + y * rb, src + y * srb, rb) } }
        guard let provider = CGDataProvider(data: copy) else { return vt }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rb,
                       space: vt.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: vt.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) ?? vt
    }

    /// OCR only every `ocrInterval` seconds (and on every app/tab switch) — frames in between are kept as images only.
    static func ocrRequest(_ level: VNRequestTextRecognitionLevel = .accurate) -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        // off: ~62% less CPU per pass (241 → 92 ms on real frames) for ~94% of the same words; screen text is full of
        // code, names and URLs that correction doesn't help with anyway
        req.usesLanguageCorrection = false
        req.recognitionLanguages = Self.ocrLanguages
        return req
    }

    /// reading order: top to bottom, then left to right
    static func ocrText(_ req: VNRecognizeTextRequest) -> String {
        let obs = (req.results ?? []).sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) > 0.01 { return a.midY > b.midY }
            return a.minX < b.minX
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Accurate OCR runs a Core ML model that macOS sometimes can't load for hours (e5rtError … 13, system-wide, until a
    /// restart), which used to mean no screen text at all. When it fails, the frame is redone in .fast mode (Vision's
    /// older engine, no Core ML) and fast is used until accurate is tried again 15 min later. Only touched on ocrQueue.
    private var accurateRetryAt: Double = 0
    static let accurateRetrySeconds: Double = 900

    /// runs the OCR (on the calling thread); nil = failed in both modes
    private func recognize(_ img: CGImage, track req: ((VNRecognizeTextRequest) -> Void)? = nil) -> (text: String, level: String)? {
        let now = Date().timeIntervalSince1970
        var firstError: Error?
        if now >= accurateRetryAt {
            let r = Self.ocrRequest(.accurate)
            req?(r)
            do {
                try VNImageRequestHandler(cgImage: img).perform([r])
                if accurateRetryAt > 0 { log("ocr: accurate mode works again"); accurateRetryAt = 0 }
                return (Self.ocrText(r), "accurate")
            } catch {
                if error is CancellationError { return nil }
                if accurateRetryAt == 0 { log("ocr: accurate mode failed (\(error)); using fast mode, retrying accurate every 15 min") }
                accurateRetryAt = now + Self.accurateRetrySeconds
                firstError = error
            }
        }
        let r = Self.ocrRequest(.fast)
        req?(r)
        do {
            try VNImageRequestHandler(cgImage: img).perform([r])
            return (Self.ocrText(r), "fast")
        } catch {
            if firstError == nil { firstError = error }
        }
        if let e = firstError { lastOCRError = "\(e)" }
        return nil
    }
    private var lastOCRError = ""

    func ocrForBench(_ img: CGImage) -> (text: String, level: String)? { recognize(img) }

    private func ocr(_ img: CGImage, id: Int64) {
        ocrBusy = true; ocrStartedAt = Date().timeIntervalSince1970
        ocrQueue.async {
            defer { self.frameQueue.async { self.ocrBusy = false; self.ocrReq = nil } }
            if let res = self.recognize(img, track: { r in self.frameQueue.async { self.ocrReq = r } }) {
                self.db.run("UPDATE screenshots SET ocr=? WHERE id=?", [res.text, id])
                self.db.run("INSERT INTO ocr_fts(rowid, text) VALUES(?,?)", [id, res.text])
                self.frameQueue.async { self.ocrFails = 0 }
            } else {
                let now = Date().timeIntervalSince1970, err = self.lastOCRError
                self.frameQueue.async {  // one line per 10 min while it keeps failing, not one per frame
                    self.ocrFails += 1
                    if self.ocrFails == 1 || now - self.ocrFailLoggedAt > 600 {
                        self.ocrFailLoggedAt = now
                        log("ocr failed (\(self.ocrFails) in a row): \(err)")
                    }
                }
            }
        }
    }

    static let thumbW = 96, thumbH = 60

    /// 96x60 grey thumbnail straight from the BGRA frame: each cell is the mean luma of every 2nd pixel of every 2nd row
    /// in it. Same job as drawing the frame into a 96x60 grey CGContext, which colour-converted and resampled all
    /// 2.4 M pixels on every delivered frame and was ~70% of the recorder's CPU.
    static func thumbnail(_ pb: CVPixelBuffer) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: thumbW * thumbH)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return px }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        guard w >= thumbW * 2, h >= thumbH * 2 else { return px }
        // cell c covers pixel columns [x0[c], x0[c+1]) and rows [y0[r], y0[r+1]); we read even columns of even rows
        let x0 = (0...thumbW).map { $0 * w / thumbW }, y0 = (0...thumbH).map { $0 * h / thumbH }
        var row = [UInt32](repeating: 0, count: thumbW)
        for r in 0..<thumbH {
            for c in 0..<thumbW { row[c] = 0 }
            var rows: UInt32 = 0
            for y in stride(from: (y0[r] + 1) & ~1, to: y0[r + 1], by: 2) {
                let line = base + y * rb
                rows += 1
                for c in 0..<thumbW {
                    var sum: UInt32 = 0
                    var p = line + ((x0[c] + 1) & ~1) * 4
                    let end = line + x0[c + 1] * 4
                    while p < end {  // BGRA → luma, BT.601 weights ×256
                        sum &+= UInt32(p[0]) &* 29 &+ UInt32(p[1]) &* 150 &+ UInt32(p[2]) &* 77
                        p += 8
                    }
                    row[c] &+= sum
                }
            }
            // flip vertically so cell order matches CoreGraphics' bottom-left origin (keeps old/new thumbs comparable)
            let out = (thumbH - 1 - r) * thumbW
            for c in 0..<thumbW {
                let n = rows * UInt32((x0[c + 1] - ((x0[c] + 1) & ~1) + 1) / 2)
                px[out + c] = n > 0 ? UInt8(min(255, row[c] / n / 256)) : 0
            }
        }
        return px
    }

    /// "changed" = at least 3 thumbnail cells moved noticeably. Filters out caret blink and clock ticks,
    /// keeps typing, scrolling, new messages.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        var n = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 10 {
            n += 1
            if n >= 3 { return true }
        }
        return false
    }
}

// MARK: - Network (so uploads start as soon as you're online, and skip hotspots)

final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var wasOnline = false
    private(set) var online = false
    private(set) var expensive = false
    /// called on the main queue when the Mac (re)gains a connection
    var onOnline: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            let info: [String: Any] = ["online": online, "expensive": path.isExpensive, "constrained": path.isConstrained,
                                       "ts": Date().timeIntervalSince1970]
            if let d = try? JSONSerialization.data(withJSONObject: info) {
                try? d.write(to: rootDir.appendingPathComponent(".network.json"))
            }
            let cameOnline = online && !self.wasOnline
            self.wasOnline = online
            DispatchQueue.main.async {
                self.online = online
                self.expensive = path.isExpensive
                if cameOnline { self.onOnline?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net"))
    }
}

// MARK: - Audio

/// Accepts PCM buffers in any format, writes 16 kHz mono AAC chunks aligned to wall-clock boundaries.
final class ChunkedAudioWriter {
    let source: String
    private let db: DB
    private let chunkSeconds: Double
    private let lock = NSLock()
    static let sampleRate: Double = 16000
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var pending: AVAudioPCMBuffer?  // converted audio not written yet (see stage)
    private var converter: AVAudioConverter?
    private var converterIn: AVAudioFormat?
    private var file: AVAudioFile?
    private var chunkId: Int64 = 0
    private var chunkSlot: Int = -1
    private var chunkPeak: Float = -160
    private var secondPeak: Float = -160
    private(set) var lastBufferAt: Double = 0

    init(source: String, db: DB, chunkSeconds: Double) {
        self.source = source; self.db = db; self.chunkSeconds = chunkSeconds
    }

    /// peak level (dBFS) since the last call
    func drainPeak() -> Float? {
        lock.lock(); defer { lock.unlock() }
        let p = secondPeak
        secondPeak = -160
        return Date().timeIntervalSince1970 - lastBufferAt < 3 ? p : nil
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        lastBufferAt = now
        let level = Self.peakDB(buf)
        secondPeak = max(secondPeak, level)

        let slot = Int(now / chunkSeconds)
        if file == nil || slot != chunkSlot {
            closeLocked()
            openLocked(now: now, slot: slot, bufferDuration: Double(buf.frameLength) / buf.format.sampleRate)
        }
        chunkPeak = max(chunkPeak, level)

        if converterIn != buf.format {
            converter = AVAudioConverter(from: buf.format, to: outFormat)
            converterIn = buf.format
        }
        guard let converter, let file else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if err == nil && out.frameLength > 0 { stage(out, to: file) }
    }

    /// Converted audio is collected for ~1 s and written in one go: writing each 20–90 ms capture buffer as it came
    /// meant an AAC encode call and a file write per buffer, dozens of times a second.
    private func stage(_ out: AVAudioPCMBuffer, to file: AVAudioFile) {
        if pending == nil { pending = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Self.sampleRate)) }
        guard let p = pending else { return }
        var from: AVAudioFrameCount = 0
        while from < out.frameLength {
            let n = min(out.frameLength - from, p.frameCapacity - p.frameLength)
            memcpy(p.floatChannelData![0] + Int(p.frameLength), out.floatChannelData![0] + Int(from), Int(n) * 4)
            p.frameLength += n
            from += n
            if p.frameLength == p.frameCapacity { flushLocked(file) }
        }
    }

    private func flushLocked(_ file: AVAudioFile?) {
        guard let p = pending, p.frameLength > 0, let file else { return }
        do { try file.write(from: p) } catch { log("\(source) write error: \(error)") }
        p.frameLength = 0
    }

    private func openLocked(now: Double, slot: Int, bufferDuration: Double) {
        let start = now - bufferDuration
        let d = Date(timeIntervalSince1970: start)
        let dir = rootDir.appendingPathComponent("media/\(dayString(d))/audio")
        ensureDir(dir)
        let f = DateFormatter()
        f.dateFormat = "HHmmss_SSS"
        let url = dir.appendingPathComponent("\(f.string(from: d))_\(source).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            chunkSlot = slot
            chunkPeak = -160
            chunkId = db.run("INSERT INTO audio_chunks(source, ts_start, path) VALUES(?,?,?)", [source, start, relPath(url)])
        } catch {
            log("\(source) cannot open \(url.path): \(error)")
            file = nil
        }
    }

    private func closeLocked() {
        guard file != nil else { return }
        flushLocked(file)
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        db.run("UPDATE audio_chunks SET ts_end=?, peak_db=? WHERE id=?", [lastBufferAt, chunkPeak, chunkId])
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    static func peakDB(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return -160 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        let p = ch[0]
        for i in 0..<n { sum += p[i] * p[i] }
        let rms = sqrt(sum / Float(n))
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}

func builtInMicID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var t: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { continue }
        var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                               mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var ssize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize) == noErr, ssize > 0 { return id }
    }
    return nil
}

final class MicRecorder {
    let writer: ChunkedAudioWriter
    private var engine: AVAudioEngine?
    private let preferBuiltIn: Bool
    private var observer: NSObjectProtocol?
    private(set) var running = false
    private var wanted = false          // the controller wants the mic on (survives internal restarts)
    private var startedAt: Double = 0
    private var stalls = 0
    private var lastAttempt: Double = 0

    init(writer: ChunkedAudioWriter, preferBuiltIn: Bool) {
        self.writer = writer; self.preferBuiltIn = preferBuiltIn
    }

    func start() {
        wanted = true
        guard !running else { return }
        lastAttempt = Date().timeIntervalSince1970
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var selected: AudioDeviceID?
        if preferBuiltIn, var dev = builtInMicID(), let au = input.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { log("mic: could not select built-in mic (\(st)), using default input") } else { selected = dev }
        }
        var fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            log("mic: no input device available")
            return
        }
        // after selecting the built-in mic, the node's output side can still report the default input's format
        // (AirPods: 24 kHz) while the hardware side runs at the built-in's rate (48 kHz); a tap in the stale format
        // gets nothing, so tap at the hardware-side rate
        let hw = input.inputFormat(forBus: 0).sampleRate
        if selected != nil, hw > 0, abs(hw - fmt.sampleRate) > 1,
           let f = AVAudioFormat(standardFormatWithSampleRate: hw, channels: fmt.channelCount) {
            fmt = f
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.writer.append(buf)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log("mic: start failed: \(error)")
            input.removeTap(onBus: 0)
            return
        }
        self.engine = engine
        running = true
        startedAt = Date().timeIntervalSince1970
        let t0 = Date()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // selecting the built-in mic above fires this once or twice right after start — not a real device change
            if Date().timeIntervalSince(t0) < 3 {
                if !engine.isRunning { try? engine.start() }  // the engine stops itself on this notification
                if engine.isRunning { return }
            }
            log("mic: audio configuration changed, restarting")
            self?.restart()
        }
        log("mic: recording (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch)")
    }

    func stop() {
        wanted = false
        halt()
    }

    /// called every second: restart a mic that's on but delivering nothing, or retry one that failed to start
    func watchdog() {
        guard wanted else { return }
        let now = Date().timeIntervalSince1970
        if !running {
            if now - lastAttempt > 5 { start() }
            return
        }
        if now - writer.lastBufferAt < 3 { stalls = 0; return }
        let limit = min(10 * pow(2, Double(stalls)), 300)  // 10 s, 20 s, 40 s … if it keeps failing
        if now - max(writer.lastBufferAt, startedAt) > limit {
            stalls += 1
            log("mic: no audio for \(Int(limit))s, restarting")
            restart()
        }
    }

    private func restart() {
        halt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.wanted == true { self?.start() }
        }
    }

    private func halt() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        writer.close()
    }
}

/// System audio. Captured by ScreenCapturer's stream (see ScreenCapturer.audioSink) rather than an SCStream of its
/// own; this just switches it on and off so the controller's start/stop/locked rules stay the same.
final class SystemAudioRecorder {
    let writer: ChunkedAudioWriter
    private let screen: ScreenCapturer
    var running: Bool { screen.audioActive }

    init(writer: ChunkedAudioWriter, screen: ScreenCapturer) { self.writer = writer; self.screen = screen }

    func start() {
        guard !running else { return }
        screen.setAudio(true)
        log("system audio: recording (on the screen stream)")
    }

    func stop() { screen.setAudio(false) }

    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sb.isValid, let desc = sb.formatDescription else { return nil }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return st == noErr ? pcm : nil
    }
}
