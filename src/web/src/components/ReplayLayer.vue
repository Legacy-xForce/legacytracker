<script setup lang="ts">
import L from 'leaflet';
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import type { HistorySession } from '../api/history';
import { formatClock } from '../lib/format';
import { useMap } from '../lib/mapContext';
import { markerHtml, markerIcon } from '../lib/marker';
import { BASE_SPEED, PLAYBACK_SPEEDS, type ReplayTrack } from '../lib/replay';

const props = defineProps<{ userId: string; userName: string; session: HistorySession; track: ReplayTrack }>();
const emit = defineEmits<{ close: [] }>();

const map = useMap();
const elapsed = ref(0);
const playing = ref(false);
const speed = ref<number>(1);
const position = computed(() => props.track.positionAt(elapsed.value));
const current = computed(() => props.track.points[position.value.index]);

let group: L.LayerGroup | null = null;
let marker: L.Marker | null = null;
let frame = 0;
let lastTick = 0;

function dot(color: string): L.DivIcon {
    return L.divIcon({
        html: `<div style="width:18px;height:18px;border-radius:9999px;background:${color};border:3px solid #fff;box-shadow:0 0 4px rgb(0 0 0 / 0.4)"></div>`,
        className: 'peer-marker-wrap',
        iconSize: [18, 18],
        iconAnchor: [9, 9]
    });
}

function icon(): L.DivIcon {
    const point = current.value;
    return markerIcon(
        markerHtml(
            {
                id: props.userId,
                name: props.userName,
                sharing: true,
                latitude: point.latitude,
                longitude: point.longitude,
                speed: point.speed,
                heading: point.heading,
                recordedAt: point.recordedAt,
                hereSince: null,
                lastSeenAt: Date.now(),
                batteryLevel: null,
                isCharging: null
            },
            { self: false, selected: false, now: Date.now() }
        )
    );
}

function draw() {
    stop();
    group?.remove();
    group = null;
    marker = null;
    if (!map.value) return;
    const route = props.track.points.map((p) => L.latLng(p.latitude, p.longitude));
    marker = L.marker(route[0], { icon: icon(), keyboard: false, zIndexOffset: 1000 });
    group = L.layerGroup([
        L.polyline(route, { color: '#0985fb', weight: 5, opacity: 0.9 }),
        L.marker(route[0], { icon: dot('#34c759'), interactive: false, keyboard: false }),
        L.marker(route[route.length - 1], { icon: dot('#ff453a'), interactive: false, keyboard: false }),
        marker
    ]).addTo(map.value);
    // Start on the whole trip, not just its first point.
    if (route.length > 1) map.value.fitBounds(L.latLngBounds(route), { padding: [56, 56], maxZoom: 17 });
    else map.value.setView(route[0], 15);
    elapsed.value = 0;
}

function render() {
    if (!marker) return;
    marker.setLatLng([position.value.latitude, position.value.longitude]);
    marker.setIcon(icon());
}

function tick(time: number) {
    if (!playing.value) return;
    elapsed.value = Math.min(props.track.duration, elapsed.value + (time - lastTick) * speed.value * BASE_SPEED);
    lastTick = time;
    render();
    map.value?.panTo(marker!.getLatLng(), { animate: false });
    if (elapsed.value >= props.track.duration) playing.value = false;
    else frame = requestAnimationFrame(tick);
}

function play() {
    if (props.track.points.length < 2) return;
    if (elapsed.value >= props.track.duration) elapsed.value = 0;
    playing.value = true;
    lastTick = performance.now();
    frame = requestAnimationFrame(tick);
}

function stop() {
    playing.value = false;
    cancelAnimationFrame(frame);
}

function seek(event: Event) {
    stop();
    const index = Number((event.target as HTMLInputElement).value);
    elapsed.value = props.track.starts[index] ?? 0;
    render();
    map.value?.panTo(marker!.getLatLng(), { animate: false });
}

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') emit('close');
}

watch([map, () => props.track], draw, { immediate: true });
window.addEventListener('keydown', onKey);
onBeforeUnmount(() => {
    stop();
    window.removeEventListener('keydown', onKey);
    group?.remove();
});
</script>

<template>
    <div
        class="absolute inset-x-3 bottom-3 z-[1000] mx-auto max-w-xl rounded-2xl border border-neutral-800 bg-black/85 p-4 backdrop-blur"
    >
        <div class="flex items-center justify-between text-sm">
            <span class="font-semibold tabular-nums" data-testid="replay-time">{{
                formatClock(current.recordedAt)
            }}</span>
            <span class="truncate px-3 text-neutral-400"
                >{{ userName }} · {{ formatClock(session.startAt) }}–{{ formatClock(session.endAt) }}</span
            >
            <span class="font-semibold tabular-nums">{{ Math.round(current.speed * 3.6) }} km/h</span>
        </div>
        <input
            type="range"
            class="accent-brand my-3 w-full"
            aria-label="Position in the trip"
            min="0"
            :max="track.points.length - 1"
            :value="position.index"
            :disabled="track.points.length < 2"
            @input="seek"
        />
        <div class="flex items-center gap-3">
            <div class="flex flex-1 overflow-hidden rounded-lg border border-neutral-800 text-sm">
                <button
                    v-for="option in PLAYBACK_SPEEDS"
                    :key="option"
                    class="flex-1 py-2"
                    :class="speed === option ? 'bg-brand font-semibold' : 'hover:bg-neutral-900'"
                    @click="speed = option"
                >
                    {{ option }}x
                </button>
            </div>
            <button
                class="rounded-lg border border-neutral-800 px-4 py-2 text-sm hover:bg-neutral-900"
                @click="emit('close')"
            >
                Close
            </button>
            <button
                class="bg-brand size-12 rounded-full text-lg"
                :aria-label="playing ? 'Pause' : 'Play'"
                @click="playing ? stop() : play()"
            >
                {{ playing ? '❚❚' : '▶' }}
            </button>
        </div>
    </div>
</template>
