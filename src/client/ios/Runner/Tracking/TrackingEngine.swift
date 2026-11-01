import BackgroundTasks
import CoreLocation
import Network
import UIKit


// Native location engine — the iOS counterpart of
// android/app/src/main/kotlin/com/legacy/legacytracker/tracking/. Same model:
//
// STATIONARY (normal) — GPS off. iOS wakes (or relaunches) the app for a
// region exit around the parking spot, a significant location change, or a
// visit departure. All three survive the app being terminated.
//
// MOVING — standard GPS updates (allowed in the background thanks to the
// `location` background mode and "Always" authorization); PathSampler keeps
// only the fixes the replay needs; after a few minutes without displacement
// GPS stops and the region is re-armed at the new parking spot.
//
// Engine state lives on the main thread, where CLLocationManager delivers. The upload batch (read,
// JSON encoding, delete after the server took it) runs on the uploader's serial queue; the SQLite
// connection is opened in serialized mode, so both threads may use it.


// MARK: - Engine

private enum SessionKind { case trip, ping }

/// GPS session while moving (trip) or while taking one fresh fix (ping).
private final class Session {
    var kind: SessionKind
    let reason: String
    let sampler = PathSampler()
    let stopDetector = StopDetector()
    let startedAt = Date()
    var lastFixAt = Date()
    var lastFix: Fix?
    var lastAccepted: Fix?
    var rejectedJumps = 0
    var pingBest: Fix?
    var lastLiveSent: Fix?
    var lastLiveAt: Date?
    var liveSoon = false
    /// Time (ms) of the first fix of the current run of near-zero GPS speeds.
    private var stillSince: Int64?

    /// The stop timeout for this fix: shorter once GPS has reported standing still long enough.
    func stopTimeout(after fix: Fix) -> TimeInterval {
        if fix.hasSpeed {
            if fix.speed >= Tuning.stillSpeed {
                stillSince = nil
            } else if stillSince == nil {
                stillSince = fix.time
            }
        }
        guard let since = stillSince, Double(fix.time - since) >= Tuning.stopTimeoutStill * 1000 else {
            return Tuning.stopTimeout
        }
        return Tuning.stopTimeoutStill
    }

    // Jitter filter: how far the trip got from its start, and its first stored row, so a trip that
    // went nowhere can be dropped before upload. Resumed trips are never discarded (their start is
    // not known).
    private var discardable = false
    private var origin: Fix?
    private var extentM = 0.0
    private(set) var firstRowId: Int64 = 0

    init(kind: SessionKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    func prepareNewTrip(anchor: Fix?) {
        discardable = kind == .trip
        origin = anchor
        sampler.startTrip(departureAnchor: anchor)
    }

    func noteStored(_ rowId: Int64) {
        if firstRowId == 0 && rowId > 0 { firstRowId = rowId }
    }

    func noteExtent(_ fix: Fix) {
        let start = origin ?? fix
        origin = start
        extentM = max(extentM, GeoMath.distance(start, fix))
    }

    func wasJitter(store: TrackingStore) -> Bool {
        discardable && kind == .trip && firstRowId > 0 &&
            extentM < Tuning.minTripExtent && store.hasPoint(firstRowId)
    }

    func currentStop() -> Fix? {
        stopDetector.currentStop() ?? lastAccepted ?? lastFix
    }
}

/// Fresh fix requested while the app is on screen and parked.
private struct ForegroundPing {
    let reason: String
    let startedAt = Date()
    var best: Fix?
}

final class TrackingEngine: NSObject, CLLocationManagerDelegate {
    static let shared = TrackingEngine()

    static let refreshTaskId = "com.legacy.legacytracker.refresh"
    private static let regionId = "lt_stationary"
    static let sourcePing = "ping"
    static let sourceHeartbeat = "heartbeat"

    let state = EngineState()
    let store = TrackingStore()
    private(set) lazy var uploader = Uploader(state: state, store: store)
    private let manager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()

