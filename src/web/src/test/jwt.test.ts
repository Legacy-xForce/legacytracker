import { describe, expect, it } from 'vitest';
import { decodeJwt, hasScope } from '../lib/jwt';
import { fakeJwt } from './helpers';

describe('jwt', () => {
    it('reads claims, including non-ASCII ones', () => {
        expect(decodeJwt(fakeJwt({ sub: 'u1', username: 'José' }))).toMatchObject({ sub: 'u1' });
    });

    it('returns null for anything that is not a token', () => {
        expect(decodeJwt('nope')).toBeNull();
        expect(decodeJwt('a.%%%.c')).toBeNull();
    });

    it('requires the scope to be exactly true', () => {
        expect(hasScope(fakeJwt({ scopes: { tracker: true } }), 'tracker')).toBe(true);
        expect(hasScope(fakeJwt({ scopes: { tracker: false } }), 'tracker')).toBe(false);
        expect(hasScope(fakeJwt({ scopes: { tracker: 'yes' } }), 'tracker')).toBe(false);
        expect(hasScope(fakeJwt({}), 'tracker')).toBe(false);
        expect(hasScope('garbage', 'tracker')).toBe(false);
    });
});
