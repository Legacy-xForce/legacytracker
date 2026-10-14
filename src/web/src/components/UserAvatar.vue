<script setup lang="ts">
import { computed } from 'vue';
import { DIMMED_COLOR, loadedPicture, profilePicture, userColor, userInitial } from '../lib/avatars';

const {
    userId,
    name,
    size = 44,
    ringColor,
    ringWidth = 0,
    dimmed = false,
    pictureUrl = null
} = defineProps<{
    userId: string;
    name: string;
    /** Where the picture is when the caller knows (calendar attendees); else Legacy Auth by id. */
    pictureUrl?: string | null;
    size?: number;
    ringColor?: string;
    ringWidth?: number;
    /** Greyed out for people we haven't heard from in a while. */
    dimmed?: boolean;
}>();

const picture = computed(() => (pictureUrl ? loadedPicture(pictureUrl) : profilePicture(userId)));
</script>

<template>
    <span
        class="relative flex shrink-0 items-center justify-center overflow-hidden rounded-full font-bold text-white select-none"
        :style="{
            width: `${size}px`,
            height: `${size}px`,
            background: dimmed ? DIMMED_COLOR : userColor(userId),
            fontSize: `${size * 0.42}px`,
            lineHeight: 1
        }"
    >
        <img
            v-if="picture"
            :src="picture"
            alt=""
            draggable="false"
            class="absolute inset-0 size-full object-cover"
            :class="{ grayscale: dimmed }"
        />
        <template v-else>{{ userInitial(name) }}</template>
        <!-- Like Flutter's border: drawn inside the circle, over the photo. -->
        <span
            v-if="ringWidth > 0 && ringColor"
            class="absolute inset-0 rounded-full"
            :style="{ boxShadow: `inset 0 0 0 ${ringWidth}px ${ringColor}` }"
        />
    </span>
</template>
