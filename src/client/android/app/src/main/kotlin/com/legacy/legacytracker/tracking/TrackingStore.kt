package com.legacy.legacytracker.tracking

import android.content.ContentValues
import android.content.Context
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Durable queue of recorded points awaiting upload, plus the activity log.
 *
 * A point is written the moment it is recorded and deleted only after the
 * server acknowledged it, so a crash, a kill or a week offline loses nothing;
 * the server's (user_id, recorded_at) unique index absorbs any re-sends.
 */
class TrackingStore private constructor(context: Context) :
    SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {

    class StoredPoint(
        val id: Long,
        val fix: Fix,
        val source: String,
        val battery: Int?,
        val charging: Boolean?,
    )

    class LogEntry(val time: Long, val category: String, val message: String)

    private var insertsSincePrune = 0
    private var logsSinceTrim = 0

    override fun onConfigure(db: SQLiteDatabase) {
        db.enableWriteAheadLogging()
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE points (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts INTEGER NOT NULL,
              lat REAL NOT NULL,
              lon REAL NOT NULL,
              acc REAL,
              speed REAL,
              heading REAL,
              alt REAL,
              source TEXT NOT NULL,
              battery INTEGER,
              charging INTEGER
            )
            """.trimIndent(),
        )
        db.execSQL(
            "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, " +
                "cat TEXT NOT NULL, msg TEXT NOT NULL)",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    @Synchronized
    fun insert(fix: Fix, source: String, battery: Int?, charging: Boolean?): Long {
        val values = ContentValues().apply {
            put("ts", fix.time)
            put("lat", fix.lat)
            put("lon", fix.lon)
            if (fix.hasAccuracy) put("acc", fix.accuracy.toDouble())
            if (fix.hasSpeed) put("speed", fix.speed.toDouble())
            if (fix.bearing >= 0f) put("heading", fix.bearing.toDouble())
            fix.altitude?.let { put("alt", it) }
            put("source", source)
            battery?.let { put("battery", it) }
            charging?.let { put("charging", if (it) 1 else 0) }
        }
        val id = writableDatabase.insert("points", null, values)
        if (++insertsSincePrune >= 500) {
            insertsSincePrune = 0
            prune(Tuning.MAX_STORED_POINTS)
        }
        return id
    }

    fun pending(limit: Int): List<StoredPoint> {
        val result = ArrayList<StoredPoint>()
        readableDatabase.rawQuery(
            "SELECT id, ts, lat, lon, acc, speed, heading, alt, source, battery, charging " +
                "FROM points ORDER BY id LIMIT ?",
            arrayOf(limit.toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val fix = Fix(
                    time = c.getLong(1),
                    lat = c.getDouble(2),
                    lon = c.getDouble(3),
                    accuracy = if (c.isNull(4)) Fix.UNKNOWN_ACCURACY else c.getFloat(4),
                    speed = if (c.isNull(5)) -1f else c.getFloat(5),
                    bearing = if (c.isNull(6)) -1f else c.getFloat(6),
                    altitude = if (c.isNull(7)) null else c.getDouble(7),
                )
                result.add(
                    StoredPoint(
                        id = c.getLong(0),
                        fix = fix,
                        source = c.getString(8),
                        battery = if (c.isNull(9)) null else c.getInt(9),
                        charging = if (c.isNull(10)) null else c.getInt(10) != 0,
                    ),
                )
            }
        }
        return result
    }

    fun deleteUpTo(id: Long) {
        writableDatabase.delete("points", "id <= ?", arrayOf(id.toString()))
    }

    fun pendingCount(): Long = DatabaseUtils.queryNumEntries(readableDatabase, "points")

    fun clearPoints() {
        writableDatabase.delete("points", null, null)
    }

    /** Keeps the newest [maxRows] points if uploads have been failing for a very long time. */
    private fun prune(maxRows: Int) {
        writableDatabase.execSQL(
            "DELETE FROM points WHERE id <= (SELECT MAX(id) FROM points) - ?",
            arrayOf<Any>(maxRows),
        )
    }

    @Synchronized
    fun log(category: String, message: String) {
        val values = ContentValues().apply {
            put("ts", System.currentTimeMillis())
            put("cat", category)
            put("msg", message)
        }
        writableDatabase.insert("logs", null, values)
        if (++logsSinceTrim >= 50) {
            logsSinceTrim = 0
            writableDatabase.execSQL(
                "DELETE FROM logs WHERE id <= (SELECT MAX(id) FROM logs) - ?",
                arrayOf<Any>(Tuning.MAX_LOG_ENTRIES),
            )
        }
    }

    fun logs(limit: Int): List<LogEntry> {
        val result = ArrayList<LogEntry>()
        readableDatabase.rawQuery(
            "SELECT ts, cat, msg FROM logs ORDER BY id DESC LIMIT ?",
            arrayOf(limit.toString()),
        ).use { c ->
            while (c.moveToNext()) {
                result.add(LogEntry(c.getLong(0), c.getString(1), c.getString(2)))
            }
        }
        return result
    }

    fun clearLogs() {
        writableDatabase.delete("logs", null, null)
    }

    companion object {
        private const val DB_NAME = "lt_tracking.db"
        private const val DB_VERSION = 1

        @Volatile
        private var instance: TrackingStore? = null

        fun get(context: Context): TrackingStore =
            instance ?: synchronized(this) {
                instance ?: TrackingStore(context.applicationContext).also { instance = it }
            }
    }
}
