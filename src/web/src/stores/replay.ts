import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import { fetchSessions, NotSharingError, type HistorySession } from '../api/history';
import { ReplayTrack } from '../lib/replay';

export function startOfDay(date: Date): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

export function addDays(date: Date, days: number): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
}

/** Browsing one person's travel sessions a day at a time, and replaying one of them. */
export const useReplayStore = defineStore('replay', () => {
    const userId = ref<string | null>(null);
    const userName = ref('');
    const day = ref(startOfDay(new Date()));
    const sessions = ref<HistorySession[]>([]);
    const loading = ref(false);
    const error = ref<string | null>(null);
    const playing = shallowRef<{ session: HistorySession; track: ReplayTrack } | null>(null);
    // Answers to superseded requests (a quick tap through days) must not overwrite the latest.
    let request = 0;

    const active = computed(() => userId.value !== null);

    function describe(reason: unknown, fallback: string): string {
        if (reason instanceof NotSharingError) return reason.message;
        return fallback;
    }

    async function loadDay(next: Date) {
        if (!userId.value) return;
        const mine = ++request;
        day.value = startOfDay(next);
        sessions.value = [];
        playing.value = null;
        loading.value = true;
        error.value = null;
        try {
            const found = await fetchSessions(userId.value, day.value, addDays(day.value, 1), false);
            if (mine !== request) return;
            sessions.value = found;
        } catch (reason) {
            if (mine !== request) return;
            error.value = describe(reason, 'Could not load the history.');
        } finally {
            if (mine === request) loading.value = false;
        }
    }

    function open(id: string, name: string) {
        userId.value = id;
        userName.value = name;
        void loadDay(new Date());
    }

    function close() {
        request++;
        userId.value = null;
        sessions.value = [];
        playing.value = null;
        loading.value = false;
        error.value = null;
    }

    /** Fetches a session's fixes and starts showing it. */
    async function show(session: HistorySession) {
        if (!userId.value) return;
        const mine = ++request;
        loading.value = true;
        error.value = null;
        try {
            // The summary listing leaves the points out; ask for exactly this session's window.
            const found = await fetchSessions(userId.value, new Date(session.startAt), new Date(session.endAt), true);
            if (mine !== request) return;
            const full = found.find((s) => s.startAt === session.startAt) ?? found[0];
            if (!full || full.points.length === 0) {
                error.value = 'There are no points to replay.';
                return;
            }
            playing.value = { session: full, track: new ReplayTrack(full.points) };
        } catch (reason) {
            if (mine !== request) return;
            error.value = describe(reason, 'Could not load the route.');
        } finally {
            if (mine === request) loading.value = false;
        }
    }

    function stopReplay() {
        playing.value = null;
    }

    return { userId, userName, day, sessions, loading, error, playing, active, open, close, loadDay, show, stopReplay };
});
