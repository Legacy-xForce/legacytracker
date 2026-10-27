<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import {
    createApiToken,
    deleteApiToken,
    listApiTokens,
    rotateApiToken,
    updateApiTokenAllowedIps,
    type ApiToken,
    type ApiTokenScope,
    type IssuedApiToken
} from '../../api/apiTokens';
import { formatShortDate, formatUpdatedAgo } from '../../lib/format';
import { showToast } from '../../lib/toast';
import ConfirmDialog from '../ui/ConfirmDialog.vue';
import Icon from '../ui/Icon.vue';
import Spinner from '../ui/Spinner.vue';
import TextField from '../ui/TextField.vue';

const emit = defineEmits<{ close: [] }>();

const SCOPES: { id: ApiTokenScope; label: string; detail: string }[] = [
    { id: 'read', label: 'Read', detail: 'See locations, trips, places and the live map' },
    { id: 'write', label: 'Write', detail: 'Everything you can do, including uploading locations' }
];

const tokens = ref<ApiToken[] | null>(null);
const loadError = ref<string | null>(null);
const name = ref('');
const scope = ref<ApiTokenScope>('read');
const creating = ref(false);
/** The token just created or rotated; its value is never shown again once dismissed. */
const issued = ref<IssuedApiToken | null>(null);
const copied = ref(false);
const pending = ref<{ action: 'rotate' | 'delete'; token: ApiToken } | null>(null);
const busy = ref(false);
/** The token whose settings panel is open, and the allowlist being edited there. */
const editingId = ref<string | null>(null);
const draft = ref<string[]>([]);
const draftEntry = ref('');
const saving = ref(false);
/** Where the API sees this page coming from, offered as a one-click entry. */
const yourIp = ref<string | null>(null);

function message(error: unknown): string {
    return error instanceof Error ? error.message : 'Something went wrong.';
}

async function load() {
    loadError.value = null;
    try {
        const list = await listApiTokens();
        tokens.value = list.tokens;
        yourIp.value = list.yourIp;
    } catch (error) {
        loadError.value = message(error);
    }
}

async function create() {
    creating.value = true;
    try {
        const token = await createApiToken(name.value.trim(), scope.value);
        tokens.value = [token, ...(tokens.value ?? [])];
        reveal(token);
        name.value = '';
    } catch (error) {
        showToast(message(error));
    } finally {
        creating.value = false;
    }
}

function reveal(token: IssuedApiToken) {
    issued.value = token;
    copied.value = false;
}

async function copy() {
    if (!issued.value) return;
    try {
        await navigator.clipboard.writeText(issued.value.token);
        copied.value = true;
    } catch {
        showToast('Copy failed. Select the token and copy it by hand.');
    }
}

async function confirmPending() {
    const action = pending.value;
    if (!action) return;
    busy.value = true;
    try {
        if (action.action === 'rotate') {
            const token = await rotateApiToken(action.token.id);
            tokens.value = (tokens.value ?? []).map((t) => (t.id === token.id ? token : t));
            reveal(token);
        } else {
            await deleteApiToken(action.token.id);
            tokens.value = (tokens.value ?? []).filter((t) => t.id !== action.token.id);
            if (issued.value?.id === action.token.id) issued.value = null;
            if (editingId.value === action.token.id) editingId.value = null;
            showToast(`Deleted “${action.token.name}”.`);
        }
        pending.value = null;
    } catch (error) {
        showToast(message(error));
    } finally {
        busy.value = false;
    }
}

/** Short phrase for a row and the save toast: "any address" or "2 addresses". */
function allowlistNote(ips: string[]): string {
    if (ips.length === 0) return 'any address';
    return `${ips.length} address${ips.length === 1 ? '' : 'es'}`;
}

function toggleEdit(token: ApiToken) {
    if (editingId.value === token.id) {
        editingId.value = null;
        return;
    }
    editingId.value = token.id;
    draft.value = [...token.allowedIps];
    draftEntry.value = '';
}

function addEntry(value: string | null) {
    const entry = value?.trim() ?? '';
    draftEntry.value = '';
    if (!entry) return;
    // The server owns validation and names whatever it refuses; a space could
    // only come from pasting a whole list at once.
    if (/\s/.test(entry)) {
        showToast('Enter one address or CIDR prefix at a time.');
        return;
    }
    if (!draft.value.includes(entry)) draft.value.push(entry);
}

