import { defineStore } from 'pinia';
import { computed, ref, shallowRef } from 'vue';
import { fetchLeaderboard, type LeaderboardEntry } from '../api/leaderboard';
import {
    customPeriod,
    isCurrentOrLater,
    MAX_PERIOD_DAYS,
    periodContaining,
    periodDays,
    shiftPeriod,
    type Period,
    type PeriodKind
} from '../lib/periods';
import { addDays, startOfDay } from './history';

/** A custom range starts as the last 30 days, today included. */
function defaultCustom(): Period {
    const today = startOfDay(new Date());
    return customPeriod(addDays(today, -29), today);
}

/** The travel leaderboard: everyone's distance and speeds over a week, a month or a picked range. */
export const useLeaderboardStore = defineStore('leaderboard', () => {
    const period = shallowRef<Period>(periodContaining('week', new Date()));
    const entries = shallowRef<LeaderboardEntry[]>([]);
    const loading = ref(false);
    const error = ref<string | null>(null);
    const loaded = ref(false);
    // Answers to superseded requests (a quick tap through weeks) must not land.
    let request = 0;

    const canGoForward = computed(() => !isCurrentOrLater(period.value));
    const leader = computed(() => entries.value[0]?.distanceMeters ?? 0);

    async function load(next: Period = period.value) {
        const mine = ++request;
        period.value = next;
        loading.value = true;
        error.value = null;
        try {
            const found = await fetchLeaderboard(next.from, next.to);
            if (mine !== request) return;
            entries.value = found;
            loaded.value = true;
        } catch {
            if (mine !== request) return;
            entries.value = [];
            error.value = "Couldn't load the leaderboard.";
        } finally {
            if (mine === request) loading.value = false;
        }
    }

    /** Opening the view: the first time loads this week, later visits refresh what was shown. */
    function open() {
        void load();
    }

    function setKind(kind: PeriodKind) {
        if (kind === period.value.kind) return;
        void load(kind === 'custom' ? defaultCustom() : periodContaining(kind, new Date()));
    }

    function shift(delta: number) {
        if (delta > 0 && !canGoForward.value) return;
        void load(shiftPeriod(period.value, delta));
    }

    /** Returns false (and loads nothing) for a range longer than the server allows. */
    function setCustom(first: Date, last: Date): boolean {
        const next = customPeriod(first, last);
        if (periodDays(next) > MAX_PERIOD_DAYS) return false;
        void load(next);
        return true;
    }

    function reset() {
        request++;
        period.value = periodContaining('week', new Date());
        entries.value = [];
        loading.value = false;
        loaded.value = false;
        error.value = null;
    }

    return { period, entries, loading, error, loaded, canGoForward, leader, open, setKind, shift, setCustom, reset };
});
