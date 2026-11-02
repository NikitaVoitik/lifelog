// Settings window tabs, the first-run welcome window, voice list and voice enrollment.

import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Int, CaseIterable {
    case general, recording, speech, cloud, permissions

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .speech: return "Voices"
        case .cloud: return "Cloud"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .speech: return "person.wave.2"
        case .cloud: return "icloud"
        case .permissions: return "lock.shield"
        }
    }

    var height: CGFloat {
        switch self {
        case .general: return 470
        case .recording: return 640
        case .speech: return 500
        case .cloud: return 470
        case .permissions: return 330
        }
    }

    @ViewBuilder func view(_ m: AppModel) -> some View {
        switch self {
        case .general: GeneralTab(model: m)
        case .recording: RecordingTab(model: m)
        case .speech: SpeechTab(model: m)
        case .cloud: CloudTab(model: m)
        case .permissions: PermissionsTab(model: m)
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var disk = "…"

    var body: some View {
        Form {
            Section {
                Toggle("Start Lifelog when you log in", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                    .disabled(!LoginItem.installed)
                if !LoginItem.installed {
                    Text("Run ./install.sh to register Lifelog as a login item.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("AI timeline") {
                Picker("Rebuild the timeline every", selection: model.binding("processEveryMinutes", 30)) {
                    Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("hour").tag(60); Text("2 hours").tag(120)
                }
                Picker("Claude model", selection: Binding(get: { model.str("analysisModel").isEmpty ? "sonnet" : model.str("analysisModel") },
                                                          set: { model.set("analysisModel", $0); model.set("summaryModel", $0) })) {
                    Text("Haiku — cheapest").tag("haiku"); Text("Sonnet — recommended").tag("sonnet"); Text("Opus — most detailed").tag("opus")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("About you")
                    TextEditor(text: model.binding("aboutMe", ""))
                        .font(.system(size: 12)).frame(height: 64)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    Text("Names of your projects, friends, chats — helps Claude label your day (\"T3 Code is my coding agent app\").")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Timeline runs are skipped while Low Power Mode is on.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Folder") {
                    HStack {
                        Text(rootDir.path).foregroundStyle(.secondary).truncationMode(.middle).lineLimit(1)
                        Button("Show") { NSWorkspace.shared.open(rootDir) }.controlSize(.small)
                    }
                }
                LabeledContent("On this Mac", value: disk)
            }
        }
        .formStyle(.grouped)
        .task { disk = await diskUsage() }
    }
}

func diskUsage() async -> String {
    await Task.detached(priority: .utility) {
        let fm = FileManager.default
        var media: Double = 0
        let files = fm.enumerator(at: rootDir.appendingPathComponent("media"), includingPropertiesForKeys: [.fileSizeKey])?.allObjects ?? []
        for case let u as URL in files { media += Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let dbSize = Double((try? fm.attributesOfItem(atPath: rootDir.appendingPathComponent("lifelog.db").path)[.size] as? Int) ?? 0)
        let free = Double((try? rootDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0)
        return "\(fmtBytes(media)) media · \(fmtBytes(dbSize)) database · \(fmtBytes(free)) free"
    }.value
}

// MARK: - Recording

struct RecordingTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Screen") {
                Picker("Screenshots", selection: model.binding("screenshotFPS", 1.0)) {
                    Text("Every 2 seconds").tag(0.5); Text("Every second").tag(1.0); Text("Twice a second").tag(2.0)
                }
                Text("Only frames where something changed are saved, so a still screen costs nothing.").font(.caption).foregroundStyle(.secondary)
                Picker("Resolution", selection: model.binding("screenshotMaxWidth", 1920)) {
                    Text("1280 px wide").tag(1280); Text("1920 px wide").tag(1920); Text("2560 px wide").tag(2560)
                }
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: model.binding("jpegQuality", 0.55), in: 0.3...0.9, step: 0.05)
                        Text("\(Int(((model.config["jpegQuality"] as? Double) ?? 0.55) * 100))%").monospacedDigit().frame(width: 36)
                    }
                }
                Toggle("Read text on screen (OCR)", isOn: model.binding("ocr", true))
                if model.bool("ocr", true) {
                    Picker("OCR a frame every", selection: model.binding("ocrInterval", 10.0)) {
                        Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0)
                    }
                }
            }
            Section("Audio") {
                Toggle("Microphone", isOn: model.binding("recordMic", true))
                Toggle("Prefer the built-in mic", isOn: model.binding("preferBuiltInMic", true))
                    .disabled(!model.bool("recordMic", true))
                    .help("Keeps AirPods in high-quality mode and hears the whole room")
                Toggle("Computer audio (calls, videos)", isOn: model.binding("recordSystemAudio", true))
                Toggle("Keep recording audio while the screen is locked", isOn: model.binding("recordAudioWhenLocked", true))
            }
            Section {
                ExcludedApps(model: model)
            } header: {
                Text("Never screenshot these apps")
            } footer: {
                Text("Password managers are excluded by default.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ExcludedApps: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    var ids: [String] { model.config["excludedBundleIDs"] as? [String] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.secondary)
                            Text(id).foregroundStyle(.secondary)
                        }
                    }
                    .tag(id)
                }
            }
            .frame(height: 120)
            HStack(spacing: 0) {
                Button { addApp() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                Divider().frame(height: 14)
                Button {
                    if let s = selection { model.set("excludedBundleIDs", ids.filter { $0 != s }); selection = nil }
                } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless).padding(.top, 4)
        }
    }

    func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Exclude"
        guard p.runModal() == .OK else { return }
        let new = p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !ids.contains($0) }
        if !new.isEmpty { model.set("excludedBundleIDs", ids + new) }
    }
}

