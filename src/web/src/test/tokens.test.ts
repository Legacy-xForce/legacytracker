/// <reference types="node" />
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const root = resolve(process.cwd(), 'src');
const css = readFileSync(join(root, 'style.css'), 'utf8');

function sources(dir: string): string[] {
    return readdirSync(dir).flatMap((name) => {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) return name === 'test' ? [] : sources(path);
        return /\.(vue|ts|css)$/.test(name) ? [path] : [];
    });
}

describe('shape tokens', () => {
    it('defines the Material 3 scale, the same as the phone app', () => {
        const scale = Object.fromEntries([...css.matchAll(/--radius-([a-z]+): ([^;]+);/g)].map((m) => [m[1], m[2]]));
        expect(scale).toEqual({
            none: '0',
            xs: '4px',
            sm: '8px',
            md: '12px',
            lg: '16px',
            xl: '28px',
            full: '9999px'
        });
    });

    it('leaves no raw corner radius outside the token block', () => {
        const offenders: string[] = [];
        for (const file of sources(root)) {
            const text = readFileSync(file, 'utf8');
            for (const [index, line] of text.split('\n').entries()) {
                if (/rounded(-[trblse]{1,2})?-\[|rounded(-[trblse]{1,2})?-(2xl|3xl)\b/.test(line)) {
                    offenders.push(`${file}:${index + 1} ${line.trim()}`);
                }
                if (/border-radius:\s*[0-9]/.test(line) && !/--radius/.test(line)) {
                    offenders.push(`${file}:${index + 1} ${line.trim()}`);
                }
            }
        }
        expect(offenders).toEqual([]);
    });

    it('has every Material 3 type role and no hand-sized text', () => {
        for (const role of ['display', 'headline', 'title', 'body', 'label']) {
            for (const size of ['lg', 'md', 'sm']) {
                expect(css, `${role}-${size}`).toMatch(new RegExp(`@utility type-${role}-${size} \\{`));
            }
        }
        const offenders: string[] = [];
        for (const file of sources(root)) {
            for (const [index, line] of readFileSync(file, 'utf8').split('\n').entries()) {
                if (/text-\[[0-9.]+px\]/.test(line)) offenders.push(`${file}:${index + 1}`);
            }
        }
        expect(offenders).toEqual([]);
    });
});
describe('elevation', () => {
    it('takes every shadow from the shadow tokens', () => {
        const offenders: string[] = [];
        for (const file of sources(root)) {
            for (const [index, line] of readFileSync(file, 'utf8').split('\n').entries()) {
                if (!/shadow-\[|box-shadow:|drop-shadow\(/.test(line)) continue;
                // The brand mark's glow and inset rings are not elevation.
                if (/shadow-level|--color-shadow|box-shadow: inset|rgb\(130 213 200/.test(line)) continue;
                offenders.push(`${file}:${index + 1} ${line.trim()}`);
            }
        }
        expect(offenders).toEqual([]);
    });

    it('defines no more than five shadow tokens', () => {
        expect([...css.matchAll(/--shadow-level-[0-9]+:/g)].length).toBeLessThanOrEqual(5);
    });
});

describe('motion', () => {
    it('has the Material 3 durations, the same as the phone app', () => {
        const durations = Object.fromEntries(
            [...css.matchAll(/--duration-([a-z-]+): (\d+)ms;/g)].map((m) => [m[1], Number(m[2])])
        );
        expect(durations).toEqual({ short: 100, medium: 200, long: 300, 'extra-long': 500 });
    });

    it('turns transitions and animations off for reduced motion', () => {
        expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\)[\s\S]*transition-duration: 0\.01ms !important/);
    });

    it('writes no millisecond duration outside the tokens', () => {
        const offenders: string[] = [];
        for (const file of sources(root)) {
            if (file.endsWith('style.css') || file.endsWith('motionTokens.ts')) continue;
            for (const [index, line] of readFileSync(file, 'utf8').split('\n').entries()) {
                if (/duration-\d+|transition[^;]*\d+m?s\b|duration: \d{2,}/.test(line)) {
                    offenders.push(`${file}:${index + 1} ${line.trim()}`);
                }
            }
        }
        expect(offenders).toEqual([]);
    });
});
