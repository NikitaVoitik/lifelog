// Entry point: CLI self-tests (--check, --selftest-frames, --selftest-audio, --render-ui DIR), then the menu-bar app.

import AppKit
import AVFoundation
import SwiftUI
import Vision
import VideoToolbox



ensureDir(rootDir)

if CommandLine.arguments.contains("--check") {
    print("data dir        :", rootDir.path)
    print("screen recording:", CGPreflightScreenCaptureAccess())
    print("accessibility   :", AXIsProcessTrusted())
    print("input monitoring:", CGPreflightListenEventAccess())
    print("microphone      :", AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "(3 = authorized)")
    print("built-in mic id :", builtInMicID().map(String.init) ?? "none")
    let c = ContextProbe().current()
    print("frontmost       :", c.app, "|", c.title, "|", c.url)
    print("idle (system)   :", systemIdleSeconds())
    print("locked          :", screenLocked())
    exit(0)
}

if CommandLine.arguments.contains("--selftest-frames") {
    // renders a text-heavy 1920x1200 frame into a CVPixelBuffer and times the per-frame path + OCR
    let W = 1920, H = 1200
    var pbOut: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pbOut)
    let pb = pbOut!
    func render(_ shift: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.11, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white]
        for row in 0..<55 {
            ("\(row + shift) hey opus, I want to know exactly where my time is going — scrolling twitter at 0:40, typing prompts in T3 Code " as NSString)
                .draw(at: NSPoint(x: 40, y: 20 + row * 21), withAttributes: attrs)
        }
        NSGraphicsContext.current = nil
        CVPixelBufferUnlockBaseAddress(pb, [])
    }
    let db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    let cap = ScreenCapturer(db: db, cfg: Config.load())
    var total = 0.0, bytes = 0, last: [UInt8]? = nil, changedCount = 0
    var lastImg: CGImage?
    for i in 0..<20 {
        render(i % 2 == 0 ? 0 : 1)
        let t0 = Date()
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        let th = ScreenCapturer.thumbnail(pb)
        if last == nil || ScreenCapturer.changed(th, last!) { changedCount += 1 }
        last = th
        let url = try! cap.saveForTest(cg!)
        total += Date().timeIntervalSince(t0)
        bytes += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        lastImg = cg
    }
    print(String(format: "frame path: %.1f ms/frame, %.0f KB/frame, changed %d/20", total / 20 * 1000, Double(bytes) / 20 / 1024, changedCount))
    let t1 = Date()
    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.usesLanguageCorrection = true
    try! VNImageRequestHandler(cgImage: lastImg!).perform([req])
    print(String(format: "OCR: %.0f ms, %d lines, first: %@", Date().timeIntervalSince(t1) * 1000, req.results?.count ?? 0,
                 req.results?.first?.topCandidates(1).first?.string ?? "-"))
    exit(0)
}

if CommandLine.arguments.contains("--selftest-audio") {
    // feeds 12 s of a 440 Hz tone at 48 kHz stereo through the chunk writer (3 s chunks)
    let db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    let w = ChunkedAudioWriter(source: "test", db: db, chunkSeconds: 3)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var phase: Float = 0
    for _ in 0..<(12 * 48000 / 4800) {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
        b.frameLength = 4800
        for i in 0..<4800 {
            let v = 0.2 * sin(phase); phase += 2 * .pi * 440 / 48000
            b.floatChannelData![0][i] = v; b.floatChannelData![1][i] = v
        }
        w.append(b)
        Thread.sleep(forTimeInterval: 0.1)
    }
    w.close()
    print("ok — see audio_chunks with source='test'")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    ensureDir(out)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = AppModel(recorder: Recorder(db: DB(path: rootDir.appendingPathComponent("lifelog.db").path)))
    model.refreshAll()
    model.state = .recording
    model.now = Context(app: "T3 Code", bundle: "", title: "lifelog — make it a proper menu bar app", url: "")
    model.screenOK = true; model.micOK = true; model.sysOK = true; model.inputOK = true; model.titlesOK = true
    model.micLevel = 0.55
    model.process.lastRun = Date().addingTimeInterval(-720)
    func snap<V: View>(_ name: String, _ view: V, dark: Bool) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = host.appearance
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
        print("rendered \(name) \(Int(size.width))x\(Int(size.height))")
    }
    for dark in [false, true] {
        snap("popover", PopoverView(model: model, openSettings: { _ in }, quit: {}), dark: dark)
    }
    for t in SettingsTab.allCases {
        snap("settings-\(t.title.lowercased())", t.view(model).frame(width: 580, height: t.height), dark: false)
    }
    snap("welcome", WelcomeView(model: model, done: {}), dark: false)
    exit(0)
}

if CommandLine.arguments.contains("--selftest-cli") {
    // runs `lifelog status` the way the app's scheduler does (environment, python, log file, streaming lines)
    _ = NSApplication.shared
    print("python:", CLI.python, "| script:", CLI.script ?? "NOT FOUND")
    CLI.run(["status"], log: "selftest", onLine: { print("  line>", $0) }) { code, out in
        print("exit \(code), \(out.count) bytes of output")
        exit(code)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(30))
    exit(1)
}

if let i = CommandLine.arguments.firstIndex(of: "--capture-test"), i + 3 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    _ = NSApplication.shared
    Task {
        await runCaptureTest(method: a[i + 1], seconds: Double(a[i + 2]) ?? 10, out: a[i + 3])
        exit(0)
    }
    RunLoop.main.run()
}

// single instance
let lockPath = rootDir.appendingPathComponent(".recorder.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    log("another Lifelog recorder is already running")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
signal(SIGTERM) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
app.run()
