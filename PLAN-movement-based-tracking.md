# Plan: movement-driven location updates (replace fixed 2-min polling)

**Status:** phases 1–3 implemented (2026-08-30), not yet field-tested / merged.
**Author context:** written 2026-08-30 after adding the Activity-log diagnostics (`557bf41`, `b13fa16`).
Delete this file once the work is merged.

### Implemented so far
- **§3.1** `tracking_tuning.dart` — pacing/battery → distanceFilter + accuracy +
  flush interval, plus pure `shouldEnqueue` / `needsHeartbeat` / `streamStalled`.
- **§3.2** `BackgroundLocationHandler` rewritten to continuous
  `getPositionStream` + app-level sample gate + outbox enqueue (`source:'move'`),
  `onRepeatEvent` repurposed as flush tick with stationary heartbeat
  (`source:'heartbeat'`), stream-stall fallback poll, and pacing-change stream
  reopen. `markTick()` now fires on each accepted stream point.
- **§3.3** `BackgroundTracker` flush intervals come from `TrackingTuning`.
- **§3.4** outbox cap 200→500, de-dup on drain.
- **§3.5** foreground `GeolocatorLocationService` settings via `TrackingTuning`;
  `TrackingController` applies the same movement gate before WS sends.
- **§3.6** `buildLocationPayload` emits optional `source`.
- **§3.7** iOS `pauseLocationUpdatesAutomatically` = !aggressive.
- **§3.8** `tracking_tuning_test.dart`, outbox de-dup test.
- **§4.1/4.2** batch multi-row insert via `jsonb_to_recordset` +
  `ON CONFLICT (user_id, recorded_at) DO NOTHING`; schema + `ensureBackendSchema`
  ALTERs for `source`, unique index, `users.last_seen_at`.
- **§4.3** `last_seen_at` touched on every HTTP + WS ingest; included in WS
  snapshot + broadcasts. Client `UserProfile.lastSeenAt` / `isStale` (15 min).
- **§4.1** heartbeat broadcasts at unchanged coords are suppressed.

### Not done
- §4.4 pacing debounce, §4.5 retention job, §4.6 server tests (no server test
  harness in repo), roster-staleness **visual** treatment on map markers
  (`isStale` is plumbed but not yet consumed by the marker widgets),
  §3.8 handler integration test with `MockLocationProvider`, §8 evaluation of
  `flutter_background_geolocation`.

---

## 1. Problem

The background pipeline wakes every `120s` (PASSIVE) / `5s` (AGGRESSIVE) via
`flutter_foreground_task`'s `onRepeatEvent` and does a **one-shot**
`Geolocator.getCurrentPosition`. After Doze parks the GPS radio, that cold fix
often doesn't complete inside the 15s limit → `GPS fix failed` → multi-minute
gaps in the track. The 2-minute cadence also misses turns/stops and makes the
foreground service look idle to OEM battery killers.

## 2. Target design

Run a **continuous, distance-filtered `getPositionStream`** inside the
foreground-service isolate. Stream points into the existing `LocationOutbox`;
**flush to the server in batches** on a short timer. Guarantee a liveness signal
with a **stationary heartbeat** (≤5 min) even when not moving.

Pacing (`AGGRESSIVE`/`PASSIVE`, still delivered by FCM) stops controlling *poll
frequency* and instead tunes **`distanceFilter` + accuracy + flush interval**.

```
        ┌──────────── foreground-service isolate ─────────────┐
 GPS ──▶│ getPositionStream(distanceFilter, accuracy)         │
        │        │  (app-level throttle: min 3s / min 10m)     │
        │        ▼                                             │
        │   LocationOutbox (SharedPreferences, cap ~500)       │
        │        ▲                                             │
        │   heartbeat: if no point in >5min, enqueue 1         │
        │        │                                             │
        │   flush tick (onRepeatEvent, 5–30s) ──▶ POST /location│
        └─────────────────────────────────────────────────────┘
```

