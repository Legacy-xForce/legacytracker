<script setup lang="ts">
import Icon from './Icon.vue';
import type { IconName } from '../../lib/icons';

defineProps<{ icon: IconName; label: string; value: string }>();
</script>

<template>
    <div class="bg-surface-container-high min-w-0 rounded-lg py-3 pr-2 pl-3">
        <Icon :name="icon" :size="18" class="text-primary" />
        <p class="type-title-md mt-2.5 truncate font-bold">{{ value }}</p>
        <p class="type-label-sm text-on-surface-variant mt-0.5 truncate">{{ label }}</p>
    </div>
</template>
