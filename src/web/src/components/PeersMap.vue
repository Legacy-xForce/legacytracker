<script setup lang="ts">
import mapboxgl, { type Map as MapboxMap } from 'mapbox-gl';
import { onBeforeUnmount, onMounted, provide, ref, shallowRef, toRef, watch } from 'vue';
import '../lib/mapbox';
import ClusterMarker from './map/ClusterMarker.vue';
import PeerMarker from './map/PeerMarker.vue';
import { centerShowing, framePadding, holdAt, NO_INSETS, visibleCenter, type Insets } from '../lib/camera';
import { CLUSTER, clusterAnchor, clusterWidth, groupByDistance, PEER_MARKER_SIZE } from '../lib/clusters';
import { boundsOf, centroid as meanLatLng, type LatLng } from '../lib/geo';
import { insetsKey, mapKey } from '../lib/mapContext';
import { Motion } from '../lib/motion';
import { hasPosition, isMoving, isStale, type Peer } from '../lib/peers';
import { applyStandardTheme, styleFor, type MapLightPreset, type MapStyle } from '../lib/styles';
import { VueMarker } from '../lib/vueMarker';

const props = withDefaults(
    defineProps<{
        peers: Peer[];
        selfId: string;
        selectedId: string | null;
        /** Changes every few seconds so "stale" markers grey out without new data. */
        now: number;
        mapStyle?: MapStyle;
        /** Standard's lighting preset, matched to the app's light/dark theme. */
        lightPreset?: MapLightPreset;
        /** Parts of the map covered by panels; centring and framing aim at the rest. */
        insets?: Insets;
        /** Takes everyone off the map, e.g. while a trip replays. */
        hidden?: boolean;
        /** North stays up: no rotating, by hand or by pinch. */
        orientationLocked?: boolean;
        /** Tilts the map so Standard's buildings stand up. */
        view3d?: boolean;
    }>(),
    {
        mapStyle: 'standard',
        lightPreset: 'day',
        insets: () => NO_INSETS,
        hidden: false,
        orientationLocked: true,
        view3d: false
    }
);
const emit = defineEmits<{ select: [id: string]; deselect: [] }>();

const element = ref<HTMLElement | null>(null);
let map: MapboxMap | null = null;
const mapRef = shallowRef<MapboxMap | null>(null);
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

const entries = new Map<string, Entry>();
const groups = new Map<string, Group>();
let framed = false;
let frame = 0;
// Whom the camera keeps in view as they move, until the user pans away.
const following = ref<string | null>(null);
/** Degrees the map is turned away from north (0 while locked). */
const bearing = ref(0);
const TILT = 60;
let flying = false;
let zooming = false;

function applyStyle() {
    map?.setStyle(styleFor(props.mapStyle));
}

/** Standard's light/dark look is a config property, reset by every style
    switch. Deliberately not gated on `isStyleLoaded()`: during a diffed
    `setStyle` the new sources are still loading when `style.load` fires, and
    skipping there left the map stuck on the style's default day preset. */
function applyTheme() {
    if (!map) return;
    applyStandardTheme(map, props.lightPreset);
}

function markerLabel(peer: Peer): string {
    const name = peer.id === props.selfId ? `${peer.name} (you)` : peer.name;
    return isStale(peer, props.now) ? `${name}, not heard from in a while` : name;
}

