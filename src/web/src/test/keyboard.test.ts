import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';
import { defineComponent, h, nextTick, ref } from 'vue';
import ConfirmDialog from '../components/ui/ConfirmDialog.vue';
import MenuItem from '../components/ui/MenuItem.vue';
import PopoverMenu from '../components/ui/PopoverMenu.vue';
import { moveFocus } from '../lib/focus';
import { VueMarker } from '../lib/vueMarker';

const mounted: { unmount(): void }[] = [];
afterEach(() => {
    while (mounted.length) mounted.pop()!.unmount();
    document.body.innerHTML = '';
});

function press(el: Element | Document, key: string, init: KeyboardEventInit = {}) {
    el.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }));
}

describe('moveFocus', () => {
    it('moves between tabs with the arrow keys, wrapping, and jumps with Home/End', () => {
        const tabs = mount(
            defineComponent({
                render: () =>
                    h(
                        'div',
                        { role: 'tablist', onKeydown: (e: KeyboardEvent) => moveFocus(e, '[role="tab"]') },
                        ['a', 'b', 'c'].map((id) => h('button', { role: 'tab', id }))
                    )
            }),
            { attachTo: document.body }
        );
        mounted.push(tabs);
        const list = tabs.get('[role="tablist"]').element;
        (list.querySelector('#a') as HTMLElement).focus();

        press(document.activeElement!, 'ArrowRight');
        expect(document.activeElement?.id).toBe('b');
        press(document.activeElement!, 'End');
        expect(document.activeElement?.id).toBe('c');
        press(document.activeElement!, 'ArrowRight');
        expect(document.activeElement?.id).toBe('a');
        press(document.activeElement!, 'ArrowLeft');
        expect(document.activeElement?.id).toBe('c');
        press(document.activeElement!, 'Home');
        expect(document.activeElement?.id).toBe('a');
    });
});

describe('PopoverMenu', () => {
    function mountMenu() {
        const wrapper = mount(
            defineComponent({
                components: { PopoverMenu, MenuItem },
                setup: () => ({ open: ref(false) }),
                template: `<PopoverMenu v-model="open">
                    <template #trigger><button id="trigger" @click="open = !open">Menu</button></template>
                    <MenuItem icon="map" label="One" /><MenuItem icon="map" label="Two" />
                </PopoverMenu>`
            }),
            { attachTo: document.body }
        );
        mounted.push(wrapper);
        return wrapper;
    }

    it('announces itself on the trigger and tracks open state', async () => {
        const wrapper = mountMenu();
        const trigger = wrapper.get('#trigger');
        expect(trigger.attributes('aria-haspopup')).toBe('menu');
        expect(trigger.attributes('aria-expanded')).toBe('false');
        await trigger.trigger('click');
        await nextTick();
        expect(trigger.attributes('aria-expanded')).toBe('true');
    });

    it('opens with ArrowDown, walks the items, and Escape returns focus to the trigger', async () => {
        const wrapper = mountMenu();
        const trigger = wrapper.get('#trigger').element as HTMLElement;
        trigger.focus();
        press(trigger, 'ArrowDown');
        await nextTick();
        await nextTick();
        const items = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
        expect(items).toHaveLength(2);
        expect(document.activeElement).toBe(items[0]);

        press(items[0], 'ArrowDown');
        expect(document.activeElement).toBe(items[1]);
        press(items[1], 'ArrowDown');
        expect(document.activeElement).toBe(items[0]);

        press(items[0], 'Escape');
        await nextTick();
        expect(document.querySelector('[role="menu"]')).toBeNull();
        expect(document.activeElement).toBe(trigger);
        expect(trigger.getAttribute('aria-expanded')).toBe('false');
    });
});

describe('ConfirmDialog', () => {
    it('takes focus, traps Tab, makes the app inert and gives focus back', async () => {
        const app = document.createElement('div');
        app.id = 'app';
        document.body.appendChild(app);
        const opener = document.createElement('button');
        app.appendChild(opener);
        opener.focus();

        const dialog = mount(ConfirmDialog, {
            props: { title: 'Delete?', message: 'Gone for good.', confirmLabel: 'Delete' },
            attachTo: document.body
        });
        await nextTick();
        await nextTick();

        const panel = document.querySelector('[role="alertdialog"]') as HTMLElement;
        const [cancel, confirm] = [...panel.querySelectorAll('button')];
        expect(app.hasAttribute('inert')).toBe(true);
        expect(document.activeElement).toBe(cancel);

        confirm.focus();
        press(confirm, 'Tab');
        expect(document.activeElement).toBe(cancel);
        press(cancel, 'Tab', { shiftKey: true });
        expect(document.activeElement).toBe(confirm);

        dialog.unmount();
        expect(app.hasAttribute('inert')).toBe(false);
        expect(document.activeElement).toBe(opener);
    });
});

describe('VueMarker', () => {
    it('is a labelled button that Enter and Space click', () => {
        const marker = new VueMarker(
            { lat: 0, lng: 0 },
            defineComponent({ render: () => h('span') }),
            {},
            [10, 10],
            [5, 5]
        );
        let clicks = 0;
        marker.onClick(() => clicks++);
        marker.setLabel('Ada');
        marker.setLabel('Ada, not heard from in a while');

        const el = marker.element;
        expect(el.getAttribute('role')).toBe('button');
        expect(el.getAttribute('aria-label')).toBe('Ada, not heard from in a while');
        expect(el.tabIndex).toBe(0);
        press(el, 'Enter');
        press(el, ' ');
        press(el, 'a');
        // Renaming must not stack a second key handler.
        expect(clicks).toBe(2);
    });
});

describe('PopoverMenu focus', () => {
    it('hands focus back to the trigger when an item is chosen', async () => {
        const wrapper = mount(
            defineComponent({
                components: { PopoverMenu, MenuItem },
                setup: () => ({ open: ref(true) }),
                template: `<PopoverMenu v-model="open">
                    <template #trigger><button id="trigger">Menu</button></template>
                    <MenuItem id="item" icon="map" label="One" @click="open = false" />
                </PopoverMenu>`
            }),
            { attachTo: document.body }
        );
        mounted.push(wrapper);
        await nextTick();
        await nextTick();
        const item = document.getElementById('item') as HTMLElement;
        item.focus();
        item.click();
        await nextTick();
        expect(document.activeElement).toBe(document.getElementById('trigger'));
    });
});