While `app_foreground == true`: the main isolate's stream + WebSocket already
cover uploads, so the background isolate **does not enqueue** (keeps the stream
subscription alive only to keep GPS warm / service healthy).

---

## 3. Client changes (`src/client`)

### 3.1 New shared tuning module — `lib/src/features/location/tracking_tuning.dart`
Single source of truth used by both isolates:

```dart
class TrackingTuning {
  // distanceFilter (metres)
  static const passiveDistanceM = 50;
  static const aggressiveDistanceM = 12;
  static const batterySavingDistanceM = 100;
  // flush cadence (ms) — the onRepeatEvent interval
  static const passiveFlushMs = 30000;
  static const aggressiveFlushMs = 5000;
  // app-level sample gate (drop GPS jitter / cap highway spam)
  static const minSampleIntervalMs = 3000;
  static const minSampleDistanceM = 10;
  // stationary heartbeat
  static const heartbeatMaxGapMs = 300000; // 5 min

  static LocationSettings settingsFor({required bool aggressive, required bool batterySaving}) { ... }
  static int distanceFilterFor(...) / flushIntervalFor(...) / accuracyFor(...)
}
```

### 3.2 `BackgroundLocationHandler` (rewrite — `background_location_handler.dart`)
- **`onStart`**: read `pacing_mode` + `battery_saving_enabled` from prefs, open
  `_sub = Geolocator.getPositionStream(locationSettings: TrackingTuning.settingsFor(...))`.
  - Android: `AndroidSettings(accuracy, distanceFilter, intervalDuration)` — **do NOT**
    set geolocator's `foregroundNotificationConfig` (flutter_foreground_task already
    owns the FGS notification; two would conflict).
  - On each position: apply the app-level gate (`minSampleIntervalMs` /
    `minSampleDistanceM` vs last enqueued point); if it passes and
    `app_foreground == false`, `outbox.enqueue(buildLocationPayload(point, battery…))`.
    Also stamp `source: 'move'`.
  - `DebugLogStore.markTick()` is no longer per-flush only — mark on each accepted
    stream point too, so `Last tick` reflects GPS liveness.
- **`onRepeatEvent`** (repurposed = flush tick, interval = `TrackingTuning.flushIntervalFor(pacing)`):
  1. `prefs.reload()`.
  2. If `pacing_mode` changed since last tick → tear down `_sub`, reopen with new settings.
  3. Heartbeat: if `now - lastEnqueuedOrSentMs > heartbeatMaxGapMs` and not foreground,
     take `getLastKnownPosition()` (fallback `getCurrentPosition`, 10s) → enqueue with
     `source: 'heartbeat'`.
  4. Drain outbox → single batched `POST /api/v1/location`. On success
     `DebugLogStore.markSuccess()`; on failure `outbox.write(batch)` (unchanged).
  5. Fallback poll: if the stream has produced **nothing** for >2 min while
     `app_foreground == false` (Doze batching), do one `getCurrentPosition` here and
     enqueue — keeps a floor on freshness even if the stream stalls.
- **`onDestroy`**: cancel `_sub` (plus existing log line).
- Keep `onReceiveData` no-op (pacing still travels via prefs).

### 3.3 `BackgroundTracker` (`background_tracker.dart`)
- `initialize()` / `start()`: `ForegroundTaskEventAction.repeat(TrackingTuning.passiveFlushMs)`
  instead of `_passiveIntervalMs`.
- `_syncServiceInterval()` / `applyPacingMode()` / `applyBatterySavingEnabled()`:
  target interval = `TrackingTuning.flushIntervalFor(pacing, batterySaving)`.
  Keep writing `pacing_mode` to prefs — the handler now also uses it to pick the
  **stream** settings, not just the flush interval.
- Keep `bg_service_running` + `ServiceRequestFailure` logging from `b13fa16`.

