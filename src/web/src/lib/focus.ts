import { nextTick, onBeforeUnmount, onMounted, watch, type Ref } from 'vue';

const FOCUSABLE =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function focusables(root: HTMLElement): HTMLElement[] {
    return [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => !el.hasAttribute('inert'));
}

// Dialogs are teleported to <body>, so making the app root inert silences everything behind them
// (focus, clicks, the accessibility tree). A counter keeps stacked dialogs from un-inerting early.
let inertDepth = 0;

function setBackgroundInert(on: boolean) {
    inertDepth += on ? 1 : -1;
    const app = document.getElementById('app');
    if (!app) return;
    app.toggleAttribute('inert', inertDepth > 0);
}

/**
 * Makes `panel` a modal dialog for as long as the calling component lives: the background goes
 * inert, focus moves in (to `[data-autofocus]`, else the first control, else the panel), Tab wraps
 * inside, and focus returns to whatever opened it on close. The panel needs `tabindex="-1"`.
 * Pass `open` for a dialog that stays mounted while closed.
 */
export function useModal(panel: Ref<HTMLElement | null>, open?: Ref<boolean>) {
    let opener: HTMLElement | null = null;
    let active = false;

    function onKey(event: KeyboardEvent) {
        const root = panel.value;
        if (event.key !== 'Tab' || !root) return;
        const items = focusables(root);
        if (items.length === 0) {
            event.preventDefault();
            root.focus();
            return;
        }
        const first = items[0];
        const last = items[items.length - 1];
        const active = document.activeElement;
        if (event.shiftKey && (active === first || active === root)) {
            event.preventDefault();
            last.focus();
        } else if (!event.shiftKey && active === last) {
            event.preventDefault();
            first.focus();
        }
    }

    async function activate() {
        if (active) return;
        active = true;
        opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        setBackgroundInert(true);
        document.addEventListener('keydown', onKey);
        await nextTick();
        const root = panel.value;
        if (!root) return;
        (root.querySelector<HTMLElement>('[data-autofocus]') ?? focusables(root)[0] ?? root).focus();
    }

    function deactivate() {
        if (!active) return;
        active = false;
        document.removeEventListener('keydown', onKey);
        setBackgroundInert(false);
        if (opener?.isConnected) opener.focus();
    }

    onMounted(() => {
        if (!open || open.value) void activate();
    });
    if (open) watch(open, (isOpen) => (isOpen ? void activate() : deactivate()));
    onBeforeUnmount(deactivate);
}

/**
 * Arrow/Home/End keys for a tablist or menu: moves focus between `selector` matches under the
 * event's currentTarget and returns the new element (or null when the key isn't one of ours).
 */
export function moveFocus(
    event: KeyboardEvent,
    selector: string,
    keys: { next: string; previous: string } = { next: 'ArrowRight', previous: 'ArrowLeft' }
): HTMLElement | null {
    const items = [...(event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(selector)];
    if (items.length === 0) return null;
    const current = items.indexOf(document.activeElement as HTMLElement);
    let target: number;
    if (event.key === keys.next) target = (current + 1) % items.length;
    else if (event.key === keys.previous) target = (current - 1 + items.length) % items.length;
    else if (event.key === 'Home') target = 0;
    else if (event.key === 'End') target = items.length - 1;
    else return null;
    event.preventDefault();
    items[target].focus();
    return items[target];
}
