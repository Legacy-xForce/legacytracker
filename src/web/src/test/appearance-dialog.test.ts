import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it } from 'vitest';
import AppearanceDialog from '../components/ui/AppearanceDialog.vue';
import { MAP_VARIANT_STORAGE_KEY } from '../lib/styles';
import { useAppearanceStore } from '../stores/appearance';

function mapRadios(): HTMLElement[] {
    const group = document.querySelector<HTMLElement>('[role="radiogroup"][aria-label="Map lighting"]');
    return group ? [...group.querySelectorAll<HTMLElement>('[role="radio"]')] : [];
}

function radio(label: string): HTMLElement {
    const found = mapRadios().find((option) => option.getAttribute('aria-label') === label);
    if (!found) throw new Error(`No map option labelled "${label}"`);
    return found;
}

describe('AppearanceDialog', () => {
    beforeEach(() => {
        localStorage.clear();
        document.body.replaceChildren();
        setActivePinia(createPinia());
    });

    function mountDialog() {
        return mount(AppearanceDialog, {
            attachTo: document.body,
            props: { modelValue: true, 'onUpdate:modelValue': () => {} }
        });
    }

    it('offers Auto plus the four map variants, selecting Auto by default', () => {
        const wrapper = mountDialog();

        expect(mapRadios().map((option) => option.getAttribute('aria-label'))).toEqual([
            'Auto, follows the time of day',
            'Dawn',
            'Day',
            'Dusk',
            'Night'
        ]);
        expect(radio('Auto, follows the time of day').getAttribute('aria-checked')).toBe('true');
        wrapper.unmount();
    });

    it('persists the chosen variant for this device', async () => {
        const wrapper = mountDialog();

        radio('Night').click();
        await wrapper.vm.$nextTick();

        expect(useAppearanceStore().mapVariant).toBe('night');
        expect(localStorage.getItem(MAP_VARIANT_STORAGE_KEY)).toBe('night');
        expect(radio('Night').getAttribute('aria-checked')).toBe('true');
        expect(radio('Auto, follows the time of day').getAttribute('aria-checked')).toBe('false');
        wrapper.unmount();
    });
});
