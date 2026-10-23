import type {
    FilterSpecification,
    LayerSpecification,
    Map as MapLibreMap,
    RasterLayerSpecification,
    StyleSpecification,
    SymbolLayerSpecification
} from 'maplibre-gl';
import { config } from '../config';

export type MapStyle = 'standard' | 'satellite' | 'terrain';

/** General amenities (shops, restaurants, services) can show one zoom level earlier. */
const OTHER_POI_ZOOM_SHIFT = -1;
const OTHER_POI_LAYERS = ['poi_r1', 'poi_r7', 'poi_r20'];
/** Bus stops are too dense at any zoom, and green-space pins read as tree clutter. */
const HIDDEN_POI_CLASSES = ['bus', 'park', 'garden', 'dog_park', 'amusement_park'];

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
/**
 * Esri bakes its place labels into the reference raster, so their contrast can only be tuned
 * relative to the imagery underneath: dim the imagery's highlights and push the labels' mid-tones
 * apart. Both are subtle enough to leave the photography looking normal.
 */
const IMAGERY_BRIGHTNESS_MAX = 0.85;
const REFERENCE_CONTRAST = 0.4;

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
 * The vector style draws POI names in mid grey, in italics, with a thin halo. That works on its
 * pale basemap but disappears over photography, so the overlay uses the treatment satellite maps
 * use instead: white text with a dark casing, upright rather than italic.
 */
const IMAGERY_LABEL_PAINT = {
    'text-color': '#ffffff',
    'text-halo-color': 'rgba(0, 0, 0, 0.8)',
    'text-halo-width': 1.6,
    'text-halo-blur': 0.5
} satisfies NonNullable<SymbolLayerSpecification['paint']>;
const IMAGERY_LABEL_LAYOUT = {
    'text-font': ['Noto Sans Regular']
} satisfies NonNullable<SymbolLayerSpecification['layout']>;

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
    // Keep the layers' layout and filters: applyPoiZoom tunes the filters and zoom ranges after load.
    const layers = (style.layers ?? [])
        .filter((layer) => POI_LAYER_IDS.includes(layer.id))
        .map((layer) => {
            const clone = structuredClone(layer);
            if (clone.type === 'symbol') {
                clone.layout = { ...clone.layout, ...IMAGERY_LABEL_LAYOUT };
                clone.paint = { ...clone.paint, ...IMAGERY_LABEL_PAINT };
            }
            return clone;
        });
    if (layers.length === 0) return null;
    return {
        sprite: style.sprite,
        glyphs: style.glyphs,
        source: structuredClone(source),
        layers
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
                poi,
                {
                    'esri-imagery': { 'raster-brightness-max': IMAGERY_BRIGHTNESS_MAX },
                    'esri-reference': { 'raster-contrast': REFERENCE_CONTRAST }
                }
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
 * 0, but bus stops also come through the ranked `poi_r*` layers, which filter on `rank` alone.
 * Drop them from both, let ordinary POIs arrive one level earlier, and hide the green-space pins.
 * Runs after every style load, because a style switch replaces the layers. Custom styles without
 * these OpenFreeMap layers are left alone.
 */
export function applyPoiZoom(map: MapLibreMap): void {
    const layers = map.getStyle().layers;
    if (layers.some((layer) => layer.id === 'poi_transit')) {
        // Airports and railway stations stay at their original zoom; bus stops are too dense to keep.
        map.setFilter('poi_transit', ['match', ['get', 'class'], ['airport', 'rail'], true, false]);
    }
    const hiddenFilter: FilterSpecification = ['match', ['get', 'class'], HIDDEN_POI_CLASSES, false, true];
    for (const id of OTHER_POI_LAYERS) {
        const layer = layers.find((candidate) => candidate.id === id) as SymbolLayerSpecification | undefined;
        if (!layer || typeof layer.minzoom !== 'number') continue;
        map.setFilter(id, layer.filter ? (['all', layer.filter, hiddenFilter] as FilterSpecification) : hiddenFilter);
        map.setLayerZoomRange(id, Math.max(0, layer.minzoom + OTHER_POI_ZOOM_SHIFT), layer.maxzoom ?? 24);
    }
}

function rasterStyle(
    background: string,
    sources: Record<string, StyleSpecification['sources'][string]>,
    poi: PoiOverlay | null = null,
    paint: Record<string, RasterLayerSpecification['paint']> = {}
): StyleSpecification {
    const style: StyleSpecification = {
        version: 8,
        sources: poi ? { ...sources, [VECTOR_SOURCE]: poi.source } : sources,
        layers: [
            { id: 'background', type: 'background', paint: { 'background-color': background } },
            ...Object.keys(sources).map((id) => {
                const layerPaint = paint[id];
                return {
                    id,
                    type: 'raster' as const,
                    source: id,
                    minzoom: 0,
                    maxzoom: 22,
                    ...(layerPaint ? { paint: layerPaint } : {})
                };
            }),
            ...(poi?.layers ?? [])
        ]
    };
    if (poi) {
        style.sprite = poi.sprite;
        style.glyphs = poi.glyphs;
    }
    return style;
}
