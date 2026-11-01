import Foundation
import SQLite3

// Part of the native tracking engine; see TrackingEngine.swift for the model.

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
    private let openLock = NSLock()
    private var insertsSincePrune = 0
    private var logsSinceTrim = 0

    /// Opens lazily: right after a reboot, before the first unlock, data
    /// protection keeps the file unreadable — a location relaunch then just
    /// skips storage until the next opportunity.
    private func handle() -> OpaquePointer? {
        // Main and the upload queue both get here; only one may open the file.
        openLock.lock()
        defer { openLock.unlock() }
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

    /// Returns the new row's id, or 0 when nothing was stored.
    @discardableResult
    func insert(_ fix: Fix, source: String, battery: Int?, charging: Bool?) -> Int64 {
        guard let db = handle() else { return 0 }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO points (ts, lat, lon, acc, speed, heading, alt, source, battery, charging) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
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
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        let rowId = sqlite3_last_insert_rowid(db)
        insertsSincePrune += 1
        if insertsSincePrune >= 500 {
            insertsSincePrune = 0
            exec("DELETE FROM points WHERE id <= (SELECT MAX(id) FROM points) - \(Tuning.maxStoredPoints)")
        }
        return rowId
    }

    func hasPoint(_ id: Int64) -> Bool {
        guard let db = handle() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM points WHERE id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Drops a trip's not-yet-uploaded points, keeping liveness rows of the given sources.
    func deleteTripFrom(_ id: Int64, keepSources: [String]) {
        guard let db = handle() else { return }
        let marks = keepSources.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM points WHERE id >= ? AND source NOT IN (\(marks))", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        for (index, source) in keepSources.enumerated() {
            sqlite3_bind_text(stmt, Int32(index) + 2, source, -1, TrackingStore.transient)
        }
        sqlite3_step(stmt)
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

    /// Whether at least `n` points wait. Looks at `n` rows at most: the table can hold 100 000 and
    /// this runs for every accepted fix, where only "enough for a batch?" matters.
    func hasPending(_ n: Int) -> Bool {
        guard let db = handle() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM (SELECT 1 FROM points LIMIT \(n))", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && Int(sqlite3_column_int64(stmt, 0)) >= n
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
