// Everything else the phone can tell about your day, recorded as plain facts (no interpretation here):
//   screen   — screen on/off, locked/unlocked (when you picked up the phone and for how long)
//   call     — phone/FaceTime/WhatsApp calls starting, connecting and ending (no numbers or names)
//   battery  — charging / unplugged, level in 5% steps
//   motion   — walking, running, cycling, in a vehicle, still (from the motion coprocessor; it keeps 7 days of history)
//   steps    — steps per 5 minutes
//   visit / location — arriving at and leaving places, and moves of ~500 m (no continuous GPS)
//   app      — this app starting, going to the background, being terminated (gaps in the phone's record)
import CallKit
import CoreLocation
import CoreMotion
import MapKit
import UIKit
import notify

final class Sensors: NSObject, @unchecked Sendable, CXCallObserverDelegate, CLLocationManagerDelegate {
    static let shared = Sensors()

    private let calls = CXCallObserver()
    private let location = CLLocationManager()
    private let activity = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private var tokens: [Int32] = []
    private var lastBatteryStep = -1
    private var lastScreen: String?

    var locationWanted: Bool {
        get { UserDefaults.standard.object(forKey: "locationOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "locationOn"); newValue ? startLocation() : stopLocation() }
    }

    func start() {
        calls.setDelegate(self, queue: .main)
        startScreen()
        startBattery()
        if locationWanted { startLocation() }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Store.shared.log("screen", ["state": "data-unlocked"])
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            Store.shared.log("screen", ["state": "data-locked"])
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Store.shared.log("battery", ["low_power": ProcessInfo.processInfo.isLowPowerModeEnabled])
        }
    }

    // MARK: screen (Darwin notifications SpringBoard posts; they work while the app runs in the background)

    private func startScreen() {
        watch("com.apple.springboard.lockstate") { state in
            self.screen(state == 1 ? "locked" : "unlocked")
        }
        watch("com.apple.springboard.hasBlankedScreen") { state in
            self.screen(state == 1 ? "off" : "on")
        }
    }

    private func screen(_ s: String) {
        guard s != lastScreen else { return }
        lastScreen = s
        Store.shared.log("screen", ["state": s])
    }

    private func watch(_ name: String, _ handler: @escaping (UInt64) -> Void) {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { t in
            var state: UInt64 = 0
            notify_get_state(t, &state)
            handler(state)
        }
        if status == NOTIFY_STATUS_OK { tokens.append(token) }
    }

    // MARK: calls

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let state = call.hasEnded ? "ended" : call.hasConnected ? "connected" : "ringing"
        Store.shared.log("call", ["call": String(call.uuid.uuidString.prefix(8)), "state": state, "outgoing": call.isOutgoing,
                                  "on_hold": call.isOnHold])
    }

    // MARK: battery

