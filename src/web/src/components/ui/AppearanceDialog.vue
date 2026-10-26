<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import Icon from './Icon.vue';
import type { IconName } from '../../lib/icons';
import { MAP_VARIANTS, type MapVariant } from '../../lib/styles';
import { useAppearanceStore } from '../../stores/appearance';
import { THEMES, type AppTheme } from '../../theme/themes';

const open = defineModel<boolean>({ required: true });
const appearance = useAppearanceStore();
const dialog = ref<HTMLElement | null>(null);

const MAP_VARIANT_ICONS: Record<MapVariant, IconName> = {
    auto: 'brightnessAuto',
    dawn: 'wbTwilight',
    day: 'lightMode',
    dusk: 'partlyCloudyDay',
    night: 'darkMode'
};

function close() {
    open.value = false;
}

function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape' && open.value) close();
}

function swatchStyle(theme: AppTheme) {
    return theme.id === 'adaptive'
        ? { background: 'linear-gradient(135deg, #0e1513 0 50%, #eff1f5 50% 100%)' }
        : { backgroundColor: theme.preview.canvas };
}

function modeLabel(theme: AppTheme) {
    return theme.mode === 'system' ? 'follows the system' : theme.mode;
}

watch(open, async (isOpen) => {
    if (!isOpen) return;
    await nextTick();
    dialog.value?.focus();
});

onMounted(() => document.addEventListener('keydown', onKey));
onBeforeUnmount(() => document.removeEventListener('keydown', onKey));
</script>

<template>
    <!-- Teleported out of the sheet, whose transforms would otherwise pin "fixed" to the sheet. -->
    <Teleport to="body">
        <div
            v-if="open"
            class="fixed inset-0 z-[2000] flex items-center justify-center bg-black/60 p-6"
            @click.self="close"
        >
            <div
                ref="dialog"
                role="dialog"
                aria-modal="true"
                aria-labelledby="appearance-title"
                tabindex="-1"
                class="bg-surface-container-high w-full max-w-md rounded-[28px] p-6 shadow-[0_8px_24px_rgb(0_0_0/0.5)] outline-none"
            >
                <div class="flex items-start justify-between gap-4">
                    <div>
                        <h2 id="appearance-title" class="type-title-lg font-bold">Appearance</h2>
                        <p class="type-body-sm text-on-surface-variant mt-1">
                            OLED, Catppuccin or adaptive. Saved on this device only.
                        </p>
                    </div>
                    <button
                        type="button"
                        aria-label="Close appearance settings"
                        class="text-on-surface-variant hover:bg-on-surface/6 -mt-1 -mr-2 flex size-10 shrink-0 items-center justify-center rounded-full"
                        @click="close"
                    >
                        <Icon name="close" :size="20" />
                    </button>
                </div>

                <div class="mt-5 flex flex-wrap gap-2" role="radiogroup" aria-label="Theme">
                    <button
                        v-for="option in THEMES"
                        :key="option.id"
                        type="button"
                        role="radio"
                        :aria-checked="appearance.theme === option.id"
                        :aria-label="`${option.label}, ${modeLabel(option)}`"
                        class="flex min-h-11 items-center gap-2 rounded-full border py-1 pr-3 pl-1.5 transition-colors"
                        :class="
                            appearance.theme === option.id
                                ? 'border-primary bg-primary-container text-on-primary-container'
                                : 'border-outline-variant bg-surface-container text-on-surface hover:bg-on-surface/6'
                        "
                        @click="appearance.setTheme(option.id)"
                    >
                        <span
                            class="border-outline-variant flex size-7 shrink-0 items-center justify-center rounded-full border"
                            :style="swatchStyle(option)"
                        >
                            <span
                                v-if="option.id === 'adaptive'"
                                class="size-2.5 rounded-full border-2 border-white/80"
                                :style="{ backgroundColor: option.preview.accent }"
                            />
                            <span
                                v-else
                                class="flex size-4 flex-col items-center justify-center gap-[3px] rounded-[4px]"
                                :style="{ backgroundColor: option.preview.raised }"
                            >
                                <span
                                    class="h-[2.5px] w-2.5 rounded-full"
                                    :style="{ backgroundColor: option.preview.accent }"
                                />
                                <span
                                    class="h-[2px] w-2 rounded-full"
                                    :style="{ backgroundColor: option.preview.text }"
                                />
                            </span>
                        </span>
                        <span class="type-label-lg whitespace-nowrap">{{ option.shortLabel }}</span>
                        <Icon v-if="appearance.theme === option.id" name="check" :size="16" class="text-current" />
                    </button>
                </div>

                <div class="mt-6">
                    <h3 class="type-title-sm font-bold">Map</h3>
                    <p class="type-body-sm text-on-surface-variant mt-1">
                        Auto follows the time of day. Saved on this device only.
                    </p>
                    <div class="mt-3 flex flex-wrap gap-2" role="radiogroup" aria-label="Map lighting">
                        <button
                            v-for="option in MAP_VARIANTS"
                            :key="option.id"
                            type="button"
                            role="radio"
                            :aria-checked="appearance.mapVariant === option.id"
                            :aria-label="option.id === 'auto' ? 'Auto, follows the time of day' : option.label"
                            class="flex min-h-11 items-center gap-2 rounded-full border px-3 py-2 transition-colors"
                            :class="
                                appearance.mapVariant === option.id
                                    ? 'border-primary bg-primary-container text-on-primary-container'
                                    : 'border-outline-variant bg-surface-container text-on-surface hover:bg-on-surface/6'
                            "
                            @click="appearance.setMapVariant(option.id)"
                        >
                            <Icon :name="MAP_VARIANT_ICONS[option.id]" :size="18" />
                            <span class="type-label-lg whitespace-nowrap">{{ option.label }}</span>
                            <Icon
                                v-if="appearance.mapVariant === option.id"
                                name="check"
                                :size="16"
                                class="text-current"
                            />
                        </button>
                    </div>
                </div>

                <div class="mt-6 flex justify-end">
                    <button
                        type="button"
                        class="text-primary type-label-lg hover:bg-on-surface/6 rounded-full px-4 py-2.5"
                        @click="close"
                    >
                        Done
                    </button>
                </div>
            </div>
        </div>
    </Teleport>
</template>
