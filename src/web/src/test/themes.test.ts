import { beforeEach, describe, expect, it } from 'vitest';
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
