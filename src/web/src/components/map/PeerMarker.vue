<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import Icon from '../ui/Icon.vue';
import UserAvatar from '../UserAvatar.vue';
import { batteryIcon } from '../../lib/icons';

const props = defineProps<{
    userId: string;
    name: string;
    self: boolean;
    selected: boolean;
    stale: boolean;
    moving: boolean;
    /** Degrees clockwise from north; only drawn while moving. */
    heading: number | null;
    speedKmh: number;
    battery: number | null;
    charging: boolean;
    /** Draw the whole marker smaller, e.g. over the replay route. */
    compact?: boolean;
}>();

/** Replay uses a smaller rider so the route and its colours stay in view. */
const COMPACT_SCALE = 0.7;

// The beam turns the short way round (350° → 10° is +20°, not -340°).
const rotation = ref(props.heading ?? 0);
watch(
    () => props.heading,
    (next) => {
        if (next === null) return;
        const delta = ((((next - rotation.value) % 360) + 540) % 360) - 180;
        rotation.value += delta;
    }
);

const scale = computed(() => (props.selected ? 1.18 : props.moving ? 1.08 : 1) * (props.compact ? COMPACT_SCALE : 1));
</script>

<template>
    <!-- The phone app's TrackedUserMarker: avatar in a ring, heading beam and pulse on the move,
         speed and battery badges. Patched in place by the map, never rebuilt. -->
    <div
        class="peer-marker"
        :class="{ 'peer-marker--self': self, 'peer-marker--stale': stale }"
        :style="{ transform: `scale(${scale})` }"
    >
        <div
            v-if="moving && heading !== null"
            class="peer-marker__beam"
            :style="{ transform: `rotate(${rotation}deg)` }"
        />
        <div v-if="moving" class="peer-marker__pulse" />
        <div class="peer-marker__ring lt-hit" :title="self ? `${name} (you)` : name">
            <UserAvatar :user-id="userId" :name="name" :size="53" />
        </div>
        <!-- Speed only means something on the move; parked it's noise. -->
        <div v-if="moving" class="peer-marker__badge peer-marker__speed">
            <Icon name="speed" :size="12" />{{ Math.round(speedKmh) }} km/h
        </div>
        <div v-if="battery !== null" class="peer-marker__badge peer-marker__battery">
            <Icon :name="batteryIcon(battery, charging)" :size="12" />{{ battery }}%
        </div>
    </div>
</template>

<style>
.peer-marker {
    --beam: var(--color-beam);
    --ring: #fff;
    --badge: #212121;
    position: relative;
    width: 152px;
    height: 168px;
    transition: transform 220ms ease-out;
}

.peer-marker--self {
    --ring: var(--color-beam);
    --badge: #00695c;
}

.peer-marker--stale {
    --beam: #9e9e9e;
    --ring: #9e9e9e;
    --badge: #616161;
}

/* A 56° cone fading out from the person, with a soft glow. */
.peer-marker__beam {
    position: absolute;
    inset: 0;
    pointer-events: none;
    transition: transform 260ms cubic-bezier(0.33, 1, 0.68, 1);
}

.peer-marker__beam::before,
.peer-marker__beam::after {
    content: '';
    position: absolute;
    inset: 0;
    background: conic-gradient(from -28deg at 76px 88px, var(--beam) 0deg 56deg, transparent 56deg);
    mask-image: radial-gradient(circle 77px at 76px 88px, #000, transparent);
}

.peer-marker__beam::before {
    opacity: 0.12;
    filter: blur(7px);
}

.peer-marker__beam::after {
    opacity: 0.5;
}

.peer-marker__pulse {
    position: absolute;
    left: 36px;
    top: 44px;
    width: 80px;
    height: 80px;
    border-radius: 9999px;
    background: color-mix(in srgb, var(--beam) 22%, transparent);
    pointer-events: none;
    animation: peer-marker-pulse 1.2s ease-out infinite alternate;
}

@keyframes peer-marker-pulse {
    from {
        transform: scale(0.725);
        opacity: 1;
    }
    to {
        transform: scale(1);
        opacity: 0;
    }
}

.peer-marker__ring {
    position: absolute;
    left: 46px;
    top: 54px;
    width: 60px;
    height: 60px;
    padding: 3.5px;
    border-radius: 9999px;
    background: var(--ring);
    box-shadow: 0 4px 10px rgb(0 0 0 / 0.28);
}

/* Greyed out, never see-through: a quiet phone is still where it was last seen. */
.peer-marker--stale .peer-marker__ring {
    filter: grayscale(1);
}

.peer-marker__badge {
    position: absolute;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    border-radius: 9999px;
    background: var(--badge);
    color: #fff;
    font-size: 10px;
    line-height: 12px;
    font-weight: 600;
    white-space: nowrap;
    box-shadow: 0 3px 8px rgb(0 0 0 / 0.12);
    pointer-events: none;
}

.peer-marker__speed {
    top: 48px;
    right: 18px;
}

.peer-marker__battery {
    top: 116px;
    left: 50%;
    transform: translateX(-50%);
}
</style>
