<script setup lang="ts">
import L from 'leaflet';
import { onBeforeUnmount, watch } from 'vue';
import { escapeHtml } from '../lib/format';
import { icons } from '../lib/icons';
import { useMap } from '../lib/mapContext';
import type { Checkpoint } from '../stores/checkpoints';

const props = defineProps<{ checkpoints: Checkpoint[] }>();
const map = useMap();
// Names sit under people and events, so a place never hides who is in it.
const PANE = 'checkpoint-labels';
// Zoomed out further, the names would pile up into noise; the circles stay.
const LABELS_FROM_ZOOM = 13;
let group: L.LayerGroup | null = null;

function updateLabels() {
    const target = map.value;
    target?.getContainer().classList.toggle('lt-hide-places', target.getZoom() < LABELS_FROM_ZOOM);
}

// The app's place circle (as in its checkpoint editor) with a compact name pill.
function draw() {
    group?.remove();
    group = null;
    const target = map.value;
    if (!target) return;
    if (!target.getPane(PANE)) target.createPane(PANE).style.zIndex = '450';
    group = L.layerGroup(
        props.checkpoints.map((checkpoint) =>
            L.circle([checkpoint.latitude, checkpoint.longitude], {
                radius: checkpoint.radius,
                color: '#82d5c8',
                weight: 1.5,
                opacity: 0.9,
                fillColor: '#82d5c8',
                fillOpacity: 0.14,
                interactive: false
            }).bindTooltip(`${icons.place}<span>${escapeHtml(checkpoint.name)}</span>`, {
                permanent: true,
                direction: 'center',
                className: 'checkpoint-label',
                pane: PANE
            })
        )
    ).addTo(target);
    updateLabels();
}

watch([map, () => props.checkpoints], draw, { immediate: true });
watch(
    map,
    (target, previous) => {
        previous?.off('zoomend', updateLabels);
        target?.on('zoomend', updateLabels);
    },
    { immediate: true }
);
onBeforeUnmount(() => {
    map.value?.off('zoomend', updateLabels);
    map.value?.getContainer().classList.remove('lt-hide-places');
    group?.remove();
});
</script>

<template><span hidden /></template>

<style>
.leaflet-tooltip.checkpoint-label {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 3px 10px 3px 6px;
    border: none;
    border-radius: 9999px;
    background: rgb(37 43 42 / 0.92);
    color: var(--color-on-surface);
    font-size: 12px;
    font-weight: 600;
    line-height: 16px;
    box-shadow: 0 2px 8px rgb(0 0 0 / 0.35);
}

.leaflet-tooltip.checkpoint-label svg {
    color: var(--color-primary);
    font-size: 14px;
}

.leaflet-tooltip.checkpoint-label::before {
    display: none;
}

.lt-hide-places .checkpoint-label {
    display: none !important;
}
</style>
