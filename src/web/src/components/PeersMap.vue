<script setup lang="ts">
import L from 'leaflet';
import 'leaflet.markercluster';
import 'leaflet.markercluster/dist/MarkerCluster.css';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { hasPosition, type Peer } from '../lib/peers';
import { markerHtml, markerIcon } from '../lib/marker';
import { MAP_STYLES, tileLayers, type MapStyle } from '../lib/tiles';
import { storage } from '../lib/storage';

const props = defineProps<{
    peers: Peer[];
    selfId: string;
    selectedId: string | null;
    /** Changes every few seconds so "stale" markers grey out without new data. */
    now: number;
}>();
const emit = defineEmits<{ select: [id: string] }>();

const STYLE_KEY = 'legacytracker.mapStyle';
const element = ref<HTMLElement | null>(null);
const style = ref<MapStyle>(readStyle());

let map: L.Map | null = null;
let tiles: L.TileLayer[] = [];
let cluster: L.MarkerClusterGroup | null = null;
const markers = new Map<string, L.Marker>();
let fitted = false;

function readStyle(): MapStyle {
    const stored = storage.get(STYLE_KEY);
    return MAP_STYLES.some((s) => s.id === stored) ? (stored as MapStyle) : 'standard';
}

function applyStyle() {
    if (!map) return;
    for (const layer of tiles) layer.remove();
    tiles = tileLayers(style.value);
    tiles.forEach((layer) => layer.addTo(map!));
}

function sync() {
    if (!map || !cluster) return;
    const visible = new Set<string>();
    for (const peer of props.peers) {
        if (!hasPosition(peer)) continue;
        visible.add(peer.id);
        const latlng = L.latLng(peer.latitude!, peer.longitude!);
        const icon = markerIcon(
            markerHtml(peer, { self: peer.id === props.selfId, selected: peer.id === props.selectedId, now: props.now })
        );
        const existing = markers.get(peer.id);
        if (existing) {
            existing.setLatLng(latlng);
            existing.setIcon(icon);
        } else {
            const marker = L.marker(latlng, { icon, keyboard: false });
            marker.on('click', () => emit('select', peer.id));
            markers.set(peer.id, marker);
            cluster.addLayer(marker);
        }
    }
    for (const [id, marker] of markers) {
        if (!visible.has(id)) {
            cluster.removeLayer(marker);
            markers.delete(id);
        }
    }
    // Frame everyone once, the first time there is anyone to frame.
    if (!fitted && markers.size > 0) {
        fitted = true;
        map.fitBounds(L.latLngBounds([...markers.values()].map((m) => m.getLatLng())), {
            padding: [60, 60],
            maxZoom: 15
        });
    }
}

function flyToSelected() {
    const marker = props.selectedId ? markers.get(props.selectedId) : undefined;
    if (!map || !marker) return;
    // Zoom out of any cluster the marker sits in before centring on it.
    cluster?.zoomToShowLayer(marker, () => map!.flyTo(marker.getLatLng(), Math.max(map!.getZoom(), 15)));
}

onMounted(() => {
    map = L.map(element.value!, { zoomControl: false, worldCopyJump: true, minZoom: 2, maxZoom: 19 }).setView(
        [37.7749, -122.4194],
        3
    );
    L.control.zoom({ position: 'bottomright' }).addTo(map);
    cluster = L.markerClusterGroup({
        maxClusterRadius: 40,
        showCoverageOnHover: false,
        iconCreateFunction: (c) =>
            L.divIcon({
                html: `<div class="peer-cluster" style="width:44px;height:44px">${c.getChildCount()}</div>`,
                className: 'peer-marker-wrap',
                iconSize: [44, 44]
            })
    });
    map.addLayer(cluster);
    applyStyle();
    sync();
});

onBeforeUnmount(() => {
    map?.remove();
    map = null;
    markers.clear();
});

watch(() => [props.peers, props.selectedId, props.now], sync);
watch(() => props.selectedId, flyToSelected);
watch(style, (next) => {
    storage.set(STYLE_KEY, next);
    applyStyle();
});
</script>

<template>
    <div class="relative h-full w-full">
        <div ref="element" class="h-full w-full bg-neutral-900" />
        <label class="absolute top-3 right-3 z-[1000]">
            <span class="sr-only">Map style</span>
            <select
                v-model="style"
                class="rounded-xl border border-neutral-800 bg-black/80 px-3 py-2 text-sm backdrop-blur"
            >
                <option v-for="option in MAP_STYLES" :key="option.id" :value="option.id">{{ option.label }}</option>
            </select>
        </label>
    </div>
</template>
