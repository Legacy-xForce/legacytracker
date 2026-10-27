import { mount } from '@vue/test-utils';
import type { Map as MapboxMap } from 'mapbox-gl';
import { beforeAll, describe, expect, it } from 'vitest';
import { h, defineComponent, type ShallowRef } from 'vue';
import PeersMap from '../components/PeersMap.vue';
import { useMap } from '../lib/mapContext';
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

/** Mapbox's own gesture events, which the jsdom stand-in fires by name (see mapbox-mock.ts). */
function fire(map: MapboxMap, type: string) {
    (map as unknown as { fire(type: string): void }).fire(type);
}

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

    it('passes the panel insets to the Mapbox chrome', () => {
        const wrapper = mount(PeersMap, {
            props: {
                peers: [],
                selfId: '',
                selectedId: null,
                now: Date.now(),
                insets: { top: 72, right: 72, bottom: 16, left: 404 }
            }
        });
        const style = (wrapper.element as HTMLElement).style;
        expect(style.getPropertyValue('--lt-map-left-inset')).toBe('404px');
        expect(style.getPropertyValue('--lt-map-right-inset')).toBe('72px');
        expect(style.getPropertyValue('--lt-map-bottom-inset')).toBe('16px');
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

    it('lets go of the person it was holding when the viewer pans the map', async () => {
        // A layer slot is the only way in to the map PeersMap owns.
        const injected: ShallowRef<MapboxMap | null>[] = [];
        const grabber = defineComponent({
            setup() {
                injected.push(useMap());
                return () => null;
            }
        });
        const wrapper = mount(PeersMap, {
            attachTo: document.body,
            props: { peers: [peer('a', 'Ada', 45.1, 9.2)], selfId: '', selectedId: 'a', now: Date.now() },
            slots: { default: () => h(grabber) }
        });
        const marker = () => document.querySelector('.peer-marker') as HTMLElement;

        wrapper.vm.focus('a');
        expect(wrapper.vm.following).toBe('a');
        expect(marker().style.transform).toBe('scale(1.18)');

        fire(injected[0].value!, 'dragstart');
        expect(wrapper.emitted('deselect')).toHaveLength(1);
        expect(wrapper.vm.following).toBeNull();

        // Once the panel takes the selection back down, the marker is an ordinary one.
        await wrapper.setProps({ selectedId: null });
        expect(marker().style.transform).toBe('scale(1)');
        wrapper.unmount();
    });
});
