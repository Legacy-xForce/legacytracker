import type {
    FilterSpecification,
    LayerSpecification,
    Map as MapLibreMap,
    StyleSpecification,
    SymbolLayerSpecification
} from 'maplibre-gl';
import { config } from '../config';

export type MapStyle = 'standard' | 'satellite' | 'terrain';

/** General amenities (shops, restaurants, services) can show one zoom level earlier. */
const OTHER_POI_ZOOM_SHIFT = -1;
const OTHER_POI_LAYERS = ['poi_r1', 'poi_r7', 'poi_r20'];
/** Green-space pins read as tree clutter when spread over a city; keep the map quieter. */
const TREE_POI_CLASSES = ['park', 'garden', 'dog_park', 'amusement_park'];

/** Where the vector style keeps POIs and the assets its symbol layers need. */
const VECTOR_SOURCE = 'openmaptiles';
const POI_LAYER_IDS = ['poi_transit', 'poi_r1', 'poi_r7', 'poi_r20'];

export const MAP_STYLES: { id: MapStyle; label: string }[] = [
    { id: 'standard', label: 'Standard' },
    { id: 'satellite', label: 'Satellite' },
    { id: 'terrain', label: 'Terrain' }
];

const ESRI = 'Tiles &copy; Esri';
const TOPO =
    'Map data &copy; OpenStreetMap contributors, SRTM | Style &copy; <a href="https://opentopomap.org">OpenTopoMap</a>';

/** The vector style's POI layers plus the sprite and glyphs they draw with. */
export interface PoiOverlay {
    sprite?: StyleSpecification['sprite'];
    glyphs?: string;
    source: StyleSpecification['sources'][string];
    layers: LayerSpecification[];
}

let poiOverlay: PoiOverlay | null = null;
let poiOverlayRequest: Promise<PoiOverlay | null> | null = null;

/**
 * Satellite and terrain are raster tiles, which carry no POIs of their own. Reuse the vector
 * style's `poi_*` symbol layers (and its sprite, glyphs and source) so those views keep the same
 * amenities as Standard. Fetched once per session and cached; failures leave the raster styles
 * plain, and a non-vector style URL simply yields no overlay.
 */
export function preloadPoiOverlay(): Promise<PoiOverlay | null> {
    poiOverlayRequest ??= fetch(config.mapStyleUrl)
        .then((response) => {
            if (!response.ok) throw new Error(`Map style responded ${response.status}`);
            return response.json() as Promise<StyleSpecification>;
        })
        .then((style) => (poiOverlay = poisFrom(style)))
        .catch(() => {
            // Let a later switch retry instead of caching the failure forever.
            poiOverlayRequest = null;
            return null;
        });
    return poiOverlayRequest;
}

function poisFrom(style: StyleSpecification): PoiOverlay | null {
    const source = style.sources?.[VECTOR_SOURCE];
    if (!source) return null;
    // Keep the layers verbatim: applyPoiZoom tunes their filters and zoom ranges after load.
    const layers = (style.layers ?? []).filter((layer) => POI_LAYER_IDS.includes(layer.id));
    if (layers.length === 0) return null;
    return {
        sprite: style.sprite,
        glyphs: style.glyphs,
        source: structuredClone(source),
        layers: structuredClone(layers)
    };
}

/**
 * MapLibre style for each map style. Standard is the vector OpenFreeMap style (free, no key),
 * which overrides the raster base; satellite and terrain are raster because that is what those
 * sources provide, with the vector style's POIs overlaid when the overlay has loaded. The phone
 * app uses the same tile sources.
 */
export function styleFor(style: MapStyle, poi: PoiOverlay | null = poiOverlay): string | StyleSpecification {
    switch (style) {
        case 'satellite':
            return rasterStyle(
                '#000',
                {
                    'esri-imagery': {
                        type: 'raster',
                        tiles: [
                            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                        ],
                        tileSize: 256,
                        maxzoom: 18,
                        attribution: ESRI
                    },
                    'esri-reference': {
                        type: 'raster',
                        tiles: [
                            'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}'
                        ],
                        tileSize: 256,
                        maxzoom: 18
                    }
                },
                poi
            );
        case 'terrain':
            return rasterStyle(
                '#f2efe9',
                {
                    opentopomap: {
                        type: 'raster',
                        tiles: ['https://a.tile.opentopomap.org/{z}/{x}/{y}.png'],
                        tileSize: 256,
                        maxzoom: 17,
                        attribution: TOPO
                    }
                },
                poi
            );
        default:
            return config.mapStyleUrl;
    }
}

/**
 * OpenFreeMap keeps bus stops, airports and railway stations in one `poi_transit` layer from zoom
 * 0. Filter the bus stops out entirely, let ordinary POIs arrive one level earlier, and drop the
 * green-space pins. Runs after every style load, because a style switch replaces the layers.
 * Custom styles without these OpenFreeMap layers are left alone.
 */
export function applyPoiZoom(map: MapLibreMap): void {
    const layers = map.getStyle().layers;
    if (layers.some((layer) => layer.id === 'poi_transit')) {
        // Airports and railway stations stay at their original zoom; bus stops are too dense to keep.
        map.setFilter('poi_transit', ['match', ['get', 'class'], ['airport', 'rail'], true, false]);
    }
    const treeFilter: FilterSpecification = ['match', ['get', 'class'], TREE_POI_CLASSES, false, true];
    for (const id of OTHER_POI_LAYERS) {
        const layer = layers.find((candidate) => candidate.id === id) as SymbolLayerSpecification | undefined;
        if (!layer || typeof layer.minzoom !== 'number') continue;
        map.setFilter(id, layer.filter ? (['all', layer.filter, treeFilter] as FilterSpecification) : treeFilter);
        map.setLayerZoomRange(id, Math.max(0, layer.minzoom + OTHER_POI_ZOOM_SHIFT), layer.maxzoom ?? 24);
    }
}

function rasterStyle(
    background: string,
    sources: Record<string, StyleSpecification['sources'][string]>,
    poi: PoiOverlay | null = null
): StyleSpecification {
    const style: StyleSpecification = {
        version: 8,
        sources: poi ? { ...sources, [VECTOR_SOURCE]: poi.source } : sources,
        layers: [
            { id: 'background', type: 'background', paint: { 'background-color': background } },
            ...Object.keys(sources).map((id) => ({
                id,
                type: 'raster' as const,
                source: id,
                minzoom: 0,
                maxzoom: 22
            })),
            ...(poi?.layers ?? [])
        ]
    };
    if (poi) {
        style.sprite = poi.sprite;
        style.glyphs = poi.glyphs;
    }
    return style;
}
