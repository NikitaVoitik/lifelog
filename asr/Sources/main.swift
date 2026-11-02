// lifelog-asr — local speech pipeline for Lifelog, built on FluidAudio (CoreML; runs on the Neural Engine / GPU).
//
//   lifelog-asr warmup                 download + compile every model (first run takes a few minutes)
//   lifelog-asr batch [--no-speakers]  JSON lines in on stdin  {"id": .., "path": ".."}
//                                      JSON lines out on stdout {"id", "ok", "duration", "speech", "words": [[start, end, word, conf, slot]],
//                                                                "speakers": [{"slot", "seconds", "embedding": [192 floats]}], ...}
//   lifelog-asr embed <file>           {"embedding": [...], "seconds": ..} — a voice fingerprint (for enrolling "me")
//
// Pipeline per file:  Silero VAD (skip silence) → Parakeet Ultra on each speech region (word timings)
//                     → Nemotron 3 diarization over the file (who spoke when, overlap-aware, up to 8 voices)
//                     → each word gets the most active voice → CAM++ fingerprint per voice (for cross-recording identity)

import AVFoundation
import Foundation
import FluidAudio

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

final class Pipeline {
    let converter = AudioConverter(sampleRate: 16_000)
    var vad: VadManager!
    var asr: AsrManager!
    var diarizer: Nemotron3Diarizer?
    var embedder: CampPlusEmbedder?
    let wantSpeakers: Bool

    init(speakers: Bool) { wantSpeakers = speakers }

    func load() async throws {
        let t0 = Date()
        vad = try await VadManager()
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        if wantSpeakers {
            let cfg = Nemotron3Config.offline
            diarizer = Nemotron3Diarizer(config: cfg, models: try await Nemotron3Models.loadFromHuggingFace(config: cfg))
            embedder = try await CampPlusEmbedder.load()
        }
        eprint("models ready in \(Int(Date().timeIntervalSince(t0)))s")
    }

