import type {
    FilterSpecification,
    Map as MapLibreMap,
    StyleSpecification,
    SymbolLayerSpecification
} from 'maplibre-gl';
import { config } from '../config';

export type MapStyle = 'standard' | 'satellite' | 'terrain';

/** Bus stops are noisy at city zoom levels; keep them for close-up navigation. */
const BUS_STOP_MIN_ZOOM = 18;
/** General amenities (shops, restaurants, services) can show one zoom level earlier. */
const OTHER_POI_ZOOM_SHIFT = -1;
const OTHER_POI_LAYERS = ['poi_r1', 'poi_r7', 'poi_r20'];
/**
 * Green-space pins read as tree clutter when spread over a city, and bus stops have their own
 * later layer. Keep both out of the general POI rank layers.
 */
const HIDDEN_POI_CLASSES = ['park', 'garden', 'dog_park', 'amusement_park', 'bus'];
const BUS_STOP_LAYER = 'poi_transit_bus';

export const MAP_STYLES: { id: MapStyle; label: string }[] = [
    { id: 'standard', label: 'Standard' },
    { id: 'satellite', label: 'Satellite' },
    { id: 'terrain', label: 'Terrain' }
];

const ESRI = 'Tiles &copy; Esri';
const TOPO =
    'Map data &copy; OpenStreetMap contributors, SRTM | Style &copy; <a href="https://opentopomap.org">OpenTopoMap</a>';

/**
 * MapLibre style for each map style. Standard is the vector OpenFreeMap style (free, no key),
 * which overrides the raster base; satellite and terrain stay raster because that is what those
 * sources provide. The phone app uses the same tile sources.
 */
export function styleFor(style: MapStyle): string | StyleSpecification {
    switch (style) {
        case 'satellite':
            return rasterStyle('#000', {
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
            });
        case 'terrain':
            return rasterStyle('#f2efe9', {
                opentopomap: {
                    type: 'raster',
                    tiles: ['https://a.tile.opentopomap.org/{z}/{x}/{y}.png'],
                    tileSize: 256,
                    maxzoom: 17,
                    attribution: TOPO
                }
            });
        default:
            return config.mapStyleUrl;
    }
}

/**
 * OpenFreeMap keeps bus stops, airports and railway stations in one `poi_transit` layer from zoom
 * 0. Split the bus stops into their own later layer so they do not clutter the city view, and let
 * ordinary POIs arrive one level earlier. Runs after every style load, because a style switch
 * replaces the layers. Custom styles without these OpenFreeMap layers are left alone.
 */
export function applyPoiZoom(map: MapLibreMap): void {
    const layers = map.getStyle().layers;
    const transit = layers.find((layer) => layer.id === 'poi_transit') as SymbolLayerSpecification | undefined;
    if (transit) {
        // Keep airports and railway stations at their original zoom; only bus stops move later.
        map.setFilter('poi_transit', ['match', ['get', 'class'], ['airport', 'rail'], true, false]);
        if (!map.getLayer(BUS_STOP_LAYER)) {
            const bus: SymbolLayerSpecification = {
                ...structuredClone(transit),
                id: BUS_STOP_LAYER,
                minzoom: BUS_STOP_MIN_ZOOM,
                filter: ['==', ['get', 'class'], 'bus']
            };
            const next = layers[layers.indexOf(transit) + 1];
            map.addLayer(bus, next?.id);
        }
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
    sources: Record<string, StyleSpecification['sources'][string]>
): StyleSpecification {
    return {
        version: 8,
        sources,
        layers: [
            { id: 'background', type: 'background', paint: { 'background-color': background } },
            ...Object.keys(sources).map((id) => ({
                id,
                type: 'raster' as const,
                source: id,
                minzoom: 0,
                maxzoom: 22
            }))
        ]
    };
}
