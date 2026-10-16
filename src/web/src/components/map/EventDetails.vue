<script setup lang="ts">
import UserAvatar from '../UserAvatar.vue';
import Icon from '../ui/Icon.vue';
import { EVENT_FALLBACK_COLOR, eventUrl, timing, type CalendarEvent } from '../../lib/events';

defineProps<{ event: CalendarEvent; now: number }>();
</script>

<template>
    <!-- Name, when it starts (or ends, once running) and who is coming, like the app's sheet. -->
    <div class="w-64">
        <div class="flex items-center gap-2.5">
            <span class="size-3.5 shrink-0 rounded" :style="{ background: event.color ?? EVENT_FALLBACK_COLOR }" />
            <h3 class="type-title-md font-semibold">{{ event.title }}</h3>
        </div>
        <p class="type-title-sm mt-2">{{ timing(event, now) }}</p>
        <p v-if="event.location" class="type-body-md text-on-surface-variant mt-1">{{ event.location }}</p>
        <p class="type-label-lg mt-4">
            {{ event.attendees.length === 0 ? 'Nobody yet' : `${event.attendees.length} going` }}
        </p>
        <ul v-if="event.attendees.length" class="mt-2 flex flex-wrap gap-x-3 gap-y-2">
            <li v-for="person in event.attendees" :key="person.id" class="type-body-md flex items-center gap-1.5">
                <UserAvatar :user-id="person.id" :name="person.name" :picture-url="person.pictureUrl" :size="28" />
                {{ person.name }}
            </li>
        </ul>
        <a
            :href="eventUrl(event)"
            target="_blank"
            rel="noopener noreferrer"
            class="text-primary type-label-lg mt-4 inline-flex items-center gap-1.5 hover:underline"
        >
            Open in Legacy Calendar
            <Icon name="openInNew" :size="16" />
        </a>
    </div>
</template>
