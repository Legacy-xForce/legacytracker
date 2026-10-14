<script setup lang="ts">
import L from 'leaflet';
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
const PANE = 'events';
const markers = new Map<string, { marker: L.Marker; event: CalendarEvent }>();
// Leaflet shows one popup at a time; this is the content of the open one.
let openDetails: HTMLElement | null = null;

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
function icon(event: CalendarEvent): L.DivIcon {
    const color = event.color ?? EVENT_FALLBACK_COLOR;
    return L.divIcon({
        html: `<div class="event-marker lt-hit" title="${escapeHtml(event.title)}" style="background:${color};color:${glyphColor(color)}">${icons.event}</div>`,
        className: 'lt-marker',
        iconSize: [44, 44],
        iconAnchor: [22, 22]
    });
}

function details(id: string): HTMLElement {
    closeDetails();
    openDetails = document.createElement('div');
    const entry = markers.get(id);
    if (!entry) return openDetails;
    // Popups read the clock when opened.
    render(h(EventDetails, { event: entry.event, now: Date.now() }), openDetails);
    // Content is built just before Leaflet pans the popup into view: keep it clear of the panels.
    const { top, right, bottom, left } = insets.value;
    Object.assign(entry.marker.getPopup()!.options, {
        autoPanPaddingTopLeft: [left + 16, top + 16],
        autoPanPaddingBottomRight: [right + 16, bottom + 16]
    });
    return openDetails;
}

function closeDetails() {
    if (openDetails) render(null, openDetails);
    openDetails = null;
}

function sync() {
    const target = map.value;
    if (!target) return;
    if (!target.getPane(PANE)) target.createPane(PANE).style.zIndex = '550';
    const placed = props.events.filter((event) => event.point !== null);
    const ids = new Set(placed.map((event) => event.id));
    for (const [id, entry] of markers) {
        if (ids.has(id)) continue;
        entry.marker.remove();
        markers.delete(id);
    }
    // Existing pins are updated in place, so an open popup stays open while places resolve.
    for (const event of placed) {
        const entry = markers.get(event.id);
        if (entry) {
            const before = entry.event;
            entry.event = event;
            if (before.point![0] !== event.point![0] || before.point![1] !== event.point![1]) {
                entry.marker.setLatLng(event.point!);
            }
            if (before.color !== event.color || before.title !== event.title) entry.marker.setIcon(icon(event));
            continue;
        }
        const marker = L.marker(event.point!, { pane: PANE, keyboard: false, icon: icon(event) })
            .bindPopup(() => details(event.id), { maxWidth: 320 })
            .on('popupclose', closeDetails)
            .addTo(target);
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
