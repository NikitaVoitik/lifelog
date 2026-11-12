// Recorder micro-benchmarks: replays real recorded data through the recorder's own code paths and reports
// CPU time (this process, user+sys) per unit of work. Build + run with bench/recorder.sh.
//
//   frames <screens dir> <n>   replay n real screenshots as BGRA IOSurface frames; every real frame is followed by a
//                              near-duplicate (2 px caret blink) like the ones ScreenCaptureKit delivers between changes
//   audio  <m4a> <seconds>     system-audio path: 48 kHz stereo 1024-frame CMSampleBuffers → pcm() → ChunkedAudioWriter
//   mic    <m4a> <seconds>     mic path: 48 kHz mono 4096-frame AVAudioPCMBuffers → ChunkedAudioWriter
//   ocr    <screens dir> <n>   the recorder's OCR request on n real screenshots
//   tick   <seconds>           the 1-second sampler's work minus AX (sample insert), at full speed
//   thumbs <screens dir> <n>   does the change detector keep/drop the same frames as the original CoreGraphics
//                              thumbnail? (consecutive real frames + synthetic edits from a caret blink to a word)

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Vision
import VideoToolbox

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func maxRSSMB() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
}

func report(_ name: String, _ fields: [String: Any]) {
    var f = fields
    f["bench"] = name
    f["max_rss_mb"] = (maxRSSMB() * 10).rounded() / 10
    let d = try! JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
}

func dirSize(_ url: URL) -> (Int, Int) {
    let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return (files.count, files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
}

func loadFrames(_ dir: String, _ n: Int) -> [CVPixelBuffer] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
    var out: [CVPixelBuffer] = []
    for name in names.prefix(n) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir).appendingPathComponent(name) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        var pbOut: CVPixelBuffer?
        CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pbOut)
        guard let pb = pbOut else { continue }
        CVPixelBufferLockBaseAddress(pb, [])
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        // what ScreenCaptureKit attaches: the display's color space
        if let icc = cs.copyICCData() { CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, icc, .shouldPropagate) }
        out.append(pb)
    }
    return out
}

/// the original thumbnail: draw the frame into a 96x60 grey CGContext (the reference for `thumbs`)
func referenceThumbnail(_ pb: CVPixelBuffer) -> [UInt8] {
    var cgOut: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgOut)
    let tw = ScreenCapturer.thumbW, th = ScreenCapturer.thumbH
    var px = [UInt8](repeating: 0, count: tw * th)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(cgOut!, in: CGRect(x: 0, y: 0, width: tw, height: th))
    }
    return px
}

/// copy of src with a w x h block at (x, y) inverted
func edited(_ src: CVPixelBuffer, x: Int, y: Int, w bw: Int, h bh: Int) -> CVPixelBuffer {
    var pbOut: CVPixelBuffer?
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pbOut)
    let pb = pbOut!
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(pb, [])
    let rb = CVPixelBufferGetBytesPerRow(src), rd = CVPixelBufferGetBytesPerRow(pb)
    let s = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self)
    let d = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for yy in 0..<h { memcpy(d + yy * rd, s + yy * rb, w * 4) }
    for yy in y..<min(h, y + bh) { for xx in x..<min(w, x + bw) { for c in 0..<3 { d[yy * rd + xx * 4 + c] ^= 0xFF } } }
    CVPixelBufferUnlockBaseAddress(pb, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
    if let a = CVBufferCopyAttachment(src, kCVImageBufferICCProfileKey, nil) { CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, a, .shouldPropagate) }
    return pb
}

func benchThumbs(_ dir: String, _ n: Int) {
    let frames = loadFrames(dir, n)
    var agree = 0, total = 0, oldKeeps = 0, newKeeps = 0
    var bySize: [String: (Int, Int, Int)] = [:]  // size → (old keeps, new keeps, cases)
    var rng = SystemRandomNumberGenerator()
    func check(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ label: String) {
        let o = ScreenCapturer.changed(referenceThumbnail(a), referenceThumbnail(b))
        let nw = ScreenCapturer.changed(ScreenCapturer.thumbnail(a), ScreenCapturer.thumbnail(b))
        total += 1; if o == nw { agree += 1 }; if o { oldKeeps += 1 }; if nw { newKeeps += 1 }
        var e = bySize[label] ?? (0, 0, 0); e.0 += o ? 1 : 0; e.1 += nw ? 1 : 0; e.2 += 1; bySize[label] = e
    }
    for i in 1..<frames.count { check(frames[i - 1], frames[i], "real consecutive") }
    let W = CVPixelBufferGetWidth(frames[0]), H = CVPixelBufferGetHeight(frames[0])
    for f in frames.prefix(60) {
        for (bw, bh) in [(2, 14), (9, 16), (30, 16), (60, 16), (120, 16), (40, 40)] {
            let pb = edited(f, x: Int.random(in: 0..<(W - bw), using: &rng), y: Int.random(in: 0..<(H - bh), using: &rng), w: bw, h: bh)
            check(f, pb, "edit \(bw)x\(bh)")
        }
    }
    report("thumbs", ["cases": total, "agree_pct": Double(agree) / Double(total) * 100, "old_keeps": oldKeeps, "new_keeps": newKeeps,
                      "by_case": bySize.mapValues { "old \($0.0)/\($0.2) new \($0.1)/\($0.2)" }])
}

