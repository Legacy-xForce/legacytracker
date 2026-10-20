<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import UserAvatar from '../UserAvatar.vue';
import Icon from '../ui/Icon.vue';
import Spinner from '../ui/Spinner.vue';
import { formatDistance, formatTripDuration } from '../../lib/format';
import { formatPeriod, fromDateInput, MAX_PERIOD_DAYS, toDateInput, type PeriodKind } from '../../lib/periods';
import { addDays } from '../../stores/history';
import { useLeaderboardStore } from '../../stores/leaderboard';

defineProps<{ selfId: string }>();

const board = useLeaderboardStore();

const KINDS: { kind: PeriodKind; label: string }[] = [
    { kind: 'week', label: 'Week' },
    { kind: 'month', label: 'Month' },
    { kind: 'custom', label: 'Custom' }
];
// Gold, silver, bronze for the podium.
const MEDALS = ['#f5c542', '#c0c7cc', '#d08b54'];

// The picked custom range as the date inputs show it (the period's last day, not the midnight after).
const firstDay = ref('');
const lastDay = ref('');
const rangeError = ref<string | null>(null);
const today = toDateInput(new Date());

watch(
    () => board.period,
    (period) => {
        firstDay.value = toDateInput(period.from);
        lastDay.value = toDateInput(addDays(period.to, -1));
    },
    { immediate: true }
);

function applyCustom() {
    const first = fromDateInput(firstDay.value);
    const last = fromDateInput(lastDay.value);
    if (!first || !last) return;
    rangeError.value = board.setCustom(first, last) ? null : `Pick at most ${MAX_PERIOD_DAYS} days.`;
}

const label = computed(() => formatPeriod(board.period));
const totals = computed(() => ({
    distance: board.entries.reduce((sum, e) => sum + e.distanceMeters, 0),
    trips: board.entries.reduce((sum, e) => sum + e.tripCount, 0)
}));

function kmh(metersPerSecond: number): string {
    return `${Math.round(metersPerSecond * 3.6)} km/h`;
}
</script>

