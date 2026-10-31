<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import PresenceAvatar from './PresenceAvatar.vue';
import StatusChip from './StatusChip.vue';
import TrackingIssuesBanner from './TrackingIssuesBanner.vue';
import PlaceLabel from '../PlaceLabel.vue';
import Icon from '../ui/Icon.vue';
import StatCard from '../ui/StatCard.vue';
import Switch from '../ui/Switch.vue';
import { fetchSessions, type HistorySession } from '../../api/history';
import { metersBetween } from '../../lib/clusters';
import { formatDistance, formatUpdatedAgo } from '../../lib/format';
import { batteryIcon } from '../../lib/icons';
import { directionsUrl } from '../../lib/navigation';
import { hasPosition, isStale, type Peer } from '../../lib/peers';
import { presence } from '../../lib/presence';
import { showToast } from '../../lib/toast';
import { addDays, startOfDay } from '../../stores/history';
import { UNREACHABLE_MESSAGE, usePeersStore } from '../../stores/peers';
import { useSharingStore } from '../../stores/sharing';

// `viewer` is where the viewer's own phone last reported; the browser never reads their position.
const props = defineProps<{ peer: Peer; self: boolean; now: number; viewer?: { lat: number; lng: number } | null }>();
const emit = defineEmits<{ history: [] }>();

const sharing = useSharingStore();
const stale = computed(() => isStale(props.peer, props.now));
const here = computed(() => presence(props.peer, props.now));
const battery = computed(() => props.peer.batteryLevel);
const charging = computed(() => props.peer.isCharging === true);
// When their position last reached the server; `now` ticks, so this stays current.
const updated = computed(() => {
    const sent = props.peer.lastSeenAt ?? props.peer.recordedAt;
    return hasPosition(props.peer) && sent !== null ? `Updated ${formatUpdatedAgo(props.now - sent)}` : null;
});

// Straight-line distance to them, and a link that opens directions to where they are.
const navigateTo = computed(() =>
    !props.self && hasPosition(props.peer) ? directionsUrl(props.peer.latitude!, props.peer.longitude!) : null
);
const distance = computed(() =>
    navigateTo.value && props.viewer
        ? formatDistance(metersBetween(props.viewer, { lat: props.peer.latitude!, lng: props.peer.longitude! }))
        : null
);

// Today's trips, summarised like the app: count, top speed, and the duration-weighted average of
// each trip's own average speed (so short hops don't dilute a long drive).
const today = ref<HistorySession[] | null>(null);
const todayFailed = ref(false);
let request = 0;

async function loadToday() {
    const mine = ++request;
    today.value = null;
    todayFailed.value = false;
    if (!props.peer.sharing) return;
    const start = startOfDay(new Date());
    try {
        const sessions = await fetchSessions(props.peer.id, start, addDays(start, 1), false);
        if (mine === request) today.value = sessions;
    } catch {
        if (mine === request) todayFailed.value = true;
    }
}

// Per field: the peer object itself is replaced on every stream update.
watch([() => props.peer.id, () => props.peer.sharing], loadToday, { immediate: true });

const summary = computed(() => {
    const sessions = today.value ?? [];
    const seconds = sessions.reduce((sum, s) => sum + s.durationSeconds, 0);
    return {
        trips: sessions.length,
        topKmh: Math.max(0, ...sessions.map((s) => s.topSpeed)) * 3.6,
        avgKmh: seconds > 0 ? (sessions.reduce((sum, s) => sum + s.avgSpeed * s.durationSeconds, 0) / seconds) * 3.6 : 0
    };
});

function todayValue(text: string): string {
    if (todayFailed.value) return '—';
    return today.value === null ? '…' : text;
}

// Phones can stop reporting under battery management; this wakes one on demand. The spinner
// runs until the phone answers, and a failure is a toast since the request outlives any inline hint.
const peersStore = usePeersStore();
const refreshing = ref(false);

async function forceRefresh() {
    if (refreshing.value) return;
    refreshing.value = true;
    try {
        await peersStore.refreshLocation(props.peer.id, props.peer.name);
    } catch (error) {
        showToast(error instanceof Error ? error.message : UNREACHABLE_MESSAGE);
    } finally {
        refreshing.value = false;
    }
}

// Hiding your location from someone is an account setting: it applies to your phone too.
const sharingBusy = ref(false);
const sharingError = ref<string | null>(null);
const sharingWith = computed({
    get: () => sharing.isSharingWith(props.peer.id),
    set: (enabled: boolean) => void changeSharing(enabled)
});

async function changeSharing(enabled: boolean) {
    sharingBusy.value = true;
    sharingError.value = null;
    try {
        await sharing.setSharing(props.peer.id, enabled);
    } catch (error) {
        sharingError.value = error instanceof Error ? error.message : 'Could not change sharing.';
    } finally {
        sharingBusy.value = false;
    }
}
</script>

