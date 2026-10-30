import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import PlacesPanel from '../components/places/PlacesPanel.vue';
import { searchPlaces } from '../lib/places';
import { CheckpointError, parseCheckpoints, useCheckpointsStore } from '../stores/checkpoints';
import { fakeJwt, jsonResponse, startSession, tokenResponse } from './helpers';

let fetchMock: ReturnType<typeof vi.fn>;

const raw = (id: string, name: string, canEdit: boolean) => ({
    id,
    name,
    latitude: 45,
    longitude: 9,
    radius_m: 80,
    created_by: 'u',
    can_edit: canEdit
});

function writes() {
    return fetchMock.mock.calls
        .filter(([url, init]) => String(url).includes('/api/v1/') && (init as RequestInit | undefined)?.method)
        .map(([url, init]) => ({
            path: new URL(String(url)).pathname,
            method: (init as RequestInit).method,
            body: (init as RequestInit).body ? JSON.parse(String((init as RequestInit).body)) : undefined
        }));
}

beforeEach(async () => {
    localStorage.clear();
    setActivePinia(createPinia());
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockResolvedValueOnce(
        jsonResponse(tokenResponse(fakeJwt({ sub: 'u', username: 'ada', scopes: { tracker: true } })))
    );
    await startSession();
    fetchMock.mockImplementation(async (_url: string, init?: RequestInit) =>
        init?.method === 'DELETE'
            ? jsonResponse({})
            : jsonResponse({ checkpoints: [raw('1', 'Home', true), raw('2', 'Work', false)] })
    );
});

afterEach(() => vi.unstubAllGlobals());

describe('checkpoint store', () => {
    it('reads who may change a place', () => {
        const parsed = parseCheckpoints({ checkpoints: [raw('1', 'Home', true), raw('2', 'Work', false)] });
        expect(parsed.map((c) => c.canEdit)).toEqual([true, false]);
    });

    it('updates with a PATCH of the full place and reloads', async () => {
        const store = useCheckpointsStore();
        await store.update('1', { name: 'Home 2', latitude: 45.1, longitude: 9.1, radius: 120 });
        expect(writes()[0]).toEqual({
            path: '/api/v1/checkpoints/1',
            method: 'PATCH',
            body: { name: 'Home 2', latitude: 45.1, longitude: 9.1, radius_m: 120 }
        });
        expect(store.checkpoints).toHaveLength(2);
    });

    it('creates with a POST', async () => {
        await useCheckpointsStore().create({ name: 'Gym', latitude: 1, longitude: 2, radius: 50 });
        expect(writes()[0]).toMatchObject({ path: '/api/v1/checkpoints', method: 'POST' });
    });

    it('drops a deleted place from the list', async () => {
        const store = useCheckpointsStore();
        await store.load();
        await store.remove('1');
        expect(writes()[0]).toMatchObject({ path: '/api/v1/checkpoints/1', method: 'DELETE' });
        expect(store.checkpoints.map((c) => c.id)).toEqual(['2']);
    });

    it('tells a taken name apart from other refusals', async () => {
        fetchMock.mockResolvedValue(jsonResponse({ error: 'x' }, 409));
        const store = useCheckpointsStore();
        const input = { name: 'Home', latitude: 1, longitude: 2, radius: 50 };
        await expect(store.create(input)).rejects.toMatchObject({ nameTaken: true });
        fetchMock.mockResolvedValue(jsonResponse({ error: 'x' }, 403));
        await expect(store.update('1', input)).rejects.toThrow("You can't change this checkpoint.");
        fetchMock.mockResolvedValue(jsonResponse({ error: 'radius_m must be at least 10' }, 400));
        await expect(store.update('1', input)).rejects.toThrow('radius_m must be at least 10');
    });

    it('reports an unreachable server as a checkpoint error', async () => {
        fetchMock.mockRejectedValue(new TypeError('offline'));
        await expect(useCheckpointsStore().remove('1')).rejects.toBeInstanceOf(CheckpointError);
    });
});

