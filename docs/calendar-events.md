# Calendar events on the map

Upcoming Legacy Calendar events with a location that can be pinpointed are
drawn on the tracker map. Tapping a pin shows the event's name, the time
until it starts (or ends, once running) and who is coming.

## Who sees it

Only accounts whose access token has `scopes.calendar`. Legacy Calendar
accepts the same token as the tracker, so nothing extra is requested. Without
the scope there is no overlay and no toggle. A 401/403 from the calendar
switches the overlay off until the session changes.

The overlay is on by default; the button under the map-style and
"my location" buttons hides or shows it, and the choice is remembered on the
phone.

## Where the data comes from

- `GET {calendar}/events?start&end` with `Authorization: Bearer <token>`,
  from yesterday to 60 days ahead. `/events/upcoming` isn't used because it
  isn't specified to include events already in progress.
- Refetched on sign-in, when the app resumes, when the overlay is turned on,
  and every 5 minutes while signed in.
- "Coming" is the host plus every participant with status `ACCEPTED`.
- Debug builds can point at another calendar with
  `--dart-define=CALENDAR_URL=...`; release builds always use production.

## What is shown, and until when

An event is shown until its `endTime`; with no end time, until midnight (local
time) at the end of the day it starts.

## Placing events

Events carry only a free-text `location`, so it is geocoded with Nominatim
(the same service as place search). Events whose text doesn't resolve are
simply not shown.

- Lookups run one at a time, at least 1.1 s apart (Nominatim's policy).
- Every answer, including "not found", is cached in SharedPreferences, so a
  given text is looked up once. A failed lookup (network) is not cached.
- Note that this sends the event's location text to Nominatim. Storing
  coordinates on the event in Legacy Calendar would avoid that and make
  placement reliable.

## Code

`features/calendar/` (provider, marker, details sheet),
`data/network/calendar_service.dart`, `data/network/event_geocoder.dart`,
`data/models/calendar_event.dart`. Tests: `test/calendar_events_test.dart`.
