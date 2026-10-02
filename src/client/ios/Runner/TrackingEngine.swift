import BackgroundTasks
import CoreLocation
import Flutter
import Network
import SQLite3
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
// Everything runs on the main thread, where CLLocationManager delivers.

// MARK: - Fix and geometry

struct Fix {
    static let unknownAccuracy = Double.greatestFiniteMagnitude

    /// UTC epoch milliseconds of the observation.
    var time: Int64
    var lat: Double
    var lon: Double
    /// Metres (68% radius); [unknownAccuracy] when absent.
    var accuracy: Double
    /// m/s, negative when unknown.
    var speed: Double = -1
    /// Degrees, negative when unknown.
    var bearing: Double = -1
    var altitude: Double? = nil

    var hasSpeed: Bool { speed >= 0 }
    var hasAccuracy: Bool { accuracy < Fix.unknownAccuracy }
}

extension Fix {
    init(location: CLLocation) {
        self.init(
            time: Int64((location.timestamp.timeIntervalSince1970 * 1000).rounded()),
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : Fix.unknownAccuracy,
            speed: location.speed >= 0 ? location.speed : -1,
            bearing: location.course >= 0 ? location.course : -1,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
    }

    func with(time newTime: Int64) -> Fix {
        var copy = self
        copy.time = newTime
        return copy
    }

    func stopped() -> Fix {
        var copy = self
        copy.speed = 0
        copy.bearing = -1
        return copy
    }
}

enum GeoMath {
    private static let earthRadius = 6_371_008.8
    private static let metresPerDegree = earthRadius * Double.pi / 180

