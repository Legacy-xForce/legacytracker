<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { useModal } from '../../lib/focus';
import Spinner from './Spinner.vue';

const props = defineProps<{ title: string; message: string; confirmLabel: string; busy?: boolean }>();
const emit = defineEmits<{ confirm: []; cancel: [] }>();

const panel = ref<HTMLElement | null>(null);
useModal(panel);

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
                ref="panel"
                tabindex="-1"
                role="alertdialog"
                aria-modal="true"
                aria-labelledby="confirm-title"
                aria-describedby="confirm-message"
                class="bg-surface-container-high shadow-level-3 w-full max-w-sm rounded-xl p-6 outline-none"
            >
                <h2 id="confirm-title" class="type-title-lg font-bold">{{ title }}</h2>
                <p id="confirm-message" class="type-body-md text-on-surface-variant mt-3">{{ message }}</p>
                <div class="mt-6 flex justify-end gap-2">
                    <button
                        class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-4 py-2.5 disabled:opacity-50"
                        :disabled="busy"
                        data-autofocus
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
