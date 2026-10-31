<script setup lang="ts">
import { ref } from 'vue';
import { AuthError } from '../api/auth';
import BrandMark from '../components/BrandMark.vue';
import Icon from '../components/ui/Icon.vue';
import Spinner from '../components/ui/Spinner.vue';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const busy = ref(false);
// Why the last sign-in or session ended (e.g. an account without tracker access), or why this one can't start.
const error = ref<string | null>(session.signInError);

// Signing in happens at Legacy Auth (password or passkey); it sends the browser back to /callback.
async function signIn() {
    if (busy.value) return;
    busy.value = true;
    error.value = null;
    try {
        await session.signIn();
    } catch (e) {
        error.value = e instanceof AuthError ? e.message : 'Sign-in failed. Please try again.';
        busy.value = false;
    }
}
</script>

<template>
    <main class="flex min-h-full items-center justify-center overflow-hidden px-5 pt-8 pb-6">
        <section class="w-full max-w-[420px]">
            <BrandMark />
            <h1 class="type-headline-sm mt-5 text-center font-bold">Legacy Tracker</h1>
            <p class="type-body-md text-on-surface-variant mt-1.5 text-center">Sign in to see where everyone is.</p>

            <div class="bg-surface-container relative mt-8 rounded-md p-4">
                <Transition
                    enter-from-class="opacity-0 -translate-y-1"
                    leave-to-class="opacity-0"
                    enter-active-class="transition duration-200"
                    leave-active-class="transition duration-150"
                >
                    <div
                        v-if="error"
                        role="alert"
                        class="bg-error-container text-on-error-container type-body-md mb-4 flex gap-2.5 rounded-md py-2.5 pr-3.5 pl-3"
                    >
                        <Icon name="error" :size="20" />
                        <span>{{ error }}</span>
                    </div>
                </Transition>

                <button
                    type="button"
                    :disabled="busy"
                    class="bg-primary text-on-primary type-label-lg flex h-[52px] w-full items-center justify-center rounded-lg font-semibold transition hover:brightness-110 disabled:opacity-60"
                    @click="signIn"
                >
                    <Spinner v-if="busy" />
                    <template v-else>Sign in with Legacy</template>
                </button>
            </div>

            <p class="type-body-sm text-on-surface-variant mt-6 text-center">
                One Legacy account for the tracker and the calendar, with a password or a passkey.
            </p>
        </section>
    </main>
</template>
