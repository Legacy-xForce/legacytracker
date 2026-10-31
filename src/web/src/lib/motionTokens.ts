/**
 * Material 3 motion: the same four durations as the phone's `AppMotion`, in
 * milliseconds for script (CSS uses the `--duration-*` tokens in `style.css`).
 */
export const duration = { short: 100, medium: 200, long: 300, extraLong: 500 } as const;

export function prefersReducedMotion(): boolean {
    return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/** [ms], or 0 when the user asked for reduced motion. */
export function motion(ms: number): number {
    return prefersReducedMotion() ? 0 : ms;
}
