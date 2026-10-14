<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import CheckpointsLayer from '../components/CheckpointsLayer.vue';
import EventsLayer from '../components/EventsLayer.vue';
import PeersMap from '../components/PeersMap.vue';
import ReplayLayer from '../components/ReplayLayer.vue';
import UserAvatar from '../components/UserAvatar.vue';
import TripHistory from '../components/history/TripHistory.vue';
import MapControlButton from '../components/map/MapControlButton.vue';
import MapControlGroup from '../components/map/MapControlGroup.vue';
import StatusPill from '../components/map/StatusPill.vue';
import PeopleSheet from '../components/people/PeopleSheet.vue';
import PersonDetail from '../components/people/PersonDetail.vue';
import PersonRow from '../components/people/PersonRow.vue';
import Icon from '../components/ui/Icon.vue';
import MenuItem from '../components/ui/MenuItem.vue';
import PopoverMenu from '../components/ui/PopoverMenu.vue';
import Spinner from '../components/ui/Spinner.vue';
import { useMediaQuery } from '../composables/useMediaQuery';
import { useNow } from '../composables/useNow';
import type { Insets } from '../lib/camera';
import { decodeJwt } from '../lib/jwt';
import { hasPosition, isStale } from '../lib/peers';
import { storage } from '../lib/storage';
import { MAP_STYLES, type MapStyle } from '../lib/tiles';
import { useCheckpointsStore } from '../stores/checkpoints';
import { useEventsStore } from '../stores/events';
import { useHistoryStore } from '../stores/history';
import { usePeersStore } from '../stores/peers';
import { useSessionStore } from '../stores/session';
import { useSharingStore } from '../stores/sharing';

const session = useSessionStore();
const peers = usePeersStore();
const checkpoints = useCheckpointsStore();
const events = useEventsStore();
const history = useHistoryStore();
const sharing = useSharingStore();
const router = useRouter();

const CHECKPOINTS_KEY = 'legacytracker.showCheckpoints';
const STYLE_KEY = 'legacytracker.mapStyle';
const EVENTS_REFRESH_MS = 5 * 60_000;
const SHEET_HEADER = 68;
let eventsTimer: ReturnType<typeof setInterval> | undefined;

const mapView = ref<InstanceType<typeof PeersMap> | null>(null);
const wide = useMediaQuery('(min-width: 768px)');
const viewportHeight = ref(window.innerHeight);
// Markers re-check staleness every few seconds; the panel's counters tick every second.
const mapNow = useNow();
const now = useNow(1_000);

const showCheckpoints = ref(storage.get(CHECKPOINTS_KEY) !== 'false');
const mapStyle = ref<MapStyle>(readStyle());
const styleMenu = ref(false);
const accountMenu = ref(false);
const sheetExpanded = ref(false);
const selectedId = ref<string | null>(null);
const view = ref<'people' | 'person' | 'history'>('people');

function readStyle(): MapStyle {
    const stored = storage.get(STYLE_KEY);
    return MAP_STYLES.some((s) => s.id === stored) ? (stored as MapStyle) : 'standard';
}

const selfId = computed(() => {
    const sub = session.accessToken ? decodeJwt(session.accessToken)?.sub : null;
    return typeof sub === 'string' ? sub : '';
});

// The app's list: you first, then everyone on the map, then those who hide from you.
const people = computed(() =>
    peers.list
        .filter((peer) => hasPosition(peer) || !peer.sharing)
        .sort((a, b) => {
            const rank = (id: string, sharing: boolean) => (id === selfId.value ? 0 : sharing ? 1 : 2);
            return rank(a.id, a.sharing) - rank(b.id, b.sharing) || a.name.localeCompare(b.name);
        })
);
const onMap = computed(() => people.value.filter(hasPosition));
const self = computed(() => peers.peers.get(selfId.value) ?? null);
const selected = computed(() => (selectedId.value ? (peers.peers.get(selectedId.value) ?? null) : null));
const replaying = computed(() => history.playing !== null);

const expandedHeight = computed(() => Math.round(viewportHeight.value * 0.6));
const insets = computed<Insets>(() =>
    wide.value
        ? { top: 72, right: 72, bottom: 16, left: 404 }
        : { top: 72, right: 0, bottom: sheetExpanded.value ? expandedHeight.value : SHEET_HEADER, left: 0 }
);

async function select(id: string) {
    selectedId.value = id;
    view.value = 'person';
    sheetExpanded.value = true;
    // Aim once the map knows how much the opened sheet covers.
    await nextTick();
    mapView.value?.focus(id);
}

