// The recording side of the app: owns the capture components, the 1-second sampling tick,
// pause/resume and sleep/wake handling. No UI in here — AppModel observes it.

import AppKit
import AVFoundation

final class Recorder {
    private(set) var cfg = Config.load()
    let db: DB
    let input = InputMonitor()
    let probe = ContextProbe()
    private(set) var screen: ScreenCapturer!
    private(set) var micWriter: ChunkedAudioWriter!
    private(set) var sysWriter: ChunkedAudioWriter!
    private(set) var mic: MicRecorder!
    private(set) var sys: SystemAudioRecorder!

    private(set) var pausedUntil: Date?
    private(set) var asleep = false
    private(set) var lastCtx = Context()
    private(set) var locked = false
    private(set) var micDB: Float?
    private(set) var sysDB: Float?
    private var timer: Timer?

    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    init(db: DB) {
        self.db = db
        build()
    }

    private func build() {
        probe.useAppleScript = cfg.browserAppleScriptFallback
        screen = ScreenCapturer(db: db, cfg: cfg)
        micWriter = ChunkedAudioWriter(source: "mic", db: db, chunkSeconds: cfg.audioChunkSeconds)
        sysWriter = ChunkedAudioWriter(source: "sys", db: db, chunkSeconds: cfg.audioChunkSeconds)
        mic = MicRecorder(writer: micWriter, preferBuiltIn: cfg.preferBuiltInMic)
        sys = SystemAudioRecorder(writer: sysWriter)
    }

    func start() {
        db.event("start", "pid \(getpid())")
        _ = input.start()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.db.event("sleep")
            self?.stopRecorders()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.db.event("wake")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.asleep = false
                self?.startRecorders()
            }
        }
        startRecorders()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }

    func shutdown() {
        stopRecorders()
        db.event("stop")
    }

    /// Settings changed: rebuild the capture components with the new config.
    func reloadConfig() {
        stopRecorders()
        cfg = Config.load()
        build()
        startRecorders()
        db.event("config", "reloaded")
    }

    func startRecorders() {
        guard !paused, !asleep else { return }
        if CGPreflightScreenCaptureAccess() { screen.start() }
        startAudio()
    }

    func stopRecorders() {
        screen.stop()
        stopAudio()
    }

    func startAudio() {
        guard !paused, !asleep else { return }
        if locked && !cfg.recordAudioWhenLocked { return }
        if cfg.recordMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { mic.start() }
        if cfg.recordSystemAudio && CGPreflightScreenCaptureAccess() { sys.start() }
    }

    func stopAudio() {
        mic.stop()
        sys.stop()
    }

    /// minutes == nil → until resumed
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        db.event("pause", minutes.map { "\($0)m" } ?? "indefinite")
        stopRecorders()
    }

    func resume() {
        pausedUntil = nil
        db.event("resume")
        startRecorders()
    }

    private func tick() {
        if !input.active { _ = input.start() }
        if paused || asleep { micDB = nil; sysDB = nil; return }
        if pausedUntil != nil {  // a timed pause just ran out
            pausedUntil = nil
            db.event("resume")
            startRecorders()
        }

        let now = Date().timeIntervalSince1970
        let isLocked = screenLocked()
        if isLocked != locked {
            db.event(isLocked ? "locked" : "unlocked")
            locked = isLocked
            if !cfg.recordAudioWhenLocked { isLocked ? stopAudio() : startAudio() }
        }

        let ctx = isLocked ? Context(app: "loginwindow", bundle: "com.apple.loginwindow") : probe.current()
        let counts = input.drain()
        let idle = idleSeconds()
        mic.watchdog()
        micDB = micWriter.drainPeak()
        sysDB = sysWriter.drainPeak()
        db.run("INSERT OR REPLACE INTO samples(ts,app,bundle,title,url,idle,keys,clicks,scroll,mouse,mic_db,sys_db,locked) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
               [Int(now), ctx.app, ctx.bundle, ctx.title, ctx.url, (idle * 10).rounded() / 10,
                counts.keys, counts.clicks, counts.scroll, counts.mouse,
                micDB.map { Double(($0 * 10).rounded() / 10) }, sysDB.map { Double(($0 * 10).rounded() / 10) }, isLocked])

        let switched = ctx.app != lastCtx.app || ctx.title != lastCtx.title || ctx.url != lastCtx.url
        lastCtx = ctx
        screen.update(ctx: ctx, allowed: !isLocked && !cfg.excludedBundleIDs.contains(ctx.bundle), switched: switched)
        if !screen.running && !screen.wantRunning && CGPreflightScreenCaptureAccess() { screen.start() }
    }
}
