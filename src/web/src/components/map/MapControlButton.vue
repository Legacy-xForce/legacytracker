<script setup lang="ts">
import Icon from '../ui/Icon.vue';
import type { IconName } from '../../lib/icons';

defineProps<{ icon: IconName; label: string }>();
</script>

<template>
    <button
        class="text-on-surface hover:bg-on-surface/6 relative flex size-12 items-center justify-center first:rounded-t-lg last:rounded-b-lg"
        :aria-label="label"
        :title="label"
    >
        <Icon :name="icon" />
    </button>
</template>
