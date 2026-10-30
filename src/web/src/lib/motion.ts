import { sameLatLng, type LatLng } from './geo';

// Glide bounds, as in the app: long enough that movement reads as continuous, short enough that a
// late update doesn't leave the marker crawling far behind reality.
const MIN_GLIDE_MS = 300;
const MAX_GLIDE_MS = 4_000;
const FIRST_GLIDE_MS = 1_000;
// Fixes rarely arrive on the beat, so a glide is timed from the average gap and runs well past it: the
// marker is still moving when the next fix lands instead of standing still waiting for it. The price
// is a marker that trails reality by about a gap; a backlog is absorbed by the next glide.
const GLIDE_SLACK = 1.5;
// How much of each new gap goes into the running average the glide is timed from.
const GAP_WEIGHT = 0.3;
// Past this long without a fix the marker is stale (the tab was in the background or the user sat
// still): it jumps to the new position instead of crawling there.
const STALE_MS = 15_000;

/**
 * Where a marker is drawn while it glides along the route of the fixes it has been sent, at a steady
 * pace. A new fix extends the route from the marker's current spot through the waypoints it has not
 * reached yet, and the whole remainder is re-timed to the average gap between updates: the marker never
 * cuts a corner, never stops between fixes, and only changes speed gradually.
 */
export class Motion {
    /** Where the marker is drawn now. */
    shown: LatLng;
    /** The newest reported position. */
    target: LatLng;
    /** Route from where the glide began; `path[0]` is that start and the last entry is `target`. */
    private path: LatLng[];
    /** Distance along the route at each waypoint, in degrees of latitude. */
    private cumulative: number[] = [0];
    private start = 0;
    private duration = 0;
    private lastUpdate: number | null = null;
    /** Running average of the gap between fixes, so one short gap doesn't end the next glide early. */
    private gap: number | null = null;

    constructor(at: LatLng) {
        this.shown = this.target = at;
        this.path = [at];
    }

    get gliding(): boolean {
        return !sameLatLng(this.shown, this.target);
    }

    /** Starts gliding towards `target`; false when there is nowhere new to go. */
    moveTo(target: LatLng, now: number): boolean {
        if (sameLatLng(target, this.target)) return false;
        const interval = this.lastUpdate === null ? null : now - this.lastUpdate;
        if (interval !== null && interval > STALE_MS) {
            this.jumpTo(target, now);
            this.gap = null;
            return true;
        }
        this.lastUpdate = now;
        if (interval !== null) this.gap = this.gap === null ? interval : this.gap + (interval - this.gap) * GAP_WEIGHT;
        this.step(now);
        // Keep the waypoints still ahead of the marker, so it carries on through them.
        const ahead = this.gliding ? this.path.slice(this.segmentAt(this.travelled(now)) + 1) : [];
        this.path = [this.shown, ...ahead.filter((point) => !sameLatLng(point, this.shown)), target];
        this.cumulative = [0];
        for (let i = 1; i < this.path.length; i++) {
            this.cumulative.push(this.cumulative[i - 1] + distance(this.path[i - 1], this.path[i]));
        }
        this.target = target;
        this.start = now;
        this.duration =
            this.gap === null ? FIRST_GLIDE_MS : Math.min(MAX_GLIDE_MS, Math.max(MIN_GLIDE_MS, this.gap * GLIDE_SLACK));
        return true;
    }

    /** Jumps straight to `target`, e.g. when it is too far away for a glide to make sense. */
    jumpTo(target: LatLng, now: number): void {
        this.lastUpdate = now;
        this.shown = this.target = target;
        this.path = [target];
        this.cumulative = [0];
    }

    /** Advances the glide to `now`: constant speed along the whole route. */
    step(now: number): void {
        const t = this.duration > 0 ? Math.min(1, (now - this.start) / this.duration) : 1;
        if (t >= 1 || this.path.length < 2) {
            this.shown = this.target;
            return;
        }
        const along = t * this.cumulative[this.cumulative.length - 1];
        const i = this.segmentAt(along);
        const span = this.cumulative[i + 1] - this.cumulative[i];
        const f = span > 0 ? (along - this.cumulative[i]) / span : 1;
        const a = this.path[i];
        const b = this.path[i + 1];
        this.shown = { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f };
    }

    private travelled(now: number): number {
        const t = this.duration > 0 ? Math.min(1, (now - this.start) / this.duration) : 1;
        return t * this.cumulative[this.cumulative.length - 1];
    }

    /** Index of the route segment containing distance `along`. */
    private segmentAt(along: number): number {
        let i = 0;
        while (i < this.path.length - 2 && this.cumulative[i + 1] <= along) i++;
        return i;
    }
}

/** Ground distance in degrees of latitude: longitude shrinks with the cosine of latitude. */
function distance(a: LatLng, b: LatLng): number {
    const scale = Math.cos(((a.lat + b.lat) / 2) * (Math.PI / 180));
    return Math.hypot(b.lat - a.lat, (b.lng - a.lng) * scale);
}