    /// Receives engine events while the Flutter UI is attached.
    var listener: (([String: Any]) -> Void)?

    private var bootstrapped = false
    private var appVisible = false
    private var session: Session?
    private var gpsRunning = false
    private var foregroundPing: ForegroundPing?
    private var tickTimer: Timer?
    private var lastFixTime: Int64 = 0
    private var queuedLive: Fix?
    private var pendingSince: Date?
    private var backoffUntil: Date?
    private var backoff = Tuning.uploadBackoffMin
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
    }

    // MARK: Launch

    /// Call first thing in application(_:didFinishLaunchingWithOptions:) —
    /// also on background relaunches for location events, which deliver to
    /// this manager's delegate.
    func bootstrap(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        guard !bootstrapped else { return }
        bootstrapped = true
        manager.delegate = self
        UIDevice.current.isBatteryMonitoringEnabled = true
        uploader.trackingIssues = { [weak self] in self?.trackingIssues() ?? [] }
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false

        BGTaskScheduler.shared.register(forTaskWithIdentifier: TrackingEngine.refreshTaskId, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleRefresh(task)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let online = path.status == .satisfied
                let cameOnline = online && !self.uploader.online
                self.uploader.online = online
                if cameOnline { self.maybeFlush(force: true) }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        if launchOptions?[.location] != nil {
            log("lifecycle", "Relaunched by iOS for a location event")
        }
        switch state.mode {
        case .off:
            break
        case .stationary:
            armStationary(initialExit: false)
        case .moving:
            resumeTrip()
        }
    }

    // MARK: Commands from Dart

    func configure(baseUrl: String, authHeader: String, userId: String, batterySaver: Bool) {
        if let previous = state.userId, previous != userId {
            log("config", "Account changed — discarding \(store.pendingCount()) unsent point(s)")
            store.clearPoints()
            state.clearRuntime()
        }
        state.saveConfig(baseUrl: baseUrl, authHeader: authHeader, userId: userId, batterySaver: batterySaver)
        applyGpsProfile()
        maybeFlush(force: true)
    }

    func start() {
        guard state.hasCredentials else {
            log("lifecycle", "Start ignored: not configured")
            return
        }
        if state.mode == .off {
            state.mode = .stationary
            log("lifecycle", "Tracking enabled")
        }
        if state.mode == .moving {
            if session == nil { resumeTrip() }
        } else {
            armStationary(initialExit: false)
            if state.anchor == nil { requestPing("first fix") }
        }
        updateGps()
        emitState()
    }

    func stop(clearData: Bool, completion: @escaping () -> Void) {
        let previous = state.mode
        state.mode = .off
        if let current = session {
            session = nil
            if current.kind == .trip {
                for (fix, source) in current.sampler.finishTrip(stop: current.currentStop()) { record(fix, source) }
            }
        }
        stopTick()
        disarmStationary()
        updateGps()
        log("lifecycle", "Tracking disabled (was \(previous.rawValue))")
        emitState()
        guard clearData else {
            maybeFlush(force: true)
            completion()
            return
        }
        // Last chance to deliver what was recorded under these credentials.
        beginBackgroundWork()
        uploader.uploadAll(live: nil) { [weak self] outcome in
            guard let self = self else { return }
            self.log("lifecycle", "Final upload before sign-out: \(self.describe(outcome))")
            self.store.clearPoints()
            self.state.clearRuntime()
            self.state.clearCredentials()
            self.endBackgroundWork()
            completion()
        }
    }

    func setAppVisible(_ visible: Bool) {
        guard appVisible != visible else { return }
        appVisible = visible
        guard state.mode != .off else { return }
        if visible && state.mode == .stationary {
            foregroundPing = ForegroundPing(reason: "app opened")
        }
        if !visible { foregroundPing = nil }
        updateGps()
        if visible { maybeFlush(force: true) }
    }

    func flush() {
        maybeFlush(force: true)
    }

    /// Silent push from the server (FCM data message). Returns whether it was ours.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let command = userInfo["lt_cmd"] as? String else { return false }
        let ttl = Int(userInfo["lt_ttl"] as? String ?? "") ?? 0
        guard state.mode != .off else { return true }
        switch command {
        case "live":
            let wasLive = isLive
            applyLiveTtl(ttl)
            let sincePing = Date().timeIntervalSince1970 - state.lastPingAt
            if !wasLive || sincePing > Tuning.pingMinInterval { requestPing("someone opened the map") }
        case "idle":
            applyLiveTtl(0)
        case "refresh":
            // Someone is waiting on this phone: skip the ping throttle.
            requestPing("location refresh requested")
        default:
            break
        }
        return true
    }

