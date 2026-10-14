<script setup lang="ts">
import Icon from '../ui/Icon.vue';
import type { IconName } from '../../lib/icons';

defineProps<{ icon: IconName; label: string; active?: boolean }>();
</script>

<template>
    <button
        class="relative flex size-12 items-center justify-center first:rounded-t-2xl last:rounded-b-2xl hover:bg-white/6"
        :class="active ? 'text-primary' : 'text-on-surface'"
        :aria-label="label"
        :title="label"
    >
        <Icon :name="icon" />
    </button>
</template>
