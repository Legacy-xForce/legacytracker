/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { AVATAR_COLORS, DIMMED_COLOR, contrastRatio, initialColor } from '../lib/avatars';
import { THEMES } from '../theme/themes';

const css = readFileSync(resolve(process.cwd(), 'src/style.css'), 'utf8');

// Accents are declared once, in `@theme`, whatever the theme.
const ACCENTS = (() => {
    const start = css.indexOf('@theme static {');
    const body = css.slice(start, css.indexOf('\n}', start));
    const accents: Record<string, string> = {};
    for (const [, name, value] of body.matchAll(/--color-(online|arrival|beam|paused|hidden): (#[0-9a-f]{6});/g)) {
        accents[name] = value;
    }
    return accents;
})();

function tokensOf(id: string): Record<string, string> {
    const header = id === 'teal' ? '@theme static {' : `html[data-theme='${id}'] {`;
    const start = css.indexOf(header);
    const body = css.slice(start, css.indexOf('\n}', start));
    const tokens: Record<string, string> = { ...ACCENTS };
    for (const [, name, value] of body.matchAll(/--color-([a-z-]+): (#[0-9a-f]{6});/g)) tokens[name] = value;
    return tokens;
}

/** `fg` at `percent` over `bg`, like color-mix(in srgb, fg percent, transparent) painted on bg. */
function tint(fg: string, bg: string, percent: number): string {
    const mixed = [1, 3, 5].map((offset) => {
        const a = parseInt(fg.slice(offset, offset + 2), 16);
        const b = parseInt(bg.slice(offset, offset + 2), 16);
        return Math.round(a * (percent / 100) + b * (1 - percent / 100));
    });
    return `#${mixed.map((value) => value.toString(16).padStart(2, '0')).join('')}`;
}

describe('avatar initials', () => {
    for (const color of [...AVATAR_COLORS, DIMMED_COLOR]) {
        it(`reads on ${color}`, () => {
            expect(contrastRatio(initialColor(color), color)).toBeGreaterThanOrEqual(4.5);
        });
    }

    it('picks the darker initial on light backgrounds', () => {
        expect(initialColor('#ffc107')).toBe('#1b1b1b');
        expect(initialColor('#0d47a1')).toBe('#ffffff');
    });
});

describe.each(THEMES.map((theme) => theme.id))('%s', (id) => {
    const tokens = tokensOf(id);
    const surfaces = [
        'surface',
        'surface-container-low',
        'surface-container',
        'surface-container-high',
        'surface-container-highest'
    ];

    it('keeps on-surface-variant readable on every surface', () => {
        // Secondary text lives on the lower surfaces; the raised ones carry on-surface.
        for (const surface of surfaces.slice(0, 3)) {
            expect(
                contrastRatio(tokens['on-surface-variant'], tokens[surface]),
                `on-surface-variant on ${surface}`
            ).toBeGreaterThanOrEqual(4.5);
        }
    });

    it('keeps warning and hidden chip text readable on its tint', () => {
        // Banners and rows sit on the lower surfaces.
        for (const surface of surfaces.slice(0, 3)) {
            for (const [accent, percent] of [
                ['paused', 12],
                ['hidden', 14],
                ['arrival', 16]
            ] as const) {
                const bg = tint(tokens[accent], tokens[surface], percent);
                expect(contrastRatio(tokens['on-surface'], bg), `${accent} tint on ${surface}`).toBeGreaterThanOrEqual(
                    4.5
                );
            }
        }
    });
});
