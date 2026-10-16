import admin from 'firebase-admin';

import type { TrackingCommand } from './live-controller';

let messaging: admin.messaging.Messaging | null = null;

// A stale "go live" push is worthless after a minute — let FCM/APNs drop it
// instead of waking the device late.
const COMMAND_TTL_SECONDS = 60;
// Devices also check on their own every few hours; a day covers phones that
// are off for a while without piling up stale notices.
const UPDATE_NOTICE_TTL_SECONDS = 24 * 60 * 60;

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
  const live = command === 'live';
  return sendToTokens(tokens, {
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
}

/**
 * Asks one user's devices for a fresh position right now (`lt_cmd: refresh`),
 * whatever live mode says. Same delivery rules as `live`: high priority for
 * the brief background-start allowance, and a short TTL, since a viewer is
 * waiting on the answer and gives up after about half a minute.
 */
export async function sendRefreshCommand(tokens: string[]): Promise<string[]> {
  return sendToTokens(tokens, {
    data: { type: 'tracking_command', lt_cmd: 'refresh' },
    android: {
      priority: 'high',
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
}

/**
 * Tells devices a new Android release is out (`lt_cmd: update`), so the
 * native updater fetches and installs it now instead of at its next periodic
 * check. Normal priority: it can wait for the phone's next maintenance
 * window. No APNs options — iOS has no self-update and ignores the command.
 */
export async function sendAppUpdateNotice(
  tokens: string[],
  versionCode: number,
): Promise<string[]> {
  return sendToTokens(tokens, {
    data: {
      type: 'app_update',
      lt_cmd: 'update',
      lt_version: String(versionCode),
    },
    android: {
      priority: 'normal',
      ttl: UPDATE_NOTICE_TTL_SECONDS * 1000,
    },
  });
}

async function sendToTokens(
  tokens: string[],
  message: Omit<admin.messaging.MulticastMessage, 'tokens'>,
): Promise<string[]> {
  if (!messaging || tokens.length === 0) {
    return [];
  }

  const invalid: string[] = [];
  for (let i = 0; i < tokens.length; i += 500) {
    const chunk = tokens.slice(i, i + 500);
    try {
      const response = await messaging.sendEachForMulticast({ ...message, tokens: chunk });
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
