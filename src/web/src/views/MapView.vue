<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import CheckpointsLayer from '../components/CheckpointsLayer.vue';
import EventsLayer from '../components/EventsLayer.vue';
import PeersMap from '../components/PeersMap.vue';
import PlaceDraftLayer, { type PlaceDraft } from '../components/places/PlaceDraftLayer.vue';
import PlacesPanel from '../components/places/PlacesPanel.vue';
import ReplayLayer from '../components/ReplayLayer.vue';
import UserAvatar from '../components/UserAvatar.vue';
import ApiTokensDialog from '../components/account/ApiTokensDialog.vue';
import TripHistory from '../components/history/TripHistory.vue';
import TravelLeaderboard from '../components/travel/TravelLeaderboard.vue';
import MapControlButton from '../components/map/MapControlButton.vue';
import MapControlGroup from '../components/map/MapControlGroup.vue';
import StatusPill from '../components/map/StatusPill.vue';
import ViewersStack from '../components/map/ViewersStack.vue';
import PeopleSheet from '../components/people/PeopleSheet.vue';
import PersonDetail from '../components/people/PersonDetail.vue';
import PersonRow from '../components/people/PersonRow.vue';
import AppearanceDialog from '../components/ui/AppearanceDialog.vue';
import Icon from '../components/ui/Icon.vue';
import MenuItem from '../components/ui/MenuItem.vue';
import MapVariantPicker from '../components/ui/MapVariantPicker.vue';
import PopoverMenu from '../components/ui/PopoverMenu.vue';
import Spinner from '../components/ui/Spinner.vue';
import { useMediaQuery } from '../composables/useMediaQuery';
import { useNow } from '../composables/useNow';
import { config } from '../config';
import type { Insets } from '../lib/camera';
import { moveFocus } from '../lib/focus';
import { decodeJwt } from '../lib/jwt';
import { hasPosition } from '../lib/peers';
import { storage } from '../lib/storage';
import { useAppearanceStore } from '../stores/appearance';
import { resolveMapPreset, MAP_STYLES, type MapStyle } from '../lib/styles';
import { useCheckpointsStore } from '../stores/checkpoints';
import { useEventsStore } from '../stores/events';
import { useHistoryStore } from '../stores/history';
import { useLeaderboardStore } from '../stores/leaderboard';
import { usePeersStore } from '../stores/peers';
import { useSessionStore } from '../stores/session';
import { useSharingStore } from '../stores/sharing';

const session = useSessionStore();
const appearance = useAppearanceStore();
const peers = usePeersStore();
const checkpoints = useCheckpointsStore();
const events = useEventsStore();
const history = useHistoryStore();
const sharing = useSharingStore();
const leaderboard = useLeaderboardStore();
const router = useRouter();

const CHECKPOINTS_KEY = 'legacytracker.showCheckpoints';
const ORIENTATION_LOCK_KEY = 'legacytracker.orientationLocked';
const VIEW_3D_KEY = 'legacytracker.view3d';
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
const orientationLocked = ref(storage.get(ORIENTATION_LOCK_KEY) !== 'false');
const view3d = ref(storage.get(VIEW_3D_KEY) === 'true');
const mapStyle = ref<MapStyle>(readStyle());
// Re-evaluated as `now` ticks, so Auto crosses into dawn/day/dusk/night on its own.
const lightPreset = computed(() => resolveMapPreset(appearance.mapVariant, now.value));
const styleMenu = ref(false);
const accountMenu = ref(false);
const appearanceOpen = ref(false);
const apiTokensOpen = ref(false);
const sheetExpanded = ref(false);
const selectedId = ref<string | null>(null);
const view = ref<'people' | 'person' | 'history' | 'travel' | 'places'>('people');
// The saved place being drawn in the editor, and what is under the crosshair meanwhile.
const placeDraft = ref<PlaceDraft | null>(null);
const crosshair = ref<{ latitude: number; longitude: number } | null>(null);
const draftLayer = ref<InstanceType<typeof PlaceDraftLayer> | null>(null);

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