function groupLabel(members: { name: string }[]): string {
    return `${members.length} people together: ${members.map((m) => m.name).join(', ')}. Zoom in`;
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

interface Showable {
    addTo(map: MapboxMap): void;
}

function show(view: Showable): void {
    if (map && !props.hidden) view.addTo(map);
}

function sync() {
    if (!map) return;
    const now = performance.now();
    const present = new Set<string>();
    for (const peer of props.peers) {
        if (!hasPosition(peer)) continue;
        present.add(peer.id);
        const at: LatLng = { lat: peer.latitude!, lng: peer.longitude! };
        let entry = entries.get(peer.id);
        if (!entry) {
            const view = new VueMarker(at, PeerMarker, markerProps(peer), PEER_MARKER_SIZE, [
                PEER_MARKER_SIZE[0] / 2,
                PEER_MARKER_SIZE[1] / 2
            ]);
            view.onClick(() => emit('select', peer.id));
            view.setLabel(markerLabel(peer));
            entry = { peer, view, motion: new Motion(at) };
            entries.set(peer.id, entry);
        } else {
            entry.peer = peer;
            entry.view.update(markerProps(peer));
            entry.view.setLabel(markerLabel(peer));
            glideTo(entry, at, now);
        }
        // Whoever is selected draws over everyone else.
        entry.view.setZIndex(peer.id === props.selectedId ? 1000 : 2);
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
        map.fitBounds(boundsOf([...entries.values()].map((entry) => entry.motion.target)), {
            ...framePadding(props.insets, 60),
            maxZoom: 15,
            duration: 0
        });
    }
}

function glideTo(entry: Entry, at: LatLng, now: number) {
    if (!map || (at.lat === entry.motion.target.lat && at.lng === entry.motion.target.lng)) return;
    // Across more than a screen there is nothing to watch: just be there.
    const shown = map.project([entry.motion.shown.lng, entry.motion.shown.lat]);
    const next = map.project([at.lng, at.lat]);
    const size = map.getContainer();
    if (Math.hypot(next.x - shown.x, next.y - shown.y) > Math.hypot(size.clientWidth, size.clientHeight)) {
        entry.motion.jumpTo(at, now);
        entry.view.setLatLng(at);
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
        entry.view.setLatLng(entry.motion.shown);
        moving ||= entry.motion.gliding;
    }
    for (const group of groups.values()) group.view.setLatLng(centroid(group.ids));
    keepFollowing();
    if (moving) animate();
}

function keepFollowing() {
    const entry = following.value ? entries.get(following.value) : undefined;
    if (!map || !entry || flying || zooming || props.hidden) return;
    holdAt(map, entry.motion.shown, visibleCenter(map, props.insets));
}

function centroid(ids: string[]): LatLng {
    return meanLatLng(ids.map((id) => entries.get(id)!.motion.shown));
}

/** Folds people who would overlap on screen into group bubbles, and splits groups that separated. */
function regroup() {
    if (!map) return;
    if (props.hidden) {
        for (const entry of entries.values()) entry.view.remove();
        for (const group of groups.values()) group.view.remove();
        return;
    }
    const list = [...entries.values()];
    const wanted = new Map<string, Entry[]>();
    for (const indexes of groupByDistance(
        list.map((entry) => ({
            ...map!.project([entry.motion.target.lng, entry.motion.target.lat]),
            lat: entry.motion.target.lat,
            lng: entry.motion.target.lng
        }))
    )) {
        const members = indexes.map((i) => list[i]);
        if (members.length === 1) show(members[0].view);
        else {
            for (const member of members) member.view.remove();
            wanted.set(members.map((member) => member.peer.id).join('\n'), members);
        }
    }
    for (const [key, group] of groups) {
        if (wanted.has(key)) continue;
        group.view.destroy();
        groups.delete(key);
    }
    for (const [key, members] of wanted) {
        const ids = members.map((member) => member.peer.id);
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
            existing.view.setLabel(groupLabel(bubble.members));
            existing.view.setLatLng(centroid(ids));
            show(existing.view);
            continue;
        }
        const view = new VueMarker(
            centroid(ids),
            ClusterMarker,
            bubble,
            [clusterWidth(ids.length), CLUSTER.height],
            clusterAnchor(ids.length)
        );
        view.setZIndex(2);
        view.onClick((event) => openGroup(ids, event));
        view.setLabel(groupLabel(bubble.members));
        show(view);
        groups.set(key, { ids, view });
    }
}