    // MARK: State transitions

    private func enterMoving(_ reason: String) {
        guard state.mode != .off else { return }
        if let current = session {
            if current.kind == .ping { convertToTrip(current, reason) }
            return
        }
        let trip = Session(kind: .trip, reason: reason)
        trip.prepareNewTrip(anchor: state.anchor)
        beginTrip(trip, reason)
    }

    private func beginTrip(_ trip: Session, _ reason: String) {
        state.mode = .moving
        session = trip
        disarmRegion()
        log("state", "Moving (\(reason))")
        updateGps()
        startTick()
        emitState()
    }

    private func convertToTrip(_ current: Session, _ reason: String) {
        current.kind = .trip
        current.prepareNewTrip(anchor: state.anchor)
        state.mode = .moving
        disarmRegion()
        log("state", "Moving (\(reason))")
        updateGps()
        startTick()
        emitState()
    }

    private func resumeTrip() {
        guard session == nil else { return }
        let trip = Session(kind: .trip, reason: "resumed")
        if let last = state.lastRecorded,
           Date().timeIntervalSince1970 - Double(last.time) / 1000 < Tuning.resumeWindow {
            trip.sampler.resumeTrip(lastStored: last)
        } else {
            trip.sampler.startTrip(departureAnchor: state.anchor)
        }
        beginTrip(trip, "resumed after relaunch")
    }

    private func endTrip(_ trip: Session, stop: Fix?, why: String) {
        guard session === trip else { return }
        // Keep running long enough to store and upload once GPS is off.
        beginBackgroundWork()
        session = nil
        stopTick()
        for (fix, source) in trip.sampler.finishTrip(stop: stop) { trip.noteStored(record(fix, source)) }
        if trip.wasJitter(store: store) {
            // Never got anywhere: GPS wander while parked, not a trip. Drop it unless part of it
            // already reached the server (the server filters those the same way).
            store.deleteTripFrom(trip.firstRowId, keepSources: [TrackingEngine.sourcePing, TrackingEngine.sourceHeartbeat])
            log("state", "Discarded a trip that never left \(Int(Tuning.minTripExtent)) m")
        }
        state.lastRecorded = nil
        if let stop = stop { state.anchor = stop }
        if state.mode != .off { state.mode = .stationary }
        log("state", "Stationary (\(why))")
        if state.mode == .stationary { armStationary(initialExit: false) }
        updateGps()
        maybeFlush(force: true)
        emitState()
        endBackgroundWork()
    }

    // MARK: Stationary triggers

    private func armStationary(initialExit: Bool) {
        if let anchor = state.anchor { monitorRegion(around: anchor, checkOutside: initialExit) }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        scheduleRefresh()
    }

    private func disarmStationary() {
        disarmRegion()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
    }

