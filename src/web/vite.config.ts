import { defineConfig } from 'vitest/config';
import { loadEnv, type Plugin } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';

// Mapbox styles, tiles, glyphs, sprites, telemetry and place search.
const MAPBOX_API = 'https://api.mapbox.com';
const MAPBOX_EVENTS = 'https://events.mapbox.com';
const NOMINATIM = 'https://nominatim.openstreetmap.org';

/**
 * Writes Cloudflare Pages' `_headers` with a Content-Security-Policy built from the same
 * VITE_* URLs as the app, so a build for other services allows those instead. The refresh token
 * lives in localStorage; the CSP keeps injected or third-party scripts from running.
 */
function securityHeaders(env: Record<string, string>): Plugin {
    const origin = (value: string | undefined, fallback: string) => new URL(value || fallback).origin;
    const backend = origin(env.VITE_BACKEND_URL, 'https://tracker.legacy-group.tech');
    const auth = origin(env.VITE_AUTH_URL, 'https://auth.legacy-group.tech');
    const calendar = origin(env.VITE_CALENDAR_URL, 'https://calendar.legacy-group.tech');
    const stream = backend.replace(/^http/, 'ws');
    const csp = [
        "default-src 'self'",
        // Mapbox Standard uses WebAssembly for buildings and 3D features.
        "script-src 'self' 'wasm-unsafe-eval'",
        // Vue style bindings set inline styles; Mapbox positions its chrome inline.
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self' data:",
        `img-src 'self' data: blob: ${auth} ${MAPBOX_API}`,
        `connect-src 'self' ${backend} ${stream} ${auth} ${calendar} ${NOMINATIM} ${MAPBOX_API} ${MAPBOX_EVENTS}`,
        // Mapbox GL JS runs its tile worker from a blob.
        "worker-src 'self' blob:",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'"
    ].join('; ');
    const headers = [
        '/*',
        `  Content-Security-Policy: ${csp}`,
        '  X-Content-Type-Options: nosniff',
        '  Referrer-Policy: strict-origin-when-cross-origin',
        ''
    ].join('\n');
    return {
        name: 'security-headers',
        apply: 'build',
        generateBundle() {
            this.emitFile({ type: 'asset', fileName: '_headers', source: headers });
        }
    };
}

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), 'VITE_');
    // The Mapbox public token is committed in .env. A runtime check in mapbox.ts
    // warns if it somehow goes missing (e.g. .env deleted).
    return {
        plugins: [vue(), tailwindcss(), securityHeaders(env)],
        test: {
            environment: 'jsdom',
            setupFiles: ['./src/test/setup.ts']
        }
    };
});
