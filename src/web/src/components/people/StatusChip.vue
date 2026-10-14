<script setup lang="ts">
import Icon from '../ui/Icon.vue';
import type { IconName } from '../../lib/icons';

defineProps<{ icon: IconName; label: string; color: string }>();
</script>

<template>
    <span
        class="type-label-sm inline-flex items-center gap-1 rounded-full px-2 py-1 font-semibold"
        :style="{ color, background: `color-mix(in srgb, ${color} 14%, transparent)` }"
    >
        <Icon :name="icon" :size="13" />{{ label }}
    </span>
</template>
