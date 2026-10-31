<script setup lang="ts">
import UserAvatar from '../UserAvatar.vue';

defineProps<{ userId: string; name: string; size: number; stale: boolean }>();
</script>

<template>
    <!-- A small dot on the avatar: green while sharing, grey once the phone has gone quiet. -->
    <span class="relative shrink-0" :style="{ width: `${size}px`, height: `${size}px` }">
        <UserAvatar :user-id="userId" :name="name" :size="size" :dimmed="stale" />
        <span
            class="border-surface-container-low absolute -right-px -bottom-px rounded-full border-[2.5px]"
            :class="stale ? 'bg-stale' : 'bg-online'"
            :style="{ width: `${size * 0.28}px`, height: `${size * 0.28}px` }"
        />
    </span>
</template>