    func process(path: String) async throws -> [String: Any] {
        let t0 = Date()
        let samples = try converter.resampleAudioFile(URL(fileURLWithPath: path))
        let sr = 16_000.0
        let duration = Double(samples.count) / sr
        let regions = try await vad.segmentSpeech(samples)
        let speech = regions.reduce(0) { $0 + $1.duration }
        var out: [String: Any] = ["ok": true, "duration": r3(duration), "speech": r3(speech), "words": [], "speakers": []]
        if speech < 0.6 {
            out["seconds"] = r3(Date().timeIntervalSince(t0))
            return out
        }

        // 1) words, region by region (keeps Parakeet from hallucinating over silence)
        struct Word { var s: Double; var e: Double; var w: String; var c: Float; var slot: Int = -1 }
        var words: [Word] = []
        var confSum: Float = 0, confN: Float = 0
        for r in regions {
            let a = max(0, Int(r.startTime * sr)), b = min(samples.count, Int(r.endTime * sr))
            guard b - a > Int(0.3 * sr) else { continue }
            var state = TdtDecoderState.make()
            let res = try await asr.transcribe(Array(samples[a..<b]), decoderState: &state)
            confSum += res.confidence; confN += 1
            for t in res.tokenTimings ?? [] {
                let piece = t.token
                let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ") || words.isEmpty
                let text = piece.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
                let s = r.startTime + t.startTime, e = r.startTime + t.endTime
                if startsWord || words.last.map({ s - $0.e > 0.8 }) == true {
                    if !text.isEmpty { words.append(Word(s: s, e: e, w: text, c: t.confidence)) }
                } else if !words.isEmpty {
                    words[words.count - 1].w += text
                    words[words.count - 1].e = e
                    words[words.count - 1].c = min(words[words.count - 1].c, t.confidence)
                }
            }
        }
        out["confidence"] = confN > 0 ? Double(confSum / confN) : 0

        // 2) who spoke when
        if let diarizer, speech >= 2.0 {
            let frames = Int(duration * 100)
            var mask = [Bool](repeating: false, count: frames)
            for r in regions {  // pad ~1 s around speech, per the diarizer docs
                let a = max(0, Int((r.startTime - 1) * 100)), b = min(frames, Int((r.endTime + 1) * 100))
                if a < b { for i in a..<b { mask[i] = true } }
            }
            let (probs, frameCount) = try diarizer.processComplete(samples, speechMask: mask)
            let K = 8
            func p(_ f: Int, _ k: Int) -> Float { f >= 0 && f < frameCount ? probs[f * K + k] : 0 }

            for i in words.indices {
                let fa = Int(words[i].s * 100), fb = max(fa + 1, Int(words[i].e * 100))
                var best = -1
                var bestV: Float = 0.25
                for k in 0..<K {
                    var sum: Float = 0
                    for f in fa..<fb { sum += p(f, k) }
                    let v = sum / Float(fb - fa)
                    if v > bestV { bestV = v; best = k }
                }
                words[i].slot = best >= 0 ? best : (i > 0 ? words[i - 1].slot : -1)
            }
            // The diarizer reacts a few hundred ms late at turn changes, so the first word after a pause tends
            // to inherit the previous voice (and the last word before one, the next voice). Fix those using
            // the pause + the neighbours' agreement.
            let n = words.count
            if n >= 3 {
                for i in 0..<n {
                    let gapBefore = i > 0 ? words[i].s - words[i - 1].e : 9
                    let gapAfter = i < n - 1 ? words[i + 1].s - words[i].e : 9
                    if gapBefore > 0.3, i + 2 < n {
                        let next = words[(i + 1)...min(n - 1, i + 3)].map { $0.slot }
                        if let x = next.first, x >= 0, x != words[i].slot, next.allSatisfy({ $0 == x }) { words[i].slot = x }
                    } else if gapAfter > 0.3, i >= 2 {
                        let prev = words[max(0, i - 3)..<i].map { $0.slot }
                        if let y = prev.first, y >= 0, y != words[i].slot, prev.allSatisfy({ $0 == y }) { words[i].slot = y }
                    }
                }
            }

            // fingerprint each voice from frames where it talks alone (cap 30 s per voice)
            var speakers: [[String: Any]] = []
            if let embedder {
                for k in 0..<K {
                    var clip: [Float] = []
                    var solo = 0
                    var f = 0
                    while f < frameCount && clip.count < Int(30 * sr) {
                        var others: Float = 0
                        for j in 0..<K where j != k { others = max(others, p(f, j)) }
                        if p(f, k) > 0.6 && others < 0.3 {
                            let a = f * 160, b = min(samples.count, a + 160)
                            if a < b { clip.append(contentsOf: samples[a..<b]) }
                            solo += 1
                        }
                        f += 1
                    }
                    let talked = (0..<frameCount).reduce(0) { $0 + (p($1, k) > 0.5 ? 1 : 0) }
                    guard talked >= 100 else { continue }  // < 1 s total: not a real voice
                    var entry: [String: Any] = ["slot": k, "seconds": r3(Double(talked) / 100), "soloSeconds": r3(Double(solo) / 100)]
                    if clip.count >= Int(1.5 * sr) {
                        entry["embedding"] = try await embedder.embed(audio: clip).map { Double($0) }
                    }
                    speakers.append(entry)
                }
            }
            out["speakers"] = speakers
        }

        out["words"] = words.map { [r3($0.s), r3($0.e), $0.w, r3(Double($0.c)), $0.slot] as [Any] }
        out["seconds"] = r3(Date().timeIntervalSince(t0))
        return out
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    eprint("usage: lifelog-asr warmup | batch [--no-speakers] | embed <file>")
    exit(2)
}

switch cmd {
case "warmup":
    let pl = Pipeline(speakers: true)
    try await pl.load()
    // compiling for the Neural Engine happens on first inference — run a short synthetic clip
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lifelog-warmup.wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000 * 5)!
    buf.frameLength = 16_000 * 5
    for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.05) }
    let f = try AVAudioFile(forWriting: tmp, settings: fmt.settings)
    try f.write(from: buf)
    _ = try await pl.process(path: tmp.path)
    emit(["ok": true])

case "batch":
    let pl = Pipeline(speakers: !args.contains("--no-speakers"))
    try await pl.load()
    while let line = readLine() {
        guard let d = line.data(using: .utf8), let req = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let path = req["path"] as? String
        else { continue }
        do {
            var res = try await pl.process(path: path)
            res["id"] = req["id"] ?? NSNull()
            emit(res)
        } catch {
            emit(["id": req["id"] ?? NSNull(), "ok": false, "error": "\(error)"])
        }
    }

case "embed":
    guard args.count >= 2 else { eprint("usage: lifelog-asr embed <file>"); exit(2) }
    let converter = AudioConverter(sampleRate: 16_000)
    var samples = try converter.resampleAudioFile(URL(fileURLWithPath: args[1]))
    // keep only speech so silence doesn't dilute the fingerprint
    let vad = try await VadManager()
    let regions = try await vad.segmentSpeech(samples)
    var speech: [Float] = []
    for r in regions {
        let a = max(0, Int(r.startTime * 16_000)), b = min(samples.count, Int(r.endTime * 16_000))
        if a < b { speech.append(contentsOf: samples[a..<b]) }
    }
    if speech.count > 16_000 * 2 { samples = speech }
    let emb = try await CampPlusEmbedder.load().embed(audio: samples)
    emit(["embedding": emb.map { Double($0) }, "seconds": r3(Double(samples.count) / 16_000)])

default:
    eprint("unknown command \(cmd)")
    exit(2)
}