/** A face selects that person; anywhere else on the bubble zooms in until the group separates. */
function openGroup(ids: string[], event: MouseEvent) {
    const face = (event.target as Element | null)?.closest('[data-member]');
    const id = face?.getAttribute('data-member');
    if (id) {
        emit('select', id);
        return;
    }
    if (!map) return;
    following.value = null;
    map.fitBounds(boundsOf(ids.map((member) => entries.get(member)!.motion.shown)), {
        ...framePadding(props.insets, 90),
        maxZoom: map.getMaxZoom(),
        duration: 600
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
    const centre = centerShowing(map, entry.motion.shown, zoom, props.insets);
    map.flyTo({ center: [centre.lng, centre.lat], zoom, duration: 800 });
}

/** Frames everyone on the map. */
function fitEveryone() {
    if (!map || entries.size === 0) return;
    following.value = null;
    map.fitBounds(boundsOf([...entries.values()].map((entry) => entry.motion.target)), {
        ...framePadding(props.insets, 60),
        maxZoom: 15,
        duration: 800
    });
}

/** Rotation and tilt follow the layers menu; the gestures are only on while they are allowed. */
function applyView() {
    if (!map) return;
    if (props.orientationLocked) {
        map.dragRotate.disable();
        map.touchZoomRotate.disableRotation();
        if (map.getBearing() !== 0) map.easeTo({ bearing: 0 });
    } else {
        map.dragRotate.enable();
        map.touchZoomRotate.enableRotation();
    }
    if (props.view3d) map.touchPitch.enable();
    else map.touchPitch.disable();
    const pitch = props.view3d ? TILT : 0;
    if (map.getPitch() !== pitch) map.easeTo({ pitch });
}

function resetNorth() {
    map?.easeTo({ bearing: 0 });
}

function zoomBy(delta: number) {
    if (!map) return;
    if (delta > 0) map.zoomIn();
    else map.zoomOut();
}

/** Never zoomed out so far that the world is shorter than the map. */
function fitWorldHeight() {
    if (!map) return;
    // Mapbox's world is 512 px per tile at zoom 0.
    map.setMinZoom(Math.max(1, Math.ceil(Math.log2(map.getContainer().clientHeight / 512))));
}

onMounted(() => {
    const container = element.value;
    if (!container) return;
    map = new mapboxgl.Map({
        container,
        style: styleFor(props.mapStyle),
        center: [0, 30],
        zoom: 3,
        maxZoom: 19,
        // Longitude wraps, so only the Mercator latitude limit constrains the camera, like the app.
        renderWorldCopies: true,
        // North-up and flat until the layers menu says otherwise (applyView).
        dragRotate: false,
        pitchWithRotate: false,
        touchPitch: false,
        attributionControl: false
    });
    map.addControl(new mapboxgl.AttributionControl({ compact: true }));
    applyView();
    map.on('rotate', () => (bearing.value = map?.getBearing() ?? 0));
    // Published before anything else can fail: the replay, checkpoint and
    // event layers draw into this ref, and a throw below used to leave them
    // - and the replay screen - with no map at all.
    mapRef.value = map;
    fitWorldHeight();
    map.on('resize', fitWorldHeight);
    // A style switch resets config properties, so re-apply the theme on every load.
    map.on('style.load', applyTheme);
    applyTheme();
    // Panning by hand means "let me look around": stop following and let go of
    // whoever is highlighted. Only a real drag gets here, never a tap on a
    // marker or a camera move of our own.
    map.on('dragstart', () => {
        following.value = null;
        emit('deselect');
    });
    map.on('zoomstart', () => (zooming = true));
    map.on('zoomend', () => {
        zooming = false;
        regroup();
        keepFollowing();
    });
    sync();
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
watch(() => [props.orientationLocked, props.view3d], applyView);
watch(() => props.lightPreset, applyTheme);
watch(
    () => props.hidden,
    (hidden) => {
        if (!map) return;
        if (hidden) following.value = null;
        regroup();
    }
);

defineExpose({ focus, fitEveryone, zoomBy, resetNorth, following, bearing });
</script>

<template>
    <div
        class="relative h-full w-full"
        :style="{
            '--lt-map-left-inset': `${insets.left}px`,
            '--lt-map-right-inset': `${insets.right}px`,
            '--lt-map-bottom-inset': `${insets.bottom}px`
        }"
    >
        <div ref="element" class="h-full w-full" />
        <!-- Overlay layers (checkpoints, events, replay) draw onto the map through the injected handle. -->
        <slot />
    </div>
</template>
