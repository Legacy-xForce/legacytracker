import { mount, shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, nextTick } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';
import ScreensaverOverlay from '../components/ui/ScreensaverOverlay.vue';
import { SCREENSAVER_TIMEOUT_MS, useScreensaver } from '../composables/useScreensaver';
import { useCheckpointsStore } from '../stores/checkpoints';
import { useEventsStore } from '../stores/events';
import { usePeersStore } from '../stores/peers';
import { useSharingStore } from '../stores/sharing';
import MapView from '../views/MapView.vue';

const TIMEOUT = 60_000;

function mountTimer(timeoutMs = TIMEOUT) {
    return mount(
        defineComponent({
            setup() {
                const { active, wake } = useScreensaver(timeoutMs);
                return { active, wake };
            },
            template: '<p>{{ active }}</p>'
        })
    );
}

beforeEach(() => vi.useFakeTimers());

afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
});

describe('useScreensaver', () => {
    it('asks whether you are still watching after the timeout', async () => {
        const wrapper = mountTimer();
        expect(wrapper.text()).toBe('false');

        await vi.advanceTimersByTimeAsync(TIMEOUT - 1);
        await nextTick();
        expect(wrapper.text()).toBe('false');

        await vi.advanceTimersByTimeAsync(1);
        await nextTick();
        expect(wrapper.text()).toBe('true');
        wrapper.unmount();
    });

    it('starts counting again when someone types or moves the pointer', async () => {
        const wrapper = mountTimer();
        await vi.advanceTimersByTimeAsync(TIMEOUT - 2_000);

        window.dispatchEvent(new Event('pointermove'));
        await vi.advanceTimersByTimeAsync(TIMEOUT - 1);
        await nextTick();
        expect(wrapper.text()).toBe('false');

        window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }));
        await vi.advanceTimersByTimeAsync(TIMEOUT - 1);
        await nextTick();
        expect(wrapper.text()).toBe('false');

        await vi.advanceTimersByTimeAsync(1);
        await nextTick();
        expect(wrapper.text()).toBe('true');
        wrapper.unmount();
    });

    it('uses the default ten-minute timeout', () => {
        expect(SCREENSAVER_TIMEOUT_MS).toBe(10 * 60_000);
    });

    it('does not wake on a pointer merely passing over the prompt', async () => {
        const wrapper = mountTimer(1_000);
        await vi.advanceTimersByTimeAsync(1_000);
        await nextTick();
        expect(wrapper.text()).toBe('true');

        window.dispatchEvent(new Event('pointermove'));
        window.dispatchEvent(new Event('wheel'));
        await vi.advanceTimersByTimeAsync(TIMEOUT);
        await nextTick();
        expect(wrapper.text()).toBe('true');
        wrapper.unmount();
    });

    it('wakes when asked, then counts down again', async () => {
        const wrapper = mountTimer(TIMEOUT);
        await vi.advanceTimersByTimeAsync(TIMEOUT);
        await nextTick();
        expect(wrapper.text()).toBe('true');

        wrapper.vm.wake();
        await nextTick();
        expect(wrapper.text()).toBe('false');

        await vi.advanceTimersByTimeAsync(TIMEOUT);
        await nextTick();
        expect(wrapper.text()).toBe('true');
        wrapper.unmount();
    });
});

describe('ScreensaverOverlay', () => {
    let app: HTMLElement;

    beforeEach(() => {
        app = document.createElement('div');
        app.id = 'app';
        document.body.appendChild(app);
    });

    afterEach(() => app.remove());

    it('is a modal prompt whose button is the only way back', async () => {
        const wrapper = mount(ScreensaverOverlay, { attachTo: document.body });
        await nextTick();
        await nextTick();

        const panel = document.querySelector('[role="alertdialog"]') as HTMLElement;
        expect(panel.getAttribute('aria-labelledby')).toBe('screensaver-title');
        const button = panel.querySelector('[data-autofocus]') as HTMLButtonElement;
        expect(button.textContent?.trim()).toBe("I'm still here");
        expect(document.activeElement).toBe(button);
        expect(app.hasAttribute('inert')).toBe(true);

        button.click();
        await nextTick();
        expect(wrapper.emitted('wake')).toHaveLength(1);

        wrapper.unmount();
        expect(app.hasAttribute('inert')).toBe(false);
    });
});

describe('MapView', () => {
    it('does not show the screensaver on the first load', async () => {
        setActivePinia(createPinia());
        vi.spyOn(usePeersStore(), 'start').mockImplementation(() => {});
        vi.spyOn(usePeersStore(), 'stop').mockImplementation(() => {});
        vi.spyOn(usePeersStore(), 'setMapActive').mockImplementation(() => {});
        vi.spyOn(useCheckpointsStore(), 'load').mockResolvedValue();
        vi.spyOn(useEventsStore(), 'refresh').mockResolvedValue();
        vi.spyOn(useSharingStore(), 'load').mockResolvedValue();

        const router = createRouter({
            history: createMemoryHistory(),
            routes: [{ path: '/', name: 'map', component: { template: '<div />' } }]
        });
        await router.push('/');

        const wrapper = shallowMount(MapView, { global: { plugins: [router] } });
        // Reading a nested ref through a plain object in a template is always truthy; the prompt
        // must stay absent until the timeout, not just once it is due.
        expect(wrapper.find('screensaver-overlay-stub').exists()).toBe(false);

        await vi.advanceTimersByTimeAsync(SCREENSAVER_TIMEOUT_MS);
        await nextTick();
        expect(wrapper.find('screensaver-overlay-stub').exists()).toBe(true);

        wrapper.unmount();
    });
});
