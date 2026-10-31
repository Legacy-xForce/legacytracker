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
});
