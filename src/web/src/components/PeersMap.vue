<script setup lang="ts">
import L from 'leaflet';
import { onBeforeUnmount, onMounted, provide, ref, shallowRef, toRef, watch } from 'vue';
import ClusterMarker from './map/ClusterMarker.vue';
import PeerMarker from './map/PeerMarker.vue';
import { centerShowing, framePadding, holdAt, NO_INSETS, visibleCenter, type Insets } from '../lib/camera';
import { CLUSTER, clusterAnchor, clusterWidth, groupByDistance, PEER_MARKER_SIZE } from '../lib/clusters';
import { insetsKey, mapKey } from '../lib/mapContext';
import { Motion } from '../lib/motion';
import { hasPosition, isMoving, isStale, type Peer } from '../lib/peers';
import { tileLayers, type MapStyle } from '../lib/tiles';
import { VueMarker } from '../lib/vueMarker';

const props = withDefaults(
    defineProps<{
        peers: Peer[];
        selfId: string;
        selectedId: string | null;
        /** Changes every few seconds so "stale" markers grey out without new data. */
        now: number;
        mapStyle?: MapStyle;
        /** Parts of the map covered by panels; centring and framing aim at the rest. */
        insets?: Insets;
        /** Takes everyone off the map, e.g. while a trip replays. */
        hidden?: boolean;
    }>(),
    { mapStyle: 'standard', insets: () => NO_INSETS, hidden: false }
);
const emit = defineEmits<{ select: [id: string] }>();

const element = ref<HTMLElement | null>(null);
let map: L.Map | null = null;
const mapRef = shallowRef<L.Map | null>(null);
provide(mapKey, mapRef);
provide(insetsKey, toRef(props, 'insets'));

interface Entry {
    peer: Peer;
    view: VueMarker<ReturnType<typeof markerProps>>;
    motion: Motion;
}
interface Group {
    ids: string[];
    view: VueMarker<{ members: { id: string; name: string; stale: boolean }[] }>;
}

let tiles: L.TileLayer[] = [];
const people = L.layerGroup();
const entries = new Map<string, Entry>();
const groups = new Map<string, Group>();
let framed = false;
let frame = 0;
// Whom the camera keeps in view as they move, until the user pans away.
const following = ref<string | null>(null);
let flying = false;
let zooming = false;

function applyStyle() {
    if (!map) return;
    for (const layer of tiles) layer.remove();
    tiles = tileLayers(props.mapStyle);
    tiles.forEach((layer) => layer.addTo(map!));
}

function markerProps(peer: Peer) {
    return {
        userId: peer.id,
        name: peer.name,
        self: peer.id === props.selfId,
        selected: peer.id === props.selectedId,
        stale: isStale(peer, props.now),
        moving: isMoving(peer),
        heading: peer.heading,
        speedKmh: peer.speed * 3.6,
        battery: peer.batteryLevel,
        charging: peer.isCharging === true
    };
}

function sync() {
    if (!map) return;
    const now = performance.now();
    const present = new Set<string>();
    for (const peer of props.peers) {
        if (!hasPosition(peer)) continue;
        present.add(peer.id);
        const at = L.latLng(peer.latitude!, peer.longitude!);
        let entry = entries.get(peer.id);
        if (!entry) {
            const view = new VueMarker(at, PeerMarker, markerProps(peer), PEER_MARKER_SIZE, [
                PEER_MARKER_SIZE[0] / 2,
                PEER_MARKER_SIZE[1] / 2
            ]);
            view.marker.on('click', () => emit('select', peer.id));
            entry = { peer, view, motion: new Motion(at) };
            entries.set(peer.id, entry);
        } else {
            entry.peer = peer;
            entry.view.update(markerProps(peer));
            glideTo(entry, at, now);
        }
        // Whoever is selected draws over everyone else.
        entry.view.marker.setZIndexOffset(peer.id === props.selectedId ? 1000 : 0);
    }
    for (const [id, entry] of entries) {
        if (present.has(id)) continue;
        entry.view.destroy();
        entries.delete(id);
        if (following.value === id) following.value = null;
    }
    regroup();
    // Frame everyone once, the first time there is anyone to frame.
    if (!framed && entries.size > 0) {
        framed = true;
        map.fitBounds(L.latLngBounds([...entries.values()].map((e) => e.motion.target)), {
            ...framePadding(props.insets, 60),
            maxZoom: 15,
            animate: false
        });
    }
}

