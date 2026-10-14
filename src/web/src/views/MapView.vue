<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import PeersMap from '../components/PeersMap.vue';
import UsersList from '../components/UsersList.vue';
import CheckpointsLayer from '../components/CheckpointsLayer.vue';
import EventsLayer from '../components/EventsLayer.vue';
import ReplayLayer from '../components/ReplayLayer.vue';
import ReplayPanel from '../components/ReplayPanel.vue';
import { useNow } from '../composables/useNow';
import { decodeJwt } from '../lib/jwt';
import { storage } from '../lib/storage';
import { useCheckpointsStore } from '../stores/checkpoints';
import { useEventsStore } from '../stores/events';
import { usePeersStore } from '../stores/peers';
import { useReplayStore } from '../stores/replay';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const peers = usePeersStore();
const checkpoints = useCheckpointsStore();
const events = useEventsStore();
const replay = useReplayStore();
const router = useRouter();
const CHECKPOINTS_KEY = 'legacytracker.showCheckpoints';
const showCheckpoints = ref(storage.get(CHECKPOINTS_KEY) !== 'false');
const EVENTS_REFRESH_MS = 5 * 60_000;
let eventsTimer: ReturnType<typeof setInterval> | undefined;
const now = useNow();
const selectedId = ref<string | null>(null);
const drawerOpen = ref(false);

const selfId = computed(() => {
    const sub = session.accessToken ? decodeJwt(session.accessToken)?.sub : null;
    return typeof sub === 'string' ? sub : '';
});

// People who are on the map first, then the rest, each alphabetically.
const sorted = computed(() =>
    [...peers.list].sort((a, b) => {
        const placed = Number(b.latitude !== null) - Number(a.latitude !== null);
        return placed || a.name.localeCompare(b.name);
    })
);

const statusLabel = computed(() => {
    if (peers.status === 'open') return 'Live';
    return peers.status === 'connecting' ? 'Connecting…' : 'Offline';
});

function select(id: string) {
    selectedId.value = id;
    drawerOpen.value = false;
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

function openHistory(id: string) {
    const peer = peers.peers.get(id);
    if (peer) replay.open(peer.id, peer.name);
    drawerOpen.value = true;
}

function toggleCheckpoints(event: Event) {
    showCheckpoints.value = (event.target as HTMLInputElement).checked;
    storage.set(CHECKPOINTS_KEY, String(showCheckpoints.value));
}

function onOnline() {
    peers.reconnect();
}

async function signOut() {
    await session.logout();
    await router.replace({ name: 'login' });
}

onMounted(() => {
    peers.start();
    void checkpoints.load();
    void events.refresh();
    eventsTimer = setInterval(() => {
        if (document.visibilityState === 'visible') void events.refresh();
    }, EVENTS_REFRESH_MS);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('online', onOnline);
    // The tab may have been opened in the background.
    if (document.visibilityState !== 'visible') peers.setMapActive(false);
});

onBeforeUnmount(() => {
    document.removeEventListener('visibilitychange', onVisibility);
    window.removeEventListener('online', onOnline);
    clearInterval(eventsTimer);
    peers.stop();
    replay.close();
    events.reset();
});

// The server refusing us flips the session into its denied state; follow it.
watch(
    () => session.accessDenial,
    (denial) => {
        if (denial) void router.replace({ name: 'access-denied' });
    }
);
</script>

<template>
    <div class="flex h-full">
        <aside
            class="absolute inset-y-0 left-0 z-[1100] flex w-80 max-w-[85vw] flex-col border-r border-neutral-900 bg-black transition-transform md:static md:translate-x-0"
            :class="drawerOpen ? 'translate-x-0' : '-translate-x-full'"
        >
            <header class="flex items-center justify-between border-b border-neutral-900 px-4 py-3">
                <div>
                    <h1 class="font-semibold">Legacy Tracker</h1>
                    <p class="text-xs text-neutral-500">
                        <span
                            class="mr-1 inline-block size-2 rounded-full"
                            :class="peers.status === 'open' ? 'bg-green-500' : 'bg-amber-500'"
                        />{{ statusLabel }} · {{ session.username }}
                    </p>
                </div>
                <button class="rounded-lg border border-neutral-800 px-3 py-1 text-sm" @click="signOut">
                    Sign out
                </button>
            </header>
            <ReplayPanel v-if="replay.active" class="flex-1 overflow-y-auto" />
            <div v-else class="flex-1 overflow-y-auto">
                <fieldset class="flex flex-wrap gap-x-4 gap-y-1 border-b border-neutral-900 px-4 py-3 text-sm">
                    <legend class="sr-only">Map layers</legend>
                    <label class="flex items-center gap-2">
                        <input
                            type="checkbox"
                            class="accent-brand"
                            :checked="showCheckpoints"
                            @change="toggleCheckpoints"
                        />
                        Saved places
                    </label>
                    <label v-if="events.available" class="flex items-center gap-2">
                        <input
                            type="checkbox"
                            class="accent-brand"
                            :checked="events.enabled"
                            @change="events.setEnabled(($event.target as HTMLInputElement).checked)"
                        />
                        Events
                    </label>
                </fieldset>
                <p v-if="!peers.loaded" class="p-4 text-sm text-neutral-500">Loading…</p>
                <p v-else-if="sorted.length === 0" class="p-4 text-sm text-neutral-500">Nobody here yet.</p>
                <UsersList
                    v-else
                    :peers="sorted"
                    :self-id="selfId"
                    :selected-id="selectedId"
                    :now="now"
                    @select="select"
                    @history="openHistory"
                />
            </div>
        </aside>
        <main class="relative flex-1">
            <PeersMap :peers="sorted" :self-id="selfId" :selected-id="selectedId" :now="now" @select="select">
                <CheckpointsLayer v-if="showCheckpoints" :checkpoints="checkpoints.checkpoints" />
                <EventsLayer v-if="events.available && events.enabled" :events="events.events" :now="now" />
                <ReplayLayer
                    v-if="replay.playing && replay.userId"
                    :key="replay.playing.session.startAt"
                    :user-id="replay.userId"
                    :user-name="replay.userName"
                    :session="replay.playing.session"
                    :track="replay.playing.track"
                    @close="replay.stopReplay()"
                />
            </PeersMap>
            <button
                class="absolute top-3 left-3 z-[1000] rounded-xl border border-neutral-800 bg-black/80 px-3 py-2 text-sm backdrop-blur md:hidden"
                @click="drawerOpen = !drawerOpen"
            >
                People
            </button>
        </main>
    </div>
</template>
