<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { moveFocus } from '../../lib/focus';

const open = defineModel<boolean>({ required: true });
const root = ref<HTMLElement | null>(null);
const triggerBox = ref<HTMLElement | null>(null);
const menu = ref<HTMLElement | null>(null);

const ITEMS = '[role="menuitem"]:not([disabled])';

function trigger(): HTMLElement | null {
    return triggerBox.value?.querySelector<HTMLElement>('button, [tabindex]') ?? null;
}

// The trigger comes from the caller's slot, so the disclosure state is put on it here.
function syncTrigger() {
    const el = trigger();
    el?.setAttribute('aria-haspopup', 'menu');
    el?.setAttribute('aria-expanded', String(open.value));
}

function onPointerDown(event: PointerEvent) {
    if (root.value && !root.value.contains(event.target as Node)) open.value = false;
}

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') {
        open.value = false;
        trigger()?.focus();
    } else if (event.key === 'Tab') {
        open.value = false;
    }
}

function onMenuKey(event: KeyboardEvent) {
    moveFocus(event, ITEMS, { next: 'ArrowDown', previous: 'ArrowUp' });
}

// ArrowDown on the closed trigger opens the menu, like a native one.
function onTriggerKey(event: KeyboardEvent) {
    if (event.key === 'ArrowDown' && !open.value) {
        event.preventDefault();
        open.value = true;
    }
}

watch(open, async (isOpen) => {
    syncTrigger();
    if (isOpen) {
        document.addEventListener('pointerdown', onPointerDown, true);
        document.addEventListener('keydown', onKey);
        // Focus moves into the menu when it opens from its trigger.
        await nextTick();
        if (document.activeElement === trigger()) menu.value?.querySelector<HTMLElement>(ITEMS)?.focus();
    } else {
        document.removeEventListener('pointerdown', onPointerDown, true);
        document.removeEventListener('keydown', onKey);
        // Picking an item removes it from the page; hand focus back so it isn't dropped on <body>
        // (and so a dialog the item opens returns here when it closes).
        if (menu.value?.contains(document.activeElement)) trigger()?.focus();
    }
});

onMounted(syncTrigger);
onBeforeUnmount(() => {
    document.removeEventListener('pointerdown', onPointerDown, true);
    document.removeEventListener('keydown', onKey);
});
</script>

<template>
    <div ref="root" class="relative">
        <div ref="triggerBox" class="contents" @keydown="onTriggerKey">
            <slot name="trigger" />
        </div>
        <Transition
            enter-from-class="opacity-0 scale-95"
            leave-to-class="opacity-0 scale-95"
            enter-active-class="transition duration-150 ease-out"
            leave-active-class="transition duration-100 ease-in"
        >
            <div
                v-if="open"
                ref="menu"
                role="menu"
                @keydown="onMenuKey"
                class="bg-surface-container-high absolute top-0 right-full z-10 mr-2 min-w-[200px] origin-top-right rounded-2xl py-2 shadow-[0_8px_24px_color-mix(in_srgb,var(--color-shadow)_50%,transparent)]"
            >
                <slot />
            </div>
        </Transition>
    </div>
</template>
