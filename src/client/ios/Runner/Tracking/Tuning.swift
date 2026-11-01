import Foundation

// Part of the native tracking engine; see TrackingEngine.swift for the model.

// MARK: - Tuning (mirrors Tuning.kt)

enum Tuning {
    static let geofenceRadius: Double = 150
    /// A trip that never got this far from its start is GPS wander, not a trip.
    static let minTripExtent: Double = geofenceRadius
    static let geofenceMaxRadius: Double = 500
    static let heartbeatInterval: TimeInterval = 25 * 60
    static let refreshInterval: TimeInterval = 30 * 60

    static let maxRecordAccuracy: Double = 40
    static let maxRecordAccuracySaver: Double = 60
    static let maxStopAccuracy: Double = 100
    static let maxPlausibleSpeed: Double = 90
    static let stopTimeout: TimeInterval = 5 * 60
    /// Stopped for sure (see `stillSpeed`): end the trip sooner. Android uses activity recognition's
    /// STILL for the same 2 min; iOS has no activity signal wired up, so GPS speed stands in.
    static let stopTimeoutStill: TimeInterval = 2 * 60
    /// Every fix with a valid speed below this, for `stopTimeoutStill`, counts as stopped.
    static let stillSpeed: Double = 0.5
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

    /// Parked with the app on screen and the app-open fix taken: a coarse request until something
    /// needs a fresh fix again (a ping, live mode). Trips still start from the geofence.
    static let foregroundIdleDistance: Double = 25
    static let foregroundMoveThreshold: Double = 60
    static let foregroundMoveAccuracy: Double = 30
    static let lowBatteryPercent = 15

    static let maxStoredPoints = 100_000
    static let maxLogEntries = 500
}