function glideTo(entry: Entry, at: L.LatLng, now: number) {
    if (!map || at.equals(entry.motion.target)) return;
    // Across more than a screen there is nothing to watch: just be there.
    const size = map.getSize();
    const jump = map.latLngToContainerPoint(at).distanceTo(map.latLngToContainerPoint(entry.motion.shown));
    if (jump > Math.hypot(size.x, size.y)) {
        entry.motion.jumpTo(at, now);
        entry.view.marker.setLatLng(at);
        if (following.value === entry.peer.id) keepFollowing();
        return;
    }
    entry.motion.moveTo(at, now);
    animate();
}

function animate() {
    if (!frame) frame = requestAnimationFrame(tick);
}

function tick() {
    frame = 0;
    const now = performance.now();
    let moving = false;
    for (const entry of entries.values()) {
        if (!entry.motion.gliding) continue;
        entry.motion.step(now);
        entry.view.marker.setLatLng(entry.motion.shown);
        moving ||= entry.motion.gliding;
    }
    for (const group of groups.values()) group.view.marker.setLatLng(centroid(group.ids));
    keepFollowing();
    if (moving) animate();
}

function keepFollowing() {
    const entry = following.value ? entries.get(following.value) : undefined;
    if (!map || !entry || flying || zooming || props.hidden) return;
    holdAt(map, entry.motion.shown, visibleCenter(map, props.insets));
}

function centroid(ids: string[]): L.LatLng {
    let lat = 0;
    let lng = 0;
    for (const id of ids) {
        const shown = entries.get(id)!.motion.shown;
        lat += shown.lat;
        lng += shown.lng;
    }
    return L.latLng(lat / ids.length, lng / ids.length);
}

function show(marker: L.Marker) {
    if (!people.hasLayer(marker)) people.addLayer(marker);
}

/** Folds people who would overlap on screen into group bubbles, and splits groups that separated. */
function regroup() {
    if (!map) return;
    const list = [...entries.values()];
    const zoom = map.getZoom();
    const wanted = new Map<string, Entry[]>();
    for (const indexes of groupByDistance(
        list.map((e) => ({
            ...map!.project(e.motion.target, zoom),
            lat: e.motion.target.lat,
            lng: e.motion.target.lng
        }))
    )) {
        const members = indexes.map((i) => list[i]);
        if (members.length === 1) show(members[0].view.marker);
        else {
            for (const member of members) people.removeLayer(member.view.marker);
            wanted.set(members.map((m) => m.peer.id).join('\n'), members);
        }
    }
    for (const [key, group] of groups) {
        if (wanted.has(key)) continue;
        group.view.destroy();
        groups.delete(key);
    }
    for (const [key, members] of wanted) {
        const ids = members.map((m) => m.peer.id);
        const bubble = {
            members: members.map(({ peer }) => ({
                id: peer.id,
                name: peer.id === props.selfId ? `${peer.name} (you)` : peer.name,
                stale: isStale(peer, props.now)
            }))
        };
        const existing = groups.get(key);
        if (existing) {
            existing.view.update(bubble);
            existing.view.marker.setLatLng(centroid(ids));
            continue;
        }
        const view = new VueMarker(
            centroid(ids),
            ClusterMarker,
            bubble,
            [clusterWidth(ids.length), CLUSTER.height],
            clusterAnchor(ids.length)
        );
        view.marker.on('click', (event) => openGroup(ids, event));
        people.addLayer(view.marker);
        groups.set(key, { ids, view });
    }
}

