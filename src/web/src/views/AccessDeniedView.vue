<script setup lang="ts">
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const router = useRouter();

const disabled = computed(() => session.accessDenial === 'accountDisabled');

async function signOut() {
    await session.logout();
    await router.replace({ name: 'login' });
}
</script>

<template>
    <main class="flex min-h-full items-center justify-center px-4">
        <div class="w-full max-w-sm space-y-4 text-center">
            <h1 class="text-2xl font-semibold">{{ disabled ? 'Access restricted' : 'Scope required' }}</h1>
            <p class="text-neutral-400">
                {{
                    disabled
                        ? 'This account has been disabled.'
                        : 'This account has not been granted access to Legacy Tracker.'
                }}
                Permissions are managed centrally, so please ask an administrator.
            </p>
            <button class="bg-brand w-full rounded-xl px-4 py-3 font-medium text-black" @click="signOut">
                {{ disabled ? 'Back to sign in' : 'Sign out' }}
            </button>
        </div>
    </main>
</template>
