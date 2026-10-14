import L from 'leaflet';

export type MapStyle = 'standard' | 'satellite' | 'terrain';

export const MAP_STYLES: { id: MapStyle; label: string }[] = [
    { id: 'standard', label: 'Standard' },
    { id: 'satellite', label: 'Satellite' },
    { id: 'terrain', label: 'Terrain' }
];

const OSM = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
const ESRI = 'Tiles &copy; Esri';
const TOPO =
    'Map data &copy; OpenStreetMap contributors, SRTM | Style &copy; <a href="https://opentopomap.org">OpenTopoMap</a>';

// The same tile sources as the phone app.
export function tileLayers(style: MapStyle): L.TileLayer[] {
    switch (style) {
        case 'satellite':
            return [
                L.tileLayer(
                    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                    {
                        attribution: ESRI,
                        maxZoom: 18
                    }
                ),
                L.tileLayer(
                    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                    { maxZoom: 18 }
                )
            ];
        case 'terrain':
            return [
                L.tileLayer('https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png', {
                    attribution: TOPO,
                    subdomains: 'abc',
                    maxZoom: 17
                })
            ];
        default:
            return [
                L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                    attribution: OSM,
                    subdomains: 'abc',
                    maxZoom: 19
                })
            ];
    }
}
