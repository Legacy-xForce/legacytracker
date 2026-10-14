<script setup lang="ts">
import { computed } from 'vue';
import Icon from './ui/Icon.vue';
import { useStreetName } from '../lib/streets';
import { useCheckpointsStore } from '../stores/checkpoints';

const props = defineProps<{
    /** Who or what the label is for; at most one lookup per subject waits at a time. */
    subject: string;
    latitude: number;
    longitude: number;
}>();

const checkpoints = useCheckpointsStore();
// Inside a saved place its name says more than the street, as on the phone.
const checkpoint = computed(() => checkpoints.resolve(props.latitude, props.longitude));
const street = useStreetName(
    () => props.subject,
    () => (checkpoint.value ? null : { latitude: props.latitude, longitude: props.longitude })
);
</script>

<template>
    <span class="flex min-w-0 items-center gap-1">
        <template v-if="checkpoint">
            <Icon name="place" :size="14" class="-ml-0.5" />
            <span class="truncate">{{ checkpoint.name }}</span>
        </template>
        <span v-else class="truncate">{{ street ?? 'Looking up street…' }}</span>
    </span>
</template>