### 3.4 `LocationOutbox` (`location_outbox.dart`)
- Raise `maxQueuedPoints` 200 → **500** (long offline drive).
- Add `enqueue` guard is unnecessary here (gate lives in the handler), but add a
  cheap **de-dup on drain**: drop consecutive points with identical
  `coords`+`timestamp` (protects against a partial re-flush).

### 3.5 Foreground path (`tracking_controller.dart` / `location_service.dart`)
- `GeolocatorLocationService._settings`: derive `distanceFilter`/accuracy from
  `TrackingTuning` keyed on **pacing** too, not only `batterySavingEnabled`
  (needs the controller to pass the current pacing down, or read prefs).
- `TrackingController._startLocationStream`: apply the same
  `minSampleIntervalMs`/`minSampleDistanceM` gate before `backend.sendLocationRealtime`
  so foreground WS traffic is also movement-shaped.
- No heartbeat needed in foreground (WS connection liveness is the signal).

### 3.6 `location_payload.dart`
- Add optional `source` (`'move' | 'heartbeat' | 'foreground'`) to
  `buildLocationPayload` → emitted as `payload['source']`.

### 3.7 iOS
- Already OK: `UIBackgroundModes` has `location`, `NSLocationAlwaysAndWhenInUse…`
  present, `AppleSettings.allowBackgroundLocationUpdates: true`.
- Set `AppleSettings.pauseLocationUpdatesAutomatically = true` in PASSIVE to let
  iOS sleep GPS when stationary; `false` in AGGRESSIVE.

### 3.8 Client tests
- `tracking_tuning_test.dart`: pacing/battery → settings mapping.
- `location_outbox_test.dart`: drain de-dup, cap at 500.
- Handler logic: extract the sample-gate + heartbeat-trigger into pure functions and
  unit-test (`shouldEnqueue(prev, next, now)`, `needsHeartbeat(lastMs, now)`).
- Integration: drive `MockLocationProvider` along a path, assert batch contents +
  that a stationary period still produces a heartbeat point.

---

## 4. Server changes (`src/server/src/app.ts`)

### 4.1 `POST /api/v1/location` — batch insert
Currently loops `await pool.query(INSERT …)` per point. With movement batches
(potentially hundreds after an offline drive) that's N round-trips. Replace with a
single multi-row insert:

```sql
INSERT INTO location_history (user_id, recorded_at, location, speed, heading, source)
SELECT $1, r.recorded_at,
       ST_SetSRID(ST_MakePoint(r.lon, r.lat), 4326)::geography,
       r.speed, r.heading, r.source
FROM jsonb_to_recordset($2::jsonb)
  AS r(recorded_at timestamptz, lon float8, lat float8, speed float8, heading float8, source text)
ON CONFLICT (user_id, recorded_at) DO NOTHING
```

- `ON CONFLICT DO NOTHING` makes re-flush after a partial failure idempotent.
- Still broadcast only the **last** point over WS (unchanged) — but skip the
  broadcast entirely if `source === 'heartbeat'` **and** the coords equal the last
  broadcast for that user (avoids pin jitter on viewers).
- Response unchanged (`{ received, pacing }`).

### 4.2 Schema (`src/db/schema.sql` + `ensureBackendSchema()`)
```sql
ALTER TABLE location_history ADD COLUMN IF NOT EXISTS source text;
-- unique key for idempotent re-flush
CREATE UNIQUE INDEX IF NOT EXISTS location_history_user_recorded_uniq
  ON location_history (user_id, recorded_at);
-- roster staleness
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;
```
Mirror the `ALTER`s in `ensureBackendSchema()` (same pattern as the existing
`role` column) so deploys are migration-free.

