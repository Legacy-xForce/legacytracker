<template>
    <!-- A floating card holding a column of map buttons separated by hairlines, so related controls
         read as one group instead of a stack of buttons. -->
    <div
        class="map-control-group bg-surface-container-high flex flex-col items-center rounded-2xl shadow-[0_4px_12px_color-mix(in_srgb,var(--color-shadow)_40%,transparent)]"
    >
        <slot />
    </div>
</template>

<style>
.map-control-group > * + *::before {
    content: '';
    position: absolute;
    top: 0;
    left: 10px;
    right: 10px;
    height: 1px;
    background: var(--color-outline-variant);
}
</style>