function showPeople() {
    view.value = 'people';
}

function openHistory() {
    if (!selected.value) return;
    history.open(selected.value.id, selected.value.name);
    view.value = 'history';
}

function closeHistory() {
    history.close();
    view.value = selected.value ? 'person' : 'people';
}

function recenterOnSelf() {
    if (self.value && hasPosition(self.value)) mapView.value?.focus(self.value.id);
}

function toggleCheckpoints() {
    showCheckpoints.value = !showCheckpoints.value;
    storage.set(CHECKPOINTS_KEY, String(showCheckpoints.value));
}

function chooseStyle(style: MapStyle) {
    mapStyle.value = style;
    storage.set(STYLE_KEY, style);
    styleMenu.value = false;
}

// A hidden tab is not a map anyone is looking at: tell the server so phones can stop streaming.
function onVisibility() {
    const visible = document.visibilityState === 'visible';
    peers.setMapActive(visible);
    // Nothing tells a browser its socket died silently; coming back always starts fresh.
    if (visible) {
        peers.reconnect();
        void events.refresh();
    }
}

function onOnline() {
    peers.reconnect();
}

function onResize() {
    viewportHeight.value = window.innerHeight;
}

async function signOut() {
    await session.logout();
    await router.replace({ name: 'login' });
}

onMounted(() => {
    peers.start();
    void checkpoints.load();
    void events.refresh();
    void sharing.load();
    eventsTimer = setInterval(() => {
        if (document.visibilityState === 'visible') void events.refresh();
    }, EVENTS_REFRESH_MS);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('online', onOnline);
    window.addEventListener('resize', onResize);
    // The tab may have been opened in the background.
    if (document.visibilityState !== 'visible') peers.setMapActive(false);
});

onBeforeUnmount(() => {
    document.removeEventListener('visibilitychange', onVisibility);
    window.removeEventListener('online', onOnline);
    window.removeEventListener('resize', onResize);
    clearInterval(eventsTimer);
    peers.stop();
    history.close();
    events.reset();
    sharing.reset();
});

// The server refusing us flips the session into its denied state; follow it.
watch(
    () => session.accessDenial,
    (denial) => {
        if (denial) void router.replace({ name: 'access-denied' });
    }
);

// A replay wants the map: fold the sheet away on phones.
watch(replaying, (isReplaying) => {
    if (isReplaying && !wide.value) sheetExpanded.value = false;
});
</script>

