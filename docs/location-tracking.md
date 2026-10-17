# Location tracking

How Legacy Tracker records, stores and shares positions. Supersedes
`PLAN-movement-based-tracking.md` (the `flutter_foreground_task` design).

## Goals

- Track continuously — app open, in the background, swiped away, after a reboot.
- No permanent notification.
- Battery: GPS only while actually moving; no polling.
- Replay accuracy: the drawn route stays within a few metres of the real one.
- Nothing lost offline; points upload in batches when the network returns.
- Realtime only while someone is looking at the map.

## Why the previous design was replaced

| Problem | Cause |
|---|---|
| Permanent notification | One foreground service running 24/7, notification permission requested explicitly. |
| Battery drain while parked | `allowWakeLock: true` held a `PARTIAL_WAKE_LOCK` for the service's whole life (CPU never slept), plus a continuous position stream and a headless Flutter engine. |
| Tracking dies for good | Everything depended on that one service. Once it was stopped (notification dismissed / "Stop" in Active apps / OEM killer) nothing could restart it: no geofence, no activity trigger; the restart alarm can't start a location FGS from the background on Android 12+. |
| iOS stops after the first stop | `pauseLocationUpdatesAutomatically: true` in PASSIVE: iOS pauses when parked and never resumes on its own; nothing (region/significant-change) relaunched or resumed the app. |
| Poor replay | PASSIVE (the default — nobody watching) used `LocationAccuracy.medium` = Wi-Fi/cell positioning (40–100 m+) with a 50 m filter: corners cut, parked drift recorded as movement. |
| Lost points | Outbox was a JSON string in SharedPreferences rewritten per point, shared by two isolates without locking; `write(batch)` after a failed upload overwrote points queued meanwhile; 500-point cap; background uploads used a JWT that expires and was never refreshed. |
| Stale positions after restart | WS snapshot came from server memory only. |
| iOS pushes | Background pushes sent with `apns-priority: 10` (must be 5 + `apns-push-type: background`). |

## Architecture

```
            OS triggers (no GPS, ~free)                       Server
  geofence exit · activity: vehicle/bike/run ·        ┌──────────────────────┐
  network fix far away · reboot · FCM "live"          │ POST /api/v1/location │
                    │                                 │  (device token)       │
                    ▼                                 │  store ← trip points  │
  ┌───────────── native TrackingEngine ─────────────┐ │  broadcast ← newest   │
  │ STATIONARY ──trigger──▶ MOVING ──5 min still──▶  │ │  live_ttl_s in reply  │
  │ (no GPS)               (GPS 1 Hz, Android:       │ └──────────▲───────────┘
  │                         short-lived FGS)         │            │ batched / live
  │                    PathSampler → SQLite queue ───┼────────────┘
  │   Uploader: every 5 min or 200 pts while moving, │
  │   at trip end, on reconnect (WorkManager/BGTask),│      FCM: live / idle
  │   immediately while live                         │◀── (only while a map
  └──────────────────────────────────────────────────┘     is open somewhere)
                    ▲  method/event channel (only while the UI is up)
                 Flutter UI: map, status card, debug log
```

The engine is **native** (`android/app/src/main/kotlin/.../tracking/`,
`ios/Runner/TrackingEngine.swift`) and runs without any Flutter engine, so OS
wake-ups cost milliseconds of native code instead of booting Dart.

### States and triggers

| | Android | iOS |
|---|---|---|
| Stationary → moving | Geofence exit (150 m around the parking spot, `INITIAL_TRIGGER_EXIT` on re-arm); Activity Recognition `IN_VEHICLE`/`ON_BICYCLE`/`RUNNING` enter; balanced-power fix > 150 m away (15 min, piggybacks other apps); app open & moved > 60 m | Region exit (150 m) — relaunches a terminated app; significant-location-change; visit departure; app open & moved > 60 m |
| Moving | FLP high accuracy, 2 s (batched 30 s), 1 s while live/visible, 5 s in battery saver; foreground service | Standard updates, best accuracy, `pausesLocationUpdatesAutomatically = false` |
| Moving → stationary | Every fix within 40 m (or 1.5× accuracy) of the stop's first fix *and* centre for 5 min (2 min if activity says STILL); or no fix for 5 min | Same |
| Wake-up safety net | WorkManager watchdog every 30 min (re-arm, resume a killed trip, heartbeat, flush); boot/app-update receiver | BGAppRefresh (opportunistic) |

