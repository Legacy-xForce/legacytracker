<script setup lang="ts">
import { palette } from '../lib/palette';
import { Marker } from 'mapbox-gl';
import { onBeforeUnmount, watch } from 'vue';
import { circlePolygon } from '../lib/geo';
import { escapeHtml } from '../lib/format';
import { icons } from '../lib/icons';
import { isStyleNotLoaded } from '../lib/mapbox';
import { useMap } from '../lib/mapContext';
import type { Checkpoint } from '../stores/checkpoints';

const props = defineProps<{ checkpoints: Checkpoint[] }>();
const map = useMap();
// Names sit under people and events, so a place never hides who is in it.
const Z_INDEX = 0;
// Zoomed out further, the names would pile up into noise; the circles stay.
const LABELS_FROM_ZOOM = 13;
const SOURCE = 'lt-checkpoints';
const FILL = 'lt-checkpoints-fill';
const LINE = 'lt-checkpoints-line';
const labels = new Map<string, Marker>();

function updateLabels() {
    const target = map.value;
    const visible = (target?.getZoom() ?? 0) >= LABELS_FROM_ZOOM;
    for (const marker of labels.values()) marker.getElement().style.display = visible ? '' : 'none';
}

function clearLayers() {
    const target = map.value;
    if (!target) return;
    if (target.getLayer(LINE)) target.removeLayer(LINE);
    if (target.getLayer(FILL)) target.removeLayer(FILL);
    if (target.getSource(SOURCE)) target.removeSource(SOURCE);
}

function clearLabels() {
    for (const marker of labels.values()) marker.remove();
    labels.clear();
}

// The app's place circle (as in its checkpoint editor) with a compact name pill.
function draw() {
    try {
        paint();
    } catch (error) {
        // A style change removes the layers; style.load draws them again once it is ready.
        if (!isStyleNotLoaded(error)) throw error;
    }
}

function paint() {
    const target = map.value;
    if (!target) return;
    clearLayers();
    clearLabels();
    if (props.checkpoints.length > 0) {
        target.addSource(SOURCE, {
            type: 'geojson',
            data: {
                type: 'FeatureCollection',
                features: props.checkpoints.map((checkpoint) => ({
                    type: 'Feature',
                    properties: { id: checkpoint.id },
                    geometry: {
                        type: 'Polygon',
                        coordinates: [
                            circlePolygon({ lat: checkpoint.latitude, lng: checkpoint.longitude }, checkpoint.radius)
                        ]
                    }
                }))
            }
        });
        target.addLayer({
            id: FILL,
            type: 'fill',
            source: SOURCE,
            paint: { 'fill-color': palette.mapAccent, 'fill-opacity': 0.14, 'fill-emissive-strength': 1 }
        });
        target.addLayer({
            id: LINE,
            type: 'line',
            source: SOURCE,
            paint: {
                'line-color': palette.mapAccent,
                'line-width': 1.5,
                'line-opacity': 0.9,
                'line-emissive-strength': 1
            }
        });
        for (const checkpoint of props.checkpoints) {
            const el = document.createElement('div');
            el.className = 'checkpoint-label lt-marker';
            el.style.pointerEvents = 'none';
            el.style.zIndex = `${Z_INDEX}`;
            el.innerHTML = `${icons.place}<span>${escapeHtml(checkpoint.name)}</span>`;
            const marker = new Marker({ element: el, anchor: 'center' })
                .setLngLat([checkpoint.longitude, checkpoint.latitude])
                .addTo(target);
            labels.set(checkpoint.id, marker);
        }
    }
    updateLabels();
}

watch(
    map,
    (target, previous) => {
        previous?.off('style.load', draw);
        previous?.off('zoom', updateLabels);
        target?.on('style.load', draw);
        target?.on('zoom', updateLabels);
        draw();
    },
    { immediate: true }
);
watch(() => props.checkpoints, draw);
onBeforeUnmount(() => {
    map.value?.off('style.load', draw);
    map.value?.off('zoom', updateLabels);
    clearLabels();
    clearLayers();
});
</script>

<template><span hidden /></template>

<style>
.checkpoint-label {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 3px 10px 3px 6px;
    border-radius: var(--radius-full);
    background: v-bind('palette.nameChip');
    color: var(--color-on-surface);
    font-size: 12px;
    font-weight: 600;
    line-height: 16px;
    box-shadow: 0 2px 8px rgb(0 0 0 / 0.35);
    white-space: nowrap;
}

.checkpoint-label svg {
    color: var(--color-primary);
    font-size: 14px;
}
</style>
