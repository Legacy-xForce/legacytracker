<script setup lang="ts">
import { computed } from 'vue';
import { selfFirst, type Viewer } from '../../lib/viewers';
import UserAvatar from '../UserAvatar.vue';

const props = defineProps<{ viewers: Viewer[]; selfId: string }>();

// At most this many circles, like the app: with more viewers, the last circle counts the rest.
const MAX_CIRCLES = 3;
const FACE = 32;
const STEP = FACE - 10;
const RING = 'var(--color-surface-container-high)';

const ordered = computed(() => selfFirst(props.viewers, props.selfId));
const faces = computed(() =>
    ordered.value.length > MAX_CIRCLES ? ordered.value.slice(0, MAX_CIRCLES - 1) : ordered.value
);
const more = computed(() => ordered.value.length - faces.value.length);
const circles = computed(() => faces.value.length + (more.value > 0 ? 1 : 0));
const names = computed(() =>
    ordered.value.map((viewer) => (viewer.id === props.selfId ? 'you' : viewer.name)).join(', ')
);
</script>

<template>
    <Transition
        enter-from-class="opacity-0 scale-75"
        enter-active-class="transition duration-medium ease-standard"
        leave-active-class="transition duration-medium ease-standard"
        leave-to-class="opacity-0 scale-75"
    >
        <!-- Who has the map open right now, us included. Faces only, like the app. -->
        <div
            v-if="ordered.length > 0"
            class="bg-surface-container-high shadow-level-1 origin-left rounded-full p-[3px]"
            role="img"
            :aria-label="`Viewing the map: ${names}`"
            :title="`Viewing the map: ${names}`"
        >
            <div
                class="duration-medium ease-standard relative transition-[width]"
                :style="{ width: `${FACE + (circles - 1) * STEP}px`, height: `${FACE}px` }"
            >
                <TransitionGroup enter-from-class="opacity-0 scale-0" leave-to-class="opacity-0 scale-0">
                    <span
                        v-for="(viewer, i) in faces"
                        :key="viewer.id"
                        class="duration-medium ease-standard absolute top-0 transition-all"
                        :style="{ left: `${i * STEP}px` }"
                        :data-viewer="viewer.id"
                    >
                        <UserAvatar
                            :user-id="viewer.id"
                            :name="viewer.name"
                            :size="FACE"
                            :ring-color="RING"
                            :ring-width="2"
                        />
                    </span>
                    <span
                        v-if="more > 0"
                        key="more"
                        class="bg-surface-container-highest type-label-md duration-medium ease-standard absolute top-0 flex items-center justify-center rounded-full font-bold transition-all"
                        :style="{
                            left: `${faces.length * STEP}px`,
                            width: `${FACE}px`,
                            height: `${FACE}px`,
                            boxShadow: `inset 0 0 0 2px ${RING}`
                        }"
                    >
                        +{{ more }}
                    </span>
                </TransitionGroup>
            </div>
        </div>
    </Transition>
</template>
