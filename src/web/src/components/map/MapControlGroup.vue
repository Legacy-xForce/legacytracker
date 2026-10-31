<template>
    <!-- A floating card holding a column of map buttons separated by hairlines, so related controls
         read as one group instead of a stack of buttons. -->
    <div class="map-control-group bg-surface-container-high shadow-level-1 flex flex-col items-center rounded-lg">
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
