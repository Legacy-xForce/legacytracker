import Foundation

// Part of the native tracking engine; see TrackingEngine.swift for the model.

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
        set {
            defaults.set(newValue.rawValue, forKey: prefix + "mode")
            // iOS ends backgrounded processes right after a state change; commit now, like Android.
            defaults.synchronize()
        }
    }

    var anchor: Fix? {
        get { readFix("anchor") }
        set {
            writeFix("anchor", newValue)
            defaults.synchronize()
        }
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
