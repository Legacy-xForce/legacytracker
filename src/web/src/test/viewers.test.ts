import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ViewersStack from '../components/map/ViewersStack.vue';
import { parseViewers, selfFirst, type Viewer } from '../lib/viewers';
import { usePeersStore } from '../stores/peers';

const streams = vi.hoisted(() => ({ onMessage: null as ((message: unknown) => void) | null }));

vi.mock('../api/stream', () => ({
    StreamClient: class {
        constructor(options: { onMessage: (message: unknown) => void }) {
            streams.onMessage = options.onMessage;
        }
        start() {}
        stop() {}
        setMapActive() {}
        reconnect() {}
    }
}));

describe('parseViewers', () => {
    it('reads the viewers in the order they started looking', () => {
        expect(
            parseViewers({
                type: 'viewers',
                viewers: [
                    { id: 'b', name: 'Bea' },
                    { id: 'a', name: 'Al' }
                ]
            })
        ).toEqual([
            { id: 'b', name: 'Bea' },
            { id: 'a', name: 'Al' }
        ]);
    });

    it('ignores every other message', () => {
        expect(parseViewers({ type: 'snapshot', users: [] })).toBeNull();
        expect(parseViewers({ user_id: 'a', latitude: 1 })).toBeNull();
        expect(parseViewers([])).toBeNull();
        expect(parseViewers(null)).toBeNull();
    });

    it('skips malformed entries and falls back to the id for a name', () => {
        expect(
            parseViewers({ type: 'viewers', viewers: [{ id: 'a' }, { name: 'No id' }, { id: '' }, 'junk'] })
        ).toEqual([{ id: 'a', name: 'a' }]);
        expect(parseViewers({ type: 'viewers' })).toEqual([]);
    });
});

describe('selfFirst', () => {
    it('puts us first and keeps everyone else in order', () => {
        const viewers = [
            { id: 'a', name: 'Al' },
            { id: 'me', name: 'Me' },
            { id: 'b', name: 'Bea' }
        ];
        expect(selfFirst(viewers, 'me').map((v) => v.id)).toEqual(['me', 'a', 'b']);
        expect(selfFirst(viewers, 'nobody').map((v) => v.id)).toEqual(['a', 'me', 'b']);
    });
});

describe('peers store', () => {
    beforeEach(() => setActivePinia(createPinia()));

    it('keeps the viewers apart from the people on the map', () => {
        const store = usePeersStore();
        store.start();
        streams.onMessage!({ type: 'snapshot', users: [{ user_id: 'a', username: 'Al' }] });
        streams.onMessage!({ type: 'viewers', viewers: [{ id: 'a', name: 'Al' }] });

        expect(store.viewers).toEqual([{ id: 'a', name: 'Al' }]);
        expect([...store.peers.keys()]).toEqual(['a']);

        streams.onMessage!({ type: 'viewers', viewers: [] });
        expect(store.viewers).toEqual([]);
        expect(store.loaded).toBe(true);
    });

    it('forgets the viewers when the stream stops', () => {
        const store = usePeersStore();
        store.start();
        streams.onMessage!({ type: 'viewers', viewers: [{ id: 'a', name: 'Al' }] });
        store.stop();
        expect(store.viewers).toEqual([]);
    });
});

describe('ViewersStack', () => {
    const viewer = (id: string): Viewer => ({ id, name: id.toUpperCase() });
    const shown = (wrapper: ReturnType<typeof mount>) =>
        wrapper.findAll('[data-viewer]').map((face) => face.attributes('data-viewer'));

    it('shows nothing while nobody is looking', () => {
        const wrapper = mount(ViewersStack, { props: { viewers: [], selfId: 'me' } });
        expect(wrapper.find('[role="img"]').exists()).toBe(false);
    });

    it('shows everyone, us first, and names them', () => {
        const wrapper = mount(ViewersStack, {
            props: { viewers: [viewer('al'), viewer('me'), viewer('bea')], selfId: 'me' }
        });
        expect(shown(wrapper)).toEqual(['me', 'al', 'bea']);
        expect(wrapper.text()).not.toContain('+');
        expect(wrapper.find('[role="img"]').attributes('aria-label')).toBe('Viewing the map: you, AL, BEA');
    });

    it('counts the rest once there are too many faces', () => {
        const wrapper = mount(ViewersStack, {
            props: { viewers: ['al', 'bea', 'me', 'cy', 'di'].map(viewer), selfId: 'me' }
        });
        expect(shown(wrapper)).toEqual(['me', 'al']);
        expect(wrapper.text()).toContain('+3');
    });

    it('follows the list as people come and go', async () => {
        const wrapper = mount(ViewersStack, { props: { viewers: [viewer('me')], selfId: 'me' } });
        await wrapper.setProps({ viewers: [viewer('me'), viewer('al')] });
        expect(shown(wrapper)).toEqual(['me', 'al']);
        await wrapper.setProps({ viewers: [viewer('al')] });
        // A leaving face may linger for its fade; the new one is there either way.
        expect(shown(wrapper)).toContain('al');
    });
});
