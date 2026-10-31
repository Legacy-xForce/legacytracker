/**
 * Fixed colours that are not part of a theme: map-layer paint, identity and
 * podium colours. The phone app's `AppPalette` carries the same values, so a
 * person, event or place looks the same on both. Everything else uses the
 * theme tokens in `style.css`.
 */
export const palette = {
    white: '#ffffff',
    black: '#000000',
    mapAccent: '#82d5c8',
    stale: '#9e9e9e',
    staleBadge: '#616161',
    eventFallback: '#7c4dff',
    medals: ['#f5c542', '#c0c7cc', '#d08b54'],
    onMedal: '#1a1300',
    // Name chips and halos drawn on the map.
    nameChip: 'rgb(37 43 42 / 0.92)'
} as const;
