<script setup lang="ts">
import { dismissToast, toasts } from '../../lib/toast';
</script>

<template>
    <div
        class="pointer-events-none fixed inset-x-0 bottom-6 z-[3000] flex flex-col items-center gap-2 px-4"
        role="status"
        aria-live="polite"
    >
        <button
            v-for="toast in toasts"
            :key="toast.id"
            class="bg-surface-container-highest text-on-surface type-body-md pointer-events-auto max-w-md rounded-lg px-4 py-3 text-left shadow-[0_8px_32px_color-mix(in_srgb,var(--color-shadow)_45%,transparent)]"
            @click="dismissToast(toast.id)"
        >
            {{ toast.message }}
        </button>
    </div>
</template>
