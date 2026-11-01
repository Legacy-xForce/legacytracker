<script setup lang="ts">
import EmojiPicker from 'vue3-emoji-picker';
import 'vue3-emoji-picker/css';
import Dialog from '../ui/Dialog.vue';
import Icon from '../ui/Icon.vue';

defineProps<{ emoji: string }>();
const emit = defineEmits<{ select: [emoji: string]; close: [] }>();

function pick(emoji: string) {
    emit('select', emoji);
    emit('close');
}
</script>

<template>
    <!-- Material 3 surface tokens replace the picker's own light/dark palette. -->
    <Dialog labelledby="emoji-picker-title" @close="emit('close')">
        <header class="flex items-center gap-1 px-3 py-2">
            <h2 id="emoji-picker-title" class="type-title-md flex-1 px-2">Choose an emoji</h2>
            <button
                class="hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                aria-label="Close"
                @click="emit('close')"
            >
                <Icon name="close" />
            </button>
        </header>
        <div class="flex justify-center px-2">
            <EmojiPicker
                native
                theme="light"
                hide-group-names
                :disable-skin-tones="false"
                data-emoji-picker
                @select="(emoji: { i: string }) => pick(emoji.i)"
            />
        </div>
        <footer class="flex justify-end p-3">
            <button
                class="text-primary type-label-lg hover:bg-on-surface/6 flex h-10 items-center rounded-full px-4 disabled:opacity-40"
                :disabled="!emoji"
                data-clear-emoji
                @click="pick('')"
            >
                Remove emoji
            </button>
        </footer>
    </Dialog>
</template>

<style>
/* The picker is a fixed-size widget with its own variables: retheme it with the page tokens. */
.v3-emoji-picker {
    --v3-picker-bg: var(--color-surface-container);
    --v3-picker-fg: var(--color-on-surface);
    --v3-picker-border: var(--color-outline-variant, color-mix(in srgb, var(--color-on-surface) 16%, transparent));
    --v3-picker-input-bg: var(--color-surface-container-high);
    --v3-picker-input-border: transparent;
    --v3-picker-input-focus-border: var(--color-primary);
    --v3-picker-emoji-hover: var(--color-surface-container-high);
    width: 100%;
    max-width: 24rem;
    height: 20rem;
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-level-1);
    font-family: inherit;
}

.v3-emoji-picker .v3-header {
    padding: 0.25rem 0.5rem;
}

.v3-emoji-picker .v3-body-inner .v3-group h5 {
    color: var(--color-on-surface-variant);
    font-size: 0.75rem;
    font-weight: 600;
}

.v3-emoji-picker .v3-search input {
    border-radius: var(--radius-full);
    padding: 0.375rem 0.75rem;
    font-size: 0.875rem;
}

.v3-emoji-picker .v3-footer {
    display: none;
}

.v3-emoji-picker .v3-emojis button {
    border-radius: var(--radius-md);
}
</style>