Walking does not start a trip by itself (that would run GPS for every walk
around the house); leaving the 150 m geofence does.

### The Android notification

Android only allows continuous background GPS inside a foreground service, and
that service must post a notification — no app (Life360 included) gets around
it. Here it exists **only while a trip is being recorded**, on a
minimum-importance channel (no status-bar icon, no sound, collapsed), with
deferred display so a ~10 s ping usually never shows it. The app no longer asks
for notification permission: on Android 13+ without it the service runs with
no visible notification at all. On 14+ it can be swiped away without stopping
the trip.

## Sampling: which points are stored

The GPS delivers ~1 fix/s while moving. Replay draws straight lines between
stored points, so the error that matters is the gap between those lines and the
road. `PathSampler` (an online "opening window" line simplification) stores a
fix only when needed:

1. **Deviation** — a fix seen since the last stored point lies > **ε = 5 m**
   from the straight line to the current fix → store the last fix before the
   bend. This puts a vertex at every turn regardless of speed.
2. **Max spacing** — straight travel reached **n = clamp(8 s × speed, 30 m, 200 m)**
   (50 km/h → 111 m, highway → 200 m, walking → 30 m). Bounds staleness and
   what a crash/kill can lose.
3. **Speed change** — |Δv| ≥ max(3 m/s, 30 %) → the replay's km/h readout
   follows braking and acceleration.
4. Never closer than **10 m** (GPS jitter floor).

Why these numbers: a chord of length *c* over a curve of radius *R* deviates by
≈ c²/8R. Drivers take curves at lateral acceleration ≲ 3 m/s², so R ≳ v²/3 and
a fixed time spacing of √(8ε/a) ≈ 3.6 s would be needed to hold ε = 5 m with a
plain filter — wasteful on straights. Testing the actual deviation instead
stores points only where the road bends. ε = 5 m is at the level of GPS noise
(below a lane width, ~1.5 px at replay zoom 15).

Fixes worse than 40 m accuracy are not stored; implausible jumps (> 90 m/s)
are dropped. Each trip starts with a `trip_start` point at the parking spot
(timestamp estimated from distance/speed to the first fix) and ends with a
`trip_end` point at the arrival time, so replays start and end where the car
was parked.

Simulated mixed drive with correlated GPS noise (`DriveSimulationTest`: city,
red light, 12 m-radius junction turn, roundabout, highway bend, exit ramp):

| | points stored | mean error | max error |
|---|---|---|---|
| This sampler | 53 of 359 fixes | 1.0 m | 6.3 m |
| Old PASSIVE filter (50 m), given ideal GPS | 80 | 6.2 m | 46.9 m |
| Old AGGRESSIVE filter (12 m + 3 s) | 102 | 1.5 m | 10.3 m |

## Uploading and offline

- Points go into SQLite (WAL) the moment they're recorded; a row is deleted
  only after the server acknowledged it. The server's `(user_id, recorded_at)`
  unique index makes re-sends harmless, so every failure degrades to "send
  again later". Cap: 100 000 points.
- Not live: upload when the oldest point is 5 min old or 200 are waiting, at
  every trip end, and when the app opens. Failures back off (30 s → 10 min)
  and hand over to WorkManager (Android, network constraint) / BGAppRefresh +
  network monitor (iOS).
- Credentials: the app exchanges its JWT once for a **device token**
  (`POST /api/v1/devices`), which the engine sends as `Authorization: Device …`.
  Background uploads therefore never depend on a short-lived JWT or on
  refreshing a rotating refresh token from two places. Sign-out uploads what's
  left, wipes the queue and revokes the token.
- Rotation: the engine alone owns the token after registration. Its uploads
  send `X-Token-Rotation: 1`, and once the token is 24 h old the response
  carries a replacement (`device_token`), stored before the next request. The
  previous token stays valid until the replacement is first used, so a lost
  response never locks the phone out (the server re-issues instead). A replaced
  token coming back means a second copy of it exists: the server revokes
  the device. The engine then shows a "Location sharing paused"
  notification, and opening the app re-registers. Dart's stored token is only
  the registration-time copy; `configure` keeps the engine's own token while
  the device id is unchanged.

