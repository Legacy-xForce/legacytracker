/**
 * A small Mapbox GL JS stand-in for jsdom. The real library needs WebGL, which jsdom does not have;
 * this mock keeps the DOM markers, camera maths and style bookkeeping that the app and its tests
 * actually use.
 */

type Handler = (...args: unknown[]) => void;
type LngLatLike = [number, number] | { lng: number; lat: number };

function pair(value: LngLatLike): [number, number] {
    return Array.isArray(value) ? value : [value.lng, value.lat];
}

const TILE_SIZE = 512;

function mercator(lat: number): number {
    return Math.asinh(Math.tan((lat * Math.PI) / 180));
}

function unmercator(y: number): number {
    return (Math.atan(Math.sinh(y)) * 180) / Math.PI;
}

export class Map {
    readonly container: HTMLElement;
    private handlers = new globalThis.Map<string, Set<Handler>>();
    private sources = new globalThis.Map<string, unknown>();
    private layers = new globalThis.Map<string, { id: string }>();
    zoom: number;
    center: [number, number];
    style: unknown;
    minZoom = 0;
    maxZoom = 22;
    padding = { top: 0, right: 0, bottom: 0, left: 0 };
    readonly config = new globalThis.Map<string, unknown>();
    readonly touchZoomRotate = { disableRotation: () => {} };
    readonly dragRotate = { disable: () => {} };

    constructor(options: { container: HTMLElement; zoom?: number; center?: [number, number]; maxZoom?: number }) {
        this.container = options.container;
        this.container.classList.add('mapboxgl-map');
        this.zoom = options.zoom ?? 0;
        this.center = options.center ?? [0, 0];
        this.maxZoom = options.maxZoom ?? 22;
    }

    on(type: string, handler: Handler): this {
        let set = this.handlers.get(type);
        if (!set) this.handlers.set(type, (set = new Set()));
        set.add(handler);
        return this;
    }

    once(type: string, handler: Handler): this {
        const wrap = (...args: unknown[]) => {
            this.off(type, wrap);
            handler(...args);
        };
        return this.on(type, wrap);
    }

    off(type: string, handler?: Handler): this {
        if (handler) this.handlers.get(type)?.delete(handler);
        else this.handlers.delete(type);
        return this;
    }

    fire(type: string, ...args: unknown[]): this {
        for (const handler of [...(this.handlers.get(type) ?? [])]) handler(...args);
        return this;
    }

    getContainer(): HTMLElement {
        return this.container;
    }

    getCanvas(): HTMLElement {
        return this.container;
    }

    getCanvasContainer(): HTMLElement {
        return this.container;
    }

    getZoom(): number {
        return this.zoom;
    }

    getCenter(): { lng: number; lat: number } {
        return { lng: this.center[0], lat: this.center[1] };
    }

    getMaxZoom(): number {
        return this.maxZoom;
    }

    setMinZoom(zoom: number): this {
        this.minZoom = zoom;
        return this;
    }

    getMinZoom(): number {
        return this.minZoom;
    }

    project(value: LngLatLike, zoom = this.zoom): { x: number; y: number } {
        const [lng, lat] = pair(value);
        const world = TILE_SIZE * 2 ** zoom;
        const [clng, clat] = this.center;
        const x = ((lng + 180) / 360) * world;
        const y = ((1 - mercator(lat) / Math.PI) / 2) * world;
        const cx = ((clng + 180) / 360) * world;
        const cy = ((1 - mercator(clat) / Math.PI) / 2) * world;
        return {
            x: x - cx + this.container.clientWidth / 2,
            y: y - cy + this.container.clientHeight / 2
        };
    }

    unproject(point: { x: number; y: number } | [number, number], zoom = this.zoom): { lng: number; lat: number } {
        const [x, y] = Array.isArray(point) ? point : [point.x, point.y];
        const world = TILE_SIZE * 2 ** zoom;
        const [clng, clat] = this.center;
        const cx = ((clng + 180) / 360) * world;
        const cy = ((1 - mercator(clat) / Math.PI) / 2) * world;
        const wx = x + cx - this.container.clientWidth / 2;
        const wy = y + cy - this.container.clientHeight / 2;
        return {
            lng: (wx / world) * 360 - 180,
            lat: unmercator((1 - (2 * wy) / world) * Math.PI)
        };
    }

    fitBounds(bounds: [[number, number], [number, number]], options: { maxZoom?: number } = {}): this {
        const [[west, south], [east, north]] = bounds;
        this.center = [(west + east) / 2, (south + north) / 2];
        this.zoom = Math.min(options.maxZoom ?? this.maxZoom, 10);
        this.fire('moveend');
        return this;
    }

