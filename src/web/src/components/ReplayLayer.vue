<script setup lang="ts">
import { palette } from '../lib/palette';
import { Marker } from 'mapbox-gl';
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import PeerMarker from './map/PeerMarker.vue';
import Icon from './ui/Icon.vue';
import UserAvatar from './UserAvatar.vue';
import type { HistorySession } from '../api/history';
import { framePadding, holdAt, visibleCenter, type Insets } from '../lib/camera';
import { PEER_MARKER_SIZE } from '../lib/clusters';
import { boundsOf, type LatLng } from '../lib/geo';
import { formatClock, formatLongDay } from '../lib/format';
import { isStyleNotLoaded } from '../lib/mapbox';
import { useInsets, useMap } from '../lib/mapContext';
import { MOVING_SPEED } from '../lib/peers';
import { BASE_SPEED, PLAYBACK_SPEEDS, speedSegments, type ReplayTrack } from '../lib/replay';
import { VueMarker } from '../lib/vueMarker';

const props = defineProps<{ userId: string; userName: string; session: HistorySession; track: ReplayTrack }>();
const emit = defineEmits<{ close: [] }>();

const map = useMap();
const insets = useInsets();
const card = ref<HTMLElement | null>(null);
const elapsed = ref(0);
const playing = ref(false);
const speed = ref<number>(1);
const position = computed(() => props.track.positionAt(elapsed.value));
const current = computed(() => props.track.points[position.value.index]);
const progress = computed(() =>
    props.track.points.length > 1 ? (position.value.index / (props.track.points.length - 1)) * 100 : 0
);

const ROUTE_SOURCE = 'lt-replay-route';
const EDGE_SOURCE = 'lt-replay-edge';
const EDGE_LAYER = 'lt-replay-edge-line';
const SPEED_LAYER = 'lt-replay-speed';

let rider: VueMarker<ReturnType<typeof riderProps>> | null = null;
let endpoints: Marker[] = [];
let riderKey = '';
let frame = 0;
let lastTick = 0;
// The camera rides along until the user pans away; playing or scrubbing brings it back.
let follow = true;
let zooming = false;
// A style change rebuilds the layers without restarting the trip.
let paintedTrack: ReplayTrack | null = null;

function riderProps() {
    const point = current.value;
    return {
        userId: props.userId,
        name: props.userName,
        self: false,
        selected: false,
        stale: false,
        moving: point.speed >= MOVING_SPEED,
        heading: point.heading,
        speedKmh: point.speed * 3.6,
        battery: null,
        charging: false,
        // The replay marker sits over the route, so it can afford to be smaller than a live peer.
        compact: true
    };
}

/** The map's uncovered area, minus the controls card. */
function viewInsets(): Insets {
    return { ...insets.value, bottom: insets.value.bottom + (card.value?.offsetHeight ?? 0) + 24 };
}

function endpoint(at: [number, number], color: string): Marker {
    const el = document.createElement('span');
    el.className = 'replay-endpoint';
    el.style.background = color;
    el.style.pointerEvents = 'none';
    el.style.zIndex = '2';
    return new Marker({ element: el, anchor: 'center' }).setLngLat(at).addTo(map.value!);
}

function removeLayers(): void {
    const target = map.value;
    if (!target) return;
    for (const id of [SPEED_LAYER, EDGE_LAYER]) {
        if (target.getLayer(id)) target.removeLayer(id);
    }
    for (const id of [ROUTE_SOURCE, EDGE_SOURCE]) {
        if (target.getSource(id)) target.removeSource(id);
    }
}

function draw() {
    try {
        paint();
    } catch (error) {
        // A style change removes the layers; style.load draws them again once it is ready.
        if (!isStyleNotLoaded(error)) throw error;
    }
}

