<script setup lang="ts">
import { themeColor } from '../lib/palette';
import { Marker, type MapMouseEvent } from 'mapbox-gl';
import { onBeforeUnmount, watch } from 'vue';
import { useAppearanceStore } from '../stores/appearance';
import { circlePolygon } from '../lib/geo';
import { escapeHtml } from '../lib/format';
import { icons } from '../lib/icons';
import { isStyleNotLoaded } from '../lib/mapbox';
import { useMap } from '../lib/mapContext';
import type { Checkpoint } from '../stores/checkpoints';

const props = defineProps<{ checkpoints: Checkpoint[] }>();
const emit = defineEmits<{ select: [id: string] }>();
const map = useMap();
const appearance = useAppearanceStore();
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

// A circle is as clickable as its name: either one opens the place.
function onCircleClick(event: MapMouseEvent) {
    const feature = event.features?.[0] as { properties?: { id?: unknown } | null } | undefined;
    const id = feature?.properties?.id;
    if (typeof id === 'string') emit('select', id);
}

function onCircleEnter() {
    const canvas = map.value?.getCanvas();
    if (canvas) canvas.style.cursor = 'pointer';
}

function onCircleLeave() {
    const canvas = map.value?.getCanvas();
    if (canvas) canvas.style.cursor = '';
}

function clearLayers() {
    const target = map.value;
    if (!target) return;
    target.off('click', FILL, onCircleClick);
    target.off('mouseenter', FILL, onCircleEnter);
    target.off('mouseleave', FILL, onCircleLeave);
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
    // The circles follow the theme's accent, like the rest of the page.
    const accent = themeColor('primary');
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
            paint: { 'fill-color': accent, 'fill-opacity': 0.14, 'fill-emissive-strength': 1 }
        });
        target.on('click', FILL, onCircleClick);
        target.on('mouseenter', FILL, onCircleEnter);
        target.on('mouseleave', FILL, onCircleLeave);
        target.addLayer({
            id: LINE,
            type: 'line',
            source: SOURCE,
            paint: {
                'line-color': accent,
                'line-width': 1.5,
                'line-opacity': 0.9,
                'line-emissive-strength': 1
            }
        });
        for (const checkpoint of props.checkpoints) {
            const el = document.createElement('div');
            el.className = 'checkpoint-label lt-marker';
            el.style.zIndex = `${Z_INDEX}`;
            // The whole pill takes the click (see .lt-hit): a button, so the keyboard reaches it too.
            el.innerHTML = `<button type="button" class="lt-hit" aria-label="${escapeHtml(checkpoint.name)}">${icons.place}<span>${escapeHtml(checkpoint.name)}</span></button>`;
            el.querySelector('button')!.addEventListener('click', (event) => {
                event.stopPropagation();
                emit('select', checkpoint.id);
            });
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
// Paint cannot read CSS variables, so a new theme redraws the circles with its own accent.
watch(() => appearance.theme, draw, { flush: 'post' });
onBeforeUnmount(() => {
    map.value?.off('style.load', draw);
    map.value?.off('zoom', updateLabels);
    onCircleLeave();
    clearLabels();
    clearLayers();
});
</script>

<template><span hidden /></template>

<style>
.checkpoint-label button {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 3px 10px 3px 6px;
    border: none;
    border-radius: var(--radius-full);
    /* Opaque, from the theme: the map shows through nothing, and every theme reads. */
    background: var(--color-surface-container-high);
    color: var(--color-on-surface);
    font: inherit;
    font-size: 12px;
    font-weight: 600;
    line-height: 16px;
    box-shadow: var(--shadow-level-1);
    white-space: nowrap;
    transition: background-color var(--duration-short);
}

.checkpoint-label button:hover {
    background: var(--color-surface-container-highest);
}

.checkpoint-label button:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
}

.checkpoint-label svg {
    color: var(--color-primary);
    font-size: 14px;
}
</style>
