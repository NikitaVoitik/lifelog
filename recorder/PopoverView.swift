// The panel that drops down from the menu-bar icon.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    var openSettings: (SettingsTab) -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            if !model.missingPermissions.isEmpty {
                permissionBanner.padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            today.padding(16)
            Divider()
            recent.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            jobs.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: 360)
    }

    // MARK: header — state, what's in front of you, sensors

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppGlyph(size: 22)
                Text("Lifelog").font(.system(size: 15, weight: .semibold))
                StatePill(state: model.state)
                Spacer()
                pauseControl
            }
            if case .recording = model.state, !model.now.app.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.now.app).font(.system(size: 12, weight: .medium))
                    let sub = model.now.url.isEmpty ? model.now.title : model.now.url
                    if !sub.isEmpty {
                        Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            HStack(spacing: 5) {
                SensorChip(symbol: "display", label: "Screen", on: model.screenOK,
                           help: model.screenOK ? "Capturing screenshots (\(model.framesToday) this session)" : "Not capturing")
                SensorChip(symbol: "mic.fill", label: "Mic", on: model.micOK, level: model.micOK ? model.micLevel : nil,
                           help: model.micOK ? "Recording the microphone" : "Mic off")
                SensorChip(symbol: "speaker.wave.2.fill", label: "Audio", on: model.sysOK,
                           help: model.sysOK ? "Recording what your Mac plays" : "System audio off")
                SensorChip(symbol: "keyboard", label: "Keys", on: model.inputOK, help: "Typing / clicking counts")
                SensorChip(symbol: "macwindow", label: "Titles", on: model.titlesOK, help: "Window titles and browser URLs")
            }
        }
    }

    @ViewBuilder var pauseControl: some View {
        switch model.state {
        case .paused:
            Button { model.resume() } label: { Label("Resume", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.small)
        default:
            Menu {
                Button("Pause for 15 minutes") { model.pause(minutes: 15) }
                Button("Pause for 1 hour") { model.pause(minutes: 60) }
                Button("Pause until tomorrow") {
                    let m = Calendar.current.dateComponents([.minute], from: Date(),
                                                            to: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(8 * 3600)).minute ?? 600
                    model.pause(minutes: m)
                }
                Divider()
                Button("Pause until I resume") { model.pause(minutes: nil) }
            } label: {
                Image(systemName: "pause.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Pause recording")
        }
    }

    var permissionBanner: some View {
        Button { openSettings(.permissions) } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.missingPermissions.count == 1 ? "1 permission missing" : "\(model.missingPermissions.count) permissions missing")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.missingPermissions.map(\.title).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("Fix…").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: today

    var today: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Today")
                Spacer()
                Text("\(fmtDuration(model.atMacSeconds)) at your Mac").font(.system(size: 12, weight: .medium))
                if model.talkSeconds > 30 {
                    Text("· \(fmtDuration(model.talkSeconds)) talking").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if model.sleepSeconds > 0 {
                    Text("· slept \(fmtDuration(model.sleepSeconds))").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            let totals = model.categoryTotals
            if totals.isEmpty {
                Text(model.pipelineInstalled
                     ? "Your timeline appears here after the first analysis run (every \(Int(model.processInterval / 60)) min)."
                     : "Run ./install.sh to set up transcription and the AI timeline.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                CategoryBar(totals: totals)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 5) {
                    ForEach(totals.prefix(6), id: \.category) { t in
                        HStack(spacing: 6) {
                            Circle().fill(Category.color(t.category)).frame(width: 8, height: 8)
                            Text(Category.label(t.category)).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(fmtDuration(t.seconds)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 6)
                    }
                }
            }
            if let s = firstSentences(model.summary) {
                Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func firstSentences(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return t
    }

    // MARK: recent activity

    var recent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Recent")
                Spacer()
                if let until = model.timelineCoversUntil {
                    Text("analyzed up to \(fmtClock(until))").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            let recent = Array(model.segments.filter { $0.category != "away" && $0.category != "sleep" }.suffix(6).reversed())
            if recent.isEmpty {
                Text("Nothing analyzed yet today.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(recent) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fmtClock(s.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    RoundedRectangle(cornerRadius: 1.5).fill(Category.color(s.category)).frame(width: 3, height: 12)
                    Text(s.activity).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(fmtDuration(s.end - s.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }
                .help(s.detail)
            }
        }
    }

    // MARK: background jobs

    var jobs: some View {
        VStack(spacing: 6) {
            JobRow(symbol: "sparkles", title: "Timeline", job: model.process,
                   idle: model.pendingChunks > 0
                       ? "\(fmtAgo(model.process.lastRun)) · \(model.pendingChunks) audio chunk\(model.pendingChunks == 1 ? "" : "s") waiting"
                       : "updated \(fmtAgo(model.process.lastRun))",
                   action: "Update now", enabled: model.pipelineInstalled,
                   run: { model.runProcess() }, log: { model.openLog("process") })
            if model.cloudConfigured {
                JobRow(symbol: "icloud.and.arrow.up", title: "Cloud", job: model.sync,
                       idle: model.network.online ? "synced \(fmtAgo(model.lastUpload ?? model.sync.lastRun))" : "offline — will upload when you're back online",
                       action: "Sync now", enabled: model.network.online,
                       run: { model.runSync() }, log: { model.openLog("sync") })
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash").frame(width: 18).foregroundStyle(.secondary)
                    Text("Cloud not set up").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set up…") { openSettings(.cloud) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: footer

    var footer: some View {
        HStack(spacing: 6) {
            Button { model.openTimeline() } label: { Label("Open Timeline", systemImage: "chart.bar.xaxis") }
                .buttonStyle(.borderedProminent).controlSize(.regular)
            if model.cloudConfigured {
                Button { model.openCloud() } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open the cloud timeline (works on your phone too)")
            }
            Spacer()
            Button { openSettings(.general) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings…")
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("Open Lifelog Folder") { NSWorkspace.shared.open(rootDir) }
                Button("Restart Lifelog") { model.restartApp() }
                Divider()
                Button("Quit Lifelog") { quit() }
            } label: { Image(systemName: "power") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: - pieces

struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        if let icon = NSImage(named: "AppIcon") {
            // the .icns has the standard ~10% transparent margin; scale it so the tile fills `size`
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size * 1.24, height: size * 1.24).frame(width: size, height: size)
        } else {
            drawn
        }
    }

    var drawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(light: 0xff6b5a, dark: 0xff6b5a), Color(light: 0xd9304a, dark: 0xd9304a)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(.white, lineWidth: size * 0.09).frame(width: size * 0.62, height: size * 0.62)
            Circle().fill(.white).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
    }
}

struct StatePill: View {
    var state: RecState
    var body: some View {
        let (text, color): (String, Color) = {
            switch state {
            case .recording: return ("Recording", .red)
            case .paused(let until):
                if until > Date().addingTimeInterval(86400 * 300) { return ("Paused", .orange) }
                let f = DateFormatter(); f.timeStyle = .short
                return ("Paused until \(f.string(from: until))", .orange)
            case .asleep: return ("Asleep", .secondary)
            case .needsPermission: return ("Needs permission", .orange)
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct SensorChip: View {
    var symbol: String
    var label: String
    var on: Bool
    var level: Double? = nil
    var help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(label).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
            if let level {
                Capsule().fill(.quaternary).frame(width: 12, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.green).frame(width: max(2, 12 * level), height: 4) }
            }
        }
        .fixedSize()
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .padding(.horizontal, 5.5).padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.green.opacity(0.14) : Color.secondary.opacity(0.1)))
        .overlay(alignment: .topTrailing) {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5).offset(x: 1.5, y: -1.5)
        }
        .help(help)
    }
}

struct SectionTitle: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
    }
}

struct CategoryBar: View {
    var totals: [(category: String, seconds: Double)]
    var body: some View {
        GeometryReader { g in
            let sum = max(1, totals.reduce(0) { $0 + $1.seconds })
            HStack(spacing: 1.5) {
                ForEach(totals, id: \.category) { t in
                    Rectangle().fill(Category.color(t.category))
                        .frame(width: max(2, (g.size.width - 1.5 * Double(totals.count - 1)) * t.seconds / sum))
                        .help("\(Category.label(t.category)): \(fmtDuration(t.seconds))")
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct JobRow: View {
    var symbol: String
    var title: String
    var job: JobState
    var idle: String
    var action: String
    var enabled: Bool
    var run: () -> Void
    var log: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Group {
                    if job.running {
                        Text(job.line.isEmpty ? "Working…" : job.line)
                    } else if !job.ok {
                        Text("Last run failed: \(job.message)").foregroundStyle(.red)
                    } else {
                        Text(idle)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if job.running {
                ProgressView().controlSize(.small)
            } else {
                if !job.ok {
                    Button("Log") { log() }.controlSize(.small)
                }
                Button(action) { run() }.controlSize(.small).disabled(!enabled)
            }
        }
    }
}
