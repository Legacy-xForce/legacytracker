<script setup lang="ts">
import { computed } from 'vue';
import BatteryPill from './BatteryPill.vue';
import PresenceAvatar from './PresenceAvatar.vue';
import StatusChip from './StatusChip.vue';
import PlaceLabel from '../PlaceLabel.vue';
import { hasPosition, isMoving, isStale, type Peer } from '../../lib/peers';
import { presence } from '../../lib/presence';

const props = defineProps<{ peer: Peer; self: boolean; selected: boolean; now: number }>();
const emit = defineEmits<{ select: [] }>();

const stale = computed(() => isStale(props.peer, props.now));
const travelling = computed(() => isMoving(props.peer) && !stale.value);
const sentence = computed(() => presence(props.peer, props.now).sentence);
</script>

<template>
    <button
        class="flex w-full items-center gap-3.5 rounded-[18px] px-2 py-2.5 text-left transition-colors disabled:cursor-default"
        :class="selected ? 'bg-primary/12' : 'hover:bg-white/4'"
        :disabled="!hasPosition(peer) && peer.sharing"
        :aria-label="self ? `${peer.name} (you)` : peer.name"
        @click="emit('select')"
    >
        <PresenceAvatar :user-id="peer.id" :name="peer.name" :size="46" :stale="stale" />
        <span class="min-w-0 flex-1">
            <span class="type-title-sm block truncate font-semibold"
                >{{ peer.name }}<template v-if="self"> (you)</template></span
            >
            <PlaceLabel
                v-if="hasPosition(peer)"
                class="type-body-sm text-on-surface-variant mt-0.5"
                :subject="`row:${peer.id}`"
                :latitude="peer.latitude!"
                :longitude="peer.longitude!"
            />
            <span
                class="type-body-sm block"
                :class="travelling ? 'text-primary font-semibold' : 'text-on-surface-variant'"
                >{{ sentence }}</span
            >
            <span v-if="!peer.sharing" class="mt-1.5 flex flex-wrap gap-1.5">
                <StatusChip icon="visibilityOff" label="Not sharing with you" color="var(--color-hidden)" />
            </span>
        </span>
        <BatteryPill
            v-if="peer.batteryLevel !== null"
            :level="peer.batteryLevel"
            :charging="peer.isCharging === true"
        />
    </button>
</template>
