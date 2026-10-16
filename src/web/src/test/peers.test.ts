import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import PeerMarker from '../components/map/PeerMarker.vue';
import { userColor, userInitial } from '../lib/avatars';
import { applyMessage, hasPosition, isMoving, isStale, type Peer } from '../lib/peers';
import { escapeHtml, formatElapsed, formatUpdatedAgo } from '../lib/format';
import { presence } from '../lib/presence';

const NOW = Date.parse('2026-10-14T12:00:00Z');

function roster(...users: Record<string, unknown>[]) {
    const peers = new Map<string, Peer>();
    applyMessage(peers, { type: 'snapshot', users });
    return peers;
}

describe('applyMessage', () => {
    it('builds the roster from a snapshot, including people who never reported a position', () => {
        const peers = roster(
            {
                user_id: 'a',
                username: 'Ada',
                sharing: true,
                latitude: 45.1,
                longitude: 9.2,
                speed: 0,
                recorded_at: '2026-10-14T11:00:00Z'
            },
            { user_id: 'b', username: 'Bob', sharing: true, latitude: null, longitude: null }
        );

        expect(peers.size).toBe(2);
        expect(hasPosition(peers.get('a')!)).toBe(true);
        expect(hasPosition(peers.get('b')!)).toBe(false);
    });

    it('drops anyone missing from a later snapshot', () => {
        const peers = roster({ user_id: 'a', username: 'Ada' }, { user_id: 'b', username: 'Bob' });
        applyMessage(peers, { type: 'snapshot', users: [{ user_id: 'a', username: 'Ada' }] });

        expect([...peers.keys()]).toEqual(['a']);
    });

    it('moves a marker on a position update and keeps what the update does not mention', () => {
        const peers = roster({ user_id: 'a', username: 'Ada', latitude: 1, longitude: 2, battery_level: 80 });
        applyMessage(peers, {
            user_id: 'a',
            username: 'Ada',
            latitude: 3,
            longitude: 4,
            speed: 5,
            heading: 90,
            here_since: null
        });

        const ada = peers.get('a')!;
        expect([ada.latitude, ada.longitude, ada.speed, ada.heading]).toEqual([3, 4, 5, 90]);
        expect(ada.batteryLevel).toBe(80);
        expect(isMoving(ada)).toBe(true);
    });

    it('treats an update without coordinates as presence only', () => {
        const peers = roster({ user_id: 'a', username: 'Ada', latitude: 1, longitude: 2 });
        applyMessage(peers, {
            user_id: 'a',
            battery_level: 40.4,
            is_charging: true,
            last_seen_at: '2026-10-14T11:59:00Z'
        });

        const ada = peers.get('a')!;
        expect([ada.latitude, ada.longitude]).toEqual([1, 2]);
        expect([ada.batteryLevel, ada.isCharging]).toEqual([40, true]);
        expect(isStale(ada, NOW)).toBe(false);
    });

    it('clears everything about someone who stops sharing', () => {
        const peers = roster({ user_id: 'a', username: 'Ada', latitude: 1, longitude: 2, battery_level: 80 });
        applyMessage(peers, { user_id: 'a', username: 'Ada', sharing: false });

        const ada = peers.get('a')!;
        expect(ada.sharing).toBe(false);
        expect(hasPosition(ada)).toBe(false);
        expect(ada.batteryLevel).toBeNull();
    });

    it('tracks the settings a phone reports as blocking its updates', () => {
        const peers = roster({ user_id: 'a', username: 'Ada', latitude: 1, longitude: 2 });
        expect(peers.get('a')!.trackingIssues).toEqual([]);

        applyMessage(peers, { user_id: 'a', tracking_issues: ['battery_optimization', 'location_services_off'] });
        expect(peers.get('a')!.trackingIssues).toEqual(['location_services_off', 'battery_optimization']);

        // Updates that don't mention it leave it alone; an empty list clears it.
        applyMessage(peers, { user_id: 'a', battery_level: 50 });
        expect(peers.get('a')!.trackingIssues).toEqual(['location_services_off', 'battery_optimization']);
        applyMessage(peers, { user_id: 'a', tracking_issues: [] });
        expect(peers.get('a')!.trackingIssues).toEqual([]);
    });

    it('ignores settings this client does not know and forgets them when sharing stops', () => {
        const peers = roster({ user_id: 'a', username: 'Ada', tracking_issues: ['wifi_off', 'background_location'] });
        expect(peers.get('a')!.trackingIssues).toEqual(['background_location']);

        applyMessage(peers, { user_id: 'a', sharing: false });
        expect(peers.get('a')!.trackingIssues).toEqual([]);
    });

    it('keeps the name when an update only carries the id as username', () => {
        const peers = roster({ user_id: 'a', username: 'Ada' });
        applyMessage(peers, { user_id: 'a', username: 'a' });

        expect(peers.get('a')!.name).toBe('Ada');
    });

    it('accepts lists and ignores junk', () => {
        const peers = new Map<string, Peer>();
        expect(applyMessage(peers, [{ user_id: 'a' }, { user_id: 'b' }])).toBe(true);
        expect(applyMessage(peers, 'nope')).toBe(false);
        expect(applyMessage(peers, null)).toBe(false);
        expect(applyMessage(peers, { no: 'id' })).toBe(false);
        expect(peers.size).toBe(2);
    });
});

