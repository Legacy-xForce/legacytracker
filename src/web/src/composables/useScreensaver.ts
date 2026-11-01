import { onBeforeUnmount, onMounted, ref } from 'vue';

/**
 * How long the page may go without input before it assumes nobody is watching. The server stops
 * renewing live mode after ten minutes without a viewer, so the map should stop being one then.
 */
export const SCREENSAVER_TIMEOUT_MS = 10 * 60_000;

/** Input that shows someone is at the screen; a hidden tab and an animating replay are not. */
const ACTIVITY_EVENTS = ['pointerdown', 'pointermove', 'keydown', 'wheel'] as const;

/**
 * A "are you still watching?" screen for a map left open. After `timeoutMs` without input it goes
 * up, and `wake` is the only way back: a pointer that happens to pass over the prompt, or a tab
 * that becomes visible again, is not proof that someone is watching.
 */
export function useScreensaver(timeoutMs = SCREENSAVER_TIMEOUT_MS) {
    const active = ref(false);
    let lastActivity = Date.now();
    let timer: ReturnType<typeof setTimeout> | undefined;

    function arm() {
        clearTimeout(timer);
        timer = setTimeout(check, Math.max(0, timeoutMs - (Date.now() - lastActivity)));
    }

    // Timers are throttled in a background tab, so the deadline is checked on return too instead
    // of trusting the timer to have fired on time.
    function check() {
        if (active.value) return;
        if (Date.now() - lastActivity >= timeoutMs) {
            clearTimeout(timer);
            active.value = true;
            return;
        }
        arm();
    }

    function noteActivity() {
        // Once the prompt is up only its button wakes the map: passing a pointer over it is not
        // someone watching.
        if (active.value) return;
        const now = Date.now();
        // Pointer moves arrive in a stream; one reset a second is plenty.
        if (now - lastActivity < 1_000) return;
        lastActivity = now;
        arm();
    }

    /** Someone confirmed they are still there: hide the prompt and start counting again. */
    function wake() {
        active.value = false;
        lastActivity = Date.now();
        arm();
    }

    onMounted(() => {
        // Capture: map controls (and Mapbox) may stop pointer events from bubbling to the window.
        for (const event of ACTIVITY_EVENTS)
            window.addEventListener(event, noteActivity, { passive: true, capture: true });
        document.addEventListener('visibilitychange', check);
        arm();
    });

    onBeforeUnmount(() => {
        for (const event of ACTIVITY_EVENTS) window.removeEventListener(event, noteActivity, true);
        document.removeEventListener('visibilitychange', check);
        clearTimeout(timer);
    });

    return { active, wake };
}
