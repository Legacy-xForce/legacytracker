<script setup lang="ts">
const model = defineModel<boolean>({ required: true });
defineProps<{ disabled?: boolean; label: string }>();
</script>

<template>
    <!-- Material 3 switch: a pill track with a thumb that grows when on. -->
    <button
        type="button"
        role="switch"
        :aria-checked="model"
        :aria-label="label"
        :disabled="disabled"
        class="duration-medium relative h-8 w-[52px] shrink-0 rounded-full border-2 transition-colors disabled:opacity-40"
        :class="model ? 'bg-primary border-primary' : 'bg-surface-container-highest border-outline'"
        @click="model = !model"
    >
        <span
            class="duration-medium absolute top-1/2 -translate-y-1/2 rounded-full transition-all"
            :class="model ? 'bg-on-primary left-[22px] size-6' : 'bg-outline left-1.5 size-4'"
        />
    </button>
</template>
