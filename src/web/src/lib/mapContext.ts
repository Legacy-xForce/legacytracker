import type L from 'leaflet';
import { inject, type InjectionKey, type ShallowRef } from 'vue';

/** The Leaflet map owned by PeersMap, shared with the overlay layers drawn inside it. */
export const mapKey: InjectionKey<ShallowRef<L.Map | null>> = Symbol('map');

export function useMap(): ShallowRef<L.Map | null> {
    const map = inject(mapKey);
    if (!map) throw new Error('Map layers must be placed inside <PeersMap>.');
    return map;
}
