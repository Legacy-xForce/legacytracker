/** Someone with the live map open right now, as the tracker stream announces them. */
export interface Viewer {
    id: string;
    name: string;
}

/** The viewers a `viewers` stream message lists, in the order they started looking; null for any other message. */
export function parseViewers(message: unknown): Viewer[] | null {
    if (message === null || typeof message !== 'object') return null;
    const payload = message as Record<string, unknown>;
    if (payload.type !== 'viewers') return null;
    if (!Array.isArray(payload.viewers)) return [];
    const viewers: Viewer[] = [];
    for (const item of payload.viewers) {
        if (item === null || typeof item !== 'object') continue;
        const { id, name } = item as Record<string, unknown>;
        if (typeof id !== 'string' || id === '') continue;
        viewers.push({ id, name: typeof name === 'string' ? name : id });
    }
    return viewers;
}

/** Us first, then everyone else in the order they started looking. */
export function selfFirst(viewers: Viewer[], selfId: string): Viewer[] {
    return [...viewers.filter((viewer) => viewer.id === selfId), ...viewers.filter((viewer) => viewer.id !== selfId)];
}
