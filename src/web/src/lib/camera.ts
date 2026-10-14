import L from 'leaflet';

/** Pixels of the map hidden behind panels and controls, per side. */
export interface Insets {
    top: number;
    right: number;
    bottom: number;
    left: number;
}

export const NO_INSETS: Insets = { top: 0, right: 0, bottom: 0, left: 0 };

/** The middle of the part of the map that isn't covered, in container pixels. */
export function visibleCenter(map: L.Map, insets: Insets): L.Point {
    const size = map.getSize();
    return L.point(
        insets.left + (size.x - insets.left - insets.right) / 2,
        insets.top + (size.y - insets.top - insets.bottom) / 2
    );
}

/** The map centre that shows `latlng` in the middle of the uncovered part, at `zoom`. */
export function centerShowing(map: L.Map, latlng: L.LatLng, zoom: number, insets: Insets): L.LatLng {
    const shift = visibleCenter(map, insets).subtract(map.getSize().divideBy(2));
    return map.unproject(map.project(latlng, zoom).subtract(shift), zoom);
}

/** fitBounds padding that keeps what is framed clear of the panels, plus a margin. */
export function framePadding(
    insets: Insets,
    margin: number
): Pick<L.FitBoundsOptions, 'paddingTopLeft' | 'paddingBottomRight'> {
    return {
        paddingTopLeft: [insets.left + margin, insets.top + margin],
        paddingBottomRight: [insets.right + margin, insets.bottom + margin]
    };
}

/**
 * Pans so `latlng` sits at `target` on screen, for following something frame by frame. Unlike
 * setView or an unanimated panTo, panBy doesn't reset the view, which would drop and reload every
 * tile (the whole map flickers).
 */
export function holdAt(map: L.Map, latlng: L.LatLng, target: L.Point): void {
    const offset = map.latLngToContainerPoint(latlng).subtract(target).round();
    if (offset.x !== 0 || offset.y !== 0) map.panBy(offset, { animate: false });
}