function select(id: string) {
    selectedId.value = id;
    view.value = 'person';
    sheetExpanded.value = true;
}

function showPeople() {
    selectedId.value = null;
    view.value = 'people';
}

// Leaving the tab drops the editor with it.
watch(view, (now) => {
    if (now !== 'places') placeDraft.value = null;
});

function showPlaces() {
    selectedId.value = null;
    view.value = 'places';
    sheetExpanded.value = true;
}

// 'people' also covers the selected-person view's list, which is not a tab of its own.
function tabActive(id: 'people' | 'travel' | 'places'): boolean {
    return id === 'travel'
        ? view.value === 'travel'
        : id === 'places'
          ? view.value === 'places'
          : view.value !== 'travel' && view.value !== 'places';
}

// Arrow keys move between the panel's tabs and select as they go (automatic activation).
function onTabKey(event: KeyboardEvent) {
    moveFocus(event, '[role="tab"]')?.click();
}

function onCrosshair(latitude: number, longitude: number) {
    crosshair.value = { latitude, longitude };
}

// The viewer moved the map themselves, so nobody they picked is on screen any more:
// let go of the highlight, the camera and the details the marker opened.
function deselect() {
    selectedId.value = null;
    if (view.value === 'person') view.value = 'people';
}

function showTravel() {
    view.value = 'travel';
    // On phones the leaderboard needs the room; the people list is fine peeking.
    sheetExpanded.value = true;
    leaderboard.open();
}

