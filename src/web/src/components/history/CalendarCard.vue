<script setup lang="ts">
import { computed } from 'vue';
import Icon from '../ui/Icon.vue';
import { formatMonth } from '../../lib/format';
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

const cells = computed(() => {
    const year = props.month.getFullYear();
    const month = props.month.getMonth();
    const count = new Date(year, month + 1, 0).getDate();
    // Weeks start on Monday.
    const leading = (new Date(year, month, 1).getDay() + 6) % 7;
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const selected = props.selectedDay?.getTime();
    const list: ({
        day: number;
        date: Date;
        trips: number;
        today: boolean;
        future: boolean;
        selected: boolean;
    } | null)[] = Array.from({ length: leading }, () => null);
    for (let day = 1; day <= count; day++) {
        const date = new Date(year, month, day);
        list.push({
            day,
            date,
            trips: props.days.get(day)?.trips ?? 0,
            today: date.getTime() === today,
            future: date.getTime() > today,
            selected: date.getTime() === selected
        });
    }
    return list;
});
</script>

<template>
    <div class="bg-surface-container overflow-hidden rounded-[20px]">
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
                    class="text-on-surface-variant flex size-10 items-center justify-center rounded-full hover:bg-white/6 disabled:opacity-30"
                    aria-label="Previous month"
                    :disabled="!canGoBack"
                    @click="emit('month', -1)"
                >
                    <Icon name="chevronLeft" />
                </button>
                <h3 class="type-title-md flex-1 text-center font-bold">{{ formatMonth(month) }}</h3>
                <button
                    class="text-on-surface-variant flex size-10 items-center justify-center rounded-full hover:bg-white/6 disabled:opacity-30"
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
                        class="flex size-10 flex-col items-center justify-center rounded-full transition-colors"
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
                        :aria-label="`${cell.date.toDateString()}${cell.trips ? `, ${cell.trips} trips` : ''}`"
                        @click="emit('select', cell.date)"
                    >
                        <span class="type-body-md leading-[1.1]" :class="{ 'font-bold': cell.trips || cell.today }">{{
                            cell.day
                        }}</span>
                        <!-- Only days with trips lead anywhere: a dot per trip, up to three. -->
                        <span v-if="cell.trips" class="mt-0.5 flex gap-0.5">
                            <span
                                v-for="dot in Math.min(cell.trips, 3)"
                                :key="dot"
                                class="size-1 rounded-full bg-current"
                            />
                        </span>
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