/// copy with a 2x14 px block inverted (a caret blink): the kind of frame that must NOT be saved
func caretBlink(_ src: CVPixelBuffer) -> CVPixelBuffer {
    var pbOut: CVPixelBuffer?
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pbOut)
    let pb = pbOut!
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(pb, [])
    let rb = CVPixelBufferGetBytesPerRow(src), rd = CVPixelBufferGetBytesPerRow(pb)
    let s = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self)
    let d = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { memcpy(d + y * rd, s + y * rb, w * 4) }
    for y in (h / 2)..<(h / 2 + 14) { for x in (w / 3)..<(w / 3 + 2) { for c in 0..<3 { d[y * rd + x * 4 + c] ^= 0xFF } } }
    CVPixelBufferUnlockBaseAddress(pb, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
    if let a = CVBufferCopyAttachment(src, kCVImageBufferICCProfileKey, nil) { CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, a, .shouldPropagate) }
    return pb
}

func benchFrames(_ dir: String, _ n: Int) {
    let frames = loadFrames(dir, n)
    let blinks = frames.map(caretBlink)
    var cfg = Config()
    cfg.ocr = false
    let cap = ScreenCapturer(db: DB(path: rootDir.appendingPathComponent("lifelog.db").path), cfg: cfg)
    cap.update(ctx: Context(app: "Bench", bundle: "bench", title: "t", url: ""), allowed: true, switched: false)
    // warm-up (codec/colour-conversion setup) on a frame not in the measured run
    cap.handleFrame(blinks[0]); cap.handleFrame(frames[0])
    let screens = rootDir.appendingPathComponent("media/\(dayString())/screens")
    let (n0, b0) = dirSize(screens)
    let c0 = cpuSeconds(), w0 = Date()
    for i in 1..<frames.count {
        cap.handleFrame(frames[i])
        cap.handleFrame(blinks[i])
    }
    let cpu = cpuSeconds() - c0, wall = Date().timeIntervalSince(w0)
    let (n1, b1) = dirSize(screens)
    let delivered = (frames.count - 1) * 2, saved = n1 - n0
    // stage breakdown (CPU ms per frame), outside the measured run
    let k = min(60, frames.count)
    var t = cpuSeconds()
    for f in frames.prefix(k) { _ = ScreenCapturer.thumbnail(f) }
    let thumbMs = (cpuSeconds() - t) / Double(k) * 1000
    var imgs: [CGImage] = []
    t = cpuSeconds()
    for f in frames.prefix(k) { var c: CGImage?; VTCreateCGImageFromCVPixelBuffer(f, options: nil, imageOut: &c); imgs.append(c!) }
    let cgMs = (cpuSeconds() - t) / Double(k) * 1000
    t = cpuSeconds()
    for i in imgs { _ = try? cap.saveForTest(i) }
    let jpegMs = (cpuSeconds() - t) / Double(k) * 1000
    report("frames", ["delivered": delivered, "saved": saved, "cpu_ms_per_delivered": cpu / Double(delivered) * 1000,
                      "cpu_ms_per_saved": cpu / Double(max(saved, 1)) * 1000, "wall_s": wall,
                      "kb_per_saved": Double(b1 - b0) / Double(max(saved, 1)) / 1024,
                      "stage_thumb_ms": thumbMs, "stage_cgimage_ms": cgMs, "stage_jpeg_ms": jpegMs])
}

/// 16 kHz mono file → `seconds` of 48 kHz audio with `channels` channels, as float32 non-interleaved
func loadAudio(_ path: String, seconds: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: src)
    let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels)!
    let total = AVAudioFrameCount(seconds * 48000)
    let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: total)!
    let conv = AVAudioConverter(from: src.format, to: outFmt)!
    let up = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * 48000 / src.format.sampleRate) + 1024)!
    var fed = false
    conv.convert(to: up, error: nil) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return src
    }
    // loop the file to the requested length
    var pos: AVAudioFrameCount = 0
    while pos < total {
        let n = min(up.frameLength, total - pos)
        for c in 0..<Int(channels) { memcpy(out.floatChannelData![c] + Int(pos), up.floatChannelData![c], Int(n) * 4) }
        pos += n
    }
    out.frameLength = total
    return out
}

