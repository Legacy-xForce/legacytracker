import { formatElapsed } from './format';
import type { IconName } from './icons';
import { hasPosition, isMoving, isStale, type Peer } from './peers';

export interface Presence {
    icon: IconName;
    /** Stat-card label and value: "Here for" / "2h 45m". */
    label: string;
    value: string;
    /** The same as one line for the people list: "Here for 2h 45m". */
    sentence: string;
}

/** Where someone is in time: how long they've been here, that they're moving, or when we last heard. */
export function presence(peer: Peer, now: number): Presence {
    if (!peer.sharing) {
        return { icon: 'visibilityOff', label: 'Location', value: 'Hidden', sentence: 'Location hidden' };
    }
    if (!hasPosition(peer)) {
        return { icon: 'locationOff', label: 'Location', value: 'None yet', sentence: 'No location yet' };
    }
    if (isStale(peer, now)) {
        const ago = peer.lastSeenAt === null ? 'a while ago' : `${formatElapsed(now - peer.lastSeenAt)} ago`;
        return {
            icon: 'history',
            label: 'Last seen',
            value: peer.lastSeenAt === null ? '—' : ago,
            sentence: `Last seen ${ago}`
        };
    }
    if (isMoving(peer)) return { icon: 'nearMe', label: 'Status', value: 'Moving', sentence: 'Moving' };
    const here = formatElapsed(now - (peer.hereSince ?? peer.recordedAt ?? now));
    return { icon: 'timer', label: 'Here for', value: here, sentence: `Here for ${here}` };
}
