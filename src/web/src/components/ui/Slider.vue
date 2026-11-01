<script setup lang="ts">
import { computed } from 'vue';

// The Material 3 slider (expressive): a thick track split around a vertical handle bar, a stop dot at the end of
// the track, and a value label above the handle while it is dragged or focused. It is a native range input, so
// keys, touch and screen readers work as they do everywhere; the track is drawn by the spans around it.
const model = defineModel<number>({ required: true });
const props = withDefaults(
    defineProps<{
        min: number;
        max: number;
        step?: number;
        disabled?: boolean;
        /** The accessible name. */
        label: string;
        /** Shown in the bubble above the handle; without it there is no bubble. */
        valueLabel?: string;
    }>(),
    { step: 1 }
);

const fill = computed(() => {
    const span = props.max - props.min;
    return span > 0 ? Math.min(1, Math.max(0, (model.value - props.min) / span)) : 0;
});
</script>

<template>
    <div class="m3-slider" :class="{ 'm3-slider-disabled': disabled }" :style="{ '--fill': fill }">
        <span class="m3-slider-active" aria-hidden="true" />
        <span class="m3-slider-inactive" aria-hidden="true" />
        <span v-if="valueLabel" class="m3-slider-bubble type-label-lg" aria-hidden="true">{{ valueLabel }}</span>
        <input
            type="range"
            class="m3-slider-input"
            :min="min"
            :max="max"
            :step="step"
            :value="model"
            :disabled="disabled"
            :aria-label="label"
            :aria-valuetext="valueLabel"
            @input="model = Number(($event.target as HTMLInputElement).value)"
        />
    </div>
</template>

<style>
/*
 * Sizes are the spec's: a 16 px track, a 4 x 44 px handle (2 px wide while pressed), a 6 px gap on each side of it,
 * small corners where the track meets the gap and a 4 px stop dot. --pos is the middle of the handle, which the
 * browser keeps half a handle away from either end.
 */
.m3-slider {
    --handle-width: 4px;
    --gap: 6px;
    --bubble-half: 28px;
    --pos: calc(var(--handle-width) / 2 + (100% - var(--handle-width)) * var(--fill));
    position: relative;
    display: block;
    width: 100%;
    height: 44px;
}

.m3-slider-disabled {
    opacity: 0.38;
}

.m3-slider-active,
.m3-slider-inactive {
    position: absolute;
    top: 14px;
    height: 16px;
    pointer-events: none;
}

.m3-slider-active {
    left: 0;
    width: max(0px, calc(var(--pos) - var(--handle-width) / 2 - var(--gap)));
    border-radius: var(--radius-sm) var(--radius-xs) var(--radius-xs) var(--radius-sm);
    background: var(--color-primary);
}

.m3-slider-inactive {
    right: 0;
    width: max(0px, calc(100% - var(--pos) - var(--handle-width) / 2 - var(--gap)));
    overflow: hidden;
    border-radius: var(--radius-xs) var(--radius-sm) var(--radius-sm) var(--radius-xs);
    background: var(--color-secondary-container);
}

.m3-slider-inactive::after {
    content: '';
    position: absolute;
    top: 6px;
    right: 6px;
    width: 4px;
    height: 4px;
    border-radius: var(--radius-full);
    background: var(--color-primary);
}

.m3-slider-bubble {
    position: absolute;
    bottom: 100%;
    /* Kept at least half its own width from either end, so it never leaves the track's box. */
    left: clamp(var(--bubble-half), var(--pos), calc(100% - var(--bubble-half)));
    padding: 0 8px;
    min-width: calc(var(--bubble-half) * 2);
    height: 44px;
    line-height: 44px;
    text-align: center;
    white-space: nowrap;
    border-radius: var(--radius-full);
    background: var(--color-on-surface);
    color: var(--color-surface);
    pointer-events: none;
    opacity: 0;
    transform: translateX(-50%) translateY(4px) scale(0.8);
    transition:
        opacity var(--duration-short),
        transform var(--duration-short);
}

.m3-slider:has(.m3-slider-input:active) .m3-slider-bubble,
.m3-slider:has(.m3-slider-input:focus-visible) .m3-slider-bubble {
    opacity: 1;
    transform: translateX(-50%) scale(1);
}

.m3-slider-input {
    appearance: none;
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    margin: 0;
    background: transparent;
    cursor: pointer;
}

.m3-slider-input:disabled {
    cursor: default;
}

.m3-slider-input:focus {
    outline: none;
}

.m3-slider-input::-webkit-slider-runnable-track {
    height: 44px;
    background: transparent;
}

.m3-slider-input::-moz-range-track {
    height: 44px;
    background: transparent;
}

.m3-slider-input::-webkit-slider-thumb {
    appearance: none;
    width: var(--handle-width, 4px);
    height: 44px;
    border: none;
    border-radius: var(--radius-xs);
    background: var(--color-primary);
    transition: width var(--duration-short);
}

.m3-slider-input::-moz-range-thumb {
    width: 4px;
    height: 44px;
    border: none;
    border-radius: var(--radius-xs);
    background: var(--color-primary);
}

.m3-slider-input:active::-webkit-slider-thumb {
    width: 2px;
}

.m3-slider-input:focus-visible::-webkit-slider-thumb {
    outline: 2px solid var(--color-primary);
    outline-offset: 3px;
}

.m3-slider-input:focus-visible::-moz-range-thumb {
    outline: 2px solid var(--color-primary);
    outline-offset: 3px;
}
</style>
