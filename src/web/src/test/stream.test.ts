import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { StreamClient, streamUrl, type StreamStatus } from '../api/stream';

class FakeSocket {
    static instances: FakeSocket[] = [];
    readyState = 0;
    sent: string[] = [];
    closed = false;
    onopen: (() => void) | null = null;
    onmessage: ((event: { data: unknown }) => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;

    constructor(readonly url: string) {
        FakeSocket.instances.push(this);
    }
    send(text: string) {
        this.sent.push(text);
    }
    close() {
        this.closed = true;
        this.readyState = 3;
    }
    open() {
        this.readyState = 1;
        this.onopen?.();
    }
    receive(data: unknown) {
        this.onmessage?.({ data: typeof data === 'string' ? data : JSON.stringify(data) });
    }
    drop() {
        this.readyState = 3;
        this.onclose?.();
    }
}

function setup(overrides: Partial<ConstructorParameters<typeof StreamClient>[0]> = {}) {
    let ticketNo = 0;
    const statuses: StreamStatus[] = [];
    const messages: unknown[] = [];
    const client = new StreamClient({
        getTicket: async () => `t${++ticketNo}`,
        onMessage: (m) => messages.push(m),
        onStatus: (s) => statuses.push(s),
        createSocket: (url) => new FakeSocket(url) as unknown as WebSocket,
        ...overrides
    });
    return { client, statuses, messages };
}

const last = () => FakeSocket.instances[FakeSocket.instances.length - 1];

beforeEach(() => {
    FakeSocket.instances = [];
    vi.useFakeTimers();
    vi.stubGlobal('WebSocket', { OPEN: 1 });
});

afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
});

describe('StreamClient', () => {
    it('connects with a ticket and announces the map as active', async () => {
        const { client, statuses } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);

        expect(last().url).toBe(streamUrl('t1'));
        last().open();

        expect(statuses.at(-1)).toBe('open');
        expect(JSON.parse(last().sent[0])).toEqual({ type: 'map_active', active: true });
    });

    it('uses wss for https backends and puts the ticket in the query', () => {
        expect(streamUrl('abc')).toMatch(/^wss:\/\/.+\/api\/v1\/stream\?ticket=abc$/);
    });

    it('passes parsed messages on and ignores ones that are not JSON', async () => {
        const { client, messages } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        last().open();

        last().receive({ type: 'snapshot', users: [] });
        last().receive('not json');

        expect(messages).toEqual([{ type: 'snapshot', users: [] }]);
    });

    it('reconnects with a new ticket after a drop, backing off up to a limit', async () => {
        const { client } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        last().open();

        last().drop();
        await vi.advanceTimersByTimeAsync(999);
        expect(FakeSocket.instances).toHaveLength(1);
        await vi.advanceTimersByTimeAsync(1);
        expect(FakeSocket.instances).toHaveLength(2);
        expect(last().url).toBe(streamUrl('t2'));

        // Never opened: the next wait doubles.
        last().drop();
        await vi.advanceTimersByTimeAsync(1_999);
        expect(FakeSocket.instances).toHaveLength(2);
        await vi.advanceTimersByTimeAsync(1);
        expect(FakeSocket.instances).toHaveLength(3);
    });

    it('resets the backoff once a connection opens', async () => {
        const { client } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        last().drop();
        await vi.advanceTimersByTimeAsync(1_000);
        last().drop();
        await vi.advanceTimersByTimeAsync(2_000);
        last().open();
        last().drop();

        await vi.advanceTimersByTimeAsync(1_000);

        expect(FakeSocket.instances).toHaveLength(4);
    });

    it('sends map_active changes, and replays the latest state on a new connection', async () => {
        const { client } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        last().open();

        client.setMapActive(false);
        expect(JSON.parse(last().sent.at(-1)!)).toEqual({ type: 'map_active', active: false });

        client.reconnect();
        await vi.advanceTimersByTimeAsync(0);
        last().open();
        expect(JSON.parse(last().sent[0])).toEqual({ type: 'map_active', active: false });
    });

    it('reconnect() replaces the connection and ignores the old one', async () => {
        const { client, messages } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        const first = last();
        first.open();

        client.reconnect();
        await vi.advanceTimersByTimeAsync(0);

        expect(first.closed).toBe(true);
        expect(FakeSocket.instances).toHaveLength(2);
        first.receive({ stale: true });
        first.drop();
        await vi.advanceTimersByTimeAsync(60_000);
        expect(messages).toEqual([]);
        expect(FakeSocket.instances).toHaveLength(2);
    });

    it('stops for good: no reconnect after stop()', async () => {
        const { client, statuses } = setup();
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        last().open();

        client.stop();
        await vi.advanceTimersByTimeAsync(60_000);

        expect(statuses.at(-1)).toBe('closed');
        expect(FakeSocket.instances).toHaveLength(1);
    });

    it('retries when a ticket cannot be fetched', async () => {
        let calls = 0;
        const { client } = setup({
            getTicket: async () => {
                if (++calls === 1) throw new Error('offline');
                return 't2';
            }
        });
        client.start();
        await vi.advanceTimersByTimeAsync(0);
        expect(FakeSocket.instances).toHaveLength(0);

        await vi.advanceTimersByTimeAsync(1_000);
        expect(FakeSocket.instances).toHaveLength(1);
    });

    it('gives up and reports when the ticket request is refused for good', async () => {
        const fatal = vi.fn();
        const { client, statuses } = setup({
            getTicket: async () => {
                throw new Error('forbidden');
            },
            isFatal: () => true,
            onFatal: fatal
        });
        client.start();
        await vi.advanceTimersByTimeAsync(60_000);

        expect(fatal).toHaveBeenCalledTimes(1);
        expect(statuses.at(-1)).toBe('closed');
        expect(FakeSocket.instances).toHaveLength(0);
    });
});
