import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import TextField from '../components/ui/TextField.vue';

describe('TextField', () => {
    it('puts spacing on the field and input attributes on the input', async () => {
        const field = mount(TextField, {
            props: { label: 'Password', icon: 'lock', modelValue: '' },
            attrs: { class: 'mt-3', type: 'password', autocomplete: 'current-password' }
        });
        const input = field.get('input');
        // A margin on the input would sit inside the field and leave the fields touching.
        expect(field.get('div').classes()).toContain('mt-3');
        expect(input.classes()).not.toContain('mt-3');
        expect(input.attributes('type')).toBe('password');
        expect(input.attributes('autocomplete')).toBe('current-password');

        // Show/hide password swaps the type after mount.
        await field.setProps({ type: 'text' } as never);
        expect(field.get('input').attributes('type')).toBe('text');
    });
});
