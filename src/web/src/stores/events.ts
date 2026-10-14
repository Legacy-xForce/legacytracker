import { defineStore } from 'pinia';
import { computed, ref } from 'vue';
import { CalendarError, fetchEvents } from '../api/calendar';
import { isOver, type CalendarEvent } from '../lib/events';
import { EventGeocoder } from '../lib/geocoder';
import { storage } from '../lib/storage';
import { useSessionStore } from './session';

const DAY_MS = 86_400_000;
const ENABLED_KEY = 'legacytracker.showEvents';

/** Upcoming Legacy Calendar events, placed on the map by geocoding their location text. */
export const useEventsStore = defineStore('events', () => {
    const session = useSessionStore();
    const events = ref<CalendarEvent[]>([]);
    const enabled = ref(storage.get(ENABLED_KEY) !== 'false');
    // Set once the calendar says this account has no access; the overlay then disappears entirely.
    const refused = ref(false);
    const loading = ref(false);
    const error = ref(false);
    let geocoder: EventGeocoder | null = null;
    let generation = 0;

    /** Whether the overlay is offered at all: needs the calendar scope and the calendar's blessing. */
    const available = computed(() => session.hasCalendarScope && !refused.value);

    function setEnabled(value: boolean) {
        enabled.value = value;
        storage.set(ENABLED_KEY, String(value));
        if (value) void refresh();
    }

    function placeKnown(list: CalendarEvent[]): CalendarEvent[] {
        const known = (geocoder ??= new EventGeocoder());
        return list.map((event) => {
            if (!event.location) return event;
            const { point } = known.peek(event.location);
            return point ? { ...event, point } : event;
        });
    }

    async function geocode(list: CalendarEvent[], mine: number) {
        geocoder ??= new EventGeocoder();
        for (const event of list) {
            if (mine !== generation) return;
            if (!event.location || geocoder.peek(event.location).known) continue;
            await geocoder.resolve(event.location);
            if (mine !== generation) return;
            events.value = placeKnown(events.value);
        }
    }

    async function refresh() {
        if (!available.value || !enabled.value) return;
        const mine = ++generation;
        loading.value = true;
        try {
            const now = Date.now();
            const found = await fetchEvents(new Date(now - DAY_MS), new Date(now + 60 * DAY_MS));
            if (mine !== generation) return;
            error.value = false;
            events.value = placeKnown(found.filter((event) => !isOver(event, now)));
            void geocode(events.value, mine);
        } catch (reason) {
            if (mine !== generation) return;
            if (reason instanceof CalendarError && reason.noAccess) {
                refused.value = true;
                events.value = [];
            } else {
                error.value = true;
            }
        } finally {
            if (mine === generation) loading.value = false;
        }
    }

    function reset() {
        generation++;
        events.value = [];
        refused.value = false;
        error.value = false;
    }

    return { events, enabled, available, loading, error, setEnabled, refresh, reset };
});
