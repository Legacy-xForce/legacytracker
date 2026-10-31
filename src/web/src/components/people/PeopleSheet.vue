<script setup lang="ts">
import { computed, ref } from 'vue';

const props = defineProps<{
    /** Wide screens get a floating side panel; narrow ones the app's bottom sheet. */
    wide: boolean;
    /** Collapsed, the sheet still shows its header, so it is obvious there's something to pull up. */
    collapsedHeight: number;
    expandedHeight: number;
}>();
const expanded = defineModel<boolean>('expanded', { required: true });

const dragHeight = ref<number | null>(null);
let start: { y: number; height: number } | null = null;
let last = { y: 0, time: 0, velocity: 0 };

const height = computed(() => dragHeight.value ?? (expanded.value ? props.expandedHeight : props.collapsedHeight));

function onPointerDown(event: PointerEvent) {
    // Buttons in the header (back) keep their own meaning.
    if (props.wide || (event.target as Element).closest('button')) return;
    start = { y: event.clientY, height: height.value };
    last = { y: event.clientY, time: event.timeStamp, velocity: 0 };
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
}

function onPointerMove(event: PointerEvent) {
    if (!start) return;
    const dy = event.clientY - start.y;
    if (dragHeight.value === null && Math.abs(dy) < 6) return;
    dragHeight.value = Math.min(props.expandedHeight, Math.max(props.collapsedHeight, start.height - dy));
    const elapsed = event.timeStamp - last.time;
    if (elapsed > 0) last = { y: event.clientY, time: event.timeStamp, velocity: (event.clientY - last.y) / elapsed };
}

function onPointerUp() {
    if (!start) return;
    start = null;
    if (dragHeight.value === null) {
        expanded.value = !expanded.value;
        return;
    }
    // A flick decides; otherwise the nearer end.
    if (Math.abs(last.velocity) > 0.5) expanded.value = last.velocity < 0;
    else expanded.value = dragHeight.value > (props.collapsedHeight + props.expandedHeight) / 2;
    dragHeight.value = null;
}
</script>

<template>
    <section
        v-if="wide"
        class="bg-surface-container-low shadow-level-3 absolute top-3 bottom-3 left-3 z-[1000] flex w-[380px] flex-col overflow-hidden rounded-xl"
    >
        <header class="flex h-[68px] shrink-0 items-center px-5">
            <slot name="header" />
        </header>
        <div class="scroll-panel min-h-0 flex-1 overflow-y-auto">
            <slot />
        </div>
    </section>
    <section
        v-else
        class="bg-surface-container-low shadow-level-3 absolute inset-x-0 bottom-0 z-[1000] flex flex-col overflow-hidden rounded-t-xl"
        :class="{ 'transition-[height] duration-[240ms] ease-out': dragHeight === null }"
        :style="{ height: `${height}px` }"
    >
        <header
            class="flex h-[68px] shrink-0 cursor-grab touch-none flex-col items-center select-none"
            @pointerdown="onPointerDown"
            @pointermove="onPointerMove"
            @pointerup="onPointerUp"
            @pointercancel="onPointerUp"
        >
            <span class="bg-on-surface-variant/40 mt-2.5 h-1 w-9 rounded-full" />
            <div class="flex w-full flex-1 items-center px-5">
                <slot name="header" />
            </div>
        </header>
        <div class="scroll-panel min-h-0 flex-1 overflow-y-auto pb-[env(safe-area-inset-bottom)]">
            <slot />
        </div>
    </section>
</template>
