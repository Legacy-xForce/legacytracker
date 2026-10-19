<script setup lang="ts">
import L from 'leaflet';
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import PeerMarker from './map/PeerMarker.vue';
import Icon from './ui/Icon.vue';
import UserAvatar from './UserAvatar.vue';
import type { HistorySession } from '../api/history';
import { framePadding, holdAt, visibleCenter, type Insets } from '../lib/camera';
import { PEER_MARKER_SIZE } from '../lib/clusters';
import { formatClock, formatLongDay } from '../lib/format';
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

let group: L.LayerGroup | null = null;
let rider: VueMarker<ReturnType<typeof riderProps>> | null = null;
let riderKey = '';
let frame = 0;
let lastTick = 0;
// The camera rides along until the user pans away; playing or scrubbing brings it back.
let follow = true;
let zooming = false;

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

function endpoint(at: L.LatLng, color: string): L.Marker {
    return L.marker(at, {
        interactive: false,
        keyboard: false,
        icon: L.divIcon({
            html: `<span class="replay-endpoint" style="background:${color}"></span>`,
            className: 'lt-marker',
            iconSize: [18, 18],
            iconAnchor: [9, 9]
        })
    });
}

function draw() {
    stop();
    clear();
    if (!map.value) return;
    const route = props.track.points.map((p) => L.latLng(p.latitude, p.longitude));
    rider = new VueMarker(route[0], PeerMarker, riderProps(), PEER_MARKER_SIZE, [
        PEER_MARKER_SIZE[0] / 2,
        PEER_MARKER_SIZE[1] / 2
    ]);
    rider.marker.setZIndexOffset(1000);
    group = L.layerGroup([
        // A dark edge keeps the route readable on any tiles, as on the phone.
        L.polyline(route, { color: '#000', opacity: 0.35, weight: 8, interactive: false }),
        // One polyline per run of similar speed: red when slow, green when fast.
        ...speedSegments(props.track.points).map((segment) =>
            L.polyline(segment.points, {
                color: segment.color,
                weight: 5,
                opacity: 1,
                interactive: false,
                lineCap: 'round',
                lineJoin: 'round'
            })
        ),
        endpoint(route[0], 'var(--color-online)'),
        endpoint(route[route.length - 1], 'var(--color-arrival)'),
        rider.marker
    ]).addTo(map.value);
    map.value.on('dragstart', unfollow).on('zoomstart', onZoomStart).on('zoomend', onZoomEnd);
    // Start on the whole trip, not just its first point.
    if (route.length > 1) {
        map.value.fitBounds(L.latLngBounds(route), { ...framePadding(viewInsets(), 56), maxZoom: 17 });
    } else map.value.setView(route[0], 15);
    elapsed.value = 0;
    follow = true;
}

function clear() {
    map.value?.off('dragstart', unfollow).off('zoomstart', onZoomStart).off('zoomend', onZoomEnd);
    group?.remove();
    rider?.destroy();
    group = null;
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
    const at = L.latLng(position.value.latitude, position.value.longitude);
    rider.marker.setLatLng(at);
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

onMounted(draw);
watch([map, () => props.track], draw);
window.addEventListener('keydown', onKey);
onBeforeUnmount(() => {
    stop();
    window.removeEventListener('keydown', onKey);
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
            class="bg-surface-container-low pointer-events-auto w-full max-w-[560px] rounded-[28px] px-5 pt-4 pb-4 shadow-[0_8px_32px_rgb(0_0_0/0.45)]"
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
                    class="text-on-surface-variant flex size-10 items-center justify-center rounded-full hover:bg-white/6"
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
                                : 'text-on-surface hover:bg-white/5',
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
    border-radius: 9999px;
    border: 3px solid #fff;
    box-shadow: 0 0 4px rgb(0 0 0 / 0.38);
}
</style>
