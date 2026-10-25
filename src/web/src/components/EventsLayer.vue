<script setup lang="ts">
import { Marker, Popup } from 'mapbox-gl';
import { h, onBeforeUnmount, render, watch } from 'vue';
import EventDetails from './map/EventDetails.vue';
import { EVENT_FALLBACK_COLOR, type CalendarEvent } from '../lib/events';
import { escapeHtml } from '../lib/format';
import { icons } from '../lib/icons';
import { useInsets, useMap } from '../lib/mapContext';

const props = defineProps<{ events: CalendarEvent[] }>();
const map = useMap();
const insets = useInsets();
// Below the people, so an event never hides someone's marker.
const Z_INDEX = 1;
const markers = new Map<string, { marker: Marker; event: CalendarEvent }>();
let popup: Popup | null = null;
let openDetails: HTMLElement | null = null;
let openEventId: string | null = null;

/** Light event colours get a dark glyph, as Flutter's brightness estimate picks it. */
function glyphColor(hex: string): string {
    const [r, g, b] = [1, 3, 5].map((i) => {
        const c = parseInt(hex.slice(i, i + 2), 16) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return (luminance + 0.05) ** 2 > 0.15 ? 'rgb(0 0 0 / 0.87)' : '#fff';
}

// A rounded-square calendar pin in the event's colour: deliberately unlike the round people.
function icon(event: CalendarEvent): string {
    const color = event.color ?? EVENT_FALLBACK_COLOR;
    return `<div class="event-marker lt-hit" title="${escapeHtml(event.title)}" style="background:${color};color:${glyphColor(color)}">${icons.event}</div>`;
}

function element(event: CalendarEvent): HTMLElement {
    const el = document.createElement('div');
    el.className = 'lt-marker';
    el.style.width = '44px';
    el.style.height = '44px';
    el.style.pointerEvents = 'none';
    el.style.zIndex = `${Z_INDEX}`;
    el.innerHTML = icon(event);
    return el;
}

function closeDetails() {
    const details = openDetails;
    const current = popup;
    openDetails = null;
    popup = null;
    openEventId = null;
    current?.remove();
    if (details) render(null, details);
    map.value?.setPadding({ top: 0, right: 0, bottom: 0, left: 0 });
}

function openDetailsFor(event: CalendarEvent) {
    const target = map.value;
    if (!target || event.point === null) return;
    closeDetails();
    openEventId = event.id;
    openDetails = document.createElement('div');
    // Popups read the clock when opened.
    render(h(EventDetails, { event, now: Date.now() }), openDetails);
    // Keep the popup clear of the panels, like the rest of the map framing.
    const { top, right, bottom, left } = insets.value;
    target.setPadding({ top: top + 16, right: right + 16, bottom: bottom + 16, left: left + 16 });
    popup = new Popup({ maxWidth: '320px', offset: 16, closeButton: true, className: 'lt-popup' })
        .setLngLat([event.point[1], event.point[0]])
        .setDOMContent(openDetails)
        .addTo(target);
    popup.on('close', closeDetails);
}

function sync() {
    const target = map.value;
    if (!target) return;
    const placed = props.events.filter((event) => event.point !== null);
    const ids = new Set(placed.map((event) => event.id));
    for (const [id, entry] of markers) {
        if (ids.has(id)) continue;
        if (openEventId === id) closeDetails();
        entry.marker.remove();
        markers.delete(id);
    }
    // Existing pins are updated in place, so an open popup stays open while places resolve.
    for (const event of placed) {
        const entry = markers.get(event.id);
        if (entry) {
            const before = entry.event;
            entry.event = event;
            const point = event.point!;
            if (before.point![0] !== point[0] || before.point![1] !== point[1]) {
                entry.marker.setLngLat([point[1], point[0]]);
            }
            if (before.color !== event.color || before.title !== event.title) {
                entry.marker.getElement().innerHTML = icon(event);
            }
            continue;
        }
        const point = event.point!;
        const marker = new Marker({ element: element(event), anchor: 'top-left', offset: [-22, -22] })
            .setLngLat([point[1], point[0]])
            .addTo(target);
        // A marker click is also a map click; without stopping it, the popup opens and closes at once.
        marker.getElement().addEventListener('click', (domEvent) => {
            domEvent.stopPropagation();
            openDetailsFor(event);
        });
        markers.set(event.id, { marker, event });
    }
}

// Only the list matters: popups read the clock when they open.
watch([map, () => props.events], sync, { immediate: true });
onBeforeUnmount(() => {
    closeDetails();
    for (const { marker } of markers.values()) marker.remove();
    markers.clear();
});
</script>

<template><span hidden /></template>

<style>
.event-marker {
    width: 36px;
    height: 36px;
    margin: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 12px;
    border: 2.5px solid #fff;
    box-shadow: 0 0 6px rgb(0 0 0 / 0.4);
    font-size: 22px;
}
</style>
