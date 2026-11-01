import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import Slider from '../components/ui/Slider.vue';

function mountSlider(props: Record<string, unknown> = {}) {
    return mount(Slider, { props: { modelValue: 50, min: 0, max: 200, label: 'Radius', ...props } });
}

describe('slider', () => {
    it('is a native range input with an accessible name', () => {
        const input = mountSlider().get('input');
        expect(input.attributes('type')).toBe('range');
        expect(input.attributes('aria-label')).toBe('Radius');
        expect(input.attributes('max')).toBe('200');
    });

    it('fills the track to the value, as a fraction of the range', async () => {
        const wrapper = mountSlider();
        const fill = () => (wrapper.get('.m3-slider').element as HTMLElement).style.getPropertyValue('--fill');
        expect(fill()).toBe('0.25');
        await wrapper.setProps({ modelValue: 200 });
        expect(fill()).toBe('1');
        await wrapper.setProps({ modelValue: 900 });
        expect(fill()).toBe('1');
    });

    it('reports a dragged or keyed value as a number', async () => {
        const wrapper = mountSlider();
        await wrapper.get('input').setValue('120');
        expect(wrapper.emitted('update:modelValue')).toEqual([[120]]);
    });

    it('shows the value bubble only when it has a label, and names it for screen readers', () => {
        expect(mountSlider().find('.m3-slider-bubble').exists()).toBe(false);
        const labelled = mountSlider({ valueLabel: '50 m' });
        expect(labelled.get('.m3-slider-bubble').text()).toBe('50 m');
        expect(labelled.get('input').attributes('aria-valuetext')).toBe('50 m');
    });

    it('can be disabled', () => {
        const wrapper = mountSlider({ disabled: true });
        expect(wrapper.get('input').attributes('disabled')).toBeDefined();
        expect(wrapper.classes()).toContain('m3-slider-disabled');
    });
});
