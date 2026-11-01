import UIKit

// Part of the native tracking engine; see TrackingEngine.swift for the model.

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
    /// Batch reads, JSON encoding and acknowledged deletes: off the main thread, one at a time.
    private let work = DispatchQueue(label: "com.legacy.legacytracker.upload", qos: .utility)
    private(set) var busy = false
    var online = true
    /// Phone settings blocking location updates right now; sent with each
    /// upload so viewers can be told why this phone went quiet.
    var trackingIssues: () -> [String] = { [] }

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

    /// Runs on the main thread; the batch work hops to `work` and every result comes back to main.
    private func sendBatch(url: URL, auth: String, live: Fix?, sent: Int, liveTtl: Int?,
                           completion: @escaping (Outcome) -> Void) {
        // Read on main: the location manager and the battery cache belong to it.
        let issues = trackingIssues()
        let liveBattery: (Int?, Bool?) = live != nil ? Battery.read() : (nil, nil)
        let store = self.store
        work.async { [weak self] in
            let batch = store.pending(limit: Tuning.uploadBatchSize)
            var body: [[String: Any]] = batch.map { Uploader.json($0.fix, $0.source, $0.battery, $0.charging) }
            if let live = live {
                body.append(Uploader.json(live, Uploader.sourceLive, liveBattery.0, liveBattery.1))
            }
            // The server keeps the latest report, so the newest point carries it.
            if !body.isEmpty { body[body.count - 1]["tracking_issues"] = issues }
            let payload = body.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: body)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if body.isEmpty {
                    completion(sent == 0 ? .nothingToSend : .sent(count: sent, liveTtl: liveTtl))
                    return
                }
                self.post(url: url, auth: auth, payload: payload, batch: batch, sent: sent, liveTtl: liveTtl,
                          completion: completion)
            }
        }
    }

    private func post(url: URL, auth: String, payload: Data?, batch: [TrackingStore.StoredPoint], sent: Int, liveTtl: Int?,
                      completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion(.failed(error.localizedDescription)) }
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                DispatchQueue.main.async {
                    completion(code == 401 || code == 403 ? .authRejected : .failed("HTTP \(code)"))
                }
                return
            }
            let ttl = Uploader.parseLiveTtl(data) ?? liveTtl
            let store = self.store
            self.work.async { [weak self] in
                if let lastId = batch.last?.id { store.deleteUpTo(lastId) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let total = sent + batch.count
                    if batch.count < Tuning.uploadBatchSize {
                        completion(.sent(count: total, liveTtl: ttl))
                    } else {
                        self.sendBatch(url: url, auth: auth, live: nil, sent: total, liveTtl: ttl, completion: completion)
                    }
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
    private static var cached: (at: Date, level: Int?, charging: Bool?)?

    /// The battery reading, at most a minute old, like the Android engine's.
    static func read() -> (Int?, Bool?) {
        if let cached = cached, Date().timeIntervalSince(cached.at) < 60 { return (cached.level, cached.charging) }
        let (level, charging) = readNow()
        cached = (Date(), level, charging)
        return (level, charging)
    }

    private static func readNow() -> (Int?, Bool?) {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level: Int? = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        switch device.batteryState {
        case .charging, .full: return (level, true)
        case .unplugged: return (level, false)
        default: return (level, nil)
        }
    }
}
