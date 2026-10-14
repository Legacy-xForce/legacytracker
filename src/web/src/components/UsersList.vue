<script setup lang="ts">
import { formatClock, formatElapsed } from '../lib/format';
import { hasPosition, isMoving, isStale, type Peer } from '../lib/peers';
import { hueFor, initials } from '../lib/marker';

defineProps<{ peers: Peer[]; selfId: string; selectedId: string | null; now: number }>();
const emit = defineEmits<{ select: [id: string] }>();

function status(peer: Peer, now: number): string {
    if (!peer.sharing) return 'Not sharing with you';
    if (!hasPosition(peer)) return 'No location yet';
    if (isMoving(peer)) return `Travelling · ${Math.round(peer.speed * 3.6)} km/h`;
    if (peer.hereSince !== null) return `Here for ${formatElapsed(now - peer.hereSince)}`;
    return 'Stopped';
}

function lastSeen(peer: Peer, now: number): string | null {
    if (!peer.sharing || peer.lastSeenAt === null) return null;
    return isStale(peer, now) ? `Last seen ${formatClock(peer.lastSeenAt)}` : null;
}
</script>

<template>
    <ul class="divide-y divide-neutral-900">
        <li v-for="peer in peers" :key="peer.id">
            <button
                class="flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-neutral-900 disabled:cursor-default disabled:opacity-60"
                :class="{ 'bg-neutral-900': peer.id === selectedId }"
                :disabled="!hasPosition(peer)"
                @click="emit('select', peer.id)"
            >
                <span
                    class="flex size-10 shrink-0 items-center justify-center rounded-full font-semibold"
                    :style="{ background: `hsl(${hueFor(peer.id)} 55% 38%)` }"
                    >{{ initials(peer.name) }}</span
                >
                <span class="min-w-0 flex-1">
                    <span class="block truncate font-medium"
                        >{{ peer.name }}<span v-if="peer.id === selfId" class="text-neutral-500"> (you)</span></span
                    >
                    <span class="block truncate text-sm text-neutral-400">{{ status(peer, now) }}</span>
                    <span v-if="lastSeen(peer, now)" class="block truncate text-xs text-neutral-500">{{
                        lastSeen(peer, now)
                    }}</span>
                </span>
                <span v-if="peer.batteryLevel !== null" class="shrink-0 text-xs text-neutral-400"
                    >{{ peer.isCharging ? '⚡ ' : '' }}{{ peer.batteryLevel }}%</span
                >
            </button>
        </li>
    </ul>
</template>