describe('places panel', () => {
    async function mountPanel() {
        const wrapper = mount(PlacesPanel, {
            props: { cursor: { latitude: 10, longitude: 20 } },
            attachTo: document.body
        });
        await useCheckpointsStore().load();
        await flushPromises();
        return wrapper;
    }

    it('offers delete only on places the viewer can change', async () => {
        const wrapper = await mountPanel();
        const rows = wrapper.findAll('[data-checkpoint]');
        expect(rows).toHaveLength(2);
        expect(rows[0].find('[data-delete]').exists()).toBe(true);
        expect(rows[1].find('[data-delete]').exists()).toBe(false);
        wrapper.unmount();
    });

    it('edits a place: draws it, saves the new name and radius', async () => {
        const wrapper = await mountPanel();
        await wrapper.findAll('[data-checkpoint] button')[0].trigger('click');
        expect(wrapper.emitted('draft')?.at(-1)).toEqual([{ latitude: 45, longitude: 9, radius: 80 }]);
        expect(wrapper.emitted('goto')?.[0]).toEqual([45, 9]);

        await wrapper.find('input[name="checkpoint-name"]').setValue('  Home   base ');
        await wrapper.find('input[type="range"]').setValue('150');
        expect(wrapper.emitted('draft')?.at(-1)).toEqual([{ latitude: 45, longitude: 9, radius: 150 }]);

        await wrapper.find('[data-save]').trigger('click');
        await flushPromises();
        expect(writes()[0].body).toEqual({ name: 'Home base', latitude: 45, longitude: 9, radius_m: 150 });
        expect(wrapper.find('[data-place-editor]').exists()).toBe(false);
        expect(wrapper.emitted('draft')?.at(-1)).toEqual([null]);
        wrapper.unmount();
    });

    it('follows the crosshair while editing', async () => {
        const wrapper = await mountPanel();
        await wrapper.find('[data-add]').trigger('click');
        await wrapper.setProps({ cursor: { latitude: 11, longitude: 21 } });
        expect(wrapper.emitted('draft')?.at(-1)).toEqual([{ latitude: 11, longitude: 21, radius: 100 }]);
        wrapper.unmount();
    });

    it('shows a taken name on the name field and stays open', async () => {
        const wrapper = await mountPanel();
        await wrapper.findAll('[data-checkpoint] button')[0].trigger('click');
        fetchMock.mockResolvedValue(jsonResponse({ error: 'x' }, 409));
        await wrapper.find('[data-save]').trigger('click');
        await flushPromises();
        expect(wrapper.find('[data-name-error]').text()).toContain('already exists');
        expect(wrapper.find('[data-place-editor]').exists()).toBe(true);
        wrapper.unmount();
    });

    it("opens a place the viewer can't change read-only", async () => {
        const wrapper = await mountPanel();
        await wrapper.findAll('[data-checkpoint] button')[2].trigger('click');
        expect(wrapper.find('[data-save]').exists()).toBe(false);
        expect(wrapper.find('input[name="checkpoint-name"]').attributes('disabled')).toBeDefined();
        await wrapper.setProps({ cursor: { latitude: 50, longitude: 50 } });
        expect(wrapper.emitted('draft')?.at(-1)).toEqual([{ latitude: 45, longitude: 9, radius: 80 }]);
        wrapper.unmount();
    });

    it('deletes after confirmation', async () => {
        const wrapper = await mountPanel();
        await wrapper.find('[data-delete]').trigger('click');
        document.querySelector<HTMLButtonElement>('[data-confirm]')!.click();
        await flushPromises();
        expect(writes()[0]).toMatchObject({ method: 'DELETE', path: '/api/v1/checkpoints/1' });
        expect(wrapper.findAll('[data-checkpoint]')).toHaveLength(1);
        wrapper.unmount();
    });
});

describe('searchPlaces', () => {
    it('returns usable rows only', async () => {
        const fetcher = vi.fn().mockResolvedValue(
            jsonResponse([
                { lat: '45.07', lon: '7.68', display_name: 'Via Roma, Torino' },
                { lat: 'x', lon: '1' }
            ])
        );
        const results = await searchPlaces('via roma', {
            fetch: fetcher as unknown as typeof fetch,
            throttle: { acquire: async () => {} } as never
        });
        expect(results).toEqual([{ label: 'Via Roma, Torino', latitude: 45.07, longitude: 7.68 }]);
    });
});