## Live mode ("someone opened the app")

1. A viewer's map becomes visible → WS `map_active` → server `LiveController`.
2. Server sends a high-priority data-only FCM `lt_cmd=live, lt_ttl=600`
   (60 s TTL; iOS: `apns-push-type: background`, priority 5).
3. Each device, natively (Android: receiver on the FCM broadcast; iOS:
   `didReceiveRemoteNotification`):
   - parked → takes one fresh fix (short foreground service / background GPS,
     ≤ 15 s) and uploads it immediately; if it turns out to have moved, it
     becomes a trip;
   - moving → streams a broadcast-only `live` point every ≥ 2.5 s and ≥ 8 m
     (30 s keep-alive), plus its recorded points immediately.
4. Viewers see the server snapshot instantly (latest stored point per user,
   even after a server restart), then fresh fixes within seconds.
5. While viewers remain, `live` is re-sent every 4 min (renewals don't re-ping
   parked devices); with no viewers for 45 s the server sends `idle`. Devices
   also expire live mode on their own after the TTL, and every upload response
   carries `live_ttl_s`, so a lost push never leaves a phone streaming.

`live` points are never stored — recorded points already describe the path.

### Who's viewing

The same `map_active` signal drives the row of faces next to the sharing pill
(the app) and the Live pill (web): everyone with the map in the foreground,
yourself included, shown to everyone — no per-user filtering.

- The server broadcasts `{type: "viewers", viewers: [{id, name}]}` (in the
  order people started looking) whenever the set changes, and sends it to
  every new connection right after the snapshot.
- A face appears once a map has been open 0.5 s (a tab opened in the
  background never flashes in) and leaves 3 s after the map closes (the web
  reconnects on every tab focus, the app on every resume).
- The server pings every socket every 25 s and drops any that missed the
  previous ping, so a viewer whose connection died silently (laptop asleep,
  phone out of signal) disappears within about a minute — and stops holding
  live mode on.
- Older clients ignore the message: it has no top-level `user_id`.

Parked devices check in every ~30 min (re-sending the parking spot with its
original timestamp: nothing new stored, but `last_seen_at` and battery
refresh). Markers grey out after 90 min without contact — not by position age,
since a parked user's last point is old by design.

### Force location update

When a phone stops reporting (battery optimisation, Doze), anyone can wake it
from that person's detail view: a refresh icon at the far right of the header
row, in the app and on the web.

1. The viewer's client `POST`s `/api/v1/users/:userId/location-refresh` and
   spins the icon until the request returns.
2. The server sends the target's devices a high-priority data push,
   `lt_cmd=refresh` (60 s TTL; iOS: background push, priority 5), and holds the
   request open.
3. The device skips the usual ping throttle and takes one fresh fix, then
   uploads it right away (a moving device sends its latest fix instead). Even
   a coarse fix ends in an upload, so the server always hears back.
4. The next upload from that user, whatever its source, completes the request:
   `200` with their roster entry (the same position also reaches viewers over
   the stream).
