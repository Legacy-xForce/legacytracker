/** Whether the viewer's device ships Apple Maps (iPhone, iPad, Mac), so directions open there. */
export function prefersAppleMaps(userAgent: string = navigator.userAgent): boolean {
    return /iPhone|iPad|iPod|Macintosh/.test(userAgent);
}

/** A link that opens turn-by-turn directions to a point: Apple Maps on Apple devices, Google Maps elsewhere. */
export function directionsUrl(latitude: number, longitude: number, apple: boolean = prefersAppleMaps()): string {
    const destination = `${latitude},${longitude}`;
    return apple
        ? `https://maps.apple.com/?daddr=${destination}&dirflg=d`
        : `https://www.google.com/maps/dir/?api=1&destination=${destination}&travelmode=driving`;
}
