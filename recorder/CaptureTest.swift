// Dev experiment: which capture methods make macOS show the purple screen-recording indicator?
//   open -n -W Lifelog.app --args --capture-test <method> <seconds> <outfile>
// (launched via `open` so the privacy permission is Lifelog's, not the terminal's)

import AVFoundation
import AppKit
import ScreenCaptureKit

final class StreamSink: NSObject, SCStreamOutput {
    var frames = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) { frames += 1 }
}

func runCaptureTest(method: String, seconds: Double, out: String) async {
    var lines: [String] = []
    func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lines.append("\(f.string(from: Date())) \(s)")
    }
    note("start \(method)")
    let end = Date().addingTimeInterval(seconds)
    do {
        switch method {
        case "sck-stream", "sck-audio":
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter = SCContentFilter(display: content.displays[0], excludingWindows: [])
            let conf = SCStreamConfiguration()
            let sink = StreamSink()
            if method == "sck-audio" {
                conf.capturesAudio = true; conf.width = 2; conf.height = 2
                conf.minimumFrameInterval = CMTime(value: 10, timescale: 1)
            } else {
                conf.width = 1280; conf.height = 800
                conf.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            }
            let s = SCStream(filter: filter, configuration: conf, delegate: nil)
            try s.addStreamOutput(sink, type: method == "sck-audio" ? .audio : .screen, sampleHandlerQueue: .global())
            try await s.startCapture()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            try await s.stopCapture()
            note("stream delivered \(sink.frames) buffers")
        case "sck-shot":
            var n = 0
            while Date() < end {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let filter = SCContentFilter(display: content.displays[0], excludingWindows: [])
                let conf = SCStreamConfiguration(); conf.width = 1280; conf.height = 800
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: conf)
                n += 1
                if n == 1 { note("first shot \(img.width)x\(img.height)") }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            note("took \(n) shots")
        case "cg-legacy":
            typealias Fn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { note("symbol missing"); break }
            let fn = unsafeBitCast(sym, to: Fn.self)
            var n = 0, ok = 0
            while Date() < end {
                if let img = fn(CGMainDisplayID())?.takeRetainedValue() {
                    ok += 1
                    if ok == 1 { note("first image \(img.width)x\(img.height)") }
                }
                n += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            note("\(ok)/\(n) images")
        case "screencapture":
            var n = 0, ok = 0
            while Date() < end {
                let f = "/tmp/indtest/sc_\(n).jpg"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-t", "jpg", f]
                try p.run(); p.waitUntilExit()
                if ((try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int) ?? 0) > 10_000 { ok += 1 }
                n += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            note("\(ok)/\(n) screenshots")
        case "mic":
            let e = AVAudioEngine()
            let fmt = e.inputNode.outputFormat(forBus: 0)
            var bufs = 0
            e.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { _, _ in bufs += 1 }
            try e.start()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            e.stop()
            note("mic buffers \(bufs)")
        default:
            note("unknown method")
        }
    } catch {
        note("error: \(error)")
    }
    note("end")
    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
}
