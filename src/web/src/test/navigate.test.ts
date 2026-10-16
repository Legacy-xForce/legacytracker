import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PersonDetail from '../components/people/PersonDetail.vue';
import { directionsUrl, prefersAppleMaps } from '../lib/navigation';
import type { Peer } from '../lib/peers';
import { jsonResponse } from './helpers';

describe('directionsUrl', () => {
    it('opens Google Maps directions by default', () => {
        expect(directionsUrl(45.1, -9.2, false)).toBe(
            'https://www.google.com/maps/dir/?api=1&destination=45.1,-9.2&travelmode=driving'
        );
    });

    it('opens Apple Maps directions on Apple devices', () => {
        expect(directionsUrl(45.1, -9.2, true)).toBe('https://maps.apple.com/?daddr=45.1,-9.2&dirflg=d');
    });

    it('picks Apple Maps only for iPhone, iPad and Mac', () => {
        expect(prefersAppleMaps('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)')).toBe(true);
        expect(prefersAppleMaps('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)')).toBe(true);
        expect(prefersAppleMaps('Mozilla/5.0 (Linux; Android 14; Pixel 8)')).toBe(false);
        expect(prefersAppleMaps('Mozilla/5.0 (X11; Linux x86_64)')).toBe(false);
    });
});

describe('the navigate pill', () => {
    const peer: Peer = {
        id: 'bob',
        name: 'Bob',
        sharing: true,
        latitude: 45.1,
        longitude: 9.2,
        speed: 0,
        heading: null,
        recordedAt: Date.now(),
        lastSeenAt: Date.now(),
        hereSince: null,
        batteryLevel: 80,
        isCharging: false,
        trackingIssues: []
    };

    beforeEach(() => {
        setActivePinia(createPinia());
        vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({ sessions: [] })));
    });

    function open(props: Record<string, unknown> = {}) {
        return mount(PersonDetail, {
            props: { peer, self: false, now: Date.now(), ...props },
            global: { stubs: { PlaceLabel: true } }
        });
    }

    it('links to directions and shows the straight-line distance from the viewer', () => {
        // 0.09° of latitude is ~10 km.
        const pill = open({ viewer: { lat: 45.01, lng: 9.2 } }).get('a[aria-label^="Navigate to Bob"]');
        expect(pill.text()).toBe('10 km');
        expect(pill.attributes('href')).toMatch(/destination=45\.1,9\.2/);
        expect(pill.attributes('target')).toBe('_blank');
    });

    it('still offers navigation when the viewer has no position of their own', () => {
        const pill = open({ viewer: null }).get('a[aria-label="Navigate to Bob"]');
        expect(pill.text()).toBe('Navigate');
    });

    it('is not offered on your own details', () => {
        expect(open({ self: true }).find('a[aria-label^="Navigate"]').exists()).toBe(false);
    });

    it('is not offered for someone with no position or who hides from you', () => {
        expect(
            open({ peer: { ...peer, latitude: null, longitude: null } })
                .find('a[href]')
                .exists()
        ).toBe(false);
        expect(
            open({ peer: { ...peer, sharing: false } })
                .find('a[href]')
                .exists()
        ).toBe(false);
    });
});
