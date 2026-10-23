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
// The OpenFreeMap vector style, its TileJSON, glyphs and sprites.
const MAP_STYLE_HOSTS = ['https://tiles.openfreemap.org'];
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
    // A custom style URL may live on another host; its glyph and sprite URLs usually share it.
    const styleHosts = [...MAP_STYLE_HOSTS];
    if (env.VITE_MAP_STYLE_URL) {
        try {
            const configured = new URL(env.VITE_MAP_STYLE_URL).origin;
            if (!styleHosts.includes(configured)) styleHosts.push(configured);
        } catch {
            // The app itself will report a malformed URL; keep the default CSP.
        }
    }
    const csp = [
        "default-src 'self'",
        "script-src 'self'",
        // Vue style bindings set inline styles; MapLibre positions its chrome inline.
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self' data:",
        `img-src 'self' data: blob: ${auth} ${TILE_HOSTS.join(' ')} ${styleHosts.join(' ')}`,
        `connect-src 'self' ${backend} ${stream} ${auth} ${calendar} ${NOMINATIM} ${styleHosts.join(' ')}`,
        // MapLibre runs its tile worker from a blob.
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

export default defineConfig(({ mode }) => ({
    plugins: [vue(), tailwindcss(), securityHeaders(loadEnv(mode, process.cwd(), 'VITE_'))],
    test: {
        environment: 'jsdom',
        setupFiles: ['./src/test/setup.ts']
    }
}));