function paint() {
    const sameTrack = paintedTrack === props.track;
    const resumeAt = sameTrack ? elapsed.value : 0;
    const resumePlaying = sameTrack && playing.value;
    const resumeFollowing = sameTrack ? follow : true;
    stop();
    clear();
    const target = map.value;
    if (!target) return;
    const points = props.track.points;
    const route: [number, number][] = points.map((point) => [point.longitude, point.latitude]);
    const start: LatLng = { lat: points[0].latitude, lng: points[0].longitude };
    rider = new VueMarker(start, PeerMarker, riderProps(), PEER_MARKER_SIZE, [
        PEER_MARKER_SIZE[0] / 2,
        PEER_MARKER_SIZE[1] / 2
    ]);
    rider.setZIndex(1000);
    rider.addTo(target);

    target.addSource(EDGE_SOURCE, {
        type: 'geojson',
        data: {
            type: 'Feature',
            properties: {},
            geometry: { type: 'LineString', coordinates: route }
        }
    });
    target.addSource(ROUTE_SOURCE, {
        type: 'geojson',
        data: {
            type: 'FeatureCollection',
            features: speedSegments(points).map((segment) => ({
                type: 'Feature',
                properties: { color: segment.color },
                geometry: {
                    type: 'LineString',
                    coordinates: segment.points.map(([lat, lng]) => [lng, lat])
                }
            }))
        }
    });
    // A dark edge keeps the route readable on any tiles, as on the phone.
    // Emissive at 1: the Standard style dims non-emissive lines to black under
    // the dawn/dusk/night presets, which is what made the route go dark.
    target.addLayer({
        id: EDGE_LAYER,
        type: 'line',
        source: EDGE_SOURCE,
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': palette.black, 'line-opacity': 0.35, 'line-width': 8, 'line-emissive-strength': 1 }
    });
    // One line per run of similar speed: red when slow, green when fast.
    target.addLayer({
        id: SPEED_LAYER,
        type: 'line',
        source: ROUTE_SOURCE,
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': ['get', 'color'], 'line-width': 5, 'line-emissive-strength': 1 }
    });

    endpoints = [endpoint(route[0], 'var(--color-online)'), endpoint(route[route.length - 1], 'var(--color-arrival)')];
    target.on('dragstart', unfollow);
    target.on('zoomstart', onZoomStart);
    target.on('zoomend', onZoomEnd);
    // Start on the whole trip, not just its first point. A style change keeps the current frame.
    if (!sameTrack) {
        if (route.length > 1) {
            target.fitBounds(boundsOf(points.map((point) => ({ lat: point.latitude, lng: point.longitude }))), {
                ...framePadding(viewInsets(), 56),
                maxZoom: 17,
                duration: 0
            });
        } else target.jumpTo({ center: route[0], zoom: 15 });
    }
    paintedTrack = props.track;
    elapsed.value = resumeAt;
    follow = resumeFollowing;
    render();
    if (resumePlaying) {
        playing.value = true;
        lastTick = performance.now();
        frame = requestAnimationFrame(tick);
    }
}

function clear() {
    const target = map.value;
    target?.off('dragstart', unfollow).off('zoomstart', onZoomStart).off('zoomend', onZoomEnd);
    removeLayers();
    for (const marker of endpoints) marker.remove();
    endpoints = [];
    rider?.destroy();
    rider = null;
    riderKey = '';
}

function unfollow() {
    follow = false;
}

function onZoomStart() {
    zooming = true;
}

function onZoomEnd() {
    zooming = false;
}

/** Moves the rider; its look (speed badge, heading) only changes when a new fix is reached. */
function render() {
    if (!rider || !map.value) return;
    const at: LatLng = { lat: position.value.latitude, lng: position.value.longitude };
    rider.setLatLng(at);
    const key = `${position.value.index}`;
    if (key !== riderKey) {
        riderKey = key;
        rider.update(riderProps());
    }
    if (follow && !zooming) holdAt(map.value, at, visibleCenter(map.value, viewInsets()));
}

function tick(time: number) {
    if (!playing.value) return;
    elapsed.value = Math.min(props.track.duration, elapsed.value + (time - lastTick) * speed.value * BASE_SPEED);
    lastTick = time;
    render();
    if (elapsed.value >= props.track.duration) playing.value = false;
    else frame = requestAnimationFrame(tick);
}

