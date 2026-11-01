import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
    formatDayKilometers,
    formatDistance,
    formatElapsed,
    formatSpeed,
    formatTripDuration,
    formatUpdatedAgo
} from '../lib/format';

// The same table the phone's tests read: docs/formatting.md.
const fixtures = JSON.parse(
    readFileSync(resolve(__dirname, '../../../../docs/formatting-fixtures.json'), 'utf8')
) as Record<string, Record<string, number | string>[]>;

function check(name: string, key: string, run: (value: number) => string) {
    describe(name, () => {
        for (const row of fixtures[name]) {
            it(`${key}=${row[key]} reads ${row.expected}`, () => {
                expect(run(row[key] as number)).toBe(row.expected);
            });
        }
    });
}

check('formatElapsed', 'seconds', (s) => formatElapsed(s * 1000));
check('formatUpdatedAgo', 'seconds', (s) => formatUpdatedAgo(s * 1000));
check('formatTripDuration', 'seconds', formatTripDuration);
check('formatDistance', 'meters', formatDistance);
check('formatDayKilometers', 'meters', formatDayKilometers);
check('formatSpeed', 'mps', formatSpeed);
