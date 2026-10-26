<script setup lang="ts">
import Icon from './Icon.vue';
import type { IconName } from '../../lib/icons';
import { MAP_VARIANTS, type MapVariant } from '../../lib/styles';
import { useAppearanceStore } from '../../stores/appearance';

/**
 * The map lighting choice (issue #86): Auto follows the local clock, the rest
 * pin a preset. Lives in the map's layers popup; saved on this device only.
 */
const appearance = useAppearanceStore();

const MAP_VARIANT_ICONS: Record<MapVariant, IconName> = {
    auto: 'brightnessAuto',
    dawn: 'wbTwilight',
    day: 'lightMode',
    dusk: 'partlyCloudyDay',
    night: 'darkMode'
};
</script>

<template>
    <div class="flex flex-wrap gap-2" role="radiogroup" aria-label="Map lighting">
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
            <Icon v-if="appearance.mapVariant === option.id" name="check" :size="16" class="text-current" />
        </button>
    </div>
</template>