function play() {
    if (props.track.points.length < 2) return;
    if (elapsed.value >= props.track.duration) elapsed.value = 0;
    playing.value = true;
    follow = true;
    lastTick = performance.now();
    frame = requestAnimationFrame(tick);
}

function stop() {
    playing.value = false;
    cancelAnimationFrame(frame);
}

function seek(event: Event) {
    stop();
    elapsed.value = props.track.starts[Number((event.target as HTMLInputElement).value)] ?? 0;
    follow = true;
    render();
}

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') emit('close');
}

watch([map, () => props.track], draw, { immediate: true });
watch(
    map,
    (target, previous) => {
        previous?.off('style.load', draw);
        target?.on('style.load', draw);
    },
    { immediate: true }
);
window.addEventListener('keydown', onKey);
onBeforeUnmount(() => {
    stop();
    window.removeEventListener('keydown', onKey);
    map.value?.off('style.load', draw);
    clear();
});
</script>

<template>
    <div
        class="pointer-events-none absolute z-[1000] flex justify-center"
        :style="{ left: `${insets.left + 12}px`, right: `${insets.right + 12}px`, bottom: `${insets.bottom + 12}px` }"
    >
        <div
            ref="card"
            class="bg-surface-container-low shadow-level-3 pointer-events-auto w-full max-w-[560px] rounded-xl px-5 pt-4 pb-4"
        >
            <div class="flex items-center gap-3">
                <UserAvatar :user-id="userId" :name="userName" :size="36" />
                <div class="min-w-0 flex-1">
                    <p class="type-title-md truncate font-semibold">{{ userName }}</p>
                    <p class="type-body-sm text-on-surface-variant truncate">
                        {{ formatLongDay(new Date(session.startAt)) }} · {{ formatClock(session.startAt) }} –
                        {{ formatClock(session.endAt) }}
                    </p>
                </div>
                <button
                    class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                    aria-label="Close replay"
                    title="Close (Esc)"
                    @click="emit('close')"
                >
                    <Icon name="close" />
                </button>
            </div>
            <div class="type-title-md mt-3 flex items-center justify-between font-bold tabular-nums">
                <span data-testid="replay-time">{{ formatClock(current.recordedAt) }}</span>
                <span>{{ Math.round(current.speed * 3.6) }} km/h</span>
            </div>
            <input
                type="range"
                class="m3-slider my-3"
                aria-label="Position in the trip"
                min="0"
                :max="track.points.length - 1"
                :value="position.index"
                :disabled="track.points.length < 2"
                :style="{ '--progress': `${progress}%` }"
                @input="seek"
            />
            <div class="flex items-center gap-4">
                <div
                    class="border-outline flex h-10 flex-1 overflow-hidden rounded-full border"
                    role="group"
                    aria-label="Speed"
                >
                    <button
                        v-for="(option, i) in PLAYBACK_SPEEDS"
                        :key="option"
                        class="type-label-lg flex-1 transition-colors"
                        :class="[
                            speed === option
                                ? 'bg-secondary-container text-on-secondary-container'
                                : 'text-on-surface hover:bg-on-surface/5',
                            i > 0 ? 'border-outline border-l' : ''
                        ]"
                        :aria-pressed="speed === option"
                        @click="speed = option"
                    >
                        {{ option }}x
                    </button>
                </div>
                <button
                    class="bg-primary text-on-primary flex size-14 shrink-0 items-center justify-center rounded-full transition hover:brightness-110"
                    :aria-label="playing ? 'Pause' : 'Play'"
                    @click="playing ? stop() : play()"
                >
                    <Icon :name="playing ? 'pause' : 'playArrow'" :size="30" />
                </button>
            </div>
        </div>
    </div>
</template>

<style>
.replay-endpoint {
    display: block;
    width: 18px;
    height: 18px;
    border-radius: var(--radius-full);
    border: 3px solid #fff;
    box-shadow: var(--shadow-level-1);
}
</style>
