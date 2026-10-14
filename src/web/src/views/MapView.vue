<script setup lang="ts">
import { useRouter } from 'vue-router';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const router = useRouter();

async function signOut() {
    await session.logout();
    await router.replace({ name: 'login' });
}
</script>

<template>
    <main class="flex min-h-full flex-col items-center justify-center gap-4 px-4">
        <p>Signed in as {{ session.username }}. The map is coming in the next step.</p>
        <button class="rounded-xl border border-neutral-800 px-4 py-2" @click="signOut">Sign out</button>
    </main>
</template>
