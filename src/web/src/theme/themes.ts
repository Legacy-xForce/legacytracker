import { storage } from '../lib/storage';

export type ThemeId =
    | 'teal'
    | 'oled'
    | 'catppuccin-mocha'
    | 'catppuccin-macchiato'
    | 'catppuccin-frappe'
    | 'catppuccin-latte'
    | 'adaptive';

export type ThemeMode = 'dark' | 'light' | 'system';

export interface AppTheme {
    id: ThemeId;
    /** Full name used in accessibility labels. */
    label: string;
    /** Short name shown on the theme pill. */
    shortLabel: string;
    mode: ThemeMode;
    /** Representative colors used by the theme picker preview. */
    preview: {
        canvas: string;
        raised: string;
        accent: string;
        text: string;
    };
}

export const THEME_STORAGE_KEY = 'legacytracker.theme';
export const DEFAULT_THEME_ID: ThemeId = 'teal';

// Keep the previews in sync with the `data-theme` blocks in style.css.
export const THEMES: AppTheme[] = [
    {
        id: 'teal',
        label: 'Teal',
        shortLabel: 'Teal',
        mode: 'dark',
        preview: { canvas: '#0e1513', raised: '#1a2120', accent: '#82d5c8', text: '#dde4e1' }
    },
    {
        id: 'oled',
        label: 'OLED',
        shortLabel: 'OLED',
        mode: 'dark',
        preview: { canvas: '#000000', raised: '#0d1312', accent: '#82d5c8', text: '#dde4e1' }
    },
    {
        id: 'catppuccin-mocha',
        label: 'Catppuccin Mocha',
        shortLabel: 'Mocha',
        mode: 'dark',
        preview: { canvas: '#1e1e2e', raised: '#313244', accent: '#cba6f7', text: '#cdd6f4' }
    },
    {
        id: 'catppuccin-macchiato',
        label: 'Catppuccin Macchiato',
        shortLabel: 'Macchiato',
        mode: 'dark',
        preview: { canvas: '#24273a', raised: '#363a4f', accent: '#c6a0f6', text: '#cad3f5' }
    },
    {
        id: 'catppuccin-frappe',
        label: 'Catppuccin Frappé',
        shortLabel: 'Frappé',
        mode: 'dark',
        preview: { canvas: '#303446', raised: '#414559', accent: '#ca9ee6', text: '#c6d0f5' }
    },
    {
        id: 'catppuccin-latte',
        label: 'Catppuccin Latte',
        shortLabel: 'Latte',
        mode: 'light',
        preview: { canvas: '#eff1f5', raised: '#e6e9ef', accent: '#8839ef', text: '#4c4f69' }
    },
    {
        id: 'adaptive',
        label: 'Adaptive',
        shortLabel: 'Adaptive',
        mode: 'system',
        preview: { canvas: '#0e1513', raised: '#eff1f5', accent: '#82d5c8', text: '#4c4f69' }
    }
];

const themeIds = new Set<string>(THEMES.map((theme) => theme.id));

export function isThemeId(value: unknown): value is ThemeId {
    return typeof value === 'string' && themeIds.has(value);
}

export function getTheme(id: ThemeId): AppTheme {
    return THEMES.find((theme) => theme.id === id) ?? THEMES[0];
}

export function getStoredTheme(): ThemeId {
    const stored = storage.get(THEME_STORAGE_KEY);
    return isThemeId(stored) ? stored : DEFAULT_THEME_ID;
}

/**
 * Applies a theme to the document. The colors live in `style.css` under
 * `html[data-theme='…']`, so this only flips the selector and keeps the
 * browser chrome (color scheme / theme-color) in sync.
 */
export function applyTheme(id: ThemeId): void {
    const theme = getTheme(id);
    const root = document.documentElement;
    const scheme = theme.mode === 'system' ? 'dark light' : theme.mode;

    root.dataset.theme = theme.id;
    root.style.colorScheme = scheme;

    document.querySelector('meta[name="color-scheme"]')?.setAttribute('content', scheme);
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme.preview.canvas);
}

export function setTheme(id: ThemeId): ThemeId {
    applyTheme(id);
    storage.set(THEME_STORAGE_KEY, id);
    return id;
}