### 4.3 `last_seen_at` / roster staleness
- On every ingest (HTTP + WS `location`): `UPDATE users SET last_seen_at = now()`.
- WS snapshot + broadcast: include `last_seen_at` so the client can grey out /
  drop markers older than e.g. 15 min. Pairs with the ≤5-min heartbeat: a user
  who's genuinely online keeps `last_seen_at` fresh even parked.

### 4.4 Pacing debounce (`updateViewerState` / `getPacingMode`)
- Keep binary AGGRESSIVE/PASSIVE.
- Debounce the **PASSIVE** transition: only broadcast PASSIVE after the map has
  been inactive for ~30s (a viewer flipping tabs shouldn't FCM-storm every
  driver). AGGRESSIVE can still fire immediately.
- Movement-based tracking makes AGGRESSIVE less critical (dense points while
  driving already), so this is tuning, not correctness.

### 4.5 Data volume / retention (follow-up, not blocking)
- `location_history` grows faster at a 12m filter. Add a retention job
  (`DELETE FROM location_history WHERE recorded_at < now() - interval '90 days'`)
  on a cron, and note it in ops docs. `session-builder` already tolerates gaps.

### 4.6 Server tests
- Batch insert: same batch POSTed twice → row count unchanged (idempotency).
- `source: 'heartbeat'` equal-coords → not re-broadcast.
- `last_seen_at` advances on both HTTP and WS ingest.

---

## 5. Rollout order

1. **Client phase 1** — `TrackingTuning`, handler rewrite to stream+flush+heartbeat,
   outbox cap. Server payload is already forward-compatible (`source` ignored by
   old server). Ship, watch Activity-log `Last tick` / `Last success` and battery
   over a real drive.
2. **Server phase 2** — batch insert + `ON CONFLICT DO NOTHING` + unique index +
   `source` column.
3. **Phase 3** — `last_seen_at` + roster staleness UI + heartbeat-broadcast skip.
4. **Phase 4** — tune `TrackingTuning` constants from collected traces; pacing
   debounce.

## 6. Risks / watch-items

- **Battery** — continuous GPS is the biggest drain. Mitigations: `distanceFilter`,
  accuracy downgrade + `pauseLocationUpdatesAutomatically` in PASSIVE. Measure over
  a 1h drive before/after.
- **Doze still batches location** on some OEMs even under an FGS + wakelock. The
  flush-tick fallback poll (§3.2.5) is the backstop.
- **Two GPS consumers** briefly during foreground⇄background transitions — accept
  it; the background isolate simply stops *enqueuing* while foreground.
- **Highway spam** — 12m filter at 110 km/h ≈ a fix every ~0.4s. The app-level
  `minSampleIntervalMs` (3s) gate is what actually bounds row volume, not the
  distanceFilter.
- **Clock skew** — `recorded_at` comes from the device. The unique index is
  `(user_id, recorded_at)`; a device with a jumping clock could drop points. Low
  risk, acceptable.

## 7. Key files

| Client | Server |
|---|---|
| `lib/src/features/location/tracking_tuning.dart` *(new)* | `src/server/src/app.ts` (`POST /api/v1/location`, WS `location`, `updateViewerState`, `getPacingMode`) |
| `lib/src/features/background/background_location_handler.dart` | `src/server/src/db/schema.sql` |
| `lib/src/features/background/background_tracker.dart` | `ensureBackendSchema()` in `app.ts` |
| `lib/src/features/location/location_outbox.dart` | `src/server/src/services/connection-manager.ts` (snapshot fields) |
| `lib/src/features/location/location_service.dart` | |
| `lib/src/features/location/location_payload.dart` | |
| `lib/src/features/tracking/tracking_controller.dart` | |

## 8. Alternative considered

`flutter_background_geolocation` (transistorsoft) already implements
stationary-geofence + motion-activity detection + batched sync + OEM handling.
Worth evaluating before hand-rolling §3.2 — it would replace most of the
`background/` folder. Downsides: paid license for release builds, larger
dependency, migration of the pacing/`app_foreground` logic. Decision pending.
