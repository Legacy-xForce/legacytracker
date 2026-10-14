<script setup lang="ts">
import Icon from './ui/Icon.vue';
import { userColor } from '../lib/avatars';

// The app's mark: a location badge at the centre of faint radar rings, with a few people (in the
// avatar palette) out on the rings. Same geometry as the phone's painter.
const RADII = [62, 98, 138, 180];
const PEOPLE: [ring: number, degrees: number, userId: string][] = [
    [1, -38, 'a'],
    [2, 202, 'e'],
    [0, 160, 'c'],
    [3, -8, 'f'],
    [2, 300, 'b']
];

const dots = PEOPLE.map(([ring, degrees, userId]) => {
    const angle = (degrees * Math.PI) / 180;
    return {
        x: Math.cos(angle) * RADII[ring],
        y: Math.sin(angle) * RADII[ring],
        color: userColor(userId),
        // Outer rings fade, like the circles they sit on.
        opacity: 1 - ring * 0.2
    };
});
</script>

<template>
    <div class="relative h-28">
        <svg
            class="pointer-events-none absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 overflow-visible"
            width="360"
            height="360"
            viewBox="-180 -180 360 360"
            aria-hidden="true"
        >
            <defs>
                <radialGradient id="brand-glow" r="0.5">
                    <stop offset="0" stop-color="var(--color-primary)" stop-opacity="0.16" />
                    <stop offset="1" stop-color="var(--color-primary)" stop-opacity="0" />
                </radialGradient>
                <!-- Rings fade out below the badge so the title sits on a clean background. -->
                <linearGradient
                    v-for="(r, i) in RADII"
                    :id="`brand-ring-${i}`"
                    :key="r"
                    gradientUnits="userSpaceOnUse"
                    x1="0"
                    :y1="-r"
                    x2="0"
                    :y2="r"
                >
                    <stop offset="0.5" stop-color="var(--color-primary)" :stop-opacity="0.3 - i * 0.07" />
                    <stop offset="0.78" stop-color="var(--color-primary)" stop-opacity="0" />
                </linearGradient>
            </defs>
            <circle r="180" fill="url(#brand-glow)" />
            <circle v-for="(r, i) in RADII" :key="r" :r="r" fill="none" :stroke="`url(#brand-ring-${i})`" />
            <g v-for="(dot, i) in dots" :key="i">
                <circle :cx="dot.x" :cy="dot.y" r="6.5" fill="var(--color-surface)" />
                <circle :cx="dot.x" :cy="dot.y" r="4.5" :fill="dot.color" :fill-opacity="dot.opacity" />
            </g>
        </svg>
        <div
            class="text-on-primary-container absolute top-1/2 left-1/2 flex size-[84px] -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full"
            style="
                background: linear-gradient(135deg, var(--color-primary-container), var(--color-secondary-container));
                border: 1.5px solid rgb(130 213 200 / 0.45);
                box-shadow: 0 0 28px rgb(130 213 200 / 0.25);
            "
        >
            <Icon name="shareLocation" :size="40" />
        </div>
    </div>
</template>
