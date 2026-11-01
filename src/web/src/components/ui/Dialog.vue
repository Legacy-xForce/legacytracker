<script setup lang="ts">
import { ref } from 'vue';
import { useModal } from '../../lib/focus';

/** A full-screen sheet on phones, a centred panel from `sm` up: scrim, focus trap and Escape. */
defineProps<{ labelledby: string; z?: number }>();
const emit = defineEmits<{ close: [] }>();

const panel = ref<HTMLElement | null>(null);
useModal(panel);
</script>

<template>
    <Teleport to="body">
        <div
            class="bg-scrim/32 fixed inset-0 flex items-stretch justify-center sm:items-center sm:p-6"
            :style="{ zIndex: z ?? 1900 }"
            @click.self="emit('close')"
        >
            <section
                ref="panel"
                tabindex="-1"
                role="dialog"
                aria-modal="true"
                :aria-labelledby="labelledby"
                class="bg-surface-container scroll-panel shadow-level-3 flex w-full flex-col overflow-y-auto outline-none sm:max-h-[90vh] sm:max-w-lg sm:rounded-xl"
            >
                <slot />
            </section>
        </div>
    </Teleport>
</template>
