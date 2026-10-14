import L from 'leaflet';

// Glide bounds, as in the app: long enough that movement reads as continuous, short enough that a
// late update doesn't leave the marker crawling far behind reality.
const MIN_GLIDE_MS = 300;
const MAX_GLIDE_MS = 4_000;
const FIRST_GLIDE_MS = 1_000;

/**
 * Where a marker is drawn while it glides from its previous position to each new one, over about
 * the time that passed between the two updates, so it is always in motion rather than hopping and
 * then sitting still until the next fix.
 */
export class Motion {
    /** Where the marker is drawn now. */
    shown: L.LatLng;
    /** The newest reported position. */
    target: L.LatLng;
    private from: L.LatLng;
    private start = 0;
    private duration = 0;
    private lastUpdate: number | null = null;

    constructor(at: L.LatLng) {
        this.shown = this.target = this.from = at;
    }

    get gliding(): boolean {
        return !this.shown.equals(this.target);
    }

    /** Starts gliding towards `target`; false when there is nowhere new to go. */
    moveTo(target: L.LatLng, now: number): boolean {
        if (target.equals(this.target)) return false;
        const interval = this.lastUpdate === null ? null : now - this.lastUpdate;
        this.lastUpdate = now;
        this.from = this.shown;
        this.target = target;
        this.start = now;
        this.duration = interval === null ? FIRST_GLIDE_MS : Math.min(MAX_GLIDE_MS, Math.max(MIN_GLIDE_MS, interval));
        return true;
    }

    /** Jumps straight to `target`, e.g. when it is too far away for a glide to make sense. */
    jumpTo(target: L.LatLng, now: number): void {
        this.lastUpdate = now;
        this.shown = this.from = this.target = target;
    }

    /** Advances the glide to `now` (linear: chained segments don't stutter at every fix). */
    step(now: number): void {
        const t = this.duration > 0 ? Math.min(1, (now - this.start) / this.duration) : 1;
        this.shown =
            t >= 1
                ? this.target
                : L.latLng(
                      this.from.lat + (this.target.lat - this.from.lat) * t,
                      this.from.lng + (this.target.lng - this.from.lng) * t
                  );
    }
}
