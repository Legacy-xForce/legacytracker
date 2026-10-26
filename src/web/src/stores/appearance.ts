import { defineStore } from 'pinia';
import { ref } from 'vue';
import { getStoredMapVariant, setMapVariant as persistMapVariant, type MapVariant } from '../lib/styles';
import { applyTheme, getStoredTheme, setTheme as persistTheme, type ThemeId } from '../theme/themes';

/// Theme and map lighting are kept on this device only. Applying the theme here
/// as well as in `main.ts` keeps the store correct when it is first created.
export const useAppearanceStore = defineStore('appearance', () => {
    const theme = ref<ThemeId>(getStoredTheme());
    applyTheme(theme.value);

    const mapVariant = ref<MapVariant>(getStoredMapVariant());

    function setTheme(id: ThemeId): void {
        theme.value = persistTheme(id);
    }

    function setMapVariant(id: MapVariant): void {
        mapVariant.value = persistMapVariant(id);
    }

    return { theme, setTheme, mapVariant, setMapVariant };
});
