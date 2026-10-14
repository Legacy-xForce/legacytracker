import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import { fetchSessions, NotSharingError, type HistorySession } from '../api/history';
import { ReplayTrack } from '../lib/replay';

/** How far back the calendar goes, like the app. */
export const MONTHS_BACK = 12;

export function startOfDay(date: Date): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

export function addDays(date: Date, days: number): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
}

export function startOfMonth(date: Date): Date {
    return new Date(date.getFullYear(), date.getMonth(), 1);
}

export function addMonths(date: Date, months: number): Date {
    return new Date(date.getFullYear(), date.getMonth() + months, 1);
}

export interface DaySummary {
    trips: number;
    distanceMeters: number;
    durationSeconds: number;
}

/** A month's trips per local day of the month, counted on the day they started. */
export function summarizeByDay(sessions: HistorySession[], month: Date): Map<number, DaySummary> {
    const days = new Map<number, DaySummary>();
    for (const session of sessions) {
        const start = new Date(session.startAt);
        if (start.getFullYear() !== month.getFullYear() || start.getMonth() !== month.getMonth()) continue;
        const day = days.get(start.getDate()) ?? { trips: 0, distanceMeters: 0, durationSeconds: 0 };
        days.set(start.getDate(), {
            trips: day.trips + 1,
            distanceMeters: day.distanceMeters + session.distanceMeters,
            durationSeconds: day.durationSeconds + session.durationSeconds
        });
    }
    return days;
}

function describe(reason: unknown, fallback: string): string {
    return reason instanceof NotSharingError ? reason.message : fallback;
}

/**
 * One person's trips: a month calendar marking the days with trips, the picked day's trips, and
 * the trip being replayed.
 */
export const useHistoryStore = defineStore('history', () => {
    const userId = ref<string | null>(null);
    const userName = ref('');
    const month = ref(startOfMonth(new Date()));
    const days = shallowRef(new Map<number, DaySummary>());
    const monthLoading = ref(false);
    const monthError = ref<string | null>(null);
    const selectedDay = ref<Date | null>(null);
    const trips = shallowRef<HistorySession[]>([]);
    const tripsLoading = ref(false);
    const tripsError = ref<string | null>(null);
    const playing = shallowRef<{ session: HistorySession; track: ReplayTrack } | null>(null);
    // Answers to superseded requests (a quick tap through months or days) must not land.
    let monthRequest = 0;
    let dayRequest = 0;

    const active = computed(() => userId.value !== null);
    const currentMonth = computed(() => startOfMonth(new Date()));
    const canGoBack = computed(() => month.value > addMonths(currentMonth.value, -MONTHS_BACK));
    const canGoForward = computed(() => month.value < currentMonth.value);

    async function showMonth(next: Date) {
        if (!userId.value) return;
        const mine = ++monthRequest;
        month.value = startOfMonth(next);
        days.value = new Map();
        monthLoading.value = true;
        monthError.value = null;
        try {
            const found = await fetchSessions(userId.value, month.value, addMonths(month.value, 1), false);
            if (mine !== monthRequest) return;
            days.value = summarizeByDay(found, month.value);
        } catch (reason) {
            if (mine !== monthRequest) return;
            monthError.value = describe(reason, "Couldn't load this month's trips.");
        } finally {
            if (mine === monthRequest) monthLoading.value = false;
        }
    }

    /** Loads a day's trips with their points: street names for each end, and ready to replay. */
    async function selectDay(day: Date) {
        if (!userId.value) return;
        const mine = ++dayRequest;
        selectedDay.value = startOfDay(day);
        trips.value = [];
        tripsLoading.value = true;
        tripsError.value = null;
        try {
            const found = await fetchSessions(userId.value, selectedDay.value, addDays(selectedDay.value, 1), true);
            if (mine !== dayRequest) return;
            trips.value = found;
        } catch (reason) {
            if (mine !== dayRequest) return;
            tripsError.value = describe(reason, "Couldn't load this day's trips.");
        } finally {
            if (mine === dayRequest) tripsLoading.value = false;
        }
    }

    function open(id: string, name: string) {
        close();
        userId.value = id;
        userName.value = name;
        void showMonth(new Date());
    }

    function close() {
        monthRequest++;
        dayRequest++;
        userId.value = null;
        days.value = new Map();
        selectedDay.value = null;
        trips.value = [];
        playing.value = null;
        monthLoading.value = tripsLoading.value = false;
        monthError.value = tripsError.value = null;
    }

    function play(session: HistorySession) {
        if (session.points.length === 0) {
            tripsError.value = 'There are no points to replay.';
            return;
        }
        playing.value = { session, track: new ReplayTrack(session.points) };
    }

    function stopReplay() {
        playing.value = null;
    }

    return {
        userId,
        userName,
        month,
        days,
        monthLoading,
        monthError,
        selectedDay,
        trips,
        tripsLoading,
        tripsError,
        playing,
        active,
        canGoBack,
        canGoForward,
        open,
        close,
        showMonth,
        selectDay,
        play,
        stopReplay
    };
});
