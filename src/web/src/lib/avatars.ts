import { reactive } from 'vue';
import { config } from '../config';

// The phone app's avatar palette: saturated enough to read on light map tiles and the dark UI
// alike, and dark enough for a white initial.
const PALETTE = [
    '#1e88e5', // blue
    '#8e24aa', // purple
    '#f4511e', // deep orange
    '#00897b', // teal
    '#d81b60', // pink
    '#43a047', // green
    '#3949ab', // indigo
    '#ef6c00', // orange
    '#6d4c41', // brown
    '#00838f' // cyan
];

/** Greyed-out people (not heard from in a while) lose their colour. */
export const DIMMED_COLOR = '#757575';

/** A stable colour per person, the same one the phone app picks (FNV-1a over UTF-16 units). */
export function userColor(userId: string): string {
    let hash = 0x811c9dc5;
    for (let i = 0; i < userId.length; i++) hash = Math.imul(hash ^ userId.charCodeAt(i), 0x01000193) >>> 0;
    return PALETTE[hash % PALETTE.length];
}

/** The first character of a name, upper-cased, for the avatar circle. */
export function userInitial(name: string): string {
    const trimmed = name.trim();
    if (!trimmed) return '?';
    const first =
        typeof Intl.Segmenter === 'function'
            ? new Intl.Segmenter().segment(trimmed)[Symbol.iterator]().next().value?.segment
            : [...trimmed][0];
    return (first ?? '?').toUpperCase();
}

// Legacy Auth keeps profile pictures by account id, which is also the tracker's user id
// (Legacy Calendar links to the same place). Ids that aren't accounts can't have one.
const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function pictureUrl(userId: string): string {
    return `${config.authUrl}/auth/profile-picture/${userId}`;
}

// Only answers are reactive: probes start from inside renders and computeds, which must not write
// the state they read.
const requested = new Set<string>();
const pictures = reactive(new Map<string, boolean>());

/**
 * The picture at `url` once it has loaded, else null (missing, or not loaded yet; the initial
 * shows meanwhile). Each picture is probed once per page, so a person without one costs one 404.
 */
export function loadedPicture(url: string): string | null {
    if (!requested.has(url)) probe(url);
    return pictures.get(url) ? url : null;
}

/** A tracker user's Legacy Auth profile picture, once loaded. */
export function profilePicture(userId: string): string | null {
    return ACCOUNT_ID.test(userId) ? loadedPicture(pictureUrl(userId)) : null;
}

function probe(url: string) {
    requested.add(url);
    if (typeof Image === 'undefined') return;
    const image = new Image();
    image.onload = () => pictures.set(url, true);
    image.onerror = () => pictures.set(url, false);
    image.src = url;
}
