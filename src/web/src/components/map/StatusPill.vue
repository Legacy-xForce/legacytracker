<script setup lang="ts">
import { computed } from 'vue';
import type { StreamStatus } from '../../api/stream';

const props = defineProps<{ status: StreamStatus }>();

const look = computed(() => {
    if (props.status === 'open') return { color: 'var(--color-online)', label: 'Live' };
    if (props.status === 'connecting') return { color: 'var(--color-paused)', label: 'Connecting…' };
    return { color: 'var(--color-error)', label: 'Offline' };
});
</script>

<template>
    <!-- Whether the map is live, at a glance, like the app's sharing pill. -->
    <div
        class="bg-surface-container-high type-label-lg flex items-center gap-2 rounded-full py-[9px] pr-3.5 pl-3 font-semibold shadow-[0_4px_12px_color-mix(in_srgb,var(--color-shadow)_40%,transparent)]"
        role="status"
    >
        <span
            class="size-[9px] rounded-full"
            :style="{ background: look.color, boxShadow: `0 0 6px color-mix(in srgb, ${look.color} 60%, transparent)` }"
        />
        {{ look.label }}
    </div>
</template>
