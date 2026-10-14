<script setup lang="ts">
import { computed } from 'vue';
import { formatClock, formatDistance } from '../lib/format';
import { addDays, startOfDay, useReplayStore } from '../stores/replay';

const replay = useReplayStore();
const today = computed(() => startOfDay(new Date()).getTime());
const isToday = computed(() => replay.day.getTime() >= today.value);
const dayLabel = computed(() =>
    replay.day.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })
);
// <input type=date> speaks local calendar dates as yyyy-mm-dd.
function dateValue(d: Date): string {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
const inputValue = computed(() => dateValue(replay.day));

function pick(event: Event) {
    const [y, m, d] = (event.target as HTMLInputElement).value.split('-').map(Number);
    if (y && m && d) void replay.loadDay(new Date(y, m - 1, d));
}

function duration(seconds: number): string {
    const minutes = Math.max(1, Math.round(seconds / 60));
    return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}
</script>

<template>
    <div>
        <div class="flex items-center gap-2 border-b border-neutral-900 px-4 py-3">
            <button class="rounded-lg border border-neutral-800 px-2 py-1 text-sm" @click="replay.close()">
                ← Back
            </button>
            <h2 class="truncate font-medium">{{ replay.userName }}</h2>
        </div>
        <div class="flex items-center gap-2 px-4 py-3">
            <button
                class="rounded-lg border border-neutral-800 px-3 py-1"
                aria-label="Previous day"
                @click="replay.loadDay(addDays(replay.day, -1))"
            >
                ‹
            </button>
            <input
                type="date"
                class="min-w-0 flex-1 rounded-lg border border-neutral-800 bg-black px-2 py-1 text-sm"
                :value="inputValue"
                :max="dateValue(new Date())"
                aria-label="Day"
                @change="pick"
            />
            <button
                class="rounded-lg border border-neutral-800 px-3 py-1 disabled:opacity-40"
                aria-label="Next day"
                :disabled="isToday"
                @click="replay.loadDay(addDays(replay.day, 1))"
            >
                ›
            </button>
        </div>
        <p class="px-4 pb-2 text-xs text-neutral-500">{{ dayLabel }}</p>
        <p v-if="replay.loading" class="px-4 py-2 text-sm text-neutral-500">Loading…</p>
        <p v-else-if="replay.error" class="px-4 py-2 text-sm text-red-400" role="alert">{{ replay.error }}</p>
        <p v-else-if="replay.sessions.length === 0" class="px-4 py-2 text-sm text-neutral-500">No trips this day.</p>
        <ul class="divide-y divide-neutral-900">
            <li v-for="session in replay.sessions" :key="session.startAt">
                <button
                    class="block w-full px-4 py-3 text-left hover:bg-neutral-900"
                    :class="{ 'bg-neutral-900': replay.playing?.session.startAt === session.startAt }"
                    @click="replay.show(session)"
                >
                    <span class="block font-medium"
                        >{{ formatClock(session.startAt) }} – {{ formatClock(session.endAt) }}</span
                    >
                    <span class="block text-sm text-neutral-400"
                        >{{ formatDistance(session.distanceMeters) }} · {{ duration(session.durationSeconds) }} · top
                        {{ Math.round(session.topSpeed * 3.6) }} km/h</span
                    >
                </button>
            </li>
        </ul>
    </div>
</template>
