import { ref } from 'vue';

export interface Toast {
    id: number;
    message: string;
}

const SHOWN_FOR_MS = 6000;

/** What is on screen now. Rendered by `ToastHost`, which sits at the app's root. */
export const toasts = ref<Toast[]>([]);

let nextId = 1;

export function dismissToast(id: number) {
    toasts.value = toasts.value.filter((toast) => toast.id !== id);
}

/** A brief message that goes away by itself; the newest sits at the bottom. */
export function showToast(message: string) {
    const id = nextId++;
    // Showing the same message twice in a row would only stack identical bubbles.
    toasts.value = [...toasts.value.filter((toast) => toast.message !== message), { id, message }];
    setTimeout(() => dismissToast(id), SHOWN_FOR_MS);
}
