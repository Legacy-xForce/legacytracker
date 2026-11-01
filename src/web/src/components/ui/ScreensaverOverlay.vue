<script setup lang="ts">
import { ref } from 'vue';
import { useModal } from '../../lib/focus';
import Icon from './Icon.vue';

const emit = defineEmits<{ wake: [] }>();

// A real modal: the map behind it is inert and focus stays on the button until it is pressed.
const panel = ref<HTMLElement | null>(null);
useModal(panel);
</script>

<template>
    <Teleport to="body">
        <div class="bg-scrim/70 fixed inset-0 z-[2500] flex items-center justify-center p-6">
            <section
                ref="panel"
                tabindex="-1"
                role="alertdialog"
                aria-modal="true"
                aria-labelledby="screensaver-title"
                aria-describedby="screensaver-body"
                class="bg-surface-container shadow-level-3 flex w-full max-w-sm flex-col items-center rounded-xl p-8 text-center outline-none"
            >
                <span
                    class="bg-primary-container text-on-primary-container mb-5 flex size-16 items-center justify-center rounded-full"
                >
                    <Icon name="touchApp" :size="32" />
                </span>
                <h2 id="screensaver-title" class="type-title-lg font-bold">Are you still watching?</h2>
                <p id="screensaver-body" class="type-body-md text-on-surface-variant mt-3">
                    Live updates are paused so phones stop streaming. Pick up right where you left off.
                </p>
                <button
                    class="bg-primary text-on-primary type-label-lg mt-6 w-full rounded-full px-6 py-3 hover:brightness-110"
                    data-autofocus
                    @click="emit('wake')"
                >
                    I'm still here
                </button>
            </section>
        </div>
    </Teleport>
</template>