5. If nothing arrives within 25 s the server answers `504 device_unreachable`
   and the client shows a toast / snackbar ("Unable to reach device for
   location update. The device may be offline or in battery saver mode.").

Other answers: `404` unknown user, `403 not_sharing` when they hide from the
requester (the button isn't offered then), `409 no_device` when the user has
no registered push token. Concurrent requests for one user share one push and
one wait. Builds that predate `refresh` ignore the push, so it ends in the
504 path.

### Why a phone went quiet

A phone can stop updating without anyone noticing: battery optimization,
Location switched off for the whole phone, or a missing permission. The engine
knows, so it reports the current problems as `tracking_issues` on the newest
point of every upload (Android: `TrackingIssues.kt`; iOS: `trackingIssues()`):

| Code | Meaning |
|---|---|
| `location_services_off` | Location is off phone-wide (Android) |
| `location_permission` | No location permission (iOS also reports Location Services off this way) |
| `background_location` | Not "Allow all the time" |
| `precise_location` | Approximate location only |
| `battery_optimization` | Android battery optimization applies to the app |

The server keeps the last report per user and sends it to viewers, and the user
detail pane (app and web) shows a warning with how to fix it. The report only
travels with uploads, so a fix shows up with the next one (a parked phone
checks in about every 30 min; opening the app uploads right away). A user who
isn't sharing with the viewer never has it revealed.

## Sharing with specific users

Everyone with the tracker scope sees everyone by default. A user can switch
their location off for one other user from that user's detail pane in the
drawer. Admins get no exception.

- Stored as a deny-list (`location_share_blocks`: owner, viewer); no row
  means sharing. The server keeps it in memory for the broadcast path.
- Enforced on the server, not the client: live updates skip hidden viewers,
  the WS snapshot carries a redacted entry (`{user_id, username,
  sharing: false}`: no position, battery, last-seen or dwell time), and
  `GET /api/v1/history?user_id=` answers 403 `not_sharing`.
- A hidden user stays in the viewer's roster, marked "Not sharing with you".
- Toggling pushes the viewer an immediate entry: redacted when switched off,
  the current position when switched back on.
- API: `GET /api/v1/sharing` (`hidden_from`), `PUT /api/v1/sharing/:viewerId`
  with `{"enabled": bool}`.

## Server protocol changes

| | |
|---|---|
| `POST /api/v1/devices` (JWT) | `{platform, replaces?}` → `{device_id, device_token}` |
| `DELETE /api/v1/devices/:id` | JWT, or the device's own token |
| `POST /api/v1/location` | Also accepts `Authorization: Device <token>` (plus `X-Token-Rotation: 1` to opt into rotation); `coords.accuracy`; `source` ∈ `move`, `trip_start`, `trip_end`, `ping`, `heartbeat`, `live` (not stored); response adds `stored`, `live_ttl_s`, and `device_token` when the token was rotated; broadcast only moves a marker forward in time |
| FCM data | `lt_cmd` (`live`/`idle`/`refresh`), `lt_ttl`; `pacing` kept for older builds |
| `POST /api/v1/users/:userId/location-refresh` (JWT) | Wakes that user's phone; `200` roster entry / `504 device_unreachable` / `403 not_sharing` / `409 no_device` / `404` |
| History | `trip_start`/`trip_end` delimit sessions; silent stops (≥ 10 min, < 75 m) split; `heartbeat`/`ping` excluded; average speed = distance / time |
| Schema | `location_history.accuracy`, `users.battery_level/is_charging/tracking_issues`, `devices` (created by `ensureBackendSchema()` on boot) |

## Rollout

1. Deploy the server first. It stays compatible with current app builds (JWT
   uploads, WS `location` messages and the `pacing` push field still work).
2. Ship the app. On first launch it uploads anything left in the old
   SharedPreferences outbox and removes the old keys; the old notification
   channel is deleted.

## On-device checklist

The Kotlin engine is compiled and its sampling/stop logic unit-tested; the
Swift engine has not been compiled (needs Xcode). Verify on real devices:

- [ ] iOS: builds; "Always" prompt flow; drive with the app swiped away →
      trip recorded and uploaded; parked overnight → resumes next morning.
- [ ] Android 13/14/15 (Pixel + one aggressive OEM): drive with the app swiped
      away; reboot while parked then drive; airplane mode during a drive →
      batch arrives after.
- [ ] Notification shows only during trips; swiping it doesn't stop the trip.
- [ ] Open the map on phone A while B is parked/driving → B updates within
      seconds; close A → B returns to batching (debug log: "Live mode off").
- [ ] Battery over a normal day vs the previous build (Settings → Battery).
- [ ] Profile tab status card flags missing "Allow all the time" / precise /
      physical activity / battery optimization.

## Known limits

- Force-stop (Settings → Force stop) disables all of this until the app is
  opened again — Android removes alarms, geofences and jobs.
- iOS force-quit: region/significant-change relaunches generally still work,
  but silent pushes are not delivered to a force-quit app.
- FCM may deprioritise high-priority messages that never show a notification,
  so "instant" can occasionally become "next upload". Moving devices still
  converge through `live_ttl_s` on their next upload.
- Trip start: before the geofence exit or activity event fires (typically
  < 1–2 min), the route is a straight line from the parking spot.
- Approximate location (Android 12+/iOS 14+) makes routes useless; the status
  card asks for precise location.
