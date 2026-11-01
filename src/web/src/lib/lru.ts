/** Drops the oldest entries (insertion order) until `map` holds at most `max`. */
export function trimOldest<K, V>(map: Map<K, V>, max: number): void {
    while (map.size > max) {
        map.delete(map.keys().next().value as K);
    }
}
