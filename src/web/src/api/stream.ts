import { config } from '../config';

export type StreamStatus = 'connecting' | 'open' | 'closed';

export interface StreamOptions {
    getTicket: () => Promise<string>;
    onMessage: (message: unknown) => void;
    onStatus: (status: StreamStatus) => void;
    /** Called when a ticket can't be had for a reason retrying won't fix. */
    onFatal?: (error: unknown) => void;
    isFatal?: (error: unknown) => boolean;
    createSocket?: (url: string) => WebSocket;
}

const BACKOFF_START_MS = 1_000;
const BACKOFF_MAX_MS = 30_000;

export function streamUrl(ticket: string): string {
    const url = new URL('/api/v1/stream', config.backendUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('ticket', ticket);
    return url.toString();
}

/**
 * The tracker's live stream. Each connection needs a fresh single-use ticket, so a reconnect is
 * a full restart; the server answers every new connection with a snapshot of everyone.
 *
 * Browsers can't send WebSocket pings, so a connection that dies silently is only noticed when
 * the page comes back or the network returns; callers use {@link reconnect} for those.
 */
export class StreamClient {
    private socket: WebSocket | null = null;
    private timer: ReturnType<typeof setTimeout> | null = null;
    private backoff = BACKOFF_START_MS;
    private running = false;
    // Bumped on every (re)start so a late ticket or event from a superseded attempt is ignored.
    private generation = 0;
    // A fresh connection counts as an open map on the server, so announce otherwise right away.
    private mapActive = true;

    constructor(private readonly options: StreamOptions) {}

    start(): void {
        if (this.running) return;
        this.running = true;
        void this.connect();
    }

    stop(): void {
        this.running = false;
        this.generation++;
        this.clearTimer();
        this.closeSocket();
        this.options.onStatus('closed');
    }

    /** Whether the map is in the foreground; drives the phones' live mode. */
    setMapActive(active: boolean): void {
        this.mapActive = active;
        this.sendMapActive();
    }

    /** Drops the current connection (if any) and connects again now, e.g. after the tab was hidden. */
    reconnect(): void {
        if (!this.running) return;
        this.generation++;
        this.clearTimer();
        this.closeSocket();
        this.backoff = BACKOFF_START_MS;
        void this.connect();
    }

    get isOpen(): boolean {
        return this.socket?.readyState === WebSocket.OPEN;
    }

    private async connect(): Promise<void> {
        const generation = this.generation;
        this.options.onStatus('connecting');
        let ticket: string;
        try {
            ticket = await this.options.getTicket();
        } catch (error) {
            if (generation !== this.generation) return;
            if (this.options.isFatal?.(error)) {
                this.running = false;
                this.options.onStatus('closed');
                this.options.onFatal?.(error);
                return;
            }
            this.scheduleReconnect();
            return;
        }
        if (generation !== this.generation) return;

        const socket = (this.options.createSocket ?? ((url) => new WebSocket(url)))(streamUrl(ticket));
        this.socket = socket;
        socket.onopen = () => {
            if (generation !== this.generation) return;
            this.backoff = BACKOFF_START_MS;
            this.options.onStatus('open');
            this.sendMapActive();
        };
        socket.onmessage = (event) => {
            if (generation !== this.generation || typeof event.data !== 'string') return;
            try {
                this.options.onMessage(JSON.parse(event.data));
            } catch {
                // Not JSON: ignore.
            }
        };
        socket.onclose = () => {
            if (generation !== this.generation) return;
            this.socket = null;
            this.scheduleReconnect();
        };
        // `close` follows an error; reconnecting is handled there.
        socket.onerror = () => {};
    }

    private scheduleReconnect(): void {
        if (!this.running) return;
        this.options.onStatus('connecting');
        this.clearTimer();
        const delay = this.backoff;
        this.backoff = Math.min(this.backoff * 2, BACKOFF_MAX_MS);
        this.timer = setTimeout(() => {
            this.timer = null;
            this.generation++;
            void this.connect();
        }, delay);
    }

    private sendMapActive(): void {
        if (this.socket?.readyState !== WebSocket.OPEN) return;
        this.socket.send(JSON.stringify({ type: 'map_active', active: this.mapActive }));
    }

    private clearTimer(): void {
        if (this.timer !== null) clearTimeout(this.timer);
        this.timer = null;
    }

    private closeSocket(): void {
        const socket = this.socket;
        this.socket = null;
        if (!socket) return;
        socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
        try {
            socket.close();
        } catch {
            // ignore
        }
    }
}
