import admin from 'firebase-admin';

let messaging: admin.messaging.Messaging | null = null;

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

export async function broadcastPacingMode(tokens: string[], pacing: string): Promise<void> {
  if (!messaging || tokens.length === 0) {
    return;
  }

  const chunks: string[][] = [];
  for (let i = 0; i < tokens.length; i += 500) {
    chunks.push(tokens.slice(i, i + 500));
  }

  for (const chunk of chunks) {
    try {
      await messaging.sendEachForMulticast({
        tokens: chunk,
        data: { type: 'pacing_update', pacing },
        android: { priority: 'high' },
        apns: {
          headers: { 'apns-priority': '10' },
          payload: { aps: { contentAvailable: true } },
        },
      });
    } catch {
      // Silently ignore FCM errors so location tracking continues unaffected.
    }
  }
}