    flyTo(options: { center?: [number, number]; zoom?: number }): this {
        if (options.center) this.center = options.center;
        if (options.zoom !== undefined) this.zoom = options.zoom;
        this.fire('moveend');
        return this;
    }

    jumpTo(options: { center?: [number, number]; zoom?: number }): this {
        return this.flyTo(options);
    }

    easeTo(options: { center?: [number, number]; zoom?: number }): this {
        return this.flyTo(options);
    }

    panBy(): this {
        return this;
    }

    zoomIn(): this {
        this.zoom = Math.min(this.maxZoom, this.zoom + 1);
        this.fire('zoomend');
        return this;
    }

    zoomOut(): this {
        this.zoom = Math.max(this.minZoom, this.zoom - 1);
        this.fire('zoomend');
        return this;
    }

    setStyle(style: unknown): this {
        this.style = style;
        this.fire('style.load');
        return this;
    }

    isStyleLoaded(): boolean {
        return true;
    }

    getStyle(): { layers: { id: string }[] } {
        return { layers: [] };
    }

    setConfigProperty(scope: string, name: string, value: unknown): this {
        this.config.set(`${scope}.${name}`, value);
        return this;
    }

    addSource(id: string, source: unknown): this {
        this.sources.set(id, source);
        return this;
    }

    removeSource(id: string): this {
        this.sources.delete(id);
        return this;
    }

    getSource(id: string): unknown {
        return this.sources.get(id);
    }

    addLayer(layer: { id: string }): this {
        this.layers.set(layer.id, layer);
        return this;
    }

    removeLayer(id: string): this {
        this.layers.delete(id);
        return this;
    }

    addControl(control: { onAdd(map: Map): HTMLElement }): this {
        control.onAdd(this);
        return this;
    }

    getLayer(id: string): { id: string } | undefined {
        return this.layers.get(id);
    }

    setPadding(padding: { top: number; right: number; bottom: number; left: number }): this {
        this.padding = padding;
        return this;
    }

    remove(): this {
        this.fire('remove');
        this.container.innerHTML = '';
        return this;
    }
}

export class AttributionControl {
    constructor(readonly options: { compact?: boolean } = {}) {}

    onAdd(map: Map): HTMLElement {
        const element = document.createElement('div');
        element.className = 'mapboxgl-ctrl mapboxgl-ctrl-attrib';
        map.getContainer().appendChild(element);
        return element;
    }

    onRemove(): void {}
}

export class Marker {
    readonly element: HTMLElement;
    lngLat: [number, number] = [0, 0];

    constructor(options: { element?: HTMLElement } = {}) {
        this.element = options.element ?? document.createElement('div');
        this.element.classList.add('mapboxgl-marker');
    }

    setLngLat(value: LngLatLike): this {
        this.lngLat = pair(value);
        return this;
    }

    getLngLat(): { lng: number; lat: number } {
        return { lng: this.lngLat[0], lat: this.lngLat[1] };
    }

    addTo(map: Map): this {
        if (this.element.parentElement !== map.getContainer()) map.getContainer().appendChild(this.element);
        return this;
    }

    remove(): this {
        this.element.remove();
        return this;
    }

    getElement(): HTMLElement {
        return this.element;
    }

    isPopupOpen(): boolean {
        return false;
    }

    togglePopup(): this {
        return this;
    }
}

export class Popup {
    readonly element = document.createElement('div');
    private handlers = new globalThis.Map<string, Set<Handler>>();
    private open = false;

    constructor() {
        this.element.className = 'mapboxgl-popup';
    }

    on(type: string, handler: Handler): this {
        let set = this.handlers.get(type);
        if (!set) this.handlers.set(type, (set = new Set()));
        set.add(handler);
        return this;
    }

    off(type: string, handler: Handler): this {
        this.handlers.get(type)?.delete(handler);
        return this;
    }

    fire(type: string): this {
        for (const handler of [...(this.handlers.get(type) ?? [])]) handler();
        return this;
    }

    setLngLat(): this {
        return this;
    }

    setDOMContent(content: HTMLElement): this {
        this.element.replaceChildren(content);
        return this;
    }

    addTo(map: Map): this {
        map.getContainer().appendChild(this.element);
        this.open = true;
        return this;
    }

    remove(): this {
        if (!this.open) return this;
        this.open = false;
        this.element.remove();
        this.fire('close');
        return this;
    }

    isOpen(): boolean {
        return this.open;
    }

    getElement(): HTMLElement {
        return this.element;
    }
}

export const accessToken: string | null = null;

export default { Map, Marker, Popup, AttributionControl, accessToken };
