<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import Icon from '../components/ui/Icon.vue';
import Spinner from '../components/ui/Spinner.vue';
import type { IconName } from '../lib/icons';
import { useSessionStore } from '../stores/session';

// The same warning/error accents as the phone app and Legacy Calendar, so every client explains
// Legacy Auth decisions the same way.
const AMBER = '#fbbf24';
const ORANGE = '#fb923c';
const RED = '#f87171';

const session = useSessionStore();
const router = useRouter();
const checking = ref(false);
const notice = ref<string | null>(null);
// Remembered before signing out clears it.
const username = session.username;

const disabled = computed(() => session.accessDenial === 'accountDisabled');
const accent = computed(() => (disabled.value ? RED : AMBER));

const notes = computed<{ icon: IconName; title: string; body: string; accent?: boolean }[]>(() =>
    disabled.value
        ? [
              {
                  icon: 'info',
                  title: 'Need access restored?',
                  body: 'Please contact your system administrator or support team to review your account status.'
              }
          ]
        : [
              {
                  icon: 'key',
                  accent: true,
                  title: 'Scopes managed via Legacy Auth',
                  body: 'Permissions and scopes are managed centrally. Please ask your administrator to grant the tracker scope to your profile.'
              }
          ]
);

// A fresh token carries the account's current scopes.
async function checkAgain() {
    checking.value = true;
    notice.value = null;
    try {
        await session.refresh();
        if (!session.accessDenial) await router.replace({ name: 'map' });
        else if (session.accessDenial === 'missingScope') {
            notice.value = 'Still no tracker access. Ask your administrator to grant it.';
        }
    } catch {
        if (session.isAuthenticated) notice.value = "Couldn't check your access. Check your connection and try again.";
    } finally {
        checking.value = false;
    }
}

async function signOut() {
    await session.logout();
    await router.replace({ name: 'login' });
}
</script>

<template>
    <main
        class="flex min-h-full items-center justify-center px-4 py-6"
        :style="{
            background: `radial-gradient(circle min(110vw, 110vh) at 50% 50%, ${accent}29, ${accent}12 50%, transparent 100%)`
        }"
    >
        <section
            class="bg-surface-container w-full max-w-[420px] rounded-[28px] border p-6 shadow-[0_20px_40px_rgb(0_0_0/0.35)]"
            :style="{ borderColor: `${accent}38` }"
        >
            <div
                class="mx-auto flex size-20 items-center justify-center rounded-[20px] border"
                :style="{ color: accent, background: `${accent}1a`, borderColor: `${accent}4d` }"
            >
                <Icon :name="disabled ? 'lock' : 'shield'" :size="32" />
            </div>
            <div class="mt-6 flex justify-center">
                <span
                    class="flex items-center gap-2 rounded-full border px-3 py-[5px] text-[11.5px] font-bold tracking-[1.1px] uppercase"
                    :style="{ color: accent, background: `${accent}1a`, borderColor: `${accent}4d` }"
                >
                    <span class="size-2 animate-pulse rounded-full" :style="{ background: accent }" />
                    {{ disabled ? 'Account disabled' : 'Insufficient permissions' }}
                </span>
            </div>
            <h1 class="type-headline-sm mt-3.5 text-center font-extrabold">
                {{ disabled ? 'Access Restricted' : 'Scope Required' }}
            </h1>
            <p class="type-body-md text-on-surface-variant mt-3 text-center leading-[1.55]">
                <template v-if="disabled">
                    Your Legacy account
                    <strong v-if="username" class="text-on-surface font-semibold">({{ username }})</strong>
                    has been marked as disabled by an administrator.
                </template>
                <template v-else>
                    Your authenticated account
                    <strong v-if="username" class="text-on-surface font-semibold">({{ username }})</strong>
                    does not currently have the required permission scope
                    <code
                        class="bg-surface-container-highest rounded-md px-1.5 py-px text-[12.5px]"
                        :style="{ color: AMBER }"
                        >tracker</code
                    >
                    to access Legacy Tracker.
                </template>
            </p>

            <div class="border-outline-variant/60 mt-6 space-y-3.5 rounded-[18px] border bg-[rgb(9_15_14/0.7)] p-4">
                <div v-for="note in notes" :key="note.title" class="flex gap-3">
                    <Icon
                        :name="note.icon"
                        :size="18"
                        class="mt-px"
                        :class="note.accent ? '' : 'text-on-surface-variant'"
                        :style="note.accent ? { color: accent } : undefined"
                    />
                    <div>
                        <p class="type-label-lg text-on-surface font-semibold">{{ note.title }}</p>
                        <p class="type-body-sm text-on-surface-variant mt-[3px] leading-[1.45]">{{ note.body }}</p>
                    </div>
                </div>
            </div>

            <p v-if="notice" role="status" class="type-body-sm text-on-surface-variant mt-4 text-center">
                {{ notice }}
            </p>

            <div class="mt-6 space-y-3">
                <button
                    v-if="!disabled"
                    class="flex h-[52px] w-full items-center justify-center gap-2 rounded-2xl text-[15px] font-semibold text-[#1c1917] transition hover:brightness-110 disabled:opacity-60"
                    :style="{ background: ORANGE }"
                    :disabled="checking"
                    @click="checkAgain"
                >
                    <Spinner v-if="checking" :size="18" />
                    <Icon v-else name="refresh" :size="18" />
                    Check Again
                </button>
                <button
                    class="flex h-[52px] w-full items-center justify-center gap-2 rounded-2xl border text-[15px] font-semibold transition hover:bg-white/5 disabled:opacity-60"
                    :class="disabled ? '' : 'text-on-surface-variant border-outline-variant'"
                    :style="disabled ? { color: RED, borderColor: `${RED}99` } : undefined"
                    :disabled="checking"
                    @click="signOut"
                >
                    <Icon name="logout" :size="18" />
                    {{ disabled ? 'Switch Account / Sign In' : 'Switch Account' }}
                </button>
            </div>
        </section>
    </main>
</template>
