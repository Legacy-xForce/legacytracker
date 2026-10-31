<script setup lang="ts">
import { computed } from 'vue';
import UserAvatar from '../UserAvatar.vue';
import { CLUSTER, clusterWidth } from '../../lib/clusters';

const props = defineProps<{
    members: { id: string; name: string; stale: boolean }[];
}>();

const width = computed(() => clusterWidth(props.members.length));
const faces = computed(() => props.members.slice(0, CLUSTER.maxFaces));
const overflow = computed(() => props.members.length - faces.value.length);
const allStale = computed(() => props.members.every((m) => m.stale));

// A fully rounded pill with a short tail into its bottom edge, as one path so the shadow never
// doubles up at the seam.
const bubble = computed(() => {
    const w = width.value;
    const h = CLUSTER.bubbleHeight;
    const r = h / 2;
    const cx = w / 2;
    const { tailHeight: th, tailHalfWidth: tw } = CLUSTER;
    return (
        `M${r} 0H${w - r}A${r} ${r} 0 0 1 ${w - r} ${h}H${cx + tw}` +
        `Q${cx + 2} ${h + th * 0.6} ${cx} ${h + th}Q${cx - 2} ${h + th * 0.6} ${cx - tw} ${h}` +
        `H${r}A${r} ${r} 0 0 1 ${r} 0Z`
    );
});

function left(index: number): string {
    return `${CLUSTER.padding + index * CLUSTER.faceStep}px`;
}
</script>

<template>
    <!-- Several people close together on screen: their faces in one bubble. A face selects that
         person; the rest of the bubble zooms in until they separate. -->
    <div
        class="peer-cluster"
        :style="{ width: `${width}px`, height: `${CLUSTER.height}px` }"
        :title="members.map((m) => m.name).join(', ')"
    >
        <svg
            class="peer-cluster__bubble lt-hit"
            :width="width"
            :height="CLUSTER.bubbleHeight + CLUSTER.tailHeight"
            aria-hidden="true"
        >
            <path :d="bubble" class="peer-cluster__path" />
        </svg>
        <!-- Leftmost on top, both visually and for clicks. -->
        <span
            v-for="(member, i) in faces"
            :key="member.id"
            class="peer-cluster__face lt-hit"
            :data-member="member.id"
            :style="{ left: left(i), zIndex: faces.length - i + 1 }"
        >
            <UserAvatar
                :user-id="member.id"
                :name="member.name"
                :size="CLUSTER.faceSize"
                :ring-color="'var(--color-surface-container-highest)'"
                :ring-width="2"
                :dimmed="member.stale"
            />
        </span>
        <span
            v-if="overflow > 0"
            class="peer-cluster__face peer-cluster__more lt-hit"
            :style="{ left: left(faces.length) }"
            >+{{ overflow }}</span
        >
        <span class="peer-cluster__dot" :class="{ 'peer-cluster__dot--stale': allStale }" />
    </div>
</template>

<style>
.peer-cluster {
    position: relative;
}

/* The bubble is an SVG; keep it under the avatar faces instead of covering them. */
.peer-cluster > .peer-cluster__bubble {
    position: absolute;
    left: 0;
    top: 0;
    z-index: 0;
    overflow: visible;
    filter: drop-shadow(0 1px 3px color-mix(in srgb, var(--color-shadow) 35%, transparent));
}

/* The bubble is the same colour as the avatar rings on the map (the peer
   pill token), so a cluster reads as one object with the people list; the
   face rings and the dot border match it to cut the overlapping faces apart. */
.peer-cluster__path {
    fill: var(--color-surface-container-highest);
}

.peer-cluster__face {
    position: absolute;
    top: 4px;
    border-radius: var(--radius-full);
}

.peer-cluster__more {
    width: 44px;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--color-on-surface);
    box-shadow: inset 0 0 0 2px var(--color-surface-container-highest);
    color: var(--color-surface);
    font-size: 12px;
    font-weight: 700;
}

.peer-cluster__dot {
    position: absolute;
    left: 50%;
    bottom: 0;
    width: 12px;
    height: 12px;
    margin-left: -6px;
    border-radius: var(--radius-full);
    background: var(--color-beam);
    border: 2px solid var(--color-surface-container-highest);
    box-shadow: var(--shadow-level-1);
}

.peer-cluster__dot--stale {
    background: var(--color-outline);
}
</style>