// MARK: - Voices / speech

struct SpeechTab: View {
    @ObservedObject var model: AppModel
    @State private var enrolling = false

    var body: some View {
        Form {
            Section {
                if !model.meEnrolled {
                    HStack(spacing: 10) {
                        Image(systemName: "person.wave.2.fill").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Teach Lifelog your voice").font(.headline)
                            Text("Read a short paragraph (20 s) so transcripts say \u{201C}Me\u{201D} instead of \u{201C}Voice #1\u{201D}.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Start…") { enrolling = true }.buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                if model.voices.isEmpty {
                    Text("No voices heard yet. People show up here after conversations are transcribed; name them once and every past and future transcript uses the name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.voices) { v in VoiceRow(model: model, voice: v) }
            } header: {
                HStack {
                    Text("People")
                    Spacer()
                    if model.meEnrolled { Button("Enroll a voice…") { enrolling = true }.controlSize(.small) }
                }
            }
            Section("Transcription") {
                Picker("Engine", selection: model.binding("transcriber", "fluidaudio")) {
                    Text("Parakeet + speaker detection (on-device)").tag("fluidaudio")
                    Text("Whisper (99 languages)").tag("whisper")
                }
                Toggle("Tell speakers apart", isOn: model.binding("diarize", true))
                    .disabled(model.str("transcriber") == "whisper")
                LabeledContent("Voice matching") {
                    HStack {
                        Text("loose").font(.caption).foregroundStyle(.secondary)
                        Slider(value: model.binding("voiceMatchThreshold", 0.72), in: 0.6...0.85, step: 0.01)
                        Text("strict").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("If one person keeps showing up as two voices, merge them or move toward loose. If two people get mixed up, move toward strict.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $enrolling) { EnrollSheet(model: model, isPresented: $enrolling) }
        .onAppear { model.refreshVoices() }
    }
}

struct VoiceRow: View {
    @ObservedObject var model: AppModel
    var voice: Voice
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(voice.name.lowercased() == "me" ? Color.accentColor : Color.secondary.opacity(0.35))
                Text(String(voice.label.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $name, prompt: Text("Voice #\(voice.id)"))
                    .labelsHidden().textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .focused($focused)
                    .onSubmit { model.renameVoice(voice, to: name) }
                    .onChange(of: focused) { _, f in if !f { model.renameVoice(voice, to: name) } }
                Text(voice.sample.isEmpty ? "\(fmtDuration(voice.seconds)) of speech · last heard \(fmtAgo(Date(timeIntervalSince1970: voice.lastHeard)))"
                                          : "\u{201C}\(voice.sample)\u{201D}")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(fmtDuration(voice.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Button("Rename") { focused = true }
                Menu("Same person as…") {
                    ForEach(model.voices.filter { $0.id != voice.id }) { o in
                        Button(o.label) { model.mergeVoice(voice, into: o) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .onAppear { name = voice.name }
        .onChange(of: voice.name) { _, n in name = n }
    }
}

// MARK: - Enrollment (record 20 s → `lifelog enroll --file`)

final class Enroller: NSObject, ObservableObject {
    enum Phase: Equatable { case ready, recording, processing, done(String), failed(String) }
    @Published var phase: Phase = .ready
    @Published var progress: Double = 0
    @Published var level: Double = 0
    let seconds = 20.0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let file = rootDir.appendingPathComponent("tmp/enroll.wav")

    func start(name: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            phase = .failed("Lifelog needs Microphone access first (Settings → Permissions).")
            return
        }
        ensureDir(file.deletingLastPathComponent())
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        do {
            let r = try AVAudioRecorder(url: file, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: seconds) else { throw NSError(domain: "lifelog", code: 1) }
            recorder = r
        } catch {
            phase = .failed("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        phase = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            self.level = max(0, min(1, (Double(r.averagePower(forChannel: 0)) + 55) / 45))
            self.progress = min(1, r.currentTime / self.seconds)
            if !r.isRecording { self.finish(name: name) }
        }
    }

    private func finish(name: String) {
        timer?.invalidate()
        recorder = nil
        phase = .processing
        CLI.run(["enroll", "--file", file.path, "--name", name], qos: .userInitiated) { [weak self] code, out in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.file)
            let last = out.split(separator: "\n").last.map(String.init) ?? ""
            self.phase = code == 0 ? .done(last) : .failed(last.isEmpty ? "enroll failed (exit \(code))" : last)
        }
    }

    func cancel() {
        timer?.invalidate()
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: file)
    }
}

struct EnrollSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var e = Enroller()
    @State private var name = "Me"

    static let passage = """
    I want to know exactly where my time goes. Some days I spend hours talking to friends, typing prompts, \
    reading, or scrolling, and at the end of the day I can't remember any of it. So this app listens, watches \
    the screen, and writes the story of my day for me. This is what my voice sounds like when I talk normally.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enroll a voice").font(.title2.weight(.semibold))
            switch e.phase {
            case .ready:
                Text("Whose voice is this? Then press Record and read the text below out loud at a normal pace, the way you'd talk to a friend.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                passageBox
            case .recording:
                passageBox
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    ProgressView(value: e.progress)
                    Text("\(Int(e.seconds - e.progress * e.seconds))s").monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                }
                LevelMeter(level: e.level)
            case .processing:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Making a voice fingerprint…") }
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .done(let msg):
                Label("Done — transcripts will now say \u{201C}\(name)\u{201D}.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(.secondary) }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch e.phase {
                case .ready:
                    Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Record") { e.start(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Me" : name) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                case .recording:
                    Button("Cancel") { e.cancel(); isPresented = false }
                case .processing:
                    EmptyView()
                case .done, .failed:
                    Button("Done") { model.refreshVoices(); isPresented = false }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    var passageBox: some View {
        Text(Self.passage)
            .font(.system(size: 15)).lineSpacing(3)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

struct LevelMeter: View {
    var level: Double
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule().fill(level > 0.85 ? Color.orange : Color.green).frame(width: g.size.width * level)
                        .animation(.linear(duration: 0.05), value: level)
                }
        }
        .frame(height: 5)
    }
}

// MARK: - Cloud

struct CloudTab: View {
    @ObservedObject var model: AppModel
    @State private var ping: String?
    @State private var showToken = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if let ping {
                            Text(ping).foregroundStyle(ping.hasPrefix("Connected") ? .green : .orange)
                        } else {
                            Text(model.cloudConfigured ? "Not checked" : "Not set up").foregroundStyle(.secondary)
                        }
                        Button("Test") { test() }.controlSize(.small).disabled(!model.cloudConfigured)
                    }
                }
                TextField("Worker URL", text: model.binding("cloudUrl", ""), prompt: Text("https://lifelog.you.workers.dev"))
                LabeledContent("Token") {
                    HStack {
                        if showToken {
                            TextField("", text: model.binding("cloudToken", "")).labelsHidden().font(.system(size: 11, design: .monospaced))
                        } else {
                            SecureField("", text: model.binding("cloudToken", "")).labelsHidden()
                        }
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.str("cloudToken"), forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }.buttonStyle(.borderless).help("Copy — paste it into the phone app")
                    }
                }
                if !model.cloudConfigured {
                    Text("Run cloud/deploy.sh (needs `wrangler login`) — it creates the R2 bucket, D1 database and Worker, and fills these in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Cloudflare") }
            Section("Uploads") {
                LabeledContent("Uploaded", value: model.uploadedBytes > 0 ? "\(fmtBytes(model.uploadedBytes)) · last \(fmtAgo(model.lastUpload))" : "nothing yet")
                Picker("Upload every", selection: model.binding("syncEveryMinutes", 10)) {
                    Text("5 minutes").tag(5); Text("10 minutes").tag(10); Text("30 minutes").tag(30); Text("hour").tag(60)
                }
                Toggle("Upload over phone hotspots", isOn: model.binding("syncOnExpensiveNetwork", false))
                Picker("Keep screenshots & audio on this Mac", selection: model.binding("localMediaKeepDays", 3)) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("1 week").tag(7); Text("2 weeks").tag(14); Text("30 days").tag(30)
                }
                Text("Older media is deleted locally only after it's safely in R2. Text, OCR, transcripts and the timeline stay on the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Sync now") { model.runSync() }.disabled(!model.cloudConfigured || model.sync.running)
                    if model.sync.running { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Open cloud timeline") { model.openCloud() }.disabled(!model.cloudConfigured)
                }
            }
        }
        .formStyle(.grouped)
    }

    func test() {
        ping = "Checking…"
        guard let base = URL(string: model.str("cloudUrl")) else { ping = "Invalid URL"; return }
        var req = URLRequest(url: base.appendingPathComponent("api/ping"), timeoutInterval: 10)
        req.setValue("Bearer \(model.str("cloudToken"))", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                ping = code == 200 ? "Connected" : code == 401 ? "Token rejected (401)" : err.map { "Unreachable: \($0.localizedDescription)" } ?? "HTTP \(code)"
            }
        }.resume()
    }
}

// MARK: - Permissions (also the body of the welcome window)

struct PermissionList: View {
    @ObservedObject var model: AppModel
    @State private var tick = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Permission.allCases) { p in
                let granted = p.granted
                HStack(spacing: 12) {
                    Image(systemName: p.symbol).font(.system(size: 17)).frame(width: 30).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: 13, weight: .medium))
                        Text(p.why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if granted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
                    } else {
                        Button("Allow…") { p.request { model.refreshLive() } }
                    }
                }
                .padding(.vertical, 9)
                .id("\(p.rawValue)-\(granted)-\(tick)")
                if p != Permission.allCases.last { Divider() }
            }
        }
        .onReceive(timer) { _ in tick += 1 }
    }
}

struct PermissionsTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                PermissionList(model: model)
            } footer: {
                HStack(alignment: .top) {
                    Text("Screen Recording and Input Monitoring take effect after Lifelog restarts. Browsers may also ask once whether Lifelog can read the current tab's URL.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Lifelog") { model.restartApp() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void
    @State private var enrolling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppGlyph(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Lifelog").font(.system(size: 22, weight: .bold))
                    Text("It records your screen, audio and activity, and Claude turns it into a minute-by-minute story of your day.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Allow access").font(.headline)
                PermissionList(model: model)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("2. Teach it your voice (optional)").font(.headline)
                HStack {
                    Text(model.meEnrolled ? "Done — your voice is labelled \u{201C}Me\u{201D}." : "20 seconds of reading aloud, so transcripts know which voice is you.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !model.meEnrolled { Button("Record…") { enrolling = true } }
                }
            }
            Text("Everything stays on this Mac until it's uploaded to your own Cloudflare account. Pause any time from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restart Lifelog") { model.restartApp() }
                    .help("Needed after granting Screen Recording or Input Monitoring")
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 560)
        .sheet(isPresented: $enrolling) { EnrollSheet(model: model, isPresented: $enrolling) }
    }
}
