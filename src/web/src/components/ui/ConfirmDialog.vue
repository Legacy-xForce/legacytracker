<script setup lang="ts">
import { onBeforeUnmount, onMounted } from 'vue';
import Spinner from './Spinner.vue';

const props = defineProps<{ title: string; message: string; confirmLabel: string; busy?: boolean }>();
const emit = defineEmits<{ confirm: []; cancel: [] }>();

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape' && !props.busy) emit('cancel');
}

onMounted(() => document.addEventListener('keydown', onKey));
onBeforeUnmount(() => document.removeEventListener('keydown', onKey));
</script>

<template>
    <!-- Teleported out of the sheet, whose transforms would otherwise pin "fixed" to the sheet. -->
    <Teleport to="body">
        <div
            class="bg-scrim/32 fixed inset-0 z-[2000] flex items-center justify-center p-6"
            @click.self="!busy && emit('cancel')"
        >
            <div
                role="alertdialog"
                aria-modal="true"
                aria-labelledby="confirm-title"
                aria-describedby="confirm-message"
                class="bg-surface-container-high w-full max-w-sm rounded-[28px] p-6 shadow-[0_8px_24px_color-mix(in_srgb,var(--color-shadow)_50%,transparent)]"
            >
                <h2 id="confirm-title" class="type-title-lg font-bold">{{ title }}</h2>
                <p id="confirm-message" class="type-body-md text-on-surface-variant mt-3">{{ message }}</p>
                <div class="mt-6 flex justify-end gap-2">
                    <button
                        class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-4 py-2.5 disabled:opacity-50"
                        :disabled="busy"
                        @click="emit('cancel')"
                    >
                        Cancel
                    </button>
                    <button
                        class="bg-error-container text-on-error-container type-label-lg flex min-w-[88px] items-center justify-center rounded-full px-4 py-2.5 hover:brightness-110 disabled:opacity-70"
                        :disabled="busy"
                        data-confirm
                        @click="emit('confirm')"
                    >
                        <Spinner v-if="busy" :size="18" />
                        <template v-else>{{ confirmLabel }}</template>
                    </button>
                </div>
            </div>
        </div>
    </Teleport>
</template>
