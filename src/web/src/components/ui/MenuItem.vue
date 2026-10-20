<script setup lang="ts">
import Icon from './Icon.vue';
import type { IconName } from '../../lib/icons';

defineProps<{ icon: IconName; label: string; checked?: boolean }>();
</script>

<template>
    <button
        role="menuitem"
        class="type-body-lg hover:bg-on-surface/6 flex h-12 w-full items-center gap-3 px-4 text-left"
    >
        <Icon :name="icon" :size="20" class="text-on-surface-variant" />
        <span class="flex-1 whitespace-nowrap">{{ label }}</span>
        <Icon v-if="checked" name="check" :size="18" class="text-primary" />
    </button>
</template>
