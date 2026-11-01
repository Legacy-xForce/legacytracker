<script setup lang="ts">
import { duration, motion } from '../../lib/motionTokens';
import { themeColor } from '../../lib/palette';
import { useAppearanceStore } from '../../stores/appearance';
import type { GeoJSONSource } from 'mapbox-gl';
import { onBeforeUnmount, watch } from 'vue';
import { centerShowing, visibleCenter } from '../../lib/camera';
import { circlePolygon } from '../../lib/geo';
import { isStyleNotLoaded } from '../../lib/mapbox';
import { useInsets, useMap } from '../../lib/mapContext';

export interface PlaceDraft {
    latitude: number;
    longitude: number;
    /** Metres. */
    radius: number;
}

const props = defineProps<{ draft: PlaceDraft | null }>();
const emit = defineEmits<{ move: [latitude: number, longitude: number] }>();
const map = useMap();
const insets = useInsets();
const SOURCE = 'lt-place-draft';
const FILL = 'lt-place-draft-fill';
const LINE = 'lt-place-draft-line';
const ZOOM = 17;

function ring(draft: PlaceDraft) {
    return {
        type: 'Feature' as const,
        properties: {},
        geometry: {
            type: 'Polygon' as const,
            coordinates: [circlePolygon({ lat: draft.latitude, lng: draft.longitude }, draft.radius)]
        }
    };
}

function clear() {
    const target = map.value;
    if (!target) return;
    if (target.getLayer(LINE)) target.removeLayer(LINE);
    if (target.getLayer(FILL)) target.removeLayer(FILL);
    if (target.getSource(SOURCE)) target.removeSource(SOURCE);
}

function paint() {
    const target = map.value;
    if (!target) return;
    const draft = props.draft;
    if (!draft) {
        clear();
        return;
    }
    const source = target.getSource(SOURCE) as GeoJSONSource | undefined;
    if (source) {
        source.setData(ring(draft));
        return;
    }
    const accent = themeColor('primary');
    target.addSource(SOURCE, { type: 'geojson', data: ring(draft) });
    target.addLayer({
        id: FILL,
        type: 'fill',
        source: SOURCE,
        paint: { 'fill-color': accent, 'fill-opacity': 0.22, 'fill-emissive-strength': 1 }
    });
    target.addLayer({
        id: LINE,
        type: 'line',
        source: SOURCE,
        paint: { 'line-color': accent, 'line-width': 2, 'line-emissive-strength': 1 }
    });
}

function draw() {
    try {
        paint();
    } catch (error) {
        // A style change removes the layers; style.load draws them again once it is ready.
        if (!isStyleNotLoaded(error)) throw error;
    }
}

// The point is whatever sits under the crosshair, in the middle of the part of the map the panels
// don't cover.
// While the map is being dragged the point changes every frame; nobody reads it mid-gesture, so
// it is reported at most every 100 ms and once more when the map settles.
const MOVE_INTERVAL_MS = 100;
let moveTimer: ReturnType<typeof setTimeout> | null = null;

function onMove() {
    if (moveTimer !== null) return;
    moveTimer = setTimeout(() => {
        moveTimer = null;
        reportCentre();
    }, MOVE_INTERVAL_MS);
}

function onMoveEnd() {
    if (moveTimer !== null) clearTimeout(moveTimer);
    moveTimer = null;
    reportCentre();
}

function reportCentre() {
    const target = map.value;
    if (!target) return;
    const centre = visibleCenter(target, insets.value);
    const at = target.unproject([centre.x, centre.y]);
    emit('move', at.lat, at.lng);
}

/** Brings a point under the crosshair, closing in on it. */
function goto(latitude: number, longitude: number) {
    const target = map.value;
    if (!target) return;
    const zoom = Math.max(target.getZoom(), ZOOM);
    const centre = centerShowing(target, { lat: latitude, lng: longitude }, zoom, insets.value);
    target.flyTo({ center: [centre.lng, centre.lat], zoom, duration: motion(duration.extraLong * 1.6) });
}

watch(
    map,
    (target, previous) => {
        previous?.off('style.load', draw);
        previous?.off('move', onMove);
        previous?.off('moveend', onMoveEnd);
        target?.on('style.load', draw);
        target?.on('move', onMove);
        target?.on('moveend', onMoveEnd);
        draw();
        reportCentre();
    },
    { immediate: true }
);
const appearance = useAppearanceStore();
// Paint cannot read CSS variables, so a new theme redraws the ring with its own accent.
watch(
    () => appearance.theme,
    () => {
        clear();
        draw();
    },
    { flush: 'post' }
);
watch(() => [props.draft?.latitude, props.draft?.longitude, props.draft?.radius, props.draft === null], draw);
onBeforeUnmount(() => {
    map.value?.off('style.load', draw);
    map.value?.off('move', onMove);
    map.value?.off('moveend', onMoveEnd);
    if (moveTimer !== null) clearTimeout(moveTimer);
    clear();
});

defineExpose({ goto });
</script>

<template><span hidden /></template>
