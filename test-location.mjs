#!/usr/bin/env node
// Test script: logs in as demouser and simulates a GPS drive around central Turin.
// Usage: node test-location.mjs [--interval 3000] [--server http://localhost:3000]

const AUTH_URL = 'https://auth.legacy-group.tech';
const DEFAULT_SERVER = 'http://localhost:3000';
const DEFAULT_INTERVAL_MS = 3000;

const args = process.argv.slice(2);
const serverIdx = args.indexOf('--server');
const serverUrl = serverIdx !== -1 ? args[serverIdx + 1] : DEFAULT_SERVER;
const intervalIdx = args.indexOf('--interval');
const intervalMs = intervalIdx !== -1 ? Number(args[intervalIdx + 1]) : DEFAULT_INTERVAL_MS;

// Route through central Turin — Piazza Castello → Via Po → Piazza Vittorio Veneto
// → Lungo Po → Parco del Valentino → Via Nizza → back north.
// Each waypoint: [lat, lng, headingDeg, speedMps]
const WAYPOINTS = [
  [45.07031, 7.68688, 180, 8.3],   // Piazza Castello
  [45.06820, 7.68680, 180, 9.0],   // Via Roma
  [45.06620, 7.68650, 170, 8.5],   // Piazza Carlo Felice
  [45.06450, 7.68700, 85,  9.5],   // turn east onto Via Lagrange
  [45.06460, 7.69100, 85,  9.0],   // Via Po mid
  [45.06480, 7.69350, 80,  8.0],   // approaching Piazza Vittorio Veneto
  [45.06450, 7.69500, 175, 6.5],   // Piazza Vittorio Veneto — slow to turn south
  [45.06200, 7.69480, 180, 7.5],   // Lungo Po Armando Diaz
  [45.05900, 7.69400, 200, 8.0],   // Parco del Valentino north
  [45.05600, 7.69200, 220, 7.0],   // Valentino deep south
  [45.05500, 7.68900, 270, 8.5],   // turn west
  [45.05500, 7.68400, 270, 9.0],   // Via Nizza heading west
  [45.05520, 7.68000, 350, 8.0],   // turn north
  [45.05800, 7.67980, 350, 9.5],   // going north along Corso Raffaello
  [45.06100, 7.68000, 5,   9.0],   // Corso Vittorio Emanuele II area
  [45.06400, 7.68050, 355, 8.5],   // approaching city centre from west
  [45.06700, 7.68100, 10,  8.0],   // Via XX Settembre
  [45.07031, 7.68688, 90,  7.0],   // back to Piazza Castello
];

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function angleLerp(a, b, t) {
  let diff = ((b - a + 540) % 360) - 180;
  return (a + diff * t + 360) % 360;
}

// Build a smooth list of coordinate steps by interpolating between waypoints.
function buildRoute(stepsPerSegment = 15) {
  const steps = [];
  for (let i = 0; i < WAYPOINTS.length; i++) {
    const from = WAYPOINTS[i];
    const to = WAYPOINTS[(i + 1) % WAYPOINTS.length];
    for (let s = 0; s < stepsPerSegment; s++) {
      const t = s / stepsPerSegment;
      steps.push({
        latitude:  lerp(from[0], to[0], t),
        longitude: lerp(from[1], to[1], t),
        heading:   angleLerp(from[2], to[2], t),
        speed:     lerp(from[3], to[3], t),
      });
    }
  }
  return steps;
}

async function login(username, password) {
  const res = await fetch(`${AUTH_URL}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Login failed (${res.status}): ${text}`);
  }

  const data = await res.json();
  return data.access_token;
}

async function sendLocation(token, { latitude, longitude, speed, heading }) {
  const payload = [
    {
      coords: { latitude, longitude, speed, heading },
      timestamp: new Date().toISOString(),
    },
  ];

  const res = await fetch(`${serverUrl}/api/v1/location`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });

  return res;
}

async function main() {
  console.log(`Logging in as demouser @ ${AUTH_URL}...`);
  let token;
  try {
    token = await login('demouser', 'demo');
    console.log('Login successful. Access token obtained.\n');
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const route = buildRoute(15);
  let step = 0;
  let lap = 0;

  console.log(`Sending location updates every ${intervalMs}ms to ${serverUrl}`);
  console.log(`Route: ${route.length} steps × waypoints = one lap\n`);
  console.log('Press Ctrl+C to stop.\n');

  const send = async () => {
    const point = route[step % route.length];
    if (step % route.length === 0 && step > 0) {
      lap++;
      console.log(`--- Lap ${lap + 1} ---`);
    }

    try {
      const res = await sendLocation(token, point);
      const pacing = res.headers.get('x-pacing-mode') ?? '-';
      const status = res.status;
      console.log(
        `[${new Date().toISOString()}] step ${(step % route.length) + 1}/${route.length} ` +
        `lat=${point.latitude.toFixed(5)} lng=${point.longitude.toFixed(5)} ` +
        `spd=${point.speed.toFixed(1)}m/s hdg=${Math.round(point.heading)}° ` +
        `→ HTTP ${status} pacing=${pacing}`
      );

      if (status === 401) {
        console.error('Token expired or rejected. Exiting.');
        process.exit(1);
      }
    } catch (err) {
      console.error(`Send failed: ${err.message}`);
    }

    step++;
    setTimeout(send, intervalMs);
  };

  send();
}

main();
