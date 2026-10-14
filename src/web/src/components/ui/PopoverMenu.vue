<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';

const open = defineModel<boolean>({ required: true });
const root = ref<HTMLElement | null>(null);

function onPointerDown(event: PointerEvent) {
    if (root.value && !root.value.contains(event.target as Node)) open.value = false;
}

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') open.value = false;
}

watch(open, (isOpen) => {
    if (isOpen) {
        document.addEventListener('pointerdown', onPointerDown, true);
        document.addEventListener('keydown', onKey);
    } else {
        document.removeEventListener('pointerdown', onPointerDown, true);
        document.removeEventListener('keydown', onKey);
    }
});

onBeforeUnmount(() => {
    document.removeEventListener('pointerdown', onPointerDown, true);
    document.removeEventListener('keydown', onKey);
});
</script>

<template>
    <div ref="root" class="relative">
        <slot name="trigger" />
        <Transition
            enter-from-class="opacity-0 scale-95"
            leave-to-class="opacity-0 scale-95"
            enter-active-class="transition duration-150 ease-out"
            leave-active-class="transition duration-100 ease-in"
        >
            <div
                v-if="open"
                role="menu"
                class="bg-surface-container-high absolute top-0 right-full z-10 mr-2 min-w-[200px] origin-top-right rounded-2xl py-2 shadow-[0_8px_24px_rgb(0_0_0/0.5)]"
            >
                <slot />
            </div>
        </Transition>
    </div>
</template>
