<script setup lang="ts">
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { AuthError } from '../api/auth';
import BrandMark from '../components/BrandMark.vue';
import Icon from '../components/ui/Icon.vue';
import Spinner from '../components/ui/Spinner.vue';
import TextField from '../components/ui/TextField.vue';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const router = useRouter();
const username = ref('');
const password = ref('');
const showPassword = ref(false);
const busy = ref(false);
const error = ref<string | null>(null);

async function submit() {
    if (busy.value) return;
    if (!username.value.trim() || !password.value) {
        error.value = 'Enter your username and password.';
        return;
    }
    busy.value = true;
    error.value = null;
    try {
        await session.login(username.value, password.value);
        await router.replace({ name: 'map' });
    } catch (e) {
        // A disabled account ends up on the access-denied page via the guard.
        if (session.accessDenial) await router.replace({ name: 'access-denied' });
        else error.value = e instanceof AuthError ? e.message : 'Sign-in failed. Please try again.';
    } finally {
        busy.value = false;
    }
}
</script>

<template>
    <main class="flex min-h-full items-center justify-center overflow-hidden px-5 pt-8 pb-6">
        <form class="w-full max-w-[420px]" novalidate @submit.prevent="submit" @input="error = null">
            <BrandMark />
            <h1 class="type-headline-sm mt-5 text-center font-bold">Legacy Tracker</h1>
            <p class="type-body-md text-on-surface-variant mt-1.5 text-center">Sign in to see where everyone is.</p>

            <div class="bg-surface-container relative mt-8 rounded-[20px] p-4">
                <TextField
                    v-model="username"
                    label="Username"
                    icon="person"
                    autocomplete="username"
                    autocapitalize="none"
                    autocorrect="off"
                    spellcheck="false"
                    :disabled="busy"
                />
                <TextField
                    v-model="password"
                    class="mt-3"
                    label="Password"
                    icon="lock"
                    autocomplete="current-password"
                    :type="showPassword ? 'text' : 'password'"
                    :disabled="busy"
                >
                    <template #suffix>
                        <button
                            type="button"
                            class="text-on-surface-variant hover:bg-on-surface/8 mr-1 flex size-10 items-center justify-center rounded-full"
                            :aria-label="showPassword ? 'Hide password' : 'Show password'"
                            :title="showPassword ? 'Hide password' : 'Show password'"
                            @click="showPassword = !showPassword"
                        >
                            <Icon :name="showPassword ? 'visibilityOff' : 'visibility'" />
                        </button>
                    </template>
                </TextField>

                <Transition
                    enter-from-class="opacity-0 -translate-y-1"
                    leave-to-class="opacity-0"
                    enter-active-class="transition duration-200"
                    leave-active-class="transition duration-150"
                >
                    <div
                        v-if="error"
                        role="alert"
                        class="bg-error-container text-on-error-container type-body-md mt-3 flex gap-2.5 rounded-[14px] py-2.5 pr-3.5 pl-3"
                    >
                        <Icon name="error" :size="20" />
                        <span>{{ error }}</span>
                    </div>
                </Transition>

                <button
                    type="submit"
                    :disabled="busy"
                    class="bg-primary text-on-primary mt-4 flex h-[52px] w-full items-center justify-center rounded-2xl text-[15px] font-semibold transition hover:brightness-110 disabled:opacity-60"
                >
                    <Spinner v-if="busy" />
                    <template v-else>Sign in</template>
                </button>
            </div>

            <p class="type-body-sm text-on-surface-variant mt-6 text-center">
                Passkey sign-in is available in the phone app.
            </p>
        </form>
    </main>
</template>