<template>
    <div class="px-4 pt-1 pb-8">
        <div class="bg-surface-container flex rounded-full p-1" role="tablist" aria-label="Period">
            <button
                v-for="option in KINDS"
                :key="option.kind"
                class="type-label-lg flex-1 rounded-full py-2 font-semibold transition-colors"
                :class="
                    board.period.kind === option.kind
                        ? 'bg-secondary-container text-on-secondary-container'
                        : 'text-on-surface-variant hover:bg-on-surface/5'
                "
                role="tab"
                :aria-selected="board.period.kind === option.kind"
                :data-kind="option.kind"
                @click="board.setKind(option.kind)"
            >
                {{ option.label }}
            </button>
        </div>

        <div class="bg-surface-container mt-3 overflow-hidden rounded-[20px]">
            <div class="h-[3px]">
                <div v-if="board.loading" class="bg-primary/25 relative h-full overflow-hidden">
                    <div
                        class="bg-primary absolute inset-y-0 w-1/3 animate-[calendar-progress_1.1s_ease-in-out_infinite]"
                    />
                </div>
            </div>
            <div class="flex items-center px-2 pt-1 pb-1.5">
                <button
                    class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                    :aria-label="`Previous ${board.period.kind === 'custom' ? 'range' : board.period.kind}`"
                    data-previous
                    @click="board.shift(-1)"
                >
                    <Icon name="chevronLeft" />
                </button>
                <h3 class="type-title-md flex-1 text-center font-bold" data-period>{{ label }}</h3>
                <button
                    class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full disabled:opacity-30"
                    :aria-label="`Next ${board.period.kind === 'custom' ? 'range' : board.period.kind}`"
                    :disabled="!board.canGoForward"
                    data-next
                    @click="board.shift(1)"
                >
                    <Icon name="chevronRight" />
                </button>
            </div>
            <div v-if="board.period.kind === 'custom'" class="grid grid-cols-2 gap-2 px-3 pb-3">
                <label class="bg-surface-container-high rounded-2xl px-3 py-2">
                    <span class="type-label-sm text-on-surface-variant block">From</span>
                    <input
                        v-model="firstDay"
                        type="date"
                        class="type-body-md text-on-surface w-full bg-transparent outline-none"
                        :max="today"
                        data-from
                        @change="applyCustom"
                    />
                </label>
                <label class="bg-surface-container-high rounded-2xl px-3 py-2">
                    <span class="type-label-sm text-on-surface-variant block">To</span>
                    <input
                        v-model="lastDay"
                        type="date"
                        class="type-body-md text-on-surface w-full bg-transparent outline-none"
                        :max="today"
                        data-to
                        @change="applyCustom"
                    />
                </label>
                <p v-if="rangeError" class="type-body-sm text-error col-span-2 px-1" role="alert">{{ rangeError }}</p>
            </div>
        </div>

        <div class="mt-5">
            <div v-if="board.error" class="text-on-surface-variant py-6 text-center">
                <Icon name="cloudOff" :size="32" class="mx-auto" />
                <p class="type-body-md mt-2.5">{{ board.error }}</p>
                <button
                    class="text-primary type-label-lg hover:bg-on-surface/5 mt-2 rounded-full px-3 py-2"
                    @click="board.open()"
                >
                    Retry
                </button>
            </div>
            <div v-else-if="!board.loaded" class="text-primary flex justify-center p-6"><Spinner :size="28" /></div>
            <div
                v-else-if="totals.trips === 0"
                class="text-on-surface-variant py-6 text-center"
                :class="{ 'opacity-60': board.loading }"
            >
                <Icon name="directionsCar" :size="32" class="mx-auto" />
                <p class="type-body-md mt-2.5">Nobody travelled in this period.</p>
            </div>
            <template v-else>
                <p class="type-body-md text-on-surface-variant mb-3 px-1">
                    {{ formatDistance(totals.distance) }} together · {{ totals.trips }}
                    {{ totals.trips === 1 ? 'trip' : 'trips' }}
                </p>
                <ol class="space-y-2.5 transition-opacity" :class="{ 'opacity-60': board.loading }">
                    <li
                        v-for="entry in board.entries"
                        :key="entry.userId"
                        class="bg-surface-container rounded-[18px] px-3 pt-3 pb-2.5"
                        :class="{ 'ring-primary/70 ring-[1.5px]': entry.userId === selfId }"
                        data-entry
                    >
                        <div class="flex items-center gap-3">
                            <span
                                class="type-label-lg flex size-7 shrink-0 items-center justify-center rounded-full font-bold tabular-nums"
                                :class="
                                    entry.rank <= 3 && entry.tripCount > 0
                                        ? 'text-[#1a1300]'
                                        : 'text-on-surface-variant'
                                "
                                :style="
                                    entry.rank <= 3 && entry.tripCount > 0
                                        ? { background: MEDALS[entry.rank - 1] }
                                        : undefined
                                "
                                :aria-label="`Rank ${entry.rank}`"
                                >{{ entry.rank }}</span
                            >
                            <UserAvatar :user-id="entry.userId" :name="entry.name" :size="40" />
                            <div class="min-w-0 flex-1">
                                <p class="type-title-sm truncate font-semibold">
                                    {{ entry.name }}<template v-if="entry.userId === selfId"> (you)</template>
                                </p>
                                <p class="type-body-sm text-on-surface-variant truncate">
                                    <template v-if="entry.tripCount > 0">
                                        {{ entry.tripCount }} {{ entry.tripCount === 1 ? 'trip' : 'trips' }} ·
                                        {{ formatTripDuration(entry.durationSeconds) }}
                                    </template>
                                    <template v-else>No trips</template>
                                </p>
                            </div>
                            <p class="type-title-lg shrink-0 font-bold tabular-nums" data-distance>
                                {{ formatDistance(entry.distanceMeters) }}
                            </p>
                        </div>
                        <div class="bg-surface-container-highest mt-3 h-1.5 overflow-hidden rounded-full">
                            <div
                                class="bg-primary h-full rounded-full"
                                :style="{
                                    width: `${board.leader > 0 ? (entry.distanceMeters / board.leader) * 100 : 0}%`
                                }"
                            />
                        </div>
                        <div v-if="entry.tripCount > 0" class="mt-2.5 flex flex-wrap gap-1.5">
                            <span
                                class="bg-surface-container-highest type-label-md flex items-center gap-[5px] rounded-full px-[9px] py-[5px]"
                            >
                                <Icon name="speedOutlined" :size="14" class="text-on-surface-variant" />{{
                                    kmh(entry.avgSpeed)
                                }}
                                avg
                            </span>
                            <span
                                class="bg-surface-container-highest type-label-md flex items-center gap-[5px] rounded-full px-[9px] py-[5px]"
                            >
                                <Icon name="speed" :size="14" class="text-on-surface-variant" />{{
                                    kmh(entry.topSpeed)
                                }}
                                top
                            </span>
                        </div>
                    </li>
                </ol>
            </template>
        </div>
    </div>
</template>
