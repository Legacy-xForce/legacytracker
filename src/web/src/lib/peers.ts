import { parseTrackingIssues, type TrackingIssue } from './tracking-issues';

/** One person on the map, as the tracker stream describes them. */
export interface Peer {
    id: string;
    name: string;
    /** False when they switched off sharing with us: no position, battery or presence. */
    sharing: boolean;
    latitude: number | null;
    longitude: number | null;
    /** m/s */
    speed: number;
    heading: number | null;
    /** Epoch ms of the newest fix. */
    recordedAt: number | null;
    /** Epoch ms they arrived where they are now; null while travelling. */
    hereSince: number | null;
    lastSeenAt: number | null;
    batteryLevel: number | null;
    isCharging: boolean | null;
    /** Phone settings that block their location updates, as they last reported them. */
    trackingIssues: TrackingIssue[];
}

// Same thresholds as the phone app: >= 1 m/s counts as moving, and silence
// beyond 90 minutes means the phone is off, offline or not sharing.
export const MOVING_SPEED = 1;
export const STALE_AFTER_MS = 90 * 60_000;

export function isMoving(peer: Peer): boolean {
    return peer.sharing && peer.latitude !== null && peer.speed >= MOVING_SPEED;
}

export function hasPosition(peer: Peer): boolean {
    return peer.sharing && peer.latitude !== null && peer.longitude !== null;
}

export function isStale(peer: Peer, now: number): boolean {
    return peer.lastSeenAt === null || now - peer.lastSeenAt > STALE_AFTER_MS;
}

function num(value: unknown): number | null {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string' && value.trim() !== '') {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : null;
    }
    return null;
}

function time(value: unknown): number | null {
    if (typeof value !== 'string') return null;
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
}

function applyUpdate(peers: Map<string, Peer>, payload: Record<string, unknown>): boolean {
    const id = payload.user_id;
    if (typeof id !== 'string' || id === '') return false;

    const existing = peers.get(id);
    const incomingName = typeof payload.username === 'string' ? payload.username : null;
    const peer: Peer = existing
        ? { ...existing }
        : {
              id,
              name: incomingName ?? id,
              sharing: true,
              latitude: null,
              longitude: null,
              speed: 0,
              heading: null,
              recordedAt: null,
              hereSince: null,
              lastSeenAt: null,
              batteryLevel: null,
              isCharging: null,
              trackingIssues: []
          };
    if (incomingName !== null && incomingName !== id) peer.name = incomingName;

    // Roster-only entries carry no coordinates; updates without them only refresh presence.
    const latitude = num(payload.latitude);
    const longitude = num(payload.longitude);
    if (latitude !== null && longitude !== null) {
        peer.latitude = latitude;
        peer.longitude = longitude;
        peer.speed = num(payload.speed) ?? 0;
        peer.heading = num(payload.heading);
        peer.recordedAt = time(payload.recorded_at) ?? Date.now();
    }
    // Sent with every update, coordinates or not; null while travelling.
    if ('here_since' in payload) peer.hereSince = time(payload.here_since);
    const lastSeenAt = time(payload.last_seen_at);
    if (lastSeenAt !== null) peer.lastSeenAt = lastSeenAt;
    const battery = num(payload.battery_level);
    if (battery !== null) peer.batteryLevel = Math.round(battery);
    if (typeof payload.is_charging === 'boolean') peer.isCharging = payload.is_charging;
    // An empty list is a report that nothing is wrong; a missing field leaves it as it was.
    if (Array.isArray(payload.tracking_issues)) peer.trackingIssues = parseTrackingIssues(payload.tracking_issues);

    if ('sharing' in payload) {
        peer.sharing = payload.sharing !== false;
        if (!peer.sharing) {
            peer.latitude = null;
            peer.longitude = null;
            peer.speed = 0;
            peer.heading = null;
            peer.recordedAt = null;
            peer.hereSince = null;
            peer.lastSeenAt = null;
            peer.batteryLevel = null;
            peer.isCharging = null;
            peer.trackingIssues = [];
        }
    }

    peers.set(id, peer);
    return true;
}

/**
 * Folds one stream message into `peers`: a `{type: 'snapshot', users}` roster, a single update, or
 * a list of updates. Returns whether anything changed. Mutates `peers`.
 */
export function applyMessage(peers: Map<string, Peer>, message: unknown): boolean {
    if (Array.isArray(message)) {
        return message.map((item) => applyMessage(peers, item)).some(Boolean);
    }
    if (message === null || typeof message !== 'object') return false;

    const payload = message as Record<string, unknown>;
    if (payload.type === 'snapshot' && Array.isArray(payload.users)) {
        // A snapshot is the whole roster: anyone missing from it has gone.
        const before = peers.size;
        peers.clear();
        for (const user of payload.users) {
            if (user !== null && typeof user === 'object') applyUpdate(peers, user as Record<string, unknown>);
        }
        return before > 0 || peers.size > 0;
    }
    return applyUpdate(peers, payload);
}
