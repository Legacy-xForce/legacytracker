<script setup lang="ts">
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { AuthError } from '../api/auth';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const router = useRouter();
const username = ref('');
const password = ref('');
const busy = ref(false);
const error = ref<string | null>(null);

async function submit() {
    if (busy.value) return;
    busy.value = true;
    error.value = null;
    try {
        await session.login(username.value, password.value);
        await router.replace({ name: 'map' });
    } catch (e) {
        // A disabled account ends up on the access-denied page via the guard.
        if (session.accessDenial) await router.replace({ name: 'access-denied' });
        else error.value = e instanceof AuthError ? e.message : 'Sign-in failed.';
    } finally {
        busy.value = false;
    }
}
</script>

<template>
    <main class="flex min-h-full items-center justify-center px-4">
        <form class="w-full max-w-sm space-y-4" @submit.prevent="submit">
            <h1 class="text-2xl font-semibold">Legacy Tracker</h1>
            <input
                v-model="username"
                autocomplete="username"
                placeholder="Username"
                required
                class="focus:border-brand w-full rounded-xl border border-neutral-800 bg-black px-4 py-3 outline-none"
            />
            <input
                v-model="password"
                type="password"
                autocomplete="current-password"
                placeholder="Password"
                required
                class="focus:border-brand w-full rounded-xl border border-neutral-800 bg-black px-4 py-3 outline-none"
            />
            <p v-if="error" role="alert" class="text-sm text-red-400">{{ error }}</p>
            <button
                type="submit"
                :disabled="busy"
                class="bg-brand w-full rounded-xl px-4 py-3 font-medium text-black disabled:opacity-60"
            >
                {{ busy ? 'Signing in…' : 'Sign in' }}
            </button>
        </form>
    </main>
</template>
