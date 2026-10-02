import admin from 'firebase-admin';

import type { TrackingCommand } from './live-controller';

let messaging: admin.messaging.Messaging | null = null;

// A stale "go live" push is worthless after a minute — let FCM/APNs drop it
// instead of waking the device late.
const COMMAND_TTL_SECONDS = 60;

const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

export function initializeFcm(): boolean {
  const json = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!json) {
    return false;
  }
  try {
    const serviceAccount = JSON.parse(json) as admin.ServiceAccount;
    const app = admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    messaging = admin.messaging(app);
    return true;
  } catch {
    return false;
  }
}

/**
 * Sends a data-only tracking command to every device. Returns the tokens FCM
 * reported as permanently invalid so the caller can prune them.
 *
 * `live` goes out at high priority: on Android that grants the brief
 * background-start allowance the engine needs to take a fresh GPS fix. iOS
 * background (content-available) pushes must use apns-priority 5 and push
 * type `background` — priority 10 is rejected for them.
 */
export async function sendTrackingCommand(
  tokens: string[],
  command: TrackingCommand,
  ttlSeconds: number,
): Promise<string[]> {
  if (!messaging || tokens.length === 0) {
    return [];
  }

  const live = command === 'live';
  const invalid: string[] = [];
  for (let i = 0; i < tokens.length; i += 500) {
    const chunk = tokens.slice(i, i + 500);
    try {
      const response = await messaging.sendEachForMulticast({
        tokens: chunk,
        data: {
          type: 'tracking_command',
          lt_cmd: command,
          lt_ttl: String(ttlSeconds),
          // Read by older app builds that still poll on a pacing mode.
          pacing: live ? 'AGGRESSIVE' : 'PASSIVE',
        },
        android: {
          priority: live ? 'high' : 'normal',
          ttl: COMMAND_TTL_SECONDS * 1000,
        },
        apns: {
          headers: {
            'apns-push-type': 'background',
            'apns-priority': '5',
            'apns-expiration': String(Math.floor(Date.now() / 1000) + COMMAND_TTL_SECONDS),
          },
          payload: { aps: { contentAvailable: true } },
        },
      });
      response.responses.forEach((result, index) => {
        const code = result.error?.code;
        if (!result.success && code && INVALID_TOKEN_CODES.has(code)) {
          invalid.push(chunk[index]);
        }
      });
    } catch {
      // Silently ignore FCM errors so location tracking continues unaffected.
    }
  }
  return invalid;
}
