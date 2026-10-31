/// <reference types="node" />
import { beforeEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
    DEFAULT_THEME_ID,
    THEMES,
    THEME_STORAGE_KEY,
    applyTheme,
    getStoredTheme,
    isThemeId,
    setTheme
} from '../theme/themes';

describe('themes', () => {
    beforeEach(() => {
        localStorage.clear();
        document.documentElement.removeAttribute('data-theme');
        document.documentElement.style.colorScheme = '';
        document.head.innerHTML =
            '<meta name="color-scheme" content="dark"><meta name="theme-color" content="#0e1513">';
    });

    it('ships one entry for every supported theme', () => {
        expect(THEMES.map((theme) => theme.id)).toEqual([
            'teal',
            'oled',
            'catppuccin-mocha',
            'catppuccin-macchiato',
            'catppuccin-frappe',
            'catppuccin-latte'
        ]);
        expect(THEME_STORAGE_KEY).toBe('legacytracker.theme');
    });

    it('defaults to teal and ignores unknown stored values', () => {
        expect(getStoredTheme()).toBe(DEFAULT_THEME_ID);

        localStorage.setItem(THEME_STORAGE_KEY, 'solarized');
        expect(getStoredTheme()).toBe(DEFAULT_THEME_ID);
        expect(isThemeId('solarized')).toBe(false);
    });

    it('reads a stored theme', () => {
        localStorage.setItem(THEME_STORAGE_KEY, 'catppuccin-latte');
        expect(getStoredTheme()).toBe('catppuccin-latte');
    });

    it('applies a fixed theme and persists it', () => {
        expect(setTheme('catppuccin-mocha')).toBe('catppuccin-mocha');

        expect(document.documentElement.dataset.theme).toBe('catppuccin-mocha');
        expect(document.documentElement.style.colorScheme).toBe('dark');
        expect(document.querySelector('meta[name="theme-color"]')?.getAttribute('content')).toBe('#1e1e2e');
        expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('catppuccin-mocha');
    });

    it('switches browser chrome for a light theme', () => {
        applyTheme('catppuccin-latte');

        expect(document.documentElement.dataset.theme).toBe('catppuccin-latte');
        expect(document.documentElement.style.colorScheme).toBe('light');
        expect(document.querySelector('meta[name="color-scheme"]')?.getAttribute('content')).toBe('light');
        expect(document.querySelector('meta[name="theme-color"]')?.getAttribute('content')).toBe('#eff1f5');
    });

    it('drops the retired adaptive theme back to teal', () => {
        localStorage.setItem(THEME_STORAGE_KEY, 'adaptive');

        expect(isThemeId('adaptive')).toBe(false);
        expect(getStoredTheme()).toBe(DEFAULT_THEME_ID);
    });
});

const css = readFileSync(resolve(process.cwd(), 'src/style.css'), 'utf8');

/** Colour tokens declared for a theme: teal lives in `@theme`, every other theme in its own block. */
function themeTokens(id: string): Record<string, string> {
    const header = id === 'teal' ? '@theme static {' : `html[data-theme='${id}'] {`;
    const start = css.indexOf(header);
    const body = css.slice(start, css.indexOf('\n}', start));
    const tokens: Record<string, string> = {};
    for (const [, name, value] of body.matchAll(/--color-([a-z-]+): (#[0-9a-f]{6});/g)) tokens[name] = value;
    return tokens;
}

function luminance(hex: string): number {
    const channel = (offset: number) => {
        const value = parseInt(hex.slice(offset, offset + 2), 16) / 255;
        return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
}

function contrast(a: string, b: string): number {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

describe('colour role tokens', () => {
    const roles = [
        'secondary',
        'on-secondary',
        'secondary-container',
        'on-secondary-container',
        'tertiary',
        'on-tertiary',
        'tertiary-container',
        'on-tertiary-container',
        'surface-dim',
        'surface-bright',
        'inverse-surface',
        'inverse-on-surface',
        'inverse-primary',
        'surface-tint',
        'scrim',
        'shadow'
    ];
    const pairs: [string, string][] = [
        ['on-secondary', 'secondary'],
        ['on-secondary-container', 'secondary-container'],
        ['on-tertiary', 'tertiary'],
        ['on-tertiary-container', 'tertiary-container'],
        ['inverse-on-surface', 'inverse-surface'],
        ['inverse-primary', 'inverse-surface'],
        ['on-surface', 'surface-dim'],
        ['on-surface', 'surface-bright']
    ];

    for (const theme of THEMES) {
        describe(theme.id, () => {
            const tokens = themeTokens(theme.id);

            it('declares every colour role', () => {
                for (const role of roles) expect(tokens[role], role).toBeDefined();
            });

            it('keeps text pairs readable', () => {
                for (const [fg, bg] of pairs) {
                    expect(contrast(tokens[fg], tokens[bg]), `${fg} on ${bg}`).toBeGreaterThanOrEqual(
                        fg === 'inverse-primary' ? 3 : 4.5
                    );
                }
            });

            it('tints the surface with the primary and brackets the surface between dim and bright', () => {
                expect(tokens['surface-tint']).toBe(tokens['primary']);
                const [dim, surface, bright] = ['surface-dim', 'surface', 'surface-bright'].map((t) =>
                    luminance(tokens[t])
                );
                expect(dim).toBeLessThanOrEqual(surface);
                expect(bright).toBeGreaterThanOrEqual(surface);
            });
        });
    }
});
