import { onBeforeUnmount, ref, type Ref } from 'vue';

/** Whether a CSS media query matches, kept up to date. */
export function useMediaQuery(query: string): Ref<boolean> {
    const list = typeof window.matchMedia === 'function' ? window.matchMedia(query) : null;
    const matches = ref(list?.matches ?? false);
    const update = (event: MediaQueryListEvent) => (matches.value = event.matches);
    list?.addEventListener('change', update);
    onBeforeUnmount(() => list?.removeEventListener('change', update));
    return matches;
}
