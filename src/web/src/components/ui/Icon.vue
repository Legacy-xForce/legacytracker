<script setup lang="ts">
import { icons, type IconName } from '../../lib/icons';

const { size = 24 } = defineProps<{ name: IconName; size?: number }>();
</script>

<template>
    <!-- The markup comes from the bundled icon set, never from users. -->
    <span class="inline-flex shrink-0" :style="{ fontSize: `${size}px` }" aria-hidden="true" v-html="icons[name]" />
</template>
