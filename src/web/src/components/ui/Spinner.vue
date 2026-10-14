<script setup lang="ts">
const { size = 20 } = defineProps<{ size?: number }>();
</script>

<template>
    <!-- Material's circular progress indicator: a thin arc, spinning. -->
    <svg :width="size" :height="size" viewBox="0 0 24 24" class="animate-spin" role="progressbar">
        <circle
            cx="12"
            cy="12"
            r="9.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-dasharray="44 60"
        />
    </svg>
</template>