function removeEntry(entry: string) {
    draft.value = draft.value.filter((ip) => ip !== entry);
}

async function saveAllowlist() {
    const token = (tokens.value ?? []).find((t) => t.id === editingId.value);
    if (!token || saving.value) return;
    saving.value = true;
    try {
        const updated = await updateApiTokenAllowedIps(token.id, draft.value);
        tokens.value = (tokens.value ?? []).map((t) => (t.id === updated.id ? updated : t));
        editingId.value = null;
        showToast(`“${updated.name}” may now be used from ${allowlistNote(updated.allowedIps)}.`);
    } catch (error) {
        showToast(message(error));
    } finally {
        saving.value = false;
    }
}

function usage(token: ApiToken): string {
    const created = `Created ${formatShortDate(token.createdAt)}`;
    if (token.lastUsedAt === null) return `${created} · Never used`;
    return `${created} · Used ${formatUpdatedAgo(Date.now() - token.lastUsedAt)}`;
}

function onKey(event: KeyboardEvent) {
    if (event.key !== 'Escape' || pending.value) return;
    // Escape backs out one level at a time: the open panel, then the dialog.
    if (editingId.value) editingId.value = null;
    else emit('close');
}

onMounted(() => {
    document.addEventListener('keydown', onKey);
    void load();
});
onBeforeUnmount(() => document.removeEventListener('keydown', onKey));
</script>

