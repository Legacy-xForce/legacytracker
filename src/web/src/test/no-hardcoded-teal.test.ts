import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Components take their colours from the theme tokens, so a switch of theme recolours them. A
 * literal teal in a component is what once kept buttons teal under Catppuccin.
 */
const SRC = join(__dirname, '..');

/** Files that may spell a teal out: the default/OLED palettes, identity colours and the map accent. */
const ALLOWED = new Set(['style.css', 'theme/themes.ts', 'lib/palette.ts', 'lib/avatars.ts', 'lib/openapi.ts']);

function sources(dir: string): string[] {
    return readdirSync(dir).flatMap((name) => {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) return name === 'test' ? [] : sources(path);
        return /\.(vue|ts|css)$/.test(name) ? [path] : [];
    });
}

/** Hue (degrees) and saturation of a `#rgb` / `#rrggbb` colour. */
function hueAndSaturation(hex: string): [number, number] {
    const full = hex.length === 4 ? [...hex.slice(1)].map((c) => c + c).join('') : hex.slice(1, 7);
    const [r, g, b] = [0, 2, 4].map((offset) => parseInt(full.slice(offset, offset + 2), 16) / 255);
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    if (delta === 0) return [0, 0];
    const lightness = (max + min) / 2;
    const saturation = delta / (1 - Math.abs(2 * lightness - 1));
    const sector = max === r ? ((g - b) / delta) % 6 : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4;
    return [(sector * 60 + 360) % 360, saturation];
}

describe('no hard-coded teal', () => {
    const files = sources(SRC).filter((file) => !ALLOWED.has(relative(SRC, file).split(sep).join('/')));

    it('scans the components', () => {
        expect(files.length).toBeGreaterThan(20);
    });

    it('has no teal/cyan hex literal outside the allow-listed palettes', () => {
        const offenders: string[] = [];
        for (const file of files) {
            const text = readFileSync(file, 'utf8');
            for (const match of text.matchAll(/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/g)) {
                const [hue, saturation] = hueAndSaturation(match[0]);
                if (hue >= 150 && hue <= 200 && saturation >= 0.25)
                    offenders.push(`${relative(SRC, file)}: ${match[0]}`);
            }
        }
        expect(offenders).toEqual([]);
    });

    it('uses no Tailwind teal, cyan or emerald palette classes', () => {
        const offenders = files.filter((file) =>
            /\b(?:bg|text|border|ring|from|to|via|fill|stroke|outline|divide|shadow|accent|caret|decoration)-(?:teal|cyan|emerald)-\d/.test(
                readFileSync(file, 'utf8')
            )
        );
        expect(offenders.map((file) => relative(SRC, file))).toEqual([]);
    });
});