    private func monitorRegion(around anchor: Fix, checkOutside: Bool) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        disarmRegion()
        let wanted = min(max(Tuning.geofenceRadius, anchor.accuracy * 2), Tuning.geofenceMaxRadius)
        let radius = min(wanted, manager.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: anchor.lat, longitude: anchor.lon),
            radius: radius,
            identifier: TrackingEngine.regionId
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        if checkOutside { manager.requestState(for: region) }
    }

    private func disarmRegion() {
        for region in manager.monitoredRegions where region.identifier == TrackingEngine.regionId {
            manager.stopMonitoring(for: region)
        }
    }

    // MARK: GPS

    /// GPS runs while a session (trip or ping) is active or the app is on screen.
    private func updateGps() {
        let wanted = state.mode != .off && (session != nil || appVisible)
        if wanted {
            applyGpsProfile()
            if !gpsRunning {
                manager.startUpdatingLocation()
                gpsRunning = true
            }
        } else if gpsRunning {
            manager.stopUpdatingLocation()
            gpsRunning = false
        }
    }

    private func applyGpsProfile() {
        if session == nil {
            // Parked with the app on screen: full accuracy only while a fresh fix is wanted.
            let idle = foregroundPing == nil && !isLive
            manager.desiredAccuracy = idle ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
            manager.distanceFilter = idle ? Tuning.foregroundIdleDistance : kCLDistanceFilterNone
            return
        }
        let saver = session?.kind == .trip && !appVisible && !isLive && lowPower
        manager.desiredAccuracy = saver ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        session?.sampler.tuning = saver ? SamplerTuning.saver : SamplerTuning.standard
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations { handle(Fix(location: location)) }
    }

    private func handle(_ fix: Fix) {
        lastFixTime = max(lastFixTime, fix.time)
        emitLocation(fix)
        if let current = session {
            switch current.kind {
            case .trip: tripFix(current, fix)
            case .ping: pingSessionFix(current, fix)
            }
        } else if appVisible {
            foregroundFix(fix)
        } else {
            significantChangeFix(fix)
        }
    }

    private func tripFix(_ trip: Session, _ fix: Fix) {
        trip.lastFixAt = Date()
        trip.lastFix = fix
        if isJump(trip, fix) { return }

        let timeout = trip.stopTimeout(after: fix)
        if fix.accuracy <= Tuning.maxStopAccuracy,
           let stop = trip.stopDetector.offer(fix, timeout: timeout) {
            endTrip(trip, stop: stop, why: "no movement for \(Int(timeout / 60)) min")
            return
        }
        let maxAccuracy = trip.sampler.tuning == SamplerTuning.saver ? Tuning.maxRecordAccuracySaver : Tuning.maxRecordAccuracy
        if fix.accuracy <= maxAccuracy {
            trip.lastAccepted = fix
            trip.noteExtent(fix)
            for (stored, source) in trip.sampler.offer(fix) { trip.noteStored(record(stored, source)) }
        }
        if isLive || trip.liveSoon { maybeSendLive(trip, fix) }
        maybeFlush()
    }

    private func isJump(_ trip: Session, _ fix: Fix) -> Bool {
        guard let previous = trip.lastAccepted else { return false }
        let seconds = Double(fix.time - previous.time) / 1000
        if seconds <= 0 { return true }
        let slack = (previous.hasAccuracy ? previous.accuracy : 50) + (fix.hasAccuracy ? fix.accuracy : 50)
        let distance = GeoMath.distance(previous, fix)
        let jump = distance > 3 * slack && (distance - slack) / seconds > Tuning.maxPlausibleSpeed
        guard jump else {
            trip.rejectedJumps = 0
            return false
        }
        trip.rejectedJumps += 1
        if trip.rejectedJumps >= 3 {
            trip.rejectedJumps = 0
            trip.lastAccepted = nil
            return false
        }
        return true
    }

    private func maybeSendLive(_ trip: Session, _ fix: Fix) {
        guard fix.accuracy <= Tuning.pingMaxAccuracy else { return }
        let now = Date()
        var due = trip.liveSoon || trip.lastLiveSent == nil
        if let lastAt = trip.lastLiveAt, let previous = trip.lastLiveSent {
            let elapsed = now.timeIntervalSince(lastAt)
            due = due || elapsed >= Tuning.liveKeepalive ||
                (elapsed >= Tuning.liveMinInterval && GeoMath.distance(previous, fix) >= Tuning.liveMinDistance)
        }
        guard due else { return }
        trip.liveSoon = false
        trip.lastLiveSent = fix
        trip.lastLiveAt = now
        startUpload(live: fix)
    }

    private func pingSessionFix(_ ping: Session, _ fix: Fix) {
        ping.lastFix = fix
        if fix.accuracy <= Tuning.pingGoodAccuracy {
            completePing(ping, fix)
        } else if ping.pingBest == nil || fix.accuracy < ping.pingBest!.accuracy {
            ping.pingBest = fix
        }
    }

    private func completePing(_ ping: Session, _ fix: Fix?) {
        guard session === ping, ping.kind == .ping else { return }
        guard let fix = fix else {
            log("ping", "No GPS fix within \(Int(Tuning.pingTimeout))s")
            endPing(ping)
            heartbeatNow()
            maybeFlush(force: true)
            return
        }
        onPingFix(fix, reason: ping.reason)
        if ping.kind == .ping { endPing(ping) }
    }

    private func endPing(_ ping: Session) {
        guard session === ping else { return }
        session = nil
        stopTick()
        updateGps()
        emitState()
        endBackgroundWork()
    }

    private func onPingFix(_ fix: Fix, reason: String) {
        guard fix.accuracy <= Tuning.pingMaxAccuracy else {
            // A cell-tower-grade fix would make the marker jump; the parking
            // spot is the better answer. Still report in (last seen, battery).
            log("ping", "Fix for \"\(reason)\" too coarse — sent the parked position")
            heartbeatNow()
            maybeFlush(force: true)
            return
        }
        record(fix, TrackingEngine.sourcePing)
        maybeFlush(force: true)
        let anchor = state.anchor
        let distance = anchor.map { GeoMath.distance($0, fix) } ?? 0
        log("ping", "Fresh fix for \"\(reason)\" (±\(Int(fix.accuracy)) m)")
        let moved = anchor != nil &&
            distance > max(Tuning.geofenceRadius, 2 * fix.accuracy)
        if moved {
            enterMoving("\(Int(distance)) m from parked spot")
        } else if anchor == nil || (fix.accuracy + 5 < anchor!.accuracy && distance <= anchor!.accuracy + fix.accuracy) {
            let refined = anchor == nil ? fix : fix.with(time: anchor!.time)
            state.anchor = refined
            if state.mode == .stationary { monitorRegion(around: refined, checkOutside: false) }
        }
    }

    private func foregroundFix(_ fix: Fix) {
        guard state.mode == .stationary else { return }
        if var ping = foregroundPing {
            if ping.best == nil || fix.accuracy < ping.best!.accuracy { ping.best = fix }
            foregroundPing = ping
            if fix.accuracy <= Tuning.pingGoodAccuracy || Date().timeIntervalSince(ping.startedAt) >= 10,
               let best = ping.best {
                foregroundPing = nil
                onPingFix(best, reason: ping.reason)
                if state.mode != .stationary { return }
                // Got what the full-accuracy request was for.
                if gpsRunning { applyGpsProfile() }
            }
        }
        guard let anchor = state.anchor, fix.accuracy <= Tuning.foregroundMoveAccuracy else { return }
        let distance = GeoMath.distance(anchor, fix)
        if distance > Tuning.foregroundMoveThreshold && (distance > Tuning.geofenceRadius || (fix.hasSpeed && fix.speed > 1)) {
            enterMoving("moving with the app open")
        }
    }

    /// Significant-change updates while parked: a fallback trip trigger.
    private func significantChangeFix(_ fix: Fix) {
        guard state.mode == .stationary else { return }
        guard let anchor = state.anchor else {
            if fix.accuracy <= Tuning.pingMaxAccuracy {
                state.anchor = fix
                monitorRegion(around: fix, checkOutside: false)
            }
            return
        }
        let distance = GeoMath.distance(anchor, fix)
        if fix.accuracy <= 2 * Tuning.pingMaxAccuracy && distance > max(Tuning.geofenceRadius, 2 * fix.accuracy) {
            enterMoving("significant change \(Int(distance)) m from parked spot")
        } else {
            heartbeatIfDue()
            maybeFlush()
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == TrackingEngine.regionId, state.mode == .stationary else { return }
        enterMoving("left the parked area")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState regionState: CLRegionState, for region: CLRegion) {
        guard region.identifier == TrackingEngine.regionId, regionState == .outside,
              state.mode == .stationary, session == nil else { return }
        enterMoving("outside the parked area")
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.departureDate != Date.distantFuture, state.mode == .stationary else { return }
        enterMoving("visit ended")
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        log("geofence", "Region monitoring failed: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        log("position", "Location error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard state.mode == .stationary, status == .authorizedAlways else { return }
        armStationary(initialExit: false)
    }

    // MARK: Pings

    private func requestPing(_ reason: String) {
        guard state.mode != .off else { return }
        state.lastPingAt = Date().timeIntervalSince1970
        if let current = session {
            if current.kind == .trip {
                current.liveSoon = true
                if let last = current.lastFix,
                   Date().timeIntervalSince1970 * 1000 - Double(last.time) < 5000 {
                    maybeSendLive(current, last)
                }
            }
            return
        }
        if appVisible {
            foregroundPing = ForegroundPing(reason: reason)
            updateGps()
            return
        }
        // Woken by a push or relaunch: a short GPS session, kept alive by the
        // location background mode, then back to sleep.
        beginBackgroundWork()
        session = Session(kind: .ping, reason: reason)
        updateGps()
        startTick()
    }

    // MARK: Ticks

    private func startTick() {
        tickTimer?.invalidate()
        let interval: TimeInterval = session?.kind == .ping ? 1 : Tuning.tickInterval
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func onTick() {
        if lastFixTime > Int64(state.lastFixAt) { state.lastFixAt = Double(lastFixTime) }
        guard let current = session else {
            stopTick()
            return
        }
        switch current.kind {
        case .ping:
            if Date().timeIntervalSince(current.startedAt) >= Tuning.pingTimeout {
                completePing(current, current.pingBest ?? current.lastFix)
            }
        case .trip:
            if Date().timeIntervalSince(current.lastFixAt) >= Tuning.noFixTimeout {
                endTrip(current, stop: current.currentStop(), why: "no GPS fixes for \(Int(Tuning.noFixTimeout / 60)) min")
                return
            }
            applyGpsProfile()
            maybeFlush()
            // Re-start the timer at the trip interval after a ping converted.
            if tickTimer?.timeInterval != Tuning.tickInterval { startTick() }
        }
    }

    // MARK: Recording and uploading

    @discardableResult
    private func record(_ fix: Fix, _ source: String) -> Int64 {
        let (battery, charging) = Battery.read()
        let rowId = store.insert(fix, source: source, battery: battery, charging: charging)
        if pendingSince == nil { pendingSince = Date() }
        if source != TrackingEngine.sourcePing && source != TrackingEngine.sourceHeartbeat {
            state.lastRecorded = fix
        }
        return rowId
    }

    private func heartbeatIfDue() {
        let now = Date().timeIntervalSince1970
        guard now - max(state.lastUploadOkAt, state.lastHeartbeatAt) >= Tuning.heartbeatInterval else { return }
        heartbeatNow()
    }

    /// Re-sends the parking spot with its original timestamp: the server
    /// stores nothing new but refreshes "last seen" and the battery level.
    private func heartbeatNow() {
        guard let anchor = state.anchor else { return }
        state.lastHeartbeatAt = Date().timeIntervalSince1970
        record(anchor, TrackingEngine.sourceHeartbeat)
    }

    private func maybeFlush(force: Bool = false) {
        guard !uploader.busy, state.hasCredentials, !state.authFailed else { return }
        if !force, let until = backoffUntil, Date() < until { return }
        if pendingSince == nil {
            guard store.hasPending(1) else { return }
            pendingSince = Date()
        }
        let age = Date().timeIntervalSince(pendingSince ?? Date())
        let due = force || isLive || appVisible || age >= Tuning.uploadMaxAge ||
            store.hasPending(Tuning.uploadMaxPending)
        if due { startUpload(live: nil) }
    }

    private func startUpload(live: Fix?) {
        if uploader.busy {
            if live != nil { queuedLive = live }
            return
        }
        beginBackgroundWork()
        uploader.uploadAll(live: live) { [weak self] outcome in
            guard let self = self else { return }
            self.handleUploadOutcome(outcome)
            if self.store.pendingCount() == 0 {
                self.pendingSince = nil
            } else if case .sent = outcome {
                self.pendingSince = Date()
            }
            if let next = self.queuedLive {
                self.queuedLive = nil
                if self.isLive { self.startUpload(live: next) }
            }
            self.endBackgroundWork()
        }
    }

    private func handleUploadOutcome(_ outcome: Uploader.Outcome) {
        switch outcome {
        case let .sent(count, liveTtl):
            state.lastUploadOkAt = Date().timeIntervalSince1970
            state.lastUploadError = nil
            backoffUntil = nil
            backoff = Tuning.uploadBackoffMin
            if let ttl = liveTtl { applyLiveTtl(ttl) }
            if count > 0 { log("upload", "Uploaded \(count) point(s)") }
            emit(["type": "upload", "ok": true, "count": count])
        case .failed, .offline:
            let reason = describe(outcome)
            state.lastUploadError = reason
            backoffUntil = Date().addingTimeInterval(backoff)
            backoff = min(backoff * 2, Tuning.uploadBackoffMax)
            scheduleRefresh()
            log("upload", "Upload deferred: \(reason)")
            emit(["type": "upload", "ok": false, "error": reason])
        case .authRejected:
            if !state.authFailed { log("upload", "Server rejected the upload credentials") }
            state.authFailed = true
            emit(["type": "auth_required"])
        case .nothingToSend, .notConfigured:
            break
        }
    }

    private func describe(_ outcome: Uploader.Outcome) -> String {
        switch outcome {
        case let .sent(count, _): return "sent \(count)"
        case let .failed(reason): return reason
        case .offline: return "offline"
        case .authRejected: return "credentials rejected"
        case .nothingToSend: return "nothing to send"
        case .notConfigured: return "not configured"
        }
    }

    // MARK: Live mode

    var isLive: Bool { Date().timeIntervalSince1970 < state.liveUntil }

    private func applyLiveTtl(_ ttlSeconds: Int) {
        let wasLive = isLive
        state.liveUntil = ttlSeconds > 0 ? Date().timeIntervalSince1970 + Double(ttlSeconds) : 0
        if wasLive != isLive {
            log("live", isLive ? "Live mode on — someone is watching" : "Live mode off")
            applyGpsProfile()
            emitState()
        }
    }

    private var lowPower: Bool {
        if state.batterySaver { return true }
        let (level, charging) = Battery.read()
        return (level ?? 100) <= Tuning.lowBatteryPercent && charging != true
    }

    // MARK: Background execution

    /// Keeps the app running for a store-and-upload after it was woken in
    /// the background (or after GPS stops, which would otherwise let iOS
    /// suspend it immediately).
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "lt.work") { [weak self] in
            // Expiring: must end now or iOS terminates the app.
            self?.finishBackgroundWork()
        }
    }

    /// Ends the background task once nothing (ping, upload) still needs it.
    private func endBackgroundWork() {
        guard session?.kind != .ping, !uploader.busy else { return }
        finishBackgroundWork()
    }

    private func finishBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: TrackingEngine.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Tuning.refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Opportunistic wake-up from iOS: re-arm, heartbeat while parked, flush.
    private func handleRefresh(_ task: BGAppRefreshTask) {
        DispatchQueue.main.async {
            guard self.state.mode != .off else {
                task.setTaskCompleted(success: true)
                return
            }
            self.scheduleRefresh()
            if self.state.mode == .stationary && self.session == nil {
                self.armStationary(initialExit: true)
                self.heartbeatIfDue()
            }
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            guard !self.uploader.busy else {
                task.setTaskCompleted(success: true)
                return
            }
            self.uploader.uploadAll(live: nil) { outcome in
                self.handleUploadOutcome(outcome)
                if case .sent = outcome { task.setTaskCompleted(success: true) } else { task.setTaskCompleted(success: false) }
            }
        }
    }

    // MARK: Status and events for the UI

    /// Codes from the server's closed set (`services/tracking-issues.ts`).
    /// iOS reports a phone-wide "Location Services" switch as `.denied`, so
    /// that case and a refused permission both read as a missing permission.
    private func locationAccess() -> (authorization: CLAuthorizationStatus, precise: Bool) {
        if #available(iOS 14.0, *) {
            return (manager.authorizationStatus, manager.accuracyAuthorization == .fullAccuracy)
        }
        return (CLLocationManager.authorizationStatus(), true)
    }

    func trackingIssues() -> [String] {
        trackingIssues(locationAccess())
    }

    private func trackingIssues(_ access: (authorization: CLAuthorizationStatus, precise: Bool)) -> [String] {
        switch access.authorization {
        case .denied, .restricted, .notDetermined:
            return ["location_permission"]
        default:
            break
        }
        var issues: [String] = []
        if access.authorization != .authorizedAlways { issues.append("background_location") }
        if !access.precise { issues.append("precise_location") }
        return issues
    }

    func status() -> [String: Any] {
        let anchor = state.anchor
        let access = locationAccess()
        let lastFix = max(Double(lastFixTime), state.lastFixAt)
        var map: [String: Any] = [
            "mode": state.mode.rawValue,
            "configured": state.hasCredentials,
            "authFailed": state.authFailed,
            "live": isLive,
            "lowPower": lowPower,
            "pending": store.pendingCount(),
            "preciseLocation": access.precise,
            "backgroundLocation": access.authorization == .authorizedAlways,
            // Android-only concepts; nothing for the user to fix on iOS.
            "activityRecognition": true,
            "batteryOptimizationIgnored": true,
            "notificationsEnabled": false,
            "issues": trackingIssues(access),
        ]
        if state.lastUploadOkAt > 0 { map["lastUploadAt"] = NSNumber(value: Int64(state.lastUploadOkAt * 1000)) }
        if let error = state.lastUploadError { map["lastUploadError"] = error }
        if lastFix > 0 { map["lastFixAt"] = NSNumber(value: Int64(lastFix)) }
        if let anchor = anchor {
            map["anchorLat"] = anchor.lat
            map["anchorLon"] = anchor.lon
            map["stationarySince"] = NSNumber(value: anchor.time)
        }
        return map
    }

    func logs(limit: Int) -> [[String: Any]] {
        store.logs(limit: limit)
    }

    func log(_ category: String, _ message: String) {
        NSLog("[LtTracking] [%@] %@", category, message)
        store.log(category, message)
    }

    private func emit(_ event: [String: Any]) {
        listener?(event)
    }

    private func emitState() {
        guard listener != nil else { return }
        emit(["type": "state", "mode": state.mode.rawValue, "live": isLive])
    }

    private func emitLocation(_ fix: Fix) {
        guard listener != nil else { return }
        var event: [String: Any] = [
            "type": "location",
            "lat": fix.lat,
            "lon": fix.lon,
            "time": NSNumber(value: fix.time),
        ]
        if fix.hasAccuracy { event["accuracy"] = fix.accuracy }
        if fix.hasSpeed { event["speed"] = fix.speed }
        if fix.bearing >= 0 { event["heading"] = fix.bearing }
        emit(event)
    }
}