    private func startBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in self.battery(force: true) }
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in self.battery(force: false) }
        battery(force: true)
    }

    private func battery(force: Bool) {
        let d = UIDevice.current
        let pct = Int((d.batteryLevel * 100).rounded())
        let step = pct / 5
        guard force || step != lastBatteryStep else { return }
        lastBatteryStep = step
        let state = ["unknown", "unplugged", "charging", "full"][min(d.batteryState.rawValue, 3)]
        Store.shared.log("battery", ["level": pct, "state": state])
    }

    // MARK: motion (queried in arrears; the coprocessor records it even while we're asleep)

    func collectMotion() {
        let now = Date()
        let key = "motionUntil"
        let since = UserDefaults.standard.object(forKey: key) as? Date ?? now.addingTimeInterval(-3600)
        let from = max(since, now.addingTimeInterval(-6 * 86400))
        guard now.timeIntervalSince(from) > 30 else { return }
        if CMMotionActivityManager.isActivityAvailable() {
            activity.queryActivityStarting(from: from, to: now, to: .main) { acts, err in
                guard let acts, err == nil else { return }
                var last = UserDefaults.standard.string(forKey: "motionLast")
                for a in acts {
                    let name = a.automotive ? "vehicle" : a.cycling ? "cycling" : a.running ? "running" : a.walking ? "walking"
                        : a.stationary ? "still" : "unknown"
                    if name == "unknown" || name == last || a.confidence == .low { continue }
                    last = name
                    Store.shared.log("motion", ["activity": name, "confidence": ["low", "medium", "high"][a.confidence.rawValue]],
                                     at: a.startDate)
                }
                UserDefaults.standard.set(last, forKey: "motionLast")
                UserDefaults.standard.set(now, forKey: key)
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            // 5-minute bins, so a walk shows up with its real start and end
            var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 300).rounded(.down) * 300)
            let lastBin = UserDefaults.standard.double(forKey: "stepsUntil")
            if t.timeIntervalSince1970 < lastBin { t = Date(timeIntervalSince1970: lastBin) }
            while t.addingTimeInterval(300) <= now {
                let a = t, b = t.addingTimeInterval(300)
                pedometer.queryPedometerData(from: a, to: b) { d, _ in
                    guard let d, d.numberOfSteps.intValue > 0 else { return }
                    Store.shared.log("steps", ["steps": d.numberOfSteps.intValue, "meters": Int(d.distance?.doubleValue ?? 0),
                                               "to": b.timeIntervalSince1970], at: a)
                }
                t = b
            }
            UserDefaults.standard.set(t.timeIntervalSince1970, forKey: "stepsUntil")
        }
    }

    func requestMotion() {
        // the first query triggers the permission prompt
        activity.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in }
    }

    // MARK: location: visits + significant changes (cheap; also relaunches the app if iOS killed it)

    func requestLocation() {
        location.delegate = self
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: location.requestAlwaysAuthorization()
        default: break
        }
    }

    private func startLocation() {
        location.delegate = self
        location.pausesLocationUpdatesAutomatically = false
        guard [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus) else { return }
        location.startMonitoringVisits()
        location.startMonitoringSignificantLocationChanges()
    }

    private func stopLocation() {
        location.stopMonitoringVisits()
        location.stopMonitoringSignificantLocationChanges()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Store.shared.log("app", ["state": "location-permission", "value": ["not-asked", "restricted", "denied", "always", "in-use"][Int(s.rawValue)]])
        if s == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        if locationWanted { startLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        var d: [String: Any] = ["lat": visit.coordinate.latitude, "lon": visit.coordinate.longitude,
                                "acc": Int(visit.horizontalAccuracy)]
        if visit.arrivalDate != .distantPast { d["arrival"] = visit.arrivalDate.timeIntervalSince1970 }
        if visit.departureDate != .distantFuture { d["departure"] = visit.departureDate.timeIntervalSince1970 }
        let when = visit.departureDate != .distantFuture ? visit.departureDate : visit.arrivalDate
        let loc = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        Task { @MainActor in
            if let place = await Self.placeName(loc) { d["place"] = place }
            Store.shared.log("visit", d, at: when == .distantPast ? Date() : when)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            Store.shared.log("location", ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "acc": Int(l.horizontalAccuracy),
                                          "speed": l.speed >= 0 ? r2(l.speed) : -1], at: l.timestamp)
        }
        // iOS may have relaunched us for this; make sure the mic is back
        AppState.shared.ensureRunning(reason: "location wake")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// "Café Name, Street 1" — Apple's reverse geocoder (on-device cache + Apple Maps), no third parties.
    static func placeName(_ loc: CLLocation) async -> String? {
        guard let req = MKReverseGeocodingRequest(location: loc) else { return nil }
        guard let item = try? await req.mapItems.first else { return nil }
        let addr = item.address?.shortAddress ?? item.address?.fullAddress
        return [item.name, addr].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { acc, s in
            if !acc.contains(s) { acc.append(s) }
        }.joined(separator: ", ")
    }
}
