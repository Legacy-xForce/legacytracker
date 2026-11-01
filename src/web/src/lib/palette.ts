/**
 * Fixed colours that are not part of a theme: map-layer paint, identity and
 * podium colours. The phone app's `AppPalette` carries the same values, so a
 * person, event or place looks the same on both. Everything else uses the
 * theme tokens in `style.css`.
 */
export const palette = {
    white: '#ffffff',
    black: '#000000',
    stale: '#9e9e9e',
    staleBadge: '#616161',
    eventFallback: '#7c4dff',
    medals: ['#f5c542', '#c0c7cc', '#d08b54'],
    onMedal: '#1a1300'
} as const;

/**
 * The current theme's value of a colour token, as a colour Mapbox paint accepts (a CSS variable
 * cannot be used there). Falls back to a neutral grey when the token is not set, as in a test
 * without the styles.
 */
export function themeColor(token: string, fallback: string = palette.stale): string {
    const value = getComputedStyle(document.documentElement).getPropertyValue(`--color-${token}`).trim();
    return value || fallback;
}
