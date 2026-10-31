<script setup lang="ts">
import { useAttrs, useId, type StyleValue } from 'vue';
import Icon from './Icon.vue';
import type { IconName } from '../../lib/icons';

// Attributes (type, autocomplete, …) belong on the input; class and style (spacing, width) on the
// field, or a margin would land inside it.
defineOptions({ inheritAttrs: false });
defineProps<{ label: string; icon: IconName }>();
const model = defineModel<string>({ required: true });
const id = useId();
const attrs = useAttrs();
// Called from the template, not computed: attrs aren't reactive, but every render sees the latest.
function inputAttrs() {
    const { class: _class, style: _style, ...rest } = attrs;
    return rest;
}
</script>

<template>
    <!-- Material's filled text field as the app themes it: no underline, a primary outline on focus. -->
    <div
        class="group bg-surface-container-high focus-within:outline-primary relative flex h-14 items-center rounded-lg outline-[1.5px] outline-transparent"
        :class="attrs.class"
        :style="attrs.style as StyleValue"
    >
        <span class="text-on-surface-variant pr-1 pl-3"><Icon :name="icon" /></span>
        <div class="relative h-full min-w-0 flex-1">
            <input
                :id="id"
                v-model="model"
                placeholder=" "
                v-bind="inputAttrs()"
                class="peer text-on-surface type-body-lg h-full w-full bg-transparent pt-4 pr-3 pl-2 outline-none disabled:opacity-60"
            />
            <label
                :for="id"
                class="text-on-surface-variant type-body-lg peer-focus:text-primary duration-medium pointer-events-none absolute top-1/2 left-2 origin-left -translate-y-1/2 transition-all peer-focus:top-2.5 peer-focus:translate-y-0 peer-focus:text-xs peer-[:not(:placeholder-shown)]:top-2.5 peer-[:not(:placeholder-shown)]:translate-y-0 peer-[:not(:placeholder-shown)]:text-xs"
                >{{ label }}</label
            >
        </div>
        <slot name="suffix" />
    </div>
</template>
