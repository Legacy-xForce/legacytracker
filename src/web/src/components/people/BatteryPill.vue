<script setup lang="ts">
import { computed } from 'vue';
import Icon from '../ui/Icon.vue';
import { batteryIcon } from '../../lib/icons';

const props = defineProps<{ level: number; charging: boolean }>();
const tone = computed(() => {
    if (props.charging) return 'text-online';
    return props.level <= 20 ? 'text-error' : 'text-on-surface-variant';
});
</script>

<template>
    <span class="type-label-md flex shrink-0 items-center gap-0.5 font-semibold" :class="tone">
        <Icon :name="charging ? 'bolt' : batteryIcon(level, false)" :size="16" />{{ level }}%
    </span>
</template>
