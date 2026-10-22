import { defineConfig } from 'vitest/config';
import { loadEnv, type Plugin } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';

// Map tiles (src/lib/tiles.ts) and place search (src/lib/geocoder.ts).
const TILE_HOSTS = [
    'https://*.tile.openstreetmap.org',
    'https://*.tile.opentopomap.org',
    'https://server.arcgisonline.com'
];
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
        "script-src 'self'",
        // Leaflet and Vue style bindings set inline styles.
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self' data:",
        `img-src 'self' data: blob: ${auth} ${TILE_HOSTS.join(' ')}`,
        `connect-src 'self' ${backend} ${stream} ${auth} ${calendar} ${NOMINATIM}`,
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

export default defineConfig(({ mode }) => ({
    plugins: [vue(), tailwindcss(), securityHeaders(loadEnv(mode, process.cwd(), 'VITE_'))],
    test: {
        environment: 'jsdom'
    }
}));
