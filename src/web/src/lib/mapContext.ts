import type { Map as MapboxMap } from 'mapbox-gl';
import { inject, type InjectionKey, type Ref, type ShallowRef } from 'vue';
import { NO_INSETS, type Insets } from './camera';

/** The Mapbox map owned by PeersMap, shared with the overlay layers drawn inside it. */
export const mapKey: InjectionKey<ShallowRef<MapboxMap | null>> = Symbol('map');

/** How much of the map the panels cover, so overlays can frame things in the visible part. */
export const insetsKey: InjectionKey<Ref<Insets>> = Symbol('insets');

export function useMap(): ShallowRef<MapboxMap | null> {
    const map = inject(mapKey);
    if (!map) throw new Error('Map layers must be placed inside <PeersMap>.');
    return map;
}

export function useInsets(): Ref<Insets> {
    return inject(insetsKey, { value: NO_INSETS } as Ref<Insets>);
}
