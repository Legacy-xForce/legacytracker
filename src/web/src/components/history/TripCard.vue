<script setup lang="ts">
import { computed } from 'vue';
import PlaceLabel from '../PlaceLabel.vue';
import Icon from '../ui/Icon.vue';
import type { HistorySession } from '../../api/history';
import { formatClock, formatDistance, formatTripDuration } from '../../lib/format';

const props = defineProps<{ session: HistorySession; playing: boolean; deletable?: boolean }>();
const emit = defineEmits<{ play: []; delete: [] }>();

const start = computed(() => props.session.points[0] ?? null);
const end = computed(() => props.session.points[props.session.points.length - 1] ?? null);
const chips = computed(() => [
    { icon: 'timelapse' as const, label: formatTripDuration(props.session.durationSeconds) },
    { icon: 'straighten' as const, label: formatDistance(props.session.distanceMeters) },
    { icon: 'speed' as const, label: `${Math.round(props.session.topSpeed * 3.6)} km/h top` }
]);
</script>

<template>
    <!-- One trip as a little timeline: departure and arrival with their streets, then its stats. -->
    <div
        class="bg-surface-container relative rounded-[20px] px-3.5 pt-3.5 pb-3 transition hover:brightness-110"
        :class="{ 'ring-primary ring-2': playing }"
        data-trip
    >
        <!-- The whole card replays; the content lets clicks through so delete can sit on top. -->
        <button class="absolute inset-0 rounded-[20px]" aria-label="Replay this trip" data-play @click="emit('play')" />
        <div class="pointer-events-none relative flex gap-3">
            <!-- Green departure dot, a line, red arrival dot: matching the replay map. -->
            <div class="flex flex-col items-center py-1">
                <span class="bg-online size-3 rounded-full border-2 border-white" />
                <span class="bg-outline-variant my-[3px] w-0.5 flex-1" />
                <span class="bg-arrival size-3 rounded-full border-2 border-white" />
            </div>
            <div class="type-body-md min-w-0 flex-1 space-y-3.5">
                <div class="flex items-center">
                    <span class="type-title-sm w-12 shrink-0 font-bold tabular-nums">{{
                        formatClock(session.startAt)
                    }}</span>
                    <PlaceLabel
                        v-if="start"
                        class="text-on-surface-variant"
                        :subject="`trip:${session.startAt}:start`"
                        :latitude="start.latitude"
                        :longitude="start.longitude"
                    />
                </div>
                <div class="flex items-center">
                    <span class="type-title-sm w-12 shrink-0 font-bold tabular-nums">{{
                        formatClock(session.endAt)
                    }}</span>
                    <PlaceLabel
                        v-if="end"
                        class="text-on-surface-variant"
                        :subject="`trip:${session.startAt}:end`"
                        :latitude="end.latitude"
                        :longitude="end.longitude"
                    />
                </div>
            </div>
        </div>
        <div class="pointer-events-none relative mt-3 flex items-center gap-2">
            <div class="flex flex-1 flex-wrap gap-1.5">
                <span
                    v-for="chip in chips"
                    :key="chip.icon"
                    class="bg-surface-container-highest type-label-md flex items-center gap-[5px] rounded-full px-[9px] py-[5px]"
                >
                    <Icon :name="chip.icon" :size="14" class="text-on-surface-variant" />{{ chip.label }}
                </span>
            </div>
            <button
                v-if="deletable"
                class="text-on-surface-variant pointer-events-auto flex size-9 shrink-0 items-center justify-center rounded-full hover:bg-white/8"
                aria-label="Delete this trip"
                data-delete
                @click="emit('delete')"
            >
                <Icon name="trash" :size="22" />
            </button>
            <span
                class="bg-primary-container text-on-primary-container flex size-9 shrink-0 items-center justify-center rounded-full"
            >
                <Icon name="playArrow" />
            </span>
        </div>
    </div>
</template>
