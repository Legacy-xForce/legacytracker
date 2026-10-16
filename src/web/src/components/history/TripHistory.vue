<script setup lang="ts">
import { computed, ref } from 'vue';
import CalendarCard from './CalendarCard.vue';
import TripCard from './TripCard.vue';
import ConfirmDialog from '../ui/ConfirmDialog.vue';
import Icon from '../ui/Icon.vue';
import Spinner from '../ui/Spinner.vue';
import type { HistorySession } from '../../api/history';
import { formatClock, formatDistance, formatLongDay, formatTripDuration } from '../../lib/format';
import { addMonths, useHistoryStore } from '../../stores/history';

const history = useHistoryStore();

// What the open confirmation would erase: one trip, or the whole picked day.
const pending = ref<{ trip: HistorySession } | { day: Date } | null>(null);

const confirmation = computed(() => {
    const target = pending.value;
    if (!target) return null;
    if ('trip' in target) {
        const { startAt, endAt } = target.trip;
        return {
            title: 'Delete this trip?',
            message: `The trip from ${formatClock(startAt)} to ${formatClock(endAt)} will be erased for good. This can't be undone.`
        };
    }
    const count = history.trips.length;
    return {
        title: 'Delete this day?',
        message: `${count === 1 ? 'The trip' : `All ${count} trips`} on ${formatLongDay(target.day)} will be erased for good. This can't be undone.`
    };
});

async function confirmDelete() {
    const target = pending.value;
    if (!target) return;
    await ('trip' in target ? history.deleteTrip(target.trip) : history.deleteDay());
    // On failure the dialog closes too: the reason is shown on the page, ready for a retry.
    pending.value = null;
}

const selectedInMonth = computed(() => {
    const day = history.selectedDay;
    return day !== null &&
        day.getFullYear() === history.month.getFullYear() &&
        day.getMonth() === history.month.getMonth()
        ? day
        : null;
});

const overview = computed(() => {
    const days = [...history.days.values()];
    return {
        trips: days.reduce((sum, d) => sum + d.trips, 0),
        days: days.length,
        distance: formatDistance(days.reduce((sum, d) => sum + d.distanceMeters, 0))
    };
});

const daySummary = computed(() => {
    const day = selectedInMonth.value ? history.days.get(selectedInMonth.value.getDate()) : undefined;
    if (!day) return null;
    return `${day.trips} ${day.trips === 1 ? 'trip' : 'trips'} · ${formatDistance(day.distanceMeters)} · ${formatTripDuration(day.durationSeconds)}`;
});
</script>

<template>
    <div class="px-4 pt-1 pb-8">
        <CalendarCard
            :month="history.month"
            :days="history.days"
            :loading="history.monthLoading"
            :selected-day="selectedInMonth"
            :can-go-back="history.canGoBack"
            :can-go-forward="history.canGoForward"
            @month="(delta) => history.showMonth(addMonths(history.month, delta))"
            @select="history.selectDay"
        />

        <div class="mt-5">
            <div v-if="history.monthError" class="text-on-surface-variant py-6 text-center">
                <Icon name="cloudOff" :size="32" class="mx-auto" />
                <p class="type-body-md mt-2.5">{{ history.monthError }}</p>
                <button
                    class="text-primary type-label-lg mt-2 rounded-full px-3 py-2 hover:bg-white/5"
                    @click="history.showMonth(history.month)"
                >
                    Retry
                </button>
            </div>
            <template v-else-if="history.monthLoading" />
            <section v-else-if="selectedInMonth">
                <div class="flex items-center">
                    <h3 class="type-title-lg min-w-0 flex-1 px-1 font-bold">{{ formatLongDay(selectedInMonth) }}</h3>
                    <button
                        v-if="history.canDelete && history.trips.length > 0 && !history.tripsLoading"
                        class="text-on-surface-variant -my-2 flex size-10 shrink-0 items-center justify-center rounded-full hover:bg-white/8"
                        aria-label="Delete this day's trips"
                        data-delete-day
                        @click="pending = { day: selectedInMonth }"
                    >
                        <Icon name="trash" />
                    </button>
                </div>
                <p v-if="daySummary" class="type-body-md text-on-surface-variant mt-0.5 px-1">{{ daySummary }}</p>
                <p v-if="history.deleteError" class="type-body-md text-error mt-2 px-1" role="alert">
                    {{ history.deleteError }}
                </p>
                <div class="mt-3.5 space-y-2.5">
                    <div v-if="history.tripsLoading" class="text-primary flex justify-center p-6">
                        <Spinner :size="32" />
                    </div>
                    <div v-else-if="history.tripsError" class="text-on-surface-variant py-6 text-center">
                        <Icon name="cloudOff" :size="32" class="mx-auto" />
                        <p class="type-body-md mt-2.5">{{ history.tripsError }}</p>
                    </div>
                    <div v-else-if="history.trips.length === 0" class="text-on-surface-variant py-6 text-center">
                        <Icon name="eventBusy" :size="32" class="mx-auto" />
                        <p class="type-body-md mt-2.5">No trips on this day.</p>
                    </div>
                    <template v-else>
                        <TripCard
                            v-for="trip in history.trips"
                            :key="trip.startAt"
                            :session="trip"
                            :playing="history.playing?.session.startAt === trip.startAt"
                            :deletable="history.canDelete"
                            @play="history.play(trip)"
                            @delete="pending = { trip }"
                        />
                    </template>
                </div>
            </section>
            <div v-else-if="overview.days === 0" class="text-on-surface-variant py-6 text-center">
                <Icon name="eventBusy" :size="32" class="mx-auto" />
                <p class="type-body-md mt-2.5">No trips this month.</p>
            </div>
            <template v-else>
                <div class="grid grid-cols-3 gap-2.5">
                    <div
                        v-for="stat in [
                            { value: String(overview.trips), label: 'Trips' },
                            { value: String(overview.days), label: overview.days === 1 ? 'Day' : 'Days' },
                            { value: overview.distance, label: 'Distance' }
                        ]"
                        :key="stat.label"
                        class="bg-surface-container rounded-[18px] px-3.5 py-3"
                    >
                        <p class="type-title-lg font-bold">{{ stat.value }}</p>
                        <p class="type-label-md text-on-surface-variant">{{ stat.label }}</p>
                    </div>
                </div>
                <p class="type-body-md text-on-surface-variant mt-5 flex items-center justify-center gap-2">
                    <Icon name="touchApp" :size="18" />
                    Pick a highlighted day to see its trips
                </p>
            </template>
        </div>

        <ConfirmDialog
            v-if="confirmation"
            :title="confirmation.title"
            :message="confirmation.message"
            confirm-label="Delete"
            :busy="history.deleting"
            @confirm="confirmDelete"
            @cancel="pending = null"
        />
    </div>
</template>
