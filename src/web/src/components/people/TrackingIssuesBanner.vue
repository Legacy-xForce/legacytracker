<script setup lang="ts">
import { computed, ref } from 'vue';
import Icon from '../ui/Icon.vue';
import { issueCopy, type TrackingIssue } from '../../lib/tracking-issues';

const props = defineProps<{ issues: TrackingIssue[]; name: string; self: boolean }>();

const copies = computed(() => props.issues.map((issue) => issueCopy(issue, { name: props.name, self: props.self })));
// One problem gets its own headline; several share one and are listed underneath.
const title = computed(() =>
    copies.value.length === 1 ? copies.value[0].title : 'Location updates are being blocked'
);
const expanded = ref(false);
</script>

<template>
    <section
        v-if="issues.length > 0"
        role="status"
        data-testid="tracking-issues"
        class="text-on-surface mb-3 rounded-2xl border px-4 py-3.5"
        :style="{
            borderColor: 'color-mix(in srgb, var(--color-paused) 45%, transparent)',
            background: 'color-mix(in srgb, var(--color-paused) 12%, transparent)'
        }"
    >
        <div class="flex items-start gap-3">
            <Icon name="locationOff" :size="24" class="mt-0.5" :style="{ color: 'var(--color-paused)' }" />
            <div class="min-w-0 flex-1">
                <h3 class="type-title-sm font-bold">{{ title }}</h3>
                <p v-if="copies.length === 1" class="type-body-md mt-0.5">{{ copies[0].summary }}</p>
                <ul v-else class="type-body-md mt-0.5 list-disc space-y-0.5 pl-4">
                    <li v-for="(copy, index) in copies" :key="issues[index]">{{ copy.summary }}</li>
                </ul>
                <button
                    type="button"
                    class="type-body-md mt-1 font-medium underline underline-offset-2"
                    :aria-expanded="expanded"
                    @click="expanded = !expanded"
                >
                    {{ expanded ? 'Hide steps' : 'Learn how to fix this' }}
                </button>
                <div v-if="expanded" class="type-body-md mt-2 space-y-2">
                    <div v-for="(copy, index) in copies" :key="issues[index]">
                        <p v-if="copies.length > 1" class="font-semibold">{{ copy.title }}</p>
                        <ol class="list-decimal space-y-0.5 pl-5">
                            <li v-for="step in copy.steps" :key="step">{{ step }}</li>
                        </ol>
                    </div>
                </div>
            </div>
        </div>
    </section>
</template>
