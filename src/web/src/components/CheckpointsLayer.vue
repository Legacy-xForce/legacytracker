<script setup lang="ts">
import L from 'leaflet';
import { onBeforeUnmount, watch } from 'vue';
import { useMap } from '../lib/mapContext';
import type { Checkpoint } from '../stores/checkpoints';

const props = defineProps<{ checkpoints: Checkpoint[] }>();
const map = useMap();
let group: L.LayerGroup | null = null;

function draw() {
    group?.remove();
    group = null;
    if (!map.value) return;
    group = L.layerGroup(
        props.checkpoints.map((checkpoint) =>
            L.circle([checkpoint.latitude, checkpoint.longitude], {
                radius: checkpoint.radius,
                color: '#f59e0b',
                weight: 2,
                fillOpacity: 0.12,
                interactive: false
            }).bindTooltip(checkpoint.name, { permanent: true, direction: 'center', className: 'checkpoint-label' })
        )
    ).addTo(map.value);
}

watch([map, () => props.checkpoints], draw, { immediate: true });
onBeforeUnmount(() => group?.remove());
</script>

<template><span hidden /></template>
