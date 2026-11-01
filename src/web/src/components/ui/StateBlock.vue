<script setup lang="ts">
import Icon from './Icon.vue';
import Spinner from './Spinner.vue';

/** What a list shows instead of rows: loading, a failure with Retry, or "nothing yet". */
defineProps<{ kind: 'loading' | 'error' | 'empty'; message?: string }>();
const emit = defineEmits<{ retry: [] }>();
</script>

<template>
    <div v-if="kind === 'loading'" class="flex justify-center py-6"><Spinner /></div>
    <div
        v-else-if="kind === 'error'"
        class="bg-surface-container-high flex items-center gap-3 rounded-lg py-2 pr-2 pl-4"
        role="alert"
    >
        <Icon name="cloudOff" :size="20" class="text-on-surface-variant" />
        <span class="type-body-md flex-1">{{ message }}</span>
        <button class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2" @click="emit('retry')">
            Retry
        </button>
    </div>
    <p v-else class="bg-surface-container-high type-body-md text-on-surface-variant rounded-lg px-4 py-4">
        <slot>{{ message }}</slot>
    </p>
</template>
