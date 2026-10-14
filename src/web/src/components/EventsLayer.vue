<script setup lang="ts">
import L from 'leaflet';
import { onBeforeUnmount, watch } from 'vue';
import { timing, type CalendarEvent } from '../lib/events';
import { escapeHtml } from '../lib/format';
import { useMap } from '../lib/mapContext';

const props = defineProps<{ events: CalendarEvent[]; now: number }>();
const map = useMap();
let group: L.LayerGroup | null = null;

function popup(event: CalendarEvent): string {
    const coming = event.attendees.length
        ? `<div>Coming: ${event.attendees.map((a) => escapeHtml(a.name)).join(', ')}</div>`
        : '';
    return (
        `<strong>${escapeHtml(event.title)}</strong>` +
        `<div>${escapeHtml(timing(event, props.now))}</div>` +
        (event.location ? `<div>${escapeHtml(event.location)}</div>` : '') +
        coming
    );
}

function draw() {
    group?.remove();
    group = null;
    if (!map.value) return;
    group = L.layerGroup(
        props.events
            .filter((event) => event.point !== null)
            .map((event) =>
                L.marker(event.point!, {
                    keyboard: false,
                    icon: L.divIcon({
                        html: `<div class="event-marker" style="background:${event.color ?? '#8b5cf6'}">★</div>`,
                        className: 'peer-marker-wrap',
                        iconSize: [30, 30],
                        iconAnchor: [15, 15]
                    })
                }).bindPopup(() => popup(event))
            )
    ).addTo(map.value);
}

// Popups read the clock when opened, so a ticking `now` must not redraw (and close) them.
watch([map, () => props.events], draw, { immediate: true });
onBeforeUnmount(() => group?.remove());
</script>

<template><span hidden /></template>
