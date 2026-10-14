import L from 'leaflet';
import { h, render, type Component } from 'vue';

/**
 * A Leaflet marker drawn by a Vue component. Updates patch the component in place, so pictures,
 * animations and transitions survive every position or status change. (Rebuilding the icon with
 * `setIcon` on each update is what made markers flicker.)
 */
export class VueMarker<P extends object> {
    readonly marker: L.Marker;
    private readonly element = document.createElement('div');

    constructor(
        latlng: L.LatLngExpression,
        private readonly component: Component,
        props: P,
        size: [number, number],
        anchor: [number, number],
        options: L.MarkerOptions = {}
    ) {
        this.update(props);
        // DivIcon adopts the element as its content and re-attaches it whenever the marker is re-added.
        const icon = L.divIcon({ html: this.element, className: 'lt-marker', iconSize: size, iconAnchor: anchor });
        this.marker = L.marker(latlng, { keyboard: false, ...options, icon });
    }

    update(props: P): void {
        render(h(this.component, props as Record<string, unknown>), this.element);
    }

    destroy(): void {
        this.marker.remove();
        render(null, this.element);
    }
}
