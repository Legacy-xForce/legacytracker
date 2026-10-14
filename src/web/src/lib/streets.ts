import { onBeforeUnmount, reactive, ref, watch, type Ref } from 'vue';
import { nominatim, type Throttle } from './throttle';

const REVERSE_URL = 'https://nominatim.openstreetmap.org/reverse';

/** What the app shows when a position has no usable address. */
export const NO_ADDRESS = 'Location unavailable';

function firstText(values: unknown[]): string | null {
    for (const value of values) {
        const text = typeof value === 'string' || typeof value === 'number' ? String(value).trim() : '';
        if (text) return text;
    }
    return null;
}

/** "Via Roma 12, Torino" from a Nominatim reverse answer, like the phone app's street label. */
export function describeAddress(payload: unknown): string {
    const body = (payload ?? {}) as { address?: Record<string, unknown>; display_name?: unknown };
    const address = body.address ?? {};
    const road = firstText([address.road, address.pedestrian, address.footway, address.path, address.street]);
    const city = firstText([
        address.city,
        address.town,
        address.village,
        address.hamlet,
        address.suburb,
        address.municipality
    ]);
    if (road) {
        const number = firstText([address.house_number]);
        const street = number ? `${road} ${number}` : road;
        return city ? `${street}, ${city}` : street;
    }
    return city ?? firstText([body.display_name]) ?? NO_ADDRESS;
}

// ~11 m: enough to name the street, coarse enough that GPS jitter doesn't cost a lookup.
function keyFor(latitude: number, longitude: number): string {
    return `${latitude.toFixed(4)},${longitude.toFixed(4)}`;
}

/**
 * Street names for map positions. Lookups go through the page's Nominatim throttle one at a
 * time, and each subject (a person, a trip's start) has at most one waiting, for its newest
 * position, so someone on the move doesn't queue a lookup per fix.
 */
export class StreetNames {
    private readonly names = reactive(new Map<string, string>());
    private readonly pending = new Map<string, { latitude: number; longitude: number }>();
    private draining = false;

    constructor(private readonly options: { fetch?: typeof fetch; throttle?: Throttle } = {}) {}

    /** The name if it is known. Reactive. */
    peek(latitude: number, longitude: number): string | undefined {
        return this.names.get(keyFor(latitude, longitude));
    }

    request(subject: string, latitude: number, longitude: number): void {
        if (this.names.has(keyFor(latitude, longitude))) return;
        // Re-inserting moves the subject to the back: fresh requests don't jump the queue.
        this.pending.delete(subject);
        this.pending.set(subject, { latitude, longitude });
        void this.drain();
    }

    cancel(subject: string): void {
        this.pending.delete(subject);
    }

    private async drain(): Promise<void> {
        if (this.draining) return;
        this.draining = true;
        try {
            while (this.pending.size > 0) {
                const [subject, queued] = this.pending.entries().next().value!;
                if (this.names.has(keyFor(queued.latitude, queued.longitude))) {
                    this.pending.delete(subject);
                    continue;
                }
                await (this.options.throttle ?? nominatim).acquire();
                // Read it again after the wait: it may have moved on, or no longer be wanted.
                const at = this.pending.get(subject);
                if (!at) continue;
                this.pending.delete(subject);
                const key = keyFor(at.latitude, at.longitude);
                if (this.names.has(key)) continue;
                try {
                    this.names.set(key, await this.lookup(at.latitude, at.longitude));
                } catch {
                    // Not remembered: the next request for this place tries again.
                }
            }
        } finally {
            this.draining = false;
        }
    }

    private async lookup(latitude: number, longitude: number): Promise<string> {
        const query = new URLSearchParams({
            format: 'jsonv2',
            lat: String(latitude),
            lon: String(longitude),
            zoom: '18',
            addressdetails: '1'
        });
        const response = await (this.options.fetch ?? fetch)(`${REVERSE_URL}?${query}`, {
            headers: { accept: 'application/json' }
        });
        if (!response.ok) throw new Error(`Reverse geocoder error (${response.status}).`);
        return describeAddress(await response.json());
    }
}

export const streetNames = new StreetNames();

/**
 * The street at `position`, for as long as the calling component lives. While a new position is
 * being looked up, the previous name stays, so a moving person's label never blanks out.
 */
export function useStreetName(
    subject: () => string,
    position: () => { latitude: number; longitude: number } | null,
    names: StreetNames = streetNames
): Ref<string | null> {
    const label = ref<string | null>(null);
    watch(subject, (_, previous) => {
        names.cancel(previous);
        label.value = null;
    });
    watch(
        () => {
            const at = position();
            return at ? { subject: subject(), at, known: names.peek(at.latitude, at.longitude) } : null;
        },
        (state) => {
            if (!state) label.value = null;
            else if (state.known !== undefined) label.value = state.known;
            else names.request(state.subject, state.at.latitude, state.at.longitude);
        },
        { immediate: true }
    );
    onBeforeUnmount(() => names.cancel(subject()));
    return label;
}
