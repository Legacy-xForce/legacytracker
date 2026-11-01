#!/usr/bin/env node
// Simulates a GPS drive around central Turin and uploads it to a tracker server.
//
//   node scripts/simulate-drive.mjs --server http://localhost:3000 --token legacy-tracker-<uuid> [--interval 3000]
//
// --server is required on purpose: there is no default, so a forgotten flag can
// never write fake history to production. The token is a *write* API token
// (X-API-Token); create one in the web app, or pass it as LEGACY_TRACKER_TOKEN.

const DEFAULT_INTERVAL_MS = 3000;

function option(name) {
  const args = process.argv.slice(2);
  const index = args.indexOf(`--${name}`);
  return index === -1 ? undefined : args[index + 1];
}

const serverUrl = option('server')?.replace(/\/+$/, '');
const token = option('token') ?? process.env.LEGACY_TRACKER_TOKEN;
const intervalMs = Number(option('interval') ?? DEFAULT_INTERVAL_MS);

if (!serverUrl || !token) {
  console.error('Usage: node scripts/simulate-drive.mjs --server <url> --token <write API token> [--interval ms]');
  console.error('--server is required (no production default); the token may also come from LEGACY_TRACKER_TOKEN.');
  process.exit(2);
}

// Piazza Castello -> Via Po -> Piazza Vittorio Veneto -> Lungo Po -> Parco del
// Valentino -> Via Nizza -> back north. Each waypoint: [lat, lng, headingDeg, speedMps]
const WAYPOINTS = [
  [45.07031, 7.68688, 180, 8.3], // Piazza Castello
  [45.0682, 7.6868, 180, 9.0], // Via Roma
  [45.0662, 7.6865, 170, 8.5], // Piazza Carlo Felice
  [45.0645, 7.687, 85, 9.5], // turn east onto Via Lagrange
  [45.0646, 7.691, 85, 9.0], // Via Po mid
  [45.0648, 7.6935, 80, 8.0], // approaching Piazza Vittorio Veneto
  [45.0645, 7.695, 175, 6.5], // Piazza Vittorio Veneto, slow to turn south
  [45.062, 7.6948, 180, 7.5], // Lungo Po Armando Diaz
  [45.059, 7.694, 200, 8.0], // Parco del Valentino north
  [45.056, 7.692, 220, 7.0], // Valentino deep south
  [45.055, 7.689, 270, 8.5], // turn west
  [45.055, 7.684, 270, 9.0], // Via Nizza heading west
  [45.0552, 7.68, 350, 8.0], // turn north
  [45.058, 7.6798, 350, 9.5], // north along Corso Raffaello
  [45.061, 7.68, 5, 9.0], // Corso Vittorio Emanuele II area
  [45.064, 7.6805, 355, 8.5], // approaching the centre from the west
  [45.067, 7.681, 10, 8.0], // Via XX Settembre
  [45.07031, 7.68688, 90, 7.0] // back to Piazza Castello
];

const lerp = (a, b, t) => a + (b - a) * t;
const angleLerp = (a, b, t) => (a + (((b - a + 540) % 360) - 180) * t + 360) % 360;

// A smooth list of fixes interpolated between the waypoints.
function buildRoute(stepsPerSegment = 15) {
  const steps = [];
  for (let i = 0; i < WAYPOINTS.length; i++) {
    const from = WAYPOINTS[i];
    const to = WAYPOINTS[(i + 1) % WAYPOINTS.length];
    for (let s = 0; s < stepsPerSegment; s++) {
      const t = s / stepsPerSegment;
      steps.push({
        latitude: lerp(from[0], to[0], t),
        longitude: lerp(from[1], to[1], t),
        heading: angleLerp(from[2], to[2], t),
        speed: lerp(from[3], to[3], t)
      });
    }
  }
  return steps;
}

async function sendLocation({ latitude, longitude, speed, heading }, source) {
  return fetch(`${serverUrl}/api/v1/location`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-token': token },
    body: JSON.stringify([
      {
        coords: { latitude, longitude, speed, heading, accuracy: 5 },
        timestamp: new Date().toISOString(),
        source,
        battery_level: 80,
        is_charging: false,
        tracking_issues: []
      }
    ])
  });
}

const route = buildRoute();
let step = 0;

console.log(`Sending a fix every ${intervalMs} ms to ${serverUrl} (${route.length} steps per lap). Ctrl+C to stop.\n`);

async function tick() {
  const index = step % route.length;
  const point = route[index];
  const source = step === 0 ? 'trip_start' : 'move';
  try {
    const res = await sendLocation(point, source);
    console.log(
      `[${new Date().toISOString()}] ${index + 1}/${route.length} ` +
        `lat=${point.latitude.toFixed(5)} lng=${point.longitude.toFixed(5)} ` +
        `spd=${point.speed.toFixed(1)}m/s -> HTTP ${res.status}`
    );
    if (res.status === 401 || res.status === 403) {
      console.error('The token was refused (needs a write API token and an allowed address). Exiting.');
      process.exit(1);
    }
  } catch (err) {
    console.error(`Send failed: ${err.message}`);
  }
  step++;
  setTimeout(tick, intervalMs);
}

tick();
