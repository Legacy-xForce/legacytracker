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
        isCharging: null
    };
}

// jsdom has no layout, so give the map a size or the cluster layer considers nothing to be in view.
beforeAll(() => {
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, value: 800 });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', { configurable: true, value: 600 });
});

// leaflet.markercluster refuses to be added to a map without a maxZoom, which only a real mount shows.
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

        // Someone standing next to them merges into a cluster...
        await wrapper.setProps({ peers: [peer('a', 'Ada', 45.1, 9.2), peer('b', 'Bob', 45.1001, 9.2001)] });
        expect(document.querySelector('.peer-cluster')?.textContent).toBe('2');

        // ...and leaving the roster takes their marker off the map.
        await wrapper.setProps({ peers: [peer('a', 'Ada', 45.1, 9.2)] });
        expect(document.querySelector('.peer-cluster')).toBeNull();
        expect(document.querySelectorAll('.peer-marker').length).toBe(1);
        wrapper.unmount();
    });
});
