import { vi } from 'vitest';

// The real library needs WebGL. Every test gets the DOM-safe stand-in instead.
vi.mock('mapbox-gl', () => import('./mapbox-mock'));

// vue3-emoji-picker touches indexedDB while its module loads, which jsdom does
// not provide. The tests only need a grid that emits a pick.
vi.mock('vue3-emoji-picker', () => ({
    default: {
        name: 'EmojiPickerStub',
        emits: ['select'],
        template:
            '<div data-emoji-grid><button type="button" data-pick-emoji @click="$emit(\'select\', { i: \'🏠\' })">🏠</button></div>'
    }
}));
vi.mock('vue3-emoji-picker/css', () => ({}));
