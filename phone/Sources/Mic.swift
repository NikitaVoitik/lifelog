// Continuous microphone recording, the same shape as the Mac's: 5-minute AAC chunks, 16 kHz mono, aligned to the clock.
// Each finished chunk goes to Store.audioDir with a sidecar (start, end, peak dB); the uploader sends it to R2 and the Mac
// transcribes it with the same speech pipeline as the laptop's mic (so your voice is still "Me").
//
// Also one "sound" event per minute: loudness around the phone and whether another app is playing audio (music, video,
// podcast). That's how silence at night, a noisy street or a call shows up even before transcription.
//
// The session mixes with other apps (music keeps playing) and never takes the Bluetooth mic (AirPods stay in high quality):
// the built-in mic is always the input.
import AVFoundation
import UIKit

final class Mic: @unchecked Sendable {
    static let shared = Mic()

    private let engine = AVAudioEngine()
    private let q = DispatchQueue(label: "lifelog.mic")
    private let chunkSeconds = 300.0
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var fileStart = Date()
    private var fileSlot = -1
    private var filePeak: Float = -160
    private var lastBuffer = Date()

    // per-minute stats
    private var minute = -1
    private var minSum: Double = 0, minN = 0, minPeak: Float = -160, loudBlocks = 0, blocks = 0

    private(set) var running = false
    private(set) var level: Float = -160  // latest block level, for the UI meter
    var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "micOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "micOn") }
    }

    private var watchdog: Timer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            self?.interrupted(n)
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Store.shared.log("mic", ["state": "media-services-reset"])
            self?.restart(reason: "media services reset")
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            self?.routeChanged(n)
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart(reason: "audio configuration changed")
        }
    }

    // MARK: start / stop

    @discardableResult
    func start(reason: String) -> Bool {
        guard wanted else { return false }
        if running { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        } catch {
            Store.shared.log("mic", ["state": "failed", "reason": reason, "error": error.localizedDescription])
            Notifier.micStopped(why: error.localizedDescription)
            return false
        }
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            Store.shared.log("mic", ["state": "failed", "reason": reason, "error": "no input format"])
            return false
        }
        // the tap must use the hardware rate; we convert to 16 kHz mono ourselves
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount)!
        converter = AVAudioConverter(from: tapFormat, to: outFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buf, _ in
            self?.q.async { self?.handle(buf) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Store.shared.log("mic", ["state": "failed", "reason": reason, "error": error.localizedDescription])
            Notifier.micStopped(why: error.localizedDescription)
            return false
        }
        running = true
        lastBuffer = Date()
        Store.shared.log("mic", ["state": "on", "reason": reason, "input": session.currentRoute.inputs.first?.portName ?? "?",
                                 "rate": hw.sampleRate])
        Notifier.clearMicStopped()
        startWatchdog()
        return true
    }

    func stop(reason: String) {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        q.sync { closeFile() }
        Store.shared.log("mic", ["state": "off", "reason": reason])
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func restart(reason: String) {
        guard wanted else { return }
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
            q.sync { closeFile() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(reason: reason) }
    }

    /// Restarts the engine if buffers stop arriving (iOS sometimes silently stalls an input after a route change).
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.lastBuffer) > 20 {
                Store.shared.log("mic", ["state": "stalled"])
                self.restart(reason: "no audio for 20s")
            }
            // a chunk whose slot ended but got no buffer since (e.g. paused) is closed here
            self.q.async {
                if self.file != nil, Int(Date().timeIntervalSince1970 / self.chunkSeconds) != self.fileSlot,
                   Date().timeIntervalSince(self.lastBuffer) > 5 {
                    self.closeFile()
                }
            }
        }
    }

    // MARK: audio path (on q)

    private func handle(_ buf: AVAudioPCMBuffer) {
        let now = Date()
        lastBuffer = now
        // level of this block (dBFS of the loudest sample in channel 0)
        var peak: Float = 0
        var sumSq: Float = 0
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) {
                let v = abs(ch[i])
                if v > peak { peak = v }
                sumSq += v * v
            }
        }
        let peakDb = peak > 0 ? 20 * log10(peak) : -160
        let rms = buf.frameLength > 0 ? sqrt(sumSq / Float(buf.frameLength)) : 0
        let rmsDb = rms > 0 ? 20 * log10(rms) : -160
        level = rmsDb
        minuteStats(now: now, rmsDb: rmsDb, peakDb: peakDb)

        // convert to 16 kHz mono
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if err != nil || out.frameLength == 0 { return }

        let slot = Int(now.timeIntervalSince1970 / chunkSeconds)
        if file == nil || slot != fileSlot {
            closeFile()
            openFile(slot: slot, now: now)
        }
        filePeak = max(filePeak, peakDb)
        try? file?.write(from: out)
    }

    private func openFile(slot: Int, now: Date) {
        let url = Store.shared.audioDir.appendingPathComponent("\(fileStamp.string(from: now))_phone.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 24_000]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: url.path)
            fileURL = url
            fileStart = now
            fileSlot = slot
            filePeak = -160
        } catch {
            file = nil
            Store.shared.log("mic", ["state": "file-error", "error": error.localizedDescription])
        }
    }

    private func closeFile() {
        guard let url = fileURL else { return }
        file = nil  // AVAudioFile finalizes on deinit
        fileURL = nil
        let meta: [String: Any] = ["start": fileStart.timeIntervalSince1970, "end": lastBuffer.timeIntervalSince1970,
                                   "peak_db": r2(Double(filePeak))]
        if let d = try? JSONSerialization.data(withJSONObject: meta) {
            try? d.write(to: url.appendingPathExtension("json"), options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }

    private func minuteStats(now: Date, rmsDb: Float, peakDb: Float) {
        let m = Int(now.timeIntervalSince1970 / 60)
        if m != minute {
            if minute >= 0, minN > 0 {
                let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
                Store.shared.log("sound", ["avg_db": r2(minSum / Double(minN)), "peak_db": r2(Double(minPeak)),
                                           "loud_s": r2(Double(loudBlocks) / Double(max(blocks, 1)) * 60),
                                           "other_audio": other],
                                 at: Date(timeIntervalSince1970: Double(minute * 60)))
            }
            minute = m; minSum = 0; minN = 0; minPeak = -160; loudBlocks = 0; blocks = 0
        }
        minSum += Double(rmsDb); minN += 1
        minPeak = max(minPeak, peakDb)
        blocks += 1
        if rmsDb > -45 { loudBlocks += 1 }
    }

    // MARK: system events

    private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let reason = (n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            Store.shared.log("mic", ["state": "interrupted", "reason": reason == .builtInMicMuted ? "mic muted" : "another app or a call"])
            running = false
            q.sync { closeFile() }
        } else {
            Store.shared.log("mic", ["state": "interruption-ended"])
            restart(reason: "interruption ended")
        }
    }

    private func routeChanged(_ n: Notification) {
        let r = AVAudioSession.sharedInstance().currentRoute
        let outs = r.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let ins = r.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        Store.shared.log("route", ["outputs": outs, "inputs": ins])
        // keep the built-in mic as input (a headset mic would switch AirPods to low-quality call mode)
        if let builtIn = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.portType == .builtInMic }),
           r.inputs.first?.portType != .builtInMic {
            try? AVAudioSession.sharedInstance().setPreferredInput(builtIn)
        }
    }
}
