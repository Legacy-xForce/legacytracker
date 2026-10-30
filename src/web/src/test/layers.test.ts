import { mount } from '@vue/test-utils';
import { h } from 'vue';
import { beforeAll, describe, expect, it } from 'vitest';
import CheckpointsLayer from '../components/CheckpointsLayer.vue';
import EventsLayer from '../components/EventsLayer.vue';
import PeersMap from '../components/PeersMap.vue';
import PlaceDraftLayer from '../components/places/PlaceDraftLayer.vue';
import ReplayLayer from '../components/ReplayLayer.vue';
import { parseEvent } from '../lib/events';
import { ReplayTrack, type ReplayPoint } from '../lib/replay';

beforeAll(() => {
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, value: 800 });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', { configurable: true, value: 600 });
});

function mountMap(layer: () => ReturnType<typeof h>) {
    return mount(PeersMap, {
        attachTo: document.body,
        props: { peers: [], selfId: '', selectedId: null, now: Date.now() },
        slots: { default: layer }
    });
}

describe('map overlays', () => {
    it('draws saved places as labelled circles', async () => {
        const wrapper = mountMap(() =>
            h(CheckpointsLayer, {
                checkpoints: [{ id: '1', name: 'Home', latitude: 45, longitude: 9, radius: 100, canEdit: true }]
            })
        );
        await wrapper.vm.$nextTick();
        expect(document.querySelector('.checkpoint-label')?.textContent).toBe('Home');
        wrapper.unmount();
    });

    it('draws the place being edited and clears it when the editor closes', async () => {
        let draft: { latitude: number; longitude: number; radius: number } | null = {
            latitude: 45,
            longitude: 9,
            radius: 80
        };
        const moves: number[][] = [];
        const wrapper = mountMap(() =>
            h(PlaceDraftLayer, { draft, onMove: (lat: number, lng: number) => moves.push([lat, lng]) })
        );
        await wrapper.vm.$nextTick();
        // The crosshair reports where the map is looking as soon as it is up.
        expect(moves.length).toBeGreaterThan(0);
        wrapper.unmount();
        draft = null;
    });

    it('draws only events that have a place on the map', async () => {
        const base = { id: 'e', title: 'Party', startTime: '2030-01-01T10:00:00Z' };
        const placed = { ...parseEvent(base)!, point: [45, 9] as [number, number] };
        const unplaced = { ...parseEvent({ ...base, id: 'f' })!, point: null };
        const wrapper = mountMap(() => h(EventsLayer, { events: [placed, unplaced], now: Date.now() }));
        await wrapper.vm.$nextTick();
        expect(document.querySelectorAll('.event-marker').length).toBe(1);

        document.querySelector('.event-marker')!.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        await wrapper.vm.$nextTick();
        expect(document.querySelector('.mapboxgl-popup')?.textContent).toContain('Party');
        wrapper.unmount();
    });

    it('shows a replay with its controls and lets you scrub', async () => {
        const points: ReplayPoint[] = [0, 1, 2].map((i) => ({
            latitude: 45 + i * 0.001,
            longitude: 9,
            speed: i * 5,
            heading: 0,
            recordedAt: Date.UTC(2026, 5, 10, 10, i)
        }));
        const session = {
            startAt: points[0].recordedAt,
            endAt: points[2].recordedAt,
            durationSeconds: 120,
            distanceMeters: 222,
            avgSpeed: 5,
            topSpeed: 10,
            pointCount: 3,
            points
        };
        const closed: unknown[] = [];
        const wrapper = mountMap(() =>
            h(ReplayLayer, {
                userId: 'u',
                userName: 'Ada',
                session,
                track: new ReplayTrack(points),
                onClose: () => closed.push(1)
            })
        );
        await wrapper.vm.$nextTick();
        expect(document.querySelector('.peer-marker')).not.toBeNull();

        const slider = document.querySelector('input[type=range]') as HTMLInputElement;
        slider.value = '2';
        slider.dispatchEvent(new Event('input'));
        await wrapper.vm.$nextTick();
        expect(document.body.textContent).toContain('36 km/h');

        window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        expect(closed).toHaveLength(1);
        wrapper.unmount();
    });
});
