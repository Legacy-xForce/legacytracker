import { mount } from '@vue/test-utils';
import { beforeAll, describe, expect, it } from 'vitest';
import PeersMap from '../components/PeersMap.vue';
import type { Peer } from '../lib/peers';

function peer(id: string, name: string, latitude: number | null, longitude: number | null): Peer {
    return {
        id,
        name,
        sharing: true,
        latitude,
        longitude,
        speed: 0,
        heading: null,
        recordedAt: Date.now(),
        hereSince: null,
        lastSeenAt: Date.now(),
        batteryLevel: null,
        isCharging: null,
        trackingIssues: []
    };
}

// jsdom has no layout, so give the map a size or the cluster layer considers nothing to be in view.
beforeAll(() => {
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, value: 800 });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', { configurable: true, value: 600 });
});

describe('PeersMap', () => {
    it('mounts and draws a marker for each person with a position', async () => {
        const wrapper = mount(PeersMap, {
            attachTo: document.body,
            props: {
                peers: [peer('a', 'Ada', 45.1, 9.2), peer('b', 'Bob', null, null)],
                selfId: 'a',
                selectedId: null,
                now: Date.now()
            }
        });
        expect(document.querySelectorAll('.peer-marker').length).toBe(1);

        // Someone standing next to them folds into one bubble, with a face each...
        await wrapper.setProps({ peers: [peer('a', 'Ada', 45.1, 9.2), peer('b', 'Bob', 45.1001, 9.2001)] });
        const faces = [...document.querySelectorAll('.peer-cluster [data-member]')];
        expect(faces.map((face) => face.getAttribute('data-member'))).toEqual(['a', 'b']);
        expect(document.querySelectorAll('.peer-marker').length).toBe(0);

        // ...and leaving the roster takes their marker off the map.
        await wrapper.setProps({ peers: [peer('a', 'Ada', 45.1, 9.2)] });
        expect(document.querySelector('.peer-cluster')).toBeNull();
        expect(document.querySelectorAll('.peer-marker').length).toBe(1);
        wrapper.unmount();
    });

    it('updates a marker in place instead of rebuilding it', async () => {
        const wrapper = mount(PeersMap, {
            attachTo: document.body,
            props: { peers: [peer('a', 'Ada', 45.1, 9.2)], selfId: '', selectedId: null, now: Date.now() }
        });
        const before = document.querySelector('.peer-marker');
        await wrapper.setProps({
            peers: [{ ...peer('a', 'Ada', 45.1, 9.2), batteryLevel: 40 }],
            now: Date.now() + 5000
        });

        expect(document.querySelector('.peer-marker')).toBe(before);
        expect(before?.textContent).toContain('40%');
        wrapper.unmount();
    });
});