/** A face selects that person; anywhere else on the bubble zooms in until the group separates. */
function openGroup(ids: string[], event: L.LeafletMouseEvent) {
    const face = (event.originalEvent.target as Element | null)?.closest('[data-member]');
    const id = face?.getAttribute('data-member');
    if (id) {
        emit('select', id);
        return;
    }
    if (!map) return;
    following.value = null;
    map.flyToBounds(L.latLngBounds(ids.map((member) => entries.get(member)!.motion.shown)), {
        ...framePadding(props.insets, 90),
        maxZoom: map.getMaxZoom(),
        duration: 0.6
    });
}

/** Brings someone into the middle of the uncovered map and keeps them there as they move. */
function focus(id: string) {
    const entry = entries.get(id);
    if (!map || !entry) return;
    following.value = id;
    const zoom = Math.max(map.getZoom(), 16);
    flying = true;
    map.once('moveend', () => (flying = false));
    map.flyTo(centerShowing(map, entry.motion.shown, zoom, props.insets), zoom, { duration: 0.8 });
}

/** Frames everyone on the map. */
function fitEveryone() {
    if (!map || entries.size === 0) return;
    following.value = null;
    map.flyToBounds(L.latLngBounds([...entries.values()].map((e) => e.motion.target)), {
        ...framePadding(props.insets, 60),
        maxZoom: 15,
        duration: 0.8
    });
}

function zoomBy(delta: number) {
    if (!map) return;
    if (delta > 0) map.zoomIn();
    else map.zoomOut();
}

// Web Mercator ends here; beyond it there are no tiles, just a void.
const WORLD = L.latLngBounds([-85.0511, -1e5], [85.0511, 1e5]);

/** Never zoomed out so far that the world is shorter than the map. */
function fitWorldHeight() {
    if (!map) return;
    map.setMinZoom(Math.max(1, Math.ceil(Math.log2(map.getSize().y / 256))));
}

onMounted(() => {
    // Longitude wraps (worldCopyJump), so only latitude is bounded, like the app's camera constraint.
    map = L.map(element.value!, {
        zoomControl: false,
        worldCopyJump: true,
        maxBounds: WORLD,
        maxBoundsViscosity: 1,
        maxZoom: 19
    }).setView([30, 0], 3);
    fitWorldHeight();
    map.on('resize', fitWorldHeight);
    // Panning by hand means "let me look around": stop following.
    map.on('dragstart', () => (following.value = null));
    map.on('zoomstart', () => (zooming = true));
    map.on('zoomend', () => {
        zooming = false;
        regroup();
        keepFollowing();
    });
    if (!props.hidden) people.addTo(map);
    applyStyle();
    sync();
    mapRef.value = map;
});

onBeforeUnmount(() => {
    cancelAnimationFrame(frame);
    for (const entry of entries.values()) entry.view.destroy();
    for (const group of groups.values()) group.view.destroy();
    entries.clear();
    groups.clear();
    mapRef.value = null;
    map?.remove();
    map = null;
});

watch(() => [props.peers, props.selectedId, props.now, props.selfId], sync);
watch(
    () => props.selectedId,
    (id) => {
        if (id === null) following.value = null;
    }
);
watch(() => props.mapStyle, applyStyle);
watch(
    () => props.hidden,
    (hidden) => {
        if (!map) return;
        if (hidden) {
            following.value = null;
            people.remove();
        } else people.addTo(map);
    }
);

defineExpose({ focus, fitEveryone, zoomBy, following });
</script>

<template>
    <div class="relative h-full w-full">
        <div ref="element" class="h-full w-full" />
        <!-- Overlay layers (checkpoints, events, replay) draw onto the map through the injected handle. -->
        <slot />
    </div>
</template>
