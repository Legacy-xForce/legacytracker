import { describe, expect, it, vi } from 'vitest';
import { redrawAfterStyleLoad } from '../lib/mapbox';

describe('redrawAfterStyleLoad', () => {
    it('paints when the style is ready', () => {
        const paint = vi.fn();
        redrawAfterStyleLoad(paint);
        expect(paint).toHaveBeenCalledOnce();
    });

    it('ignores a style that is not done loading', () => {
        const paint = () => {
            throw new Error('Style is not done loading.');
        };
        expect(() => redrawAfterStyleLoad(paint)).not.toThrow();
    });

    it('lets every other paint failure through', () => {
        const paint = () => {
            throw new Error('bad layer');
        };
        expect(() => redrawAfterStyleLoad(paint)).toThrow('bad layer');
    });
});