function openHistory() {
    if (!selected.value) return;
    history.open(selected.value.id, selected.value.name, selected.value.id === selfId.value);
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

function toggleOrientationLock() {
    orientationLocked.value = !orientationLocked.value;
    storage.set(ORIENTATION_LOCK_KEY, String(orientationLocked.value));
}

function toggleView3d() {
    view3d.value = !view3d.value;
    storage.set(VIEW_3D_KEY, String(view3d.value));
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

function openAppearance() {
    accountMenu.value = false;
    appearanceOpen.value = true;
}

function openApiTokens() {
    accountMenu.value = false;
    apiTokensOpen.value = true;
}

function openDocs() {
    accountMenu.value = false;
    window.open(router.resolve({ name: 'docs' }).href, '_blank', 'noopener');
}

// Name, picture and credentials live in Legacy Auth, not in the tracker.
function openProfile() {
    accountMenu.value = false;
    window.open(`${config.authUrl}/settings`, '_blank', 'noopener');
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
    leaderboard.reset();
});

// The session can end under us: refused refresh, lost access, sign-out in another tab or app.
watch(
    () => session.isAuthenticated,
    (signedIn) => {
        if (!signedIn) void router.replace({ name: 'login' });
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
            :light-preset="lightPreset"
            :insets="insets"
            :hidden="replaying"
            :orientation-locked="orientationLocked"
            :view3d="view3d"
            @select="select"
            @deselect="deselect"
        >
            <CheckpointsLayer
                v-if="(showCheckpoints || view === 'places') && !replaying"
                :checkpoints="checkpoints.checkpoints"
            />
            <PlaceDraftLayer
                v-if="view === 'places' && !replaying"
                ref="draftLayer"
                :draft="placeDraft"
                @move="onCrosshair"
            />
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

        <!-- The point a saved place is set on, in the middle of the part of the map nothing covers. -->
        <div
            v-if="placeDraft && view === 'places'"
            class="pointer-events-none absolute z-[1000] flex items-center justify-center"
            :style="{
                top: `${insets.top}px`,
                right: `${insets.right}px`,
                bottom: `${insets.bottom}px`,
                left: `${insets.left}px`
            }"
            data-crosshair
        >
            <Icon name="add" :size="32" class="text-primary" />
        </div>

        <div class="absolute top-3 z-[1000] flex items-center gap-2" :class="wide ? 'left-[404px]' : 'left-4'">
            <StatusPill :status="peers.status" />
            <ViewersStack :viewers="peers.viewers" :self-id="selfId" />
        </div>

        <div class="absolute top-3 right-3 z-[1001] flex flex-col items-end gap-3">
            <PopoverMenu v-model="accountMenu">
                <template #trigger>
                    <button
                        class="bg-surface-container-high flex size-12 items-center justify-center rounded-full shadow-[0_4px_12px_color-mix(in_srgb,var(--color-shadow)_40%,transparent)]"
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
                <MenuItem icon="person" label="Manage profile" @click="openProfile" />
                <MenuItem icon="palette" label="Appearance" @click="openAppearance" />
                <MenuItem icon="api" label="API tokens" @click="openApiTokens" />
                <MenuItem icon="menuBook" label="API documentation" @click="openDocs" />
                <div class="bg-outline-variant mx-3 my-2 h-px" />
                <MenuItem icon="logout" label="Sign out" @click="signOut" />
            </PopoverMenu>

            <MapControlGroup>
                <PopoverMenu v-model="styleMenu">
                    <template #trigger>
                        <MapControlButton icon="layers" label="Layers" @click="styleMenu = !styleMenu" />
                    </template>
                    <MenuItem
                        v-for="option in MAP_STYLES"
                        :key="option.id"
                        :icon="option.id === 'satellite' ? 'satellite' : 'map'"
                        :label="option.label"
                        :checked="option.id === mapStyle"
                        @click="chooseStyle(option.id)"
                    />
                    <div class="bg-outline-variant mx-3 my-2 h-px" />
                    <p class="type-body-sm text-on-surface-variant px-4 pb-2">
                        Map lighting &middot; Auto follows the time of day
                    </p>
                    <div class="px-4 pb-4">
                        <MapVariantPicker />
                    </div>
                    <div class="bg-outline-variant mx-3 mb-2 h-px" />
                    <MenuItem
                        icon="explore"
                        label="Lock orientation"
                        :checked="orientationLocked"
                        @click="toggleOrientationLock"
                    />
                    <MenuItem icon="view3d" label="3D view" :checked="view3d" @click="toggleView3d" />
                    <MenuItem
                        v-if="events.available"
                        icon="event"
                        label="Events"
                        :checked="events.enabled"
                        @click="events.setEnabled(!events.enabled)"
                    />
                    <MenuItem icon="place" label="Saved places" :checked="showCheckpoints" @click="toggleCheckpoints" />
                </PopoverMenu>
                <MapControlButton icon="fitAll" label="Show everyone" @click="mapView?.fitEveryone()" />
            </MapControlGroup>
            <!-- Only when the map can be turned and no longer faces north. -->
            <MapControlGroup v-if="!orientationLocked && Math.abs(mapView?.bearing ?? 0) > 0.5">
                <MapControlButton icon="explore" label="Reset north" @click="mapView?.resetNorth()" />
            </MapControlGroup>
        </div>

        <!-- Bottom right, clear of the Mapbox attribution: under the zoom buttons on wide screens, above the sheet on phones. -->
        <div
            class="absolute right-3 z-[1000] flex flex-col items-end gap-3 transition-[bottom] duration-200"
            :class="wide ? 'bottom-8' : undefined"
            :style="wide ? undefined : { bottom: `${(sheetExpanded ? expandedHeight : SHEET_HEADER) + 12}px` }"
        >
            <MapControlGroup v-if="wide">
                <MapControlButton icon="add" label="Zoom in" @click="mapView?.zoomBy(1)" />
                <MapControlButton icon="remove" label="Zoom out" @click="mapView?.zoomBy(-1)" />
            </MapControlGroup>
            <MapControlGroup v-if="self && hasPosition(self)">
                <MapControlButton
                    :icon="mapView?.following === selfId ? 'myLocation' : 'locationSearching'"
                    label="My location"
                    @click="recenterOnSelf"
                />
            </MapControlGroup>
        </div>

        <PeopleSheet
            v-model:expanded="sheetExpanded"
            :wide="wide"
            :collapsed-height="SHEET_HEADER"
            :expanded-height="expandedHeight"
        >
            <template #header>
                <template
                    v-if="
                        view === 'people' || view === 'travel' || view === 'places' || (view === 'person' && !selected)
                    "
                >
                    <template v-if="view === 'travel'">
                        <h2 class="type-title-md font-bold">Travel</h2>
                    </template>
                    <template v-else-if="view === 'places'">
                        <h2 class="type-title-md font-bold">Checkpoints</h2>
                    </template>
                    <template v-else>
                        <h2 class="type-title-md font-bold">People</h2>
                        <span
                            class="bg-secondary-container text-on-secondary-container type-label-md ml-2 rounded-full px-2 py-0.5 font-bold"
                            >{{ people.length }}</span
                        >
                    </template>
                    <!-- Switches the panel between the people list and the travel leaderboard. -->
                    <span
                        class="bg-surface-container-high ml-auto flex rounded-full p-1"
                        role="tablist"
                        aria-label="Panel"
                        @keydown="onTabKey"
                    >
                        <button
                            v-for="option in [
                                { id: 'people', icon: 'group', label: 'People' },
                                { id: 'travel', icon: 'directionsCar', label: 'Travel' },
                                { id: 'places', icon: 'place', label: 'Checkpoints' }
                            ] as const"
                            :key="option.id"
                            class="flex h-11 w-12 items-center justify-center rounded-full transition-colors"
                            :class="
                                tabActive(option.id)
                                    ? 'bg-secondary-container text-on-secondary-container'
                                    : 'text-on-surface-variant hover:bg-on-surface/6'
                            "
                            role="tab"
                            :id="`panel-tab-${option.id}`"
                            aria-controls="panel-tabpanel"
                            :aria-selected="tabActive(option.id)"
                            :tabindex="tabActive(option.id) ? 0 : -1"
                            :aria-label="option.label"
                            :title="option.label"
                            :data-view="option.id"
                            @click="
                                option.id === 'travel'
                                    ? showTravel()
                                    : option.id === 'places'
                                      ? showPlaces()
                                      : showPeople()
                            "
                        >
                            <Icon :name="option.icon" :size="20" />
                        </button>
                    </span>
                </template>
                <template v-else>
                    <button
                        class="hover:bg-on-surface/6 -ml-2 flex size-10 items-center justify-center rounded-full"
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

            <div
                id="panel-tabpanel"
                class="contents"
                :role="view === 'history' ? undefined : 'tabpanel'"
                :aria-labelledby="
                    view === 'history'
                        ? undefined
                        : `panel-tab-${tabActive('travel') ? 'travel' : tabActive('places') ? 'places' : 'people'}`
                "
            >
                <TripHistory v-if="view === 'history'" />
                <TravelLeaderboard v-else-if="view === 'travel'" :self-id="selfId" />
                <PlacesPanel
                    v-else-if="view === 'places'"
                    :cursor="crosshair"
                    @draft="placeDraft = $event"
                    @goto="(lat, lng) => draftLayer?.goto(lat, lng)"
                />
                <PersonDetail
                    v-else-if="view === 'person' && selected"
                    :key="selected.id"
                    :peer="selected"
                    :self="selected.id === selfId"
                    :now="now"
                    :viewer="self && hasPosition(self) ? { lat: self.latitude!, lng: self.longitude! } : null"
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
            </div>
        </PeopleSheet>

        <AppearanceDialog v-model="appearanceOpen" />
        <ApiTokensDialog v-if="apiTokensOpen" @close="apiTokensOpen = false" />
    </div>
</template>