<template>
    <Teleport to="body">
        <div
            class="fixed inset-0 z-[1900] flex items-stretch justify-center bg-black/60 sm:items-center sm:p-6"
            @click.self="emit('close')"
        >
            <section
                role="dialog"
                aria-modal="true"
                aria-labelledby="api-tokens-title"
                class="bg-surface-container scroll-panel flex w-full flex-col overflow-y-auto shadow-[0_8px_24px_rgb(0_0_0/0.5)] sm:max-h-[90vh] sm:max-w-lg sm:rounded-[28px]"
            >
                <header class="flex items-center gap-3 px-6 pt-5 pb-2">
                    <span
                        class="bg-primary-container text-on-primary-container flex size-10 items-center justify-center rounded-full"
                    >
                        <Icon name="api" :size="22" />
                    </span>
                    <h2 id="api-tokens-title" class="type-title-lg flex-1 font-bold">API tokens</h2>
                    <button
                        class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                        aria-label="Close"
                        @click="emit('close')"
                    >
                        <Icon name="close" />
                    </button>
                </header>

                <div class="flex flex-col gap-6 px-6 pt-2 pb-6">
                    <p class="type-body-md text-on-surface-variant">
                        Let scripts and other apps use the tracker as you. Send a token in the
                        <code class="text-on-surface">X-API-Token</code> header. Tokens don't expire, so rotate or
                        delete any you no longer trust, and edit one to limit it to the addresses that may use it.
                        <RouterLink to="/docs" target="_blank" class="text-primary inline-flex items-center gap-0.5">
                            API documentation <Icon name="openInNew" :size="14" />
                        </RouterLink>
                    </p>

                    <div
                        v-if="issued"
                        class="bg-primary-container/40 border-primary/40 rounded-2xl border p-4"
                        data-issued
                    >
                        <p class="type-title-sm">Copy “{{ issued.name }}” now</p>
                        <p class="type-body-sm text-on-surface-variant mt-1">
                            You won't be able to see this token again.
                        </p>
                        <div class="bg-surface-container-lowest mt-3 flex items-center gap-2 rounded-xl py-1 pr-1 pl-3">
                            <code class="type-body-sm min-w-0 flex-1 font-mono break-all select-all" data-token>{{
                                issued.token
                            }}</code>
                            <button
                                class="text-primary hover:bg-on-surface/6 flex size-10 shrink-0 items-center justify-center rounded-full"
                                :aria-label="copied ? 'Copied' : 'Copy token'"
                                :title="copied ? 'Copied' : 'Copy token'"
                                @click="copy"
                            >
                                <Icon :name="copied ? 'check' : 'contentCopy'" :size="20" />
                            </button>
                        </div>
                        <div class="mt-2 flex justify-end">
                            <button
                                class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2"
                                @click="issued = null"
                            >
                                Done
                            </button>
                        </div>
                    </div>

                    <form class="flex flex-col gap-3" @submit.prevent="create">
                        <h3 class="type-label-md text-on-surface-variant tracking-[0.8px] uppercase">New token</h3>
                        <TextField v-model="name" label="Name (e.g. Home Assistant)" icon="key" maxlength="60" />
                        <div role="radiogroup" aria-label="Scope" class="grid grid-cols-2 gap-2">
                            <button
                                v-for="option in SCOPES"
                                :key="option.id"
                                type="button"
                                role="radio"
                                :aria-checked="scope === option.id"
                                class="rounded-2xl border p-3 text-left transition-colors"
                                :class="
                                    scope === option.id
                                        ? 'border-primary bg-secondary-container'
                                        : 'border-outline-variant hover:bg-on-surface/4'
                                "
                                @click="scope = option.id"
                            >
                                <span class="type-title-sm flex items-center gap-1.5">
                                    <Icon v-if="scope === option.id" name="check" :size="16" class="text-primary" />
                                    {{ option.label }}
                                </span>
                                <span class="type-body-sm text-on-surface-variant mt-1 block">{{ option.detail }}</span>
                            </button>
                        </div>
                        <button
                            type="submit"
                            class="bg-primary text-on-primary type-label-lg flex h-10 items-center justify-center gap-2 self-end rounded-full px-5 hover:brightness-110 disabled:opacity-60"
                            :disabled="creating"
                        >
                            <Spinner v-if="creating" :size="18" />
                            <Icon v-else name="add" :size="18" />
                            Create token
                        </button>
                    </form>

                    <div class="flex flex-col gap-2">
                        <h3 class="type-label-md text-on-surface-variant tracking-[0.8px] uppercase">Your tokens</h3>
                        <div v-if="tokens === null && !loadError" class="flex justify-center py-6"><Spinner /></div>
                        <div
                            v-else-if="loadError"
                            class="bg-surface-container-high flex items-center gap-3 rounded-2xl py-2 pr-2 pl-4"
                        >
                            <Icon name="cloudOff" :size="20" class="text-on-surface-variant" />
                            <span class="type-body-md flex-1">{{ loadError }}</span>
                            <button
                                class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2"
                                @click="load"
                            >
                                Retry
                            </button>
                        </div>
                        <p
                            v-else-if="tokens && tokens.length === 0"
                            class="bg-surface-container-high type-body-md text-on-surface-variant rounded-2xl px-4 py-4"
                        >
                            No tokens yet.
                        </p>
                        <ul v-else class="flex flex-col gap-2">
                            <li
                                v-for="token in tokens"
                                :key="token.id"
                                class="bg-surface-container-high rounded-2xl"
                                data-token-row
                            >
                                <div class="flex items-center gap-3 py-3 pr-2 pl-4">
                                    <div class="min-w-0 flex-1">
                                        <p class="flex items-center gap-2">
                                            <span class="type-title-sm truncate">{{ token.name }}</span>
                                            <span
                                                class="type-label-sm shrink-0 rounded-md px-1.5 py-0.5 uppercase"
                                                :class="
                                                    token.scope === 'write'
                                                        ? 'bg-error-container text-on-error-container'
                                                        : 'bg-secondary-container text-on-secondary-container'
                                                "
                                                >{{ token.scope }}</span
                                            >
                                        </p>
                                        <p class="type-body-sm text-on-surface-variant mt-0.5 truncate font-mono">
                                            {{ token.hint }}
                                        </p>
                                        <p class="type-body-sm text-on-surface-variant mt-0.5">{{ usage(token) }}</p>
                                        <p
                                            v-if="token.allowedIps.length"
                                            class="type-body-sm text-on-surface-variant mt-0.5 truncate font-mono"
                                            :title="token.allowedIps.join(', ')"
                                            data-allowed-ips
                                        >
                                            From {{ token.allowedIps.join(', ') }}
                                        </p>
                                    </div>
                                    <button
                                        class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2"
                                        :aria-label="
                                            editingId === token.id
                                                ? `Close ${token.name} settings`
                                                : `Edit ${token.name}`
                                        "
                                        :aria-expanded="editingId === token.id"
                                        @click="toggleEdit(token)"
                                    >
                                        {{ editingId === token.id ? 'Done' : 'Edit' }}
                                    </button>
                                </div>

                                <div
                                    v-if="editingId === token.id"
                                    class="bg-surface-container-lowest border-outline-variant mx-2 mb-2 rounded-xl border p-3"
                                >
                                    <p class="type-label-md text-on-surface-variant tracking-[0.8px] uppercase">
                                        Allowed addresses
                                    </p>
                                    <p class="type-body-sm text-on-surface-variant mt-1">
                                        With nothing listed the token works from anywhere. Otherwise only these
                                        addresses, or prefixes such as
                                        <code class="text-on-surface font-mono">203.0.113.0/24</code>, may use it.
                                    </p>
                                    <ul v-if="draft.length" class="mt-2 flex flex-wrap gap-1.5">
                                        <li
                                            v-for="entry in draft"
                                            :key="entry"
                                            class="bg-surface-container-high type-body-sm flex items-center gap-1 rounded-lg py-1 pr-1 pl-2 font-mono"
                                        >
                                            {{ entry }}
                                            <button
                                                class="text-on-surface-variant hover:bg-on-surface/10 flex size-7 items-center justify-center rounded-full"
                                                :aria-label="`Remove ${entry}`"
                                                :title="`Remove ${entry}`"
                                                @click="removeEntry(entry)"
                                            >
                                                <Icon name="close" :size="14" />
                                            </button>
                                        </li>
                                    </ul>
                                    <div class="mt-2 flex items-center gap-2">
                                        <TextField
                                            v-model="draftEntry"
                                            label="Address or CIDR prefix"
                                            icon="lock"
                                            autocomplete="off"
                                            data-allow-entry
                                            class="min-w-0 flex-1"
                                            @keyup.enter="addEntry(draftEntry)"
                                        />
                                        <button
                                            class="text-primary hover:bg-on-surface/6 flex size-10 shrink-0 items-center justify-center rounded-full"
                                            aria-label="Add address"
                                            title="Add address"
                                            data-add-entry
                                            @click="addEntry(draftEntry)"
                                        >
                                            <Icon name="add" :size="20" />
                                        </button>
                                    </div>
                                    <button
                                        v-if="yourIp && !draft.includes(yourIp)"
                                        class="text-primary type-label-md hover:bg-on-surface/5 mt-1 self-start rounded-full px-2 py-1.5"
                                        data-add-your-ip
                                        @click="addEntry(yourIp)"
                                    >
                                        Add your current address ({{ yourIp }})
                                    </button>
                                    <div class="mt-3 flex flex-wrap items-center gap-2">
                                        <button
                                            class="bg-primary text-on-primary type-label-lg flex h-10 items-center justify-center gap-2 rounded-full px-5 hover:brightness-110 disabled:opacity-60"
                                            :disabled="saving"
                                            data-save-allowlist
                                            @click="saveAllowlist"
                                        >
                                            <Spinner v-if="saving" :size="18" />
                                            <Icon v-else name="check" :size="18" />
                                            Save
                                        </button>
                                        <button
                                            v-if="draft.length"
                                            class="text-on-surface-variant type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2"
                                            @click="draft = []"
                                        >
                                            Allow from any address
                                        </button>
                                        <span class="min-w-0 flex-1"></span>
                                        <button
                                            class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                                            :aria-label="`Rotate ${token.name}`"
                                            title="Rotate"
                                            @click="pending = { action: 'rotate', token }"
                                        >
                                            <Icon name="refresh" :size="20" />
                                        </button>
                                        <button
                                            class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                                            :aria-label="`Delete ${token.name}`"
                                            title="Delete"
                                            @click="pending = { action: 'delete', token }"
                                        >
                                            <Icon name="trash" :size="20" />
                                        </button>
                                    </div>
                                </div>
                            </li>
                        </ul>
                    </div>
                </div>
            </section>
        </div>

        <ConfirmDialog
            v-if="pending"
            :title="pending.action === 'rotate' ? 'Rotate token?' : 'Delete token?'"
            :message="
                pending.action === 'rotate'
                    ? `“${pending.token.name}” gets a new value and the current one stops working right away. Update anything that uses it.`
                    : `Anything using “${pending.token.name}” will stop working right away.`
            "
            :confirm-label="pending.action === 'rotate' ? 'Rotate' : 'Delete'"
            :busy="busy"
            @confirm="confirmPending"
            @cancel="pending = null"
        />
    </Teleport>
</template>