    static func distance(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * Double.pi / 180
        let dLon = (bLon - aLon) * Double.pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
            cos(aLat * Double.pi / 180) * cos(bLat * Double.pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(sqrt(min(max(h, 0), 1)))
    }

    static func distance(_ a: Fix, _ b: Fix) -> Double {
        distance(a.lat, a.lon, b.lat, b.lon)
    }

    /// Distance from p to the segment a→b (local equirectangular projection).
    static func distanceToSegment(_ p: Fix, _ a: Fix, _ b: Fix) -> Double {
        let cosLat = cos(a.lat * Double.pi / 180)
        let bx = (b.lon - a.lon) * cosLat * metresPerDegree
        let by = (b.lat - a.lat) * metresPerDegree
        let px = (p.lon - a.lon) * cosLat * metresPerDegree
        let py = (p.lat - a.lat) * metresPerDegree
        let lengthSq = bx * bx + by * by
        let t = lengthSq <= 0 ? 0 : min(max((px * bx + py * by) / lengthSq, 0), 1)
        let dx = px - t * bx
        let dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - Tuning (mirrors Tuning.kt)

enum Tuning {
    static let geofenceRadius: Double = 150
    static let geofenceMaxRadius: Double = 500
    static let heartbeatInterval: TimeInterval = 25 * 60
    static let refreshInterval: TimeInterval = 30 * 60

    static let maxRecordAccuracy: Double = 40
    static let maxRecordAccuracySaver: Double = 60
    static let maxStopAccuracy: Double = 100
    static let maxPlausibleSpeed: Double = 90
    static let stopTimeout: TimeInterval = 5 * 60
    static let noFixTimeout: TimeInterval = 5 * 60
    static let tickInterval: TimeInterval = 20
    static let resumeWindow: TimeInterval = 10 * 60

    static let uploadBatchSize = 500
    static let uploadMaxAge: TimeInterval = 5 * 60
    static let uploadMaxPending = 200
    static let uploadBackoffMin: TimeInterval = 30
    static let uploadBackoffMax: TimeInterval = 10 * 60

    static let liveMinInterval: TimeInterval = 2.5
    static let liveMinDistance: Double = 8
    static let liveKeepalive: TimeInterval = 30
    static let pingMinInterval: TimeInterval = 10 * 60

    static let pingGoodAccuracy: Double = 20
    static let pingTimeout: TimeInterval = 15
    static let pingMaxAccuracy: Double = 100

    static let foregroundMoveThreshold: Double = 60
    static let foregroundMoveAccuracy: Double = 30
    static let lowBatteryPercent = 15

    static let maxStoredPoints = 100_000
    static let maxLogEntries = 500
}

// MARK: - Path sampler (mirrors PathSampler.kt — see there for the rationale)

struct SamplerTuning: Equatable {
    var tolerance: Double = 5
    var minSpacing: Double = 10
    var maxSpacingSeconds: Double = 8
    var maxSpacingMin: Double = 30
    var maxSpacingMax: Double = 200
    var speedDeltaMin: Double = 3
    var speedDeltaRatio: Double = 0.3

    static let standard = SamplerTuning()
    static let saver = SamplerTuning(tolerance: 12, minSpacing: 15, maxSpacingMax: 300)
}

final class PathSampler {
    static let sourceMove = "move"
    static let sourceTripStart = "trip_start"
    static let sourceTripEnd = "trip_end"

    private static let maxWindow = 400
    private static let maxDepartureGap: Double = 3000
    private static let assumedDepartureSpeed: Double = 1.5

    var tuning = SamplerTuning.standard
    private(set) var last: Fix?
    private var window: [Fix] = []
    private var departure: Fix?
    private var recordedInTrip = 0

    func startTrip(departureAnchor: Fix?) {
        last = nil
        window.removeAll()
        departure = departureAnchor
        recordedInTrip = 0
    }

    func resumeTrip(lastStored: Fix) {
        last = lastStored
        window.removeAll()
        departure = nil
        recordedInTrip = 1
    }

    func offer(_ fix: Fix) -> [(Fix, String)] {
        var out: [(Fix, String)] = []

        if let anchor = departure {
            departure = nil
            let gap = GeoMath.distance(anchor, fix)
            if gap >= tuning.minSpacing && gap <= PathSampler.maxDepartureGap && fix.time - anchor.time > 2 {
                let speed = fix.hasSpeed && fix.speed > 1 ? fix.speed : PathSampler.assumedDepartureSpeed
                let travelMs = Int64(gap / speed * 1000)
                let departedAt = clamp(fix.time - travelMs, anchor.time + 1, fix.time - 1)
                record(anchor.with(time: departedAt).stopped(), PathSampler.sourceTripStart, &out)
            } else {
                record(fix, PathSampler.sourceTripStart, &out)
                return out
            }
        }

        guard var reference = last else {
            record(fix, PathSampler.sourceTripStart, &out)
            return out
        }
        if fix.time <= (window.last ?? reference).time { return out }

        if !window.isEmpty && maxDeviation(reference, fix) > tuning.tolerance {
            let vertex = window[window.count - 1]
            if GeoMath.distance(reference, vertex) >= tuning.minSpacing {
                record(vertex, PathSampler.sourceMove, &out)
                reference = vertex
            } else {
                window.removeAll()
            }
        }

        let travelled = GeoMath.distance(reference, fix)
        if travelled >= maxSpacing(reference, fix, travelled) ||
            (travelled >= tuning.minSpacing && speedChanged(reference, fix)) {
            record(fix, PathSampler.sourceMove, &out)
        } else {
            window.append(fix)
            if window.count > PathSampler.maxWindow { decimateWindow() }
        }
        return out
    }

    func finishTrip(stop: Fix?) -> [(Fix, String)] {
        var out: [(Fix, String)] = []
        departure = nil
        if let reference = last {
            let tail = window.last(where: { stop == nil || $0.time < stop!.time })
            if let tail = tail,
               GeoMath.distance(reference, tail) >= tuning.minSpacing,
               stop == nil || GeoMath.distance(tail, stop!) >= tuning.minSpacing {
                record(tail, PathSampler.sourceMove, &out)
            }
        }
        if let stop = stop, recordedInTrip > 0, last == nil || stop.time > last!.time {
            record(stop.stopped(), PathSampler.sourceTripEnd, &out)
        }
        last = nil
        window.removeAll()
        recordedInTrip = 0
        return out
    }

    private func record(_ fix: Fix, _ source: String, _ out: inout [(Fix, String)]) {
        out.append((fix, source))
        last = fix
        window.removeAll()
        recordedInTrip += 1
    }

    private func maxDeviation(_ from: Fix, _ to: Fix) -> Double {
        var worst = 0.0
        for p in window {
            worst = max(worst, GeoMath.distanceToSegment(p, from, to))
        }
        return worst
    }

    private func maxSpacing(_ from: Fix, _ to: Fix, _ travelled: Double) -> Double {
        let seconds = max(1.0, Double(to.time - from.time) / 1000)
        let speed = to.hasSpeed ? to.speed : travelled / seconds
        return min(max(speed * tuning.maxSpacingSeconds, tuning.maxSpacingMin), tuning.maxSpacingMax)
    }

    private func speedChanged(_ from: Fix, _ to: Fix) -> Bool {
        guard from.hasSpeed && to.hasSpeed else { return false }
        let threshold = max(tuning.speedDeltaMin, tuning.speedDeltaRatio * from.speed)
        return abs(to.speed - from.speed) >= threshold
    }

    private func decimateWindow() {
        let lastIndex = window.count - 1
        window = window.enumerated()
            .filter { $0.offset % 2 == 1 || $0.offset == lastIndex }
            .map { $0.element }
    }

    private func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        low > high ? high : min(max(value, low), high)
    }
}

// MARK: - Stop detector (mirrors StopDetector.kt)

final class StopDetector {
    static let movingSpeed: Double = 2.5

    private let radius: Double = 40
    private let maxRadius: Double = 100
    private var start: Fix?
    private var weightSum = 0.0
    private var latSum = 0.0
    private var lonSum = 0.0
    private var bestAccuracy = Fix.unknownAccuracy

    func reset() {
        start = nil
        weightSum = 0
        latSum = 0
        lonSum = 0
        bestAccuracy = Fix.unknownAccuracy
    }

    func offer(_ fix: Fix, timeout: TimeInterval) -> Fix? {
        let movingFast = fix.hasSpeed && fix.speed > StopDetector.movingSpeed
        guard let first = start, !movingFast, inside(fix, first: first) else {
            begin(fix)
            return nil
        }
        add(fix)
        return Double(fix.time - first.time) >= timeout * 1000 ? currentStop() : nil
    }

    func currentStop() -> Fix? {
        guard let first = start else { return nil }
        return Fix(time: first.time, lat: latSum / weightSum, lon: lonSum / weightSum, accuracy: bestAccuracy, speed: 0)
    }

    private func inside(_ fix: Fix, first: Fix) -> Bool {
        let r = max(radius, min(maxRadius, 1.5 * fix.accuracy))
        return GeoMath.distance(first, fix) <= r &&
            GeoMath.distance(latSum / weightSum, lonSum / weightSum, fix.lat, fix.lon) <= r
    }

    private func begin(_ fix: Fix) {
        reset()
        start = fix
        add(fix)
    }

    private func add(_ fix: Fix) {
        let accuracy = max(3.0, fix.hasAccuracy ? fix.accuracy : maxRadius)
        let weight = 1 / (accuracy * accuracy)
        weightSum += weight
        latSum += fix.lat * weight
        lonSum += fix.lon * weight
        bestAccuracy = min(bestAccuracy, fix.accuracy)
    }
}

// MARK: - Durable queue + activity log (SQLite)

final class TrackingStore {
    struct StoredPoint {
        let id: Int64
        let fix: Fix
        let source: String
        let battery: Int?
        let charging: Bool?
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer?
    private var insertsSincePrune = 0
    private var logsSinceTrim = 0

    /// Opens lazily: right after a reboot, before the first unlock, data
    /// protection keeps the file unreadable — a location relaunch then just
    /// skips storage until the next opportunity.
    private func handle() -> OpaquePointer? {
        if let db = db { return db }
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("lt_tracking.sqlite").path
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            return nil
        }
        db = opened
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS points (
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
              lat REAL NOT NULL, lon REAL NOT NULL, acc REAL, speed REAL,
              heading REAL, alt REAL, source TEXT NOT NULL, battery INTEGER,
              charging INTEGER)
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
              cat TEXT NOT NULL, msg TEXT NOT NULL)
            """)
        return db
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func insert(_ fix: Fix, source: String, battery: Int?, charging: Bool?) {
        guard let db = handle() else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO points (ts, lat, lon, acc, speed, heading, alt, source, battery, charging) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fix.time)
        sqlite3_bind_double(stmt, 2, fix.lat)
        sqlite3_bind_double(stmt, 3, fix.lon)
        bindOptional(stmt, 4, fix.hasAccuracy ? fix.accuracy : nil)
        bindOptional(stmt, 5, fix.hasSpeed ? fix.speed : nil)
        bindOptional(stmt, 6, fix.bearing >= 0 ? fix.bearing : nil)
        bindOptional(stmt, 7, fix.altitude)
        sqlite3_bind_text(stmt, 8, source, -1, TrackingStore.transient)
        if let battery = battery { sqlite3_bind_int(stmt, 9, Int32(battery)) } else { sqlite3_bind_null(stmt, 9) }
        if let charging = charging { sqlite3_bind_int(stmt, 10, charging ? 1 : 0) } else { sqlite3_bind_null(stmt, 10) }
        sqlite3_step(stmt)
        insertsSincePrune += 1
        if insertsSincePrune >= 500 {
            insertsSincePrune = 0
            exec("DELETE FROM points WHERE id <= (SELECT MAX(id) FROM points) - \(Tuning.maxStoredPoints)")
        }
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value = value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    func pending(limit: Int) -> [StoredPoint] {
        guard let db = handle() else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id, ts, lat, lon, acc, speed, heading, alt, source, battery, charging " +
            "FROM points ORDER BY id LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [StoredPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func optionalDouble(_ column: Int32) -> Double? {
                sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
            }
            let fix = Fix(
                time: sqlite3_column_int64(stmt, 1),
                lat: sqlite3_column_double(stmt, 2),
                lon: sqlite3_column_double(stmt, 3),
                accuracy: optionalDouble(4) ?? Fix.unknownAccuracy,
                speed: optionalDouble(5) ?? -1,
                bearing: optionalDouble(6) ?? -1,
                altitude: optionalDouble(7)
            )
            let source = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? PathSampler.sourceMove
            let battery: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
            let charging: Bool? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 10) != 0
            result.append(StoredPoint(id: sqlite3_column_int64(stmt, 0), fix: fix, source: source, battery: battery, charging: charging))
        }
        return result
    }

    func deleteUpTo(_ id: Int64) {
        guard handle() != nil else { return }
        exec("DELETE FROM points WHERE id <= \(id)")
    }

    func pendingCount() -> Int {
        guard let db = handle() else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM points", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func clearPoints() {
        guard handle() != nil else { return }
        exec("DELETE FROM points")
    }

    func log(_ category: String, _ message: String) {
        guard let db = handle() else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO logs (ts, cat, msg) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970 * 1000))
        sqlite3_bind_text(stmt, 2, category, -1, TrackingStore.transient)
        sqlite3_bind_text(stmt, 3, message, -1, TrackingStore.transient)
        sqlite3_step(stmt)
        logsSinceTrim += 1
        if logsSinceTrim >= 50 {
            logsSinceTrim = 0
            exec("DELETE FROM logs WHERE id <= (SELECT MAX(id) FROM logs) - \(Tuning.maxLogEntries)")
        }
    }

    func logs(limit: Int) -> [[String: Any]] {
        guard let db = handle() else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ts, cat, msg FROM logs ORDER BY id DESC LIMIT \(limit)", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var result: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append([
                "ts": NSNumber(value: sqlite3_column_int64(stmt, 0)),
                "cat": sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                "msg": sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
            ])
        }
        return result
    }

    func clearLogs() {
        guard handle() != nil else { return }
        exec("DELETE FROM logs")
    }
}

// MARK: - Persistent state

enum TrackingMode: String {
    case off, stationary, moving
}

final class EngineState {
    private let defaults = UserDefaults.standard
    private let prefix = "lt.engine."

    var baseUrl: String? { defaults.string(forKey: prefix + "baseUrl") }
    var authHeader: String? { defaults.string(forKey: prefix + "authHeader") }
    var userId: String? { defaults.string(forKey: prefix + "userId") }
    var batterySaver: Bool { defaults.bool(forKey: prefix + "batterySaver") }
    var hasCredentials: Bool { baseUrl != nil && authHeader != nil }

    func saveConfig(baseUrl: String, authHeader: String, userId: String, batterySaver: Bool) {
        var url = baseUrl
        while url.hasSuffix("/") { url.removeLast() }
        defaults.set(url, forKey: prefix + "baseUrl")
        defaults.set(authHeader, forKey: prefix + "authHeader")
        defaults.set(userId, forKey: prefix + "userId")
        defaults.set(batterySaver, forKey: prefix + "batterySaver")
        defaults.set(false, forKey: prefix + "authFailed")
    }

    func clearCredentials() {
        defaults.removeObject(forKey: prefix + "authHeader")
        defaults.removeObject(forKey: prefix + "userId")
        defaults.removeObject(forKey: prefix + "authFailed")
    }

    var authFailed: Bool {
        get { defaults.bool(forKey: prefix + "authFailed") }
        set { defaults.set(newValue, forKey: prefix + "authFailed") }
    }

    var mode: TrackingMode {
        get { TrackingMode(rawValue: defaults.string(forKey: prefix + "mode") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: prefix + "mode") }
    }

    var anchor: Fix? {
        get { readFix("anchor") }
        set { writeFix("anchor", newValue) }
    }

    var lastRecorded: Fix? {
        get { readFix("lastRecorded") }
        set { writeFix("lastRecorded", newValue) }
    }

    var liveUntil: Double {
        get { defaults.double(forKey: prefix + "liveUntil") }
        set { defaults.set(newValue, forKey: prefix + "liveUntil") }
    }

    var lastPingAt: Double {
        get { defaults.double(forKey: prefix + "lastPingAt") }
        set { defaults.set(newValue, forKey: prefix + "lastPingAt") }
    }

    var lastUploadOkAt: Double {
        get { defaults.double(forKey: prefix + "lastUploadOkAt") }
        set { defaults.set(newValue, forKey: prefix + "lastUploadOkAt") }
    }

    var lastUploadError: String? {
        get { defaults.string(forKey: prefix + "lastUploadError") }
        set { defaults.set(newValue, forKey: prefix + "lastUploadError") }
    }

    var lastHeartbeatAt: Double {
        get { defaults.double(forKey: prefix + "lastHeartbeatAt") }
        set { defaults.set(newValue, forKey: prefix + "lastHeartbeatAt") }
    }

    var lastFixAt: Double {
        get { defaults.double(forKey: prefix + "lastFixAt") }
        set { defaults.set(newValue, forKey: prefix + "lastFixAt") }
    }

    func clearRuntime() {
        for key in ["anchor", "lastRecorded"] { writeFix(key, nil) }
        for key in ["liveUntil", "lastPingAt", "lastUploadOkAt", "lastUploadError", "lastHeartbeatAt", "lastFixAt"] {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    private func readFix(_ key: String) -> Fix? {
        guard let values = defaults.array(forKey: prefix + key) as? [Double], values.count == 4 else { return nil }
        return Fix(time: Int64(values[0]), lat: values[1], lon: values[2], accuracy: values[3])
    }

    private func writeFix(_ key: String, _ fix: Fix?) {
        if let fix = fix {
            defaults.set([Double(fix.time), fix.lat, fix.lon, fix.accuracy], forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }
}

// MARK: - Uploader

final class Uploader {
    enum Outcome {
        case sent(count: Int, liveTtl: Int?)
        case nothingToSend
        case offline
        case notConfigured
        case authRejected
        case failed(String)
    }

    static let sourceLive = "live"

    private let state: EngineState
    private let store: TrackingStore
    private let session: URLSession
    private(set) var busy = false
    var online = true

    init(state: EngineState, store: TrackingStore) {
        self.state = state
        self.store = store
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Uploads all pending points plus an optional broadcast-only live fix;
    /// [completion] runs on the main thread.
    func uploadAll(live: Fix?, completion: @escaping (Outcome) -> Void) {
        guard !busy else {
            completion(.failed("upload already in progress"))
            return
        }
        guard let baseUrl = state.baseUrl, let auth = state.authHeader,
              let url = URL(string: baseUrl + "/api/v1/location") else {
            completion(.notConfigured)
            return
        }
        if state.authFailed { completion(.authRejected); return }
        if !online { completion(.offline); return }
        busy = true
        sendBatch(url: url, auth: auth, live: live, sent: 0, liveTtl: nil) { [weak self] outcome in
            self?.busy = false
            completion(outcome)
        }
    }

    private func sendBatch(url: URL, auth: String, live: Fix?, sent: Int, liveTtl: Int?,
                           completion: @escaping (Outcome) -> Void) {
        let batch = store.pending(limit: Tuning.uploadBatchSize)
        if batch.isEmpty && live == nil {
            completion(sent == 0 ? .nothingToSend : .sent(count: sent, liveTtl: liveTtl))
            return
        }
        var body: [[String: Any]] = batch.map { Uploader.json($0.fix, $0.source, $0.battery, $0.charging) }
        if let live = live {
            let (level, charging) = Battery.read()
            body.append(Uploader.json(live, Uploader.sourceLive, level, charging))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    completion(.failed(error.localizedDescription))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<300:
                    if let lastId = batch.last?.id { self.store.deleteUpTo(lastId) }
                    let ttl = Uploader.parseLiveTtl(data) ?? liveTtl
                    let total = sent + batch.count
                    if batch.count < Tuning.uploadBatchSize {
                        completion(.sent(count: total, liveTtl: ttl))
                    } else {
                        self.sendBatch(url: url, auth: auth, live: nil, sent: total, liveTtl: ttl, completion: completion)
                    }
                case 401, 403:
                    completion(.authRejected)
                default:
                    completion(.failed("HTTP \(code)"))
                }
            }
        }.resume()
    }

    private static func parseLiveTtl(_ data: Data?) -> Int? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["live_ttl_s"] as? NSNumber)?.intValue
    }

    static func json(_ fix: Fix, _ source: String, _ battery: Int?, _ charging: Bool?) -> [String: Any] {
        var coords: [String: Any] = [
            "latitude": fix.lat,
            "longitude": fix.lon,
            "speed": fix.hasSpeed ? fix.speed : 0,
        ]
        if fix.bearing >= 0 && fix.speed >= 0.5 { coords["heading"] = fix.bearing }
        if fix.hasAccuracy { coords["accuracy"] = fix.accuracy }
        if let altitude = fix.altitude, altitude.isFinite { coords["altitude"] = altitude }
        var json: [String: Any] = [
            "coords": coords,
            "timestamp": isoFormatter.string(from: Date(timeIntervalSince1970: Double(fix.time) / 1000)),
            "source": source,
        ]
        if let battery = battery { json["battery_level"] = battery }
        if let charging = charging { json["is_charging"] = charging }
        return json
    }
}

enum Battery {
    static func read() -> (Int?, Bool?) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level: Int? = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        switch device.batteryState {
        case .charging, .full: return (level, true)
        case .unplugged: return (level, false)
        default: return (level, nil)
        }
    }
}

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

    init(kind: SessionKind, reason: String) {
        self.kind = kind
        self.reason = reason
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
        trip.sampler.startTrip(departureAnchor: state.anchor)
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
        current.sampler.startTrip(departureAnchor: state.anchor)
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
        for (fix, source) in trip.sampler.finishTrip(stop: stop) { record(fix, source) }
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

        if fix.accuracy <= Tuning.maxStopAccuracy,
           let stop = trip.stopDetector.offer(fix, timeout: Tuning.stopTimeout) {
            endTrip(trip, stop: stop, why: "no movement for \(Int(Tuning.stopTimeout / 60)) min")
            return
        }
        let maxAccuracy = trip.sampler.tuning == SamplerTuning.saver ? Tuning.maxRecordAccuracySaver : Tuning.maxRecordAccuracy
        if fix.accuracy <= maxAccuracy {
            trip.lastAccepted = fix
            for (stored, source) in trip.sampler.offer(fix) { record(stored, source) }
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
        let moved = anchor != nil && fix.accuracy <= Tuning.pingMaxAccuracy &&
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

    private func record(_ fix: Fix, _ source: String) {
        let (battery, charging) = Battery.read()
        store.insert(fix, source: source, battery: battery, charging: charging)
        if pendingSince == nil { pendingSince = Date() }
        if source != TrackingEngine.sourcePing && source != TrackingEngine.sourceHeartbeat {
            state.lastRecorded = fix
        }
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
            guard store.pendingCount() > 0 else { return }
            pendingSince = Date()
        }
        let age = Date().timeIntervalSince(pendingSince ?? Date())
        let due = force || isLive || appVisible || age >= Tuning.uploadMaxAge ||
            store.pendingCount() >= Tuning.uploadMaxPending
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

    func status() -> [String: Any] {
        let anchor = state.anchor
        let authorization: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            authorization = manager.authorizationStatus
        } else {
            authorization = CLLocationManager.authorizationStatus()
        }
        var precise = true
        if #available(iOS 14.0, *) { precise = manager.accuracyAuthorization == .fullAccuracy }
        let lastFix = max(Double(lastFixTime), state.lastFixAt)
        var map: [String: Any] = [
            "mode": state.mode.rawValue,
            "configured": state.hasCredentials,
            "authFailed": state.authFailed,
            "live": isLive,
            "lowPower": lowPower,
            "pending": store.pendingCount(),
            "preciseLocation": precise,
            "backgroundLocation": authorization == .authorizedAlways,
            // Android-only concepts; nothing for the user to fix on iOS.
            "activityRecognition": true,
            "batteryOptimizationIgnored": true,
            "notificationsEnabled": false,
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

// MARK: - Flutter bridge

/// Method/event channels for the UI engine (see tracking_engine.dart).
final class TrackingChannel: NSObject, FlutterStreamHandler {
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var sink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "legacytracker/tracking", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "legacytracker/tracking/events", binaryMessenger: messenger)
        super.init()
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        events.setStreamHandler(self)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let engine = TrackingEngine.shared
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let baseUrl = args["baseUrl"] as? String,
                  let authHeader = args["authHeader"] as? String,
                  let userId = args["userId"] as? String else {
                result(FlutterError(code: "bad_args", message: "baseUrl, authHeader and userId are required", details: nil))
                return
            }
            engine.configure(baseUrl: baseUrl, authHeader: authHeader, userId: userId,
                             batterySaver: args["batterySaver"] as? Bool ?? false)
            result(nil)
        case "start":
            engine.start()
            result(nil)
        case "stop":
            engine.stop(clearData: args["clearData"] as? Bool ?? false) { result(nil) }
        case "setAppVisible":
            engine.setAppVisible(args["visible"] as? Bool ?? false)
            result(nil)
        case "flush":
            engine.flush()
            result(nil)
        case "status":
            result(engine.status())
        case "logs":
            result(engine.logs(limit: args["limit"] as? Int ?? 300))
        case "clearLogs":
            engine.store.clearLogs()
            result(nil)
        case "log":
            engine.log(args["category"] as? String ?? "app", args["message"] as? String ?? "")
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        TrackingEngine.shared.listener = { [weak self] event in self?.sink?(event) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        TrackingEngine.shared.listener = nil
        return nil
    }
}
