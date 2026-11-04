// Lifelog for iPhone: records what the phone can know about your day and sends it to your Lifelog Worker.
// The Mac pulls it from there, transcribes the audio, and Claude reads it next to the laptop's record.
import AVFoundation
import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct LifelogPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // (with scenes, every launch starts in .background, so that can't tell an open from a wake-up)
        let why = opts?[.location] != nil ? "location wake" : "launched"
        Store.shared.log("app", ["state": "launch", "reason": why])
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppState.refreshID, using: nil) { task in
            AppState.shared.refresh(task as! BGAppRefreshTask)
        }
        Sensors.shared.start()
        Uploader.shared.start()
        AppState.shared.ensureRunning(reason: why)
        AppState.shared.scheduleRefresh()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Store.shared.log("app", ["state": "background"])
            AppState.shared.scheduleRefresh()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Store.shared.log("app", ["state": "foreground"])
            AppState.shared.ensureRunning(reason: "opened")
            Uploader.shared.kick()
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Mic.shared.stop(reason: "app terminated")
        Store.shared.log("app", ["state": "terminate"])
        Notifier.micStopped(why: "The app was closed.")
    }
}

final class AppState: @unchecked Sendable {
    static let shared = AppState()
    static let refreshID = "lifelog.example.phone.refresh"

    func ensureRunning(reason: String) {
        DispatchQueue.main.async {
            if Mic.shared.wanted && !Mic.shared.running {
                // iOS doesn't let an app *start* recording from the background; if this fails we notify instead
                Mic.shared.start(reason: reason)
            }
        }
    }

    func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    func refresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        ensureRunning(reason: "background refresh")
        task.expirationHandler = {}
        Uploader.shared.kick { task.setTaskCompleted(success: true) }
    }
}

/// One local notification when recording stops and the app can't restart it itself.
enum Notifier {
    static let id = "mic-stopped"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func micStopped(why: String) {
        guard Mic.shared.wanted else { return }
        let c = UNMutableNotificationContent()
        c.title = "Lifelog stopped listening"
        c.body = "\(why) Open Lifelog to resume."
        let req = UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    static func clearMicStopped() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

// MARK: - UI

struct ContentView: View {
    @State private var tick = 0
    @State private var mic = Mic.shared.wanted
    @State private var loc = Sensors.shared.locationWanted
    @State private var cell = Uploader.shared.audioOnCellular
    @State private var showLog = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle().fill(Mic.shared.running ? Color.red : Color.secondary).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Mic.shared.running ? "Listening" : Mic.shared.wanted ? "Not listening" : "Microphone off")
                                .font(.headline)
                            Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if Mic.shared.running { LevelBar(db: Mic.shared.level) }
                    }
                    if Mic.shared.wanted && !Mic.shared.running {
                        Button("Start listening") { Mic.shared.start(reason: "button") }
                    }
                }
                Section("Record") {
                    Toggle("Microphone", isOn: $mic).onChange(of: mic) { _, v in
                        Mic.shared.wanted = v
                        if v { Mic.shared.start(reason: "toggle") } else { Mic.shared.stop(reason: "turned off") }
                    }
                    Toggle("Places (arrive / leave)", isOn: $loc).onChange(of: loc) { _, v in
                        Sensors.shared.locationWanted = v
                        if v { Sensors.shared.requestLocation() }
                    }
                    Toggle("Upload audio on cellular", isOn: $cell).onChange(of: cell) { _, v in Uploader.shared.audioOnCellular = v }
                }
                Section("Upload") {
                    LabeledContent("Last upload", value: Uploader.shared.lastSuccess.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never")
                    LabeledContent("Waiting", value: "\(Store.shared.pendingAudio().count) audio, \(Store.shared.pendingEventBatches) event batches")
                    if let e = Uploader.shared.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                    Button("Upload now") { Uploader.shared.kick() }
                }
                Section("Permissions") {
                    Button("Microphone") { AVAudioApplication.requestRecordPermission { _ in } }
                    Button("Location (choose “Always”)") { Sensors.shared.requestLocation() }
                    Button("Motion & fitness") { Sensors.shared.requestMotion() }
                    Button("Notifications") { Notifier.requestPermission() }
                }
                Section {
                    Button("Recent activity") { showLog = true }
                } footer: {
                    Text("Sends to \(Secrets.url.replacingOccurrences(of: "https://", with: "")) as “\(Secrets.device)”. Recording the mic keeps the orange dot on.")
                }
            }
            .navigationTitle("Lifelog")
            .sheet(isPresented: $showLog) {
                NavigationStack {
                    List(Log.recent, id: \.self) { Text($0).font(.caption.monospaced()) }
                        .navigationTitle("Recent activity")
                }
            }
        }
        .onReceive(timer) { _ in tick += 1 }
        .onAppear {
            Notifier.requestPermission()
            if Sensors.shared.locationWanted { Sensors.shared.requestLocation() }
            Sensors.shared.requestMotion()
        }
    }

    private var statusLine: String {
        _ = tick
        return "\(Store.shared.recorded) events since launch"
    }
}

struct LevelBar: View {
    let db: Float
    var body: some View {
        let x = CGFloat(max(0, min(1, (db + 70) / 60)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule().fill(Color.red.opacity(0.8)).frame(width: 60 * x)
        }
        .frame(width: 60, height: 6)
    }
}
