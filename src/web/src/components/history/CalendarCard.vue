<script setup lang="ts">
import { computed } from 'vue';
import Icon from '../ui/Icon.vue';
import { formatDayKilometers, formatMonth } from '../../lib/format';
import type { DaySummary } from '../../stores/history';

const props = defineProps<{
    month: Date;
    days: Map<number, DaySummary>;
    loading: boolean;
    selectedDay: Date | null;
    canGoBack: boolean;
    canGoForward: boolean;
}>();
const emit = defineEmits<{ month: [delta: number]; select: [day: Date] }>();

const WEEKDAYS = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

interface Cell {
    day: number;
    date: Date;
    trips: number;
    km: string;
    today: boolean;
    future: boolean;
    selected: boolean;
}

const cells = computed(() => {
    const year = props.month.getFullYear();
    const month = props.month.getMonth();
    const count = new Date(year, month + 1, 0).getDate();
    // Weeks start on Monday.
    const leading = (new Date(year, month, 1).getDay() + 6) % 7;
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const selected = props.selectedDay?.getTime();
    const list: (Cell | null)[] = Array.from({ length: leading }, () => null);
    for (let day = 1; day <= count; day++) {
        const date = new Date(year, month, day);
        const summary = props.days.get(day);
        const trips = summary?.trips ?? 0;
        list.push({
            day,
            date,
            trips,
            km: trips ? formatDayKilometers(summary?.distanceMeters ?? 0) : '',
            today: date.getTime() === today,
            future: date.getTime() > today,
            selected: date.getTime() === selected
        });
    }
    return list;
});

/** What the cell shows, so the accessible name matches it. */
function ariaLabel(cell: Cell): string {
    const day = cell.date.toDateString();
    return cell.trips ? `${day}, ${cell.trips} trips, ${cell.km}` : day;
}
</script>

<template>
    <div class="bg-surface-container overflow-hidden rounded-md">
        <div class="h-[3px]">
            <div v-if="loading" class="bg-primary/25 relative h-full overflow-hidden">
                <div
                    class="bg-primary absolute inset-y-0 w-1/3 animate-[calendar-progress_1.1s_ease-in-out_infinite]"
                />
            </div>
        </div>
        <div class="px-2 pt-1.5 pb-3">
            <div class="flex items-center">
                <button
                    class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full disabled:opacity-30"
                    aria-label="Previous month"
                    :disabled="!canGoBack"
                    @click="emit('month', -1)"
                >
                    <Icon name="chevronLeft" />
                </button>
                <h3 class="type-title-md flex-1 text-center font-bold">{{ formatMonth(month) }}</h3>
                <button
                    class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full disabled:opacity-30"
                    aria-label="Next month"
                    :disabled="!canGoForward"
                    @click="emit('month', 1)"
                >
                    <Icon name="chevronRight" />
                </button>
            </div>
            <div class="type-label-sm text-on-surface-variant mt-1 grid grid-cols-7 text-center font-semibold">
                <span v-for="(letter, i) in WEEKDAYS" :key="i">{{ letter }}</span>
            </div>
            <div class="mt-1.5 grid grid-cols-7">
                <div v-for="(cell, i) in cells" :key="i" class="flex h-[46px] items-center justify-center">
                    <button
                        v-if="cell"
                        class="flex h-10 min-w-10 flex-col items-center justify-center rounded-full px-1 whitespace-nowrap transition-colors"
                        :class="[
                            cell.selected
                                ? 'bg-primary text-on-primary'
                                : cell.trips
                                  ? 'bg-primary-container text-on-primary-container hover:brightness-125'
                                  : cell.future
                                    ? 'text-on-surface/25'
                                    : 'text-on-surface-variant',
                            cell.today && !cell.selected ? 'ring-primary ring-[1.5px]' : ''
                        ]"
                        :disabled="!cell.trips"
                        :data-has-trips="cell.trips ? '' : undefined"
                        :aria-label="ariaLabel(cell)"
                        @click="emit('select', cell.date)"
                    >
                        <span class="type-body-md leading-[1.1]" :class="{ 'font-bold': cell.trips || cell.today }">{{
                            cell.day
                        }}</span>
                        <!-- Only days with trips lead anywhere: their total, in whole km. -->
                        <span v-if="cell.trips" class="type-label-sm mt-0.5 leading-none opacity-70">{{
                            cell.km
                        }}</span>
                    </button>
                </div>
            </div>
        </div>
    </div>
</template>

<style>
@keyframes calendar-progress {
    from {
        left: -33%;
    }
    to {
        left: 100%;
    }
}
</style>
