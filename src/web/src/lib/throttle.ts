export interface ThrottleOptions {
    spacingMs?: number;
    now?: () => number;
    sleep?: (ms: number) => Promise<void>;
}

/** Hands out turns one at a time, at least `spacingMs` apart, in the order they were asked for. */
export class Throttle {
    private chain: Promise<void> = Promise.resolve();
    private last = 0;

    constructor(private readonly options: ThrottleOptions = {}) {}

    /** Resolves when the caller may send its request. */
    acquire(): Promise<void> {
        const turn = this.chain.then(async () => {
            const now = this.options.now ?? Date.now;
            const wait = (this.options.spacingMs ?? 1100) - (now() - this.last);
            if (this.last > 0 && wait > 0) {
                await (this.options.sleep ?? ((ms) => new Promise<void>((r) => setTimeout(r, ms))))(wait);
            }
            this.last = now();
        });
        this.chain = turn;
        return turn;
    }
}

/**
 * Nominatim allows one request a second per client, so every lookup the page makes (event places,
 * street names) takes its turn here.
 */
export const nominatim = new Throttle({ spacingMs: 1100 });
