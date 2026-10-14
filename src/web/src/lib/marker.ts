import L from 'leaflet';
import { escapeHtml } from './format';
import { isMoving, isStale, type Peer } from './peers';

/** The first letters of up to two words of a name, for the avatar circle. */
export function initials(name: string): string {
    const words = name.trim().split(/\s+/).filter(Boolean);
    const letters = words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? '?').slice(0, 2);
    return letters.toUpperCase();
}

/** A stable hue per user so the same person always has the same colour. */
export function hueFor(id: string): number {
    let hash = 0;
    for (const char of id) hash = (hash * 31 + char.charCodeAt(0)) >>> 0;
    return hash % 360;
}

/** The marker HTML for a peer. Names are user-controlled, so they are escaped. */
export function markerHtml(peer: Peer, opts: { self: boolean; selected: boolean; now: number }): string {
    const stale = isStale(peer, opts.now);
    const moving = isMoving(peer);
    const classes = [
        'peer-marker',
        opts.self ? 'peer-marker--self' : '',
        opts.selected ? 'peer-marker--selected' : '',
        stale ? 'peer-marker--stale' : ''
    ]
        .filter(Boolean)
        .join(' ');
    const arrow =
        moving && peer.heading !== null
            ? `<span class="peer-marker__heading" style="transform: rotate(${Math.round(peer.heading)}deg)"></span>`
            : '';
    const speed = moving ? `<span class="peer-marker__badge">${Math.round(peer.speed * 3.6)} km/h</span>` : '';
    return (
        `<div class="${classes}" title="${escapeHtml(peer.name)}">` +
        arrow +
        `<span class="peer-marker__avatar" style="background: hsl(${hueFor(peer.id)} 55% 38%)">${escapeHtml(initials(peer.name))}</span>` +
        speed +
        `</div>`
    );
}

export function markerIcon(html: string): L.DivIcon {
    return L.divIcon({ html, className: 'peer-marker-wrap', iconSize: [64, 64], iconAnchor: [32, 32] });
}