<template>
    <div class="px-5 pt-1 pb-5">
        <TrackingIssuesBanner v-if="peer.sharing" :issues="peer.trackingIssues" :name="peer.name" :self="self" />
        <div class="flex items-center gap-3.5">
            <PresenceAvatar :user-id="peer.id" :name="peer.name" :size="52" :stale="stale" />
            <div class="min-w-0 flex-1">
                <h2 class="type-title-lg truncate font-bold">{{ peer.name }}<template v-if="self"> (you)</template></h2>
                <PlaceLabel
                    v-if="hasPosition(peer)"
                    class="type-body-md text-on-surface-variant mt-0.5"
                    :subject="`detail:${peer.id}`"
                    :latitude="peer.latitude!"
                    :longitude="peer.longitude!"
                />
                <p v-if="updated" class="type-body-sm text-on-surface-variant">{{ updated }}</p>
            </div>
            <button
                v-if="peer.sharing"
                class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 shrink-0 items-center justify-center rounded-full disabled:hover:bg-transparent"
                :class="{ 'text-primary': refreshing }"
                :disabled="refreshing"
                :aria-busy="refreshing"
                :aria-label="`Force location update for ${peer.name}`"
                @click="forceRefresh"
            >
                <Icon name="refresh" :class="{ 'animate-spin': refreshing }" />
            </button>
        </div>

        <a
            v-if="navigateTo"
            :href="navigateTo"
            target="_blank"
            rel="noopener noreferrer"
            class="bg-secondary-container text-on-secondary-container mt-3 inline-flex h-11 items-center gap-2 rounded-full px-4 text-[15px] font-semibold transition hover:brightness-110"
            :aria-label="`Navigate to ${peer.name}${distance ? `, ${distance} away` : ''}`"
        >
            <Icon name="directions" :size="22" />
            <span>{{ distance ?? 'Navigate' }}</span>
        </a>

        <div v-if="!peer.sharing" class="mt-3 flex flex-wrap gap-1.5">
            <StatusChip icon="visibilityOff" label="Not sharing with you" color="var(--color-hidden)" />
        </div>

        <div v-if="!self && sharing.loaded" class="mt-3 flex items-center gap-4 py-2">
            <Icon name="shareLocation" class="text-on-surface-variant" />
            <div class="min-w-0 flex-1">
                <p class="type-body-lg">Share my location with {{ peer.name }}</p>
                <p class="type-body-md text-on-surface-variant">
                    {{ peer.name }} {{ sharingWith ? 'can' : "can't" }} see you on the map
                </p>
                <p v-if="sharingError" role="alert" class="type-body-sm text-error mt-1">{{ sharingError }}</p>
            </div>
            <Switch v-model="sharingWith" :disabled="sharingBusy" :label="`Share my location with ${peer.name}`" />
        </div>

        <p v-if="!peer.sharing" class="type-body-md text-on-surface-variant mt-[18px]">
            {{ peer.name }} isn't sharing their location with you.
        </p>
        <div v-else-if="hasPosition(peer)" class="mt-[18px] grid grid-cols-3 gap-2.5">
            <StatCard icon="speed" label="Speed" :value="`${Math.round(peer.speed * 3.6)} km/h`" />
            <StatCard
                :icon="charging ? 'batteryCharging' : batteryIcon(battery, false)"
                :label="charging ? 'Charging' : 'Battery'"
                :value="battery === null ? '—' : `${battery}%`"
            />
            <StatCard :icon="here.icon" :label="here.label" :value="here.value" />
        </div>
        <p v-else class="type-body-md mt-[18px]">No recent location</p>

        <template v-if="peer.sharing">
            <h3 class="type-title-sm mt-[22px] font-bold">Today</h3>
            <div class="mt-2.5 grid grid-cols-3 gap-2.5">
                <StatCard
                    icon="route"
                    :label="summary.trips === 1 ? 'Trip' : 'Trips'"
                    :value="todayValue(String(summary.trips))"
                />
                <StatCard
                    icon="trendingUp"
                    label="Top speed"
                    :value="todayValue(`${Math.round(summary.topKmh)} km/h`)"
                />
                <StatCard
                    icon="speedOutlined"
                    label="Avg speed"
                    :value="todayValue(`${Math.round(summary.avgKmh)} km/h`)"
                />
            </div>
            <button
                class="bg-secondary-container text-on-secondary-container mt-[22px] flex h-[52px] w-full items-center justify-center gap-2 rounded-lg text-[15px] font-semibold transition hover:brightness-110"
                @click="emit('history')"
            >
                <Icon name="calendarMonth" :size="20" />
                Trip history
            </button>
        </template>
    </div>
</template>