func sampleBuffer(_ pcm: AVAudioPCMBuffer, from: Int, frames: Int) -> CMSampleBuffer {
    var asbd = pcm.format.streamDescription.pointee
    var fmtDesc: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                   extensions: nil, formatDescriptionOut: &fmtDesc)
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateWithPacketDescriptions(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                                    refcon: nil, formatDescription: fmtDesc!, sampleCount: frames,
                                                    presentationTimeStamp: CMTime(value: CMTimeValue(from), timescale: 48000),
                                                    packetDescriptions: nil, sampleBufferOut: &sb)
    let tmp = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: AVAudioFrameCount(frames))!
    tmp.frameLength = AVAudioFrameCount(frames)
    for c in 0..<Int(pcm.format.channelCount) { memcpy(tmp.floatChannelData![c], pcm.floatChannelData![c] + from, frames * 4) }
    CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                   bufferList: tmp.audioBufferList)
    return sb!
}

func benchAudio(_ path: String, seconds: Double, mic: Bool) {
    let channels: AVAudioChannelCount = mic ? 1 : 2
    let per = mic ? 4096 : 1024
    let pcm = loadAudio(path, seconds: seconds, channels: channels)
    let db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    let w = ChunkedAudioWriter(source: mic ? "benchmic" : "benchsys", db: db, chunkSeconds: 100_000)
    var cpu = 0.0
    if mic {
        // the AVAudioEngine tap hands over ready-made buffers
        var bufs: [AVAudioPCMBuffer] = []
        var i = 0
        while i + per <= Int(pcm.frameLength) {
            let b = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: AVAudioFrameCount(per))!
            b.frameLength = AVAudioFrameCount(per)
            memcpy(b.floatChannelData![0], pcm.floatChannelData![0] + i, per * 4)
            bufs.append(b); i += per
        }
        let c0 = cpuSeconds()
        for b in bufs { w.append(b) }
        w.close()
        cpu = cpuSeconds() - c0
    } else {
        var sbs: [CMSampleBuffer] = []
        var i = 0
        while i + per <= Int(pcm.frameLength) { sbs.append(sampleBuffer(pcm, from: i, frames: per)); i += per }
        let c0 = cpuSeconds()
        for sb in sbs { if let p = SystemAudioRecorder.pcm(sb) { w.append(p) } }
        w.close()
        cpu = cpuSeconds() - c0
    }
    report(mic ? "mic" : "audio", ["audio_seconds": seconds, "cpu_ms_per_audio_second": cpu / seconds * 1000,
                                   "pct_core": cpu / seconds * 100])
}

func benchOCR(_ dir: String, _ n: Int) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
    let step = max(1, names.count / n)
    var imgs: [CGImage] = []
    for name in stride(from: 0, to: names.count, by: step).map({ names[$0] }).prefix(n) {
        if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir).appendingPathComponent(name) as CFURL, nil),
           let i = CGImageSourceCreateImageAtIndex(s, 0, nil) { imgs.append(i) }
    }
    var cfg = Config()
    cfg.ocr = true
    let db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    let cap = ScreenCapturer(db: db, cfg: cfg)
    _ = cap.ocrForBench(imgs[0])  // model load
    let c0 = cpuSeconds(), w0 = Date()
    var chars = 0, fails = 0
    for img in imgs.dropFirst() {
        if let t = cap.ocrForBench(img) { chars += t.count } else { fails += 1 }
    }
    let k = Double(imgs.count - 1)
    report("ocr", ["frames": imgs.count - 1, "cpu_ms_per_frame": (cpuSeconds() - c0) / k * 1000,
                   "wall_ms_per_frame": Date().timeIntervalSince(w0) / k * 1000, "chars_per_frame": Double(chars) / k, "fails": fails])
}

func benchTick(_ seconds: Int) {
    let db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    let base = Int(Date().timeIntervalSince1970) - 10_000_000
    let c0 = cpuSeconds()
    for i in 0..<seconds {
        db.run("INSERT OR REPLACE INTO samples(ts,app,bundle,title,url,idle,keys,clicks,scroll,mouse,synth,mic_db,sys_db,locked) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
               [base + i, "T3 Code", "com.t3.code", "lifelog — benchmarks", "", 0.4, 3, 0, 0, 120, 0, -42.5, -60.1, false])
    }
    report("tick", ["samples": seconds, "cpu_us_per_sample": (cpuSeconds() - c0) / Double(seconds) * 1e6])
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "frames": benchFrames(a[2], Int(a[3]) ?? 200)
case "audio": benchAudio(a[2], seconds: Double(a[3]) ?? 300, mic: false)
case "mic": benchAudio(a[2], seconds: Double(a[3]) ?? 300, mic: true)
case "ocr": benchOCR(a[2], Int(a[3]) ?? 20)
case "tick": benchTick(Int(a[2]) ?? 3600)
case "thumbs": benchThumbs(a[2], Int(a[3]) ?? 200)
default: print("usage: bench frames|audio|mic|ocr|tick …"); exit(2)
}
