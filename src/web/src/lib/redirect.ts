/** Leaves the app for `url` (the sign-in server). Its own module so tests can stub it. */
export function redirectTo(url: string): void {
    window.location.assign(url);
}
