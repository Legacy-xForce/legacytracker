<script setup lang="ts">
import { onMounted } from 'vue';
import { useRouter } from 'vue-router';
import Spinner from '../components/ui/Spinner.vue';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const router = useRouter();

// Back from Legacy Auth: finish the sign-in. Replacing the route also takes the code out of the address bar.
onMounted(async () => {
    const next = await session.completeSignIn(new URL(window.location.href));
    // null: on the way back to Legacy Auth.
    if (next !== null) await router.replace(next);
});
</script>

<template>
    <main class="text-on-surface-variant flex min-h-full items-center justify-center" aria-busy="true">
        <Spinner />
    </main>
</template>
