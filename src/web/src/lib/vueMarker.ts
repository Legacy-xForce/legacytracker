import { Marker, type MarkerOptions } from 'mapbox-gl';
import { h, render, type Component } from 'vue';
import type { LatLng } from './geo';

/**
 * A Mapbox marker drawn by a Vue component. Updates patch the component in place, so pictures,
 * animations and transitions survive every position or status change. (Rebuilding the icon on
 * each update is what made markers flicker.)
 */
export class VueMarker<P extends object> {
    readonly marker: Marker;
    readonly element = document.createElement('div');
    private attached = false;

    constructor(
        at: LatLng,
        private readonly component: Component,
        props: P,
        size: [number, number],
        anchor: [number, number],
        options: Omit<MarkerOptions, 'element' | 'anchor' | 'offset'> = {}
    ) {
        this.element.className = 'lt-marker';
        this.element.style.width = `${size[0]}px`;
        this.element.style.height = `${size[1]}px`;
        // The box is larger than what the marker draws (beams, badges); only `.lt-hit` takes clicks.
        this.element.style.pointerEvents = 'none';
        this.update(props);
        this.marker = new Marker({
            ...options,
            element: this.element,
            // Match the old iconAnchor: the given point inside the box sits on the map position.
            anchor: 'top-left',
            offset: [-anchor[0], -anchor[1]]
        }).setLngLat([at.lng, at.lat]);
    }

    addTo(map: import('mapbox-gl').Map): void {
        if (this.attached) return;
        this.marker.addTo(map);
        this.attached = true;
    }

    remove(): void {
        if (!this.attached) return;
        this.marker.remove();
        this.attached = false;
    }

    setLatLng(at: LatLng): void {
        this.marker.setLngLat([at.lng, at.lat]);
    }

    setZIndex(z: number): void {
        this.element.style.zIndex = `${z}`;
    }

    /** Listens on the marker element, so clicks on its clickable children bubble here. */
    onClick(handler: (event: MouseEvent) => void): void {
        this.element.addEventListener('click', handler);
    }

    update(props: P): void {
        render(h(this.component, props as Record<string, unknown>), this.element);
    }

    destroy(): void {
        this.remove();
        render(null, this.element);
    }
}