describe('peer status', () => {
    it('greys out people not heard from for 90 minutes, or never', () => {
        const peers = roster({ user_id: 'a', last_seen_at: '2026-10-14T10:29:00Z' }, { user_id: 'b' });

        expect(isStale(peers.get('a')!, NOW)).toBe(true);
        expect(isStale(peers.get('b')!, NOW)).toBe(true);
    });
});

describe('formatting', () => {
    it('shows the two most significant units', () => {
        expect(formatElapsed(42_000)).toBe('42s');
        expect(formatElapsed(125_000)).toBe('2m 5s');
        expect(formatElapsed(3 * 3600_000 + 20 * 60_000)).toBe('3h 20m');
        expect(formatElapsed(42 * 86400_000 + 3600_000)).toBe('42d 1h');
        expect(formatElapsed(-5)).toBe('0s');
    });

    it('says how long ago a position was sent', () => {
        expect(formatUpdatedAgo(59_000)).toBe('just now');
        expect(formatUpdatedAgo(60_000)).toBe('1 min ago');
        expect(formatUpdatedAgo(100 * 60_000)).toBe('1 hour ago');
        expect(formatUpdatedAgo(5 * 3600_000)).toBe('5 hours ago');
        expect(formatUpdatedAgo(24 * 3600_000)).toBe('1 day ago');
        expect(formatUpdatedAgo(3 * 86400_000 + 7 * 3600_000)).toBe('3 days ago');
        expect(formatUpdatedAgo(-30_000)).toBe('just now');
    });

    it('takes the first letter of a name for the avatar, like the app', () => {
        expect(userInitial('ada Lovelace')).toBe('A');
        expect(userInitial('  iQuick')).toBe('I');
        expect(userInitial('   ')).toBe('?');
    });

    it('gives each person the same colour the phone app does', () => {
        expect(userColor('bob')).toBe('#d81b60');
        expect(userColor('acc3b458-2b51-4e73-9a48-092450b882ee')).toBe('#8e24aa');
    });

    it('never lets a name inject markup into a marker', () => {
        const peer = roster({
            user_id: 'a',
            username: '"><img src=x onerror=alert(1)>',
            latitude: 1,
            longitude: 2
        }).get('a')!;
        const marker = mount(PeerMarker, {
            props: {
                userId: peer.id,
                name: peer.name,
                self: false,
                selected: false,
                stale: false,
                moving: false,
                heading: null,
                speedKmh: 0,
                battery: null,
                charging: false
            }
        });

        expect(marker.find('img').exists()).toBe(false);
        expect(escapeHtml(`<a href="x">&'`)).toBe('&lt;a href=&quot;x&quot;&gt;&amp;&#39;');
    });
});

describe('presence', () => {
    const base = roster({
        user_id: 'a',
        latitude: 1,
        longitude: 2,
        recorded_at: '2026-10-14T11:00:00Z',
        last_seen_at: '2026-10-14T11:59:00Z',
        here_since: '2026-10-14T09:15:00Z'
    }).get('a')!;

    it('says how long someone has been where they are', () => {
        expect(presence(base, NOW)).toMatchObject({ label: 'Here for', value: '2h 45m', sentence: 'Here for 2h 45m' });
    });

    it('says when someone is moving, or when we last heard from them', () => {
        expect(presence({ ...base, speed: 12 }, NOW).sentence).toBe('Moving');
        expect(presence({ ...base, lastSeenAt: NOW - 2 * 3600_000 }, NOW).sentence).toBe('Last seen 2h ago');
    });

    it('says nothing about where someone is who hides from you', () => {
        expect(presence({ ...base, sharing: false }, NOW).sentence).toBe('Location hidden');
    });
});