<template>
    <div class="bg-surface relative h-full overflow-hidden">
        <PeersMap
            ref="mapView"
            :peers="onMap"
            :self-id="selfId"
            :selected-id="selectedId"
            :now="mapNow"
            :map-style="mapStyle"
            :insets="insets"
            :hidden="replaying"
            @select="select"
        >
            <CheckpointsLayer v-if="showCheckpoints && !replaying" :checkpoints="checkpoints.checkpoints" />
            <EventsLayer v-if="events.available && events.enabled && !replaying" :events="events.events" />
            <ReplayLayer
                v-if="history.playing && history.userId"
                :key="history.playing.session.startAt"
                :user-id="history.userId"
                :user-name="history.userName"
                :session="history.playing.session"
                :track="history.playing.track"
                @close="history.stopReplay()"
            />
        </PeersMap>

        <div class="absolute top-3 z-[1000]" :class="wide ? 'left-[404px]' : 'left-4'">
            <StatusPill :status="peers.status" />
        </div>

        <div class="absolute top-3 right-3 z-[1001] flex flex-col items-end gap-3">
            <PopoverMenu v-model="accountMenu">
                <template #trigger>
                    <button
                        class="bg-surface-container-high flex size-12 items-center justify-center rounded-full shadow-[0_4px_12px_rgb(0_0_0/0.4)]"
                        :aria-label="`Account: ${session.username}`"
                        :title="session.username"
                        @click="accountMenu = !accountMenu"
                    >
                        <UserAvatar :user-id="selfId" :name="session.username || '?'" :size="40" />
                    </button>
                </template>
                <div class="flex items-center gap-3 px-4 pt-2 pb-3">
                    <UserAvatar :user-id="selfId" :name="session.username || '?'" :size="40" />
                    <div class="min-w-0">
                        <p class="type-title-sm truncate">{{ session.username }}</p>
                        <p class="type-body-sm text-on-surface-variant">Legacy account</p>
                    </div>
                </div>
                <div class="bg-outline-variant mx-3 mb-2 h-px" />
                <MenuItem icon="logout" label="Sign out" @click="signOut" />
            </PopoverMenu>

            <MapControlGroup>
                <PopoverMenu v-model="styleMenu">
                    <template #trigger>
                        <MapControlButton icon="layers" label="Map style" @click="styleMenu = !styleMenu" />
                    </template>
                    <MenuItem
                        v-for="option in MAP_STYLES"
                        :key="option.id"
                        :icon="option.id === 'satellite' ? 'satellite' : option.id === 'terrain' ? 'landscape' : 'map'"
                        :label="option.label"
                        :checked="option.id === mapStyle"
                        @click="chooseStyle(option.id)"
                    />
                </PopoverMenu>
                <MapControlButton
                    v-if="self && hasPosition(self)"
                    :icon="mapView?.following === selfId ? 'myLocation' : 'locationSearching'"
                    label="My location"
                    @click="recenterOnSelf"
                />
                <MapControlButton icon="fitAll" label="Show everyone" @click="mapView?.fitEveryone()" />
                <MapControlButton
                    v-if="events.available"
                    :icon="events.enabled ? 'event' : 'eventBusy'"
                    :label="events.enabled ? 'Hide events' : 'Show events'"
                    :active="events.enabled"
                    @click="events.setEnabled(!events.enabled)"
                />
                <MapControlButton
                    :icon="showCheckpoints ? 'place' : 'locationOff'"
                    :label="showCheckpoints ? 'Hide saved places' : 'Show saved places'"
                    :active="showCheckpoints"
                    @click="toggleCheckpoints"
                />
            </MapControlGroup>
        </div>

        <div v-if="wide" class="absolute right-3 bottom-8 z-[1000]">
            <MapControlGroup>
                <MapControlButton icon="add" label="Zoom in" @click="mapView?.zoomBy(1)" />
                <MapControlButton icon="remove" label="Zoom out" @click="mapView?.zoomBy(-1)" />
            </MapControlGroup>
        </div>

        <PeopleSheet
            v-model:expanded="sheetExpanded"
            :wide="wide"
            :collapsed-height="SHEET_HEADER"
            :expanded-height="expandedHeight"
        >
            <template #header>
                <template v-if="view === 'people' || (view === 'person' && !selected)">
                    <h2 class="type-title-md font-bold">People</h2>
                    <span
                        class="bg-secondary-container text-on-secondary-container type-label-md ml-2 rounded-full px-2 py-0.5 font-bold"
                        >{{ people.length }}</span
                    >
                    <span class="ml-auto flex">
                        <span
                            v-for="(peer, i) in people.slice(0, 4)"
                            :key="peer.id"
                            class="relative"
                            :style="{ marginLeft: i ? '-8px' : '0', zIndex: 4 - i }"
                        >
                            <UserAvatar
                                :user-id="peer.id"
                                :name="peer.name"
                                :size="28"
                                ring-color="var(--color-surface-container-low)"
                                :ring-width="2"
                                :dimmed="isStale(peer, mapNow)"
                            />
                        </span>
                    </span>
                </template>
                <template v-else>
                    <button
                        class="-ml-2 flex size-10 items-center justify-center rounded-full hover:bg-white/6"
                        :aria-label="view === 'history' ? 'Back' : 'All people'"
                        @click="view === 'history' ? closeHistory() : showPeople()"
                    >
                        <Icon name="arrowBack" />
                    </button>
                    <div v-if="view === 'history'" class="ml-1.5 min-w-0">
                        <h2 class="type-title-md leading-tight font-bold">Trip history</h2>
                        <p class="type-body-sm text-on-surface-variant truncate">{{ history.userName }}</p>
                    </div>
                    <h2 v-else class="type-title-md ml-1.5">All people</h2>
                </template>
            </template>

            <TripHistory v-if="view === 'history'" />
            <PersonDetail
                v-else-if="view === 'person' && selected"
                :key="selected.id"
                :peer="selected"
                :self="selected.id === selfId"
                :now="now"
                @history="openHistory"
            />
            <div v-else class="px-3 pb-4">
                <div v-if="!peers.loaded" class="text-primary flex justify-center p-6"><Spinner :size="28" /></div>
                <p v-else-if="people.length === 0" class="type-body-md text-on-surface-variant p-4 text-center">
                    Nobody is sharing yet.
                </p>
                <div v-else class="space-y-1">
                    <PersonRow
                        v-for="peer in people"
                        :key="peer.id"
                        :peer="peer"
                        :self="peer.id === selfId"
                        :selected="peer.id === selectedId"
                        :now="now"
                        @select="select(peer.id)"
                    />
                </div>
            </div>
        </PeopleSheet>
    </div>
</template>
