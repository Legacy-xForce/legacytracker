<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import {
    createApiToken,
    deleteApiToken,
    listAllApiTokens,
    listApiTokens,
    rotateApiToken,
    updateApiTokenAllowedIps,
    type ApiToken,
    type ApiTokenScope,
    type AuditedApiToken,
    type IssuedApiToken
} from '../../api/apiTokens';
import { formatShortDate, formatUpdatedAgo } from '../../lib/format';
import { useModal } from '../../lib/focus';
import { showToast } from '../../lib/toast';
import ApiTokenRequestsDialog from './ApiTokenRequestsDialog.vue';
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
/** The token whose request history popup is open. */
const requestsFor = ref<ApiToken | null>(null);
const draft = ref<string[]>([]);
const draftEntry = ref('');
const saving = ref(false);
/** Where the API sees this page coming from, offered as a one-click entry. */
const yourIp = ref<string | null>(null);
/** Which list is on screen: the account's own tokens, or everyone's. */
const view = ref<'mine' | 'all'>('mine');
const allTokens = ref<AuditedApiToken[] | null>(null);
const allLoading = ref(false);
const allError = ref<string | null>(null);

/** The tracker-wide list arrives ordered by owner, so a walk groups it. */
const allGroups = computed(() => {
    const groups: { userId: string; userName: string; tokens: AuditedApiToken[] }[] = [];
    for (const token of allTokens.value ?? []) {
        const last = groups[groups.length - 1];
        if (last && last.userId === token.userId) last.tokens.push(token);
        else groups.push({ userId: token.userId, userName: token.userName, tokens: [token] });
    }
    return groups;
});

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
        allTokens.value = null;
        reveal(token);
        name.value = '';
    } catch (error) {
        showToast(message(error));
    } finally {
        creating.value = false;
    }
}

/** Loads the tracker-wide list the first time its tab is opened. */
async function showAll() {
    view.value = 'all';
    if (allTokens.value === null && !allLoading.value) await loadAll();
}

async function loadAll() {
    allLoading.value = true;
    allError.value = null;
    try {
        allTokens.value = await listAllApiTokens();
    } catch (error) {
        allError.value = message(error);
    } finally {
        allLoading.value = false;
    }
}

/** The owner to name in a request-history popup, when the row has one. */
function ownerOf(token: ApiToken | null): string | null {
    return token && 'userName' in token && typeof token.userName === 'string' ? token.userName : null;
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
            allTokens.value = null;
            reveal(token);
        } else {
            await deleteApiToken(action.token.id);
            tokens.value = (tokens.value ?? []).filter((t) => t.id !== action.token.id);
            allTokens.value = null;
            if (issued.value?.id === action.token.id) issued.value = null;
            if (editingId.value === action.token.id) editingId.value = null;
            if (requestsFor.value?.id === action.token.id) requestsFor.value = null;
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

const panel = ref<HTMLElement | null>(null);
useModal(panel);

function onKey(event: KeyboardEvent) {
    if (event.key !== 'Escape' || pending.value) return;
    // Escape backs out one level at a time: the activity popup, the open panel,
    // the everyone list, then the dialog.
    if (requestsFor.value) requestsFor.value = null;
    else if (editingId.value) editingId.value = null;
    else if (view.value === 'all') view.value = 'mine';
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
            class="bg-scrim/32 fixed inset-0 z-[1900] flex items-stretch justify-center sm:items-center sm:p-6"
            @click.self="emit('close')"
        >
            <section
                ref="panel"
                tabindex="-1"
                role="dialog"
                aria-modal="true"
                aria-labelledby="api-tokens-title"
                class="bg-surface-container scroll-panel flex w-full flex-col overflow-y-auto shadow-[0_8px_24px_color-mix(in_srgb,var(--color-shadow)_50%,transparent)] outline-none sm:max-h-[90vh] sm:max-w-lg sm:rounded-xl"
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

                <div
                    class="bg-surface-container-high mx-6 mb-2 grid grid-cols-2 gap-1 rounded-full p-1"
                    role="tablist"
                    aria-label="API token lists"
                >
                    <button
                        type="button"
                        role="tab"
                        :aria-selected="view === 'mine'"
                        class="type-label-lg rounded-full px-3 py-1.5 transition-colors"
                        :class="
                            view === 'mine'
                                ? 'bg-primary text-on-primary'
                                : 'text-on-surface-variant hover:bg-on-surface/6'
                        "
                        @click="view = 'mine'"
                    >
                        Your tokens
                    </button>
                    <button
                        type="button"
                        role="tab"
                        :aria-selected="view === 'all'"
                        class="type-label-lg rounded-full px-3 py-1.5 transition-colors"
                        :class="
                            view === 'all'
                                ? 'bg-primary text-on-primary'
                                : 'text-on-surface-variant hover:bg-on-surface/6'
                        "
                        data-everyone-tab
                        @click="showAll"
                    >
                        Everyone
                    </button>
                </div>

                <div class="flex flex-col gap-6 px-6 pt-2 pb-6">
                    <template v-if="view === 'mine'">
                        <p class="type-body-md text-on-surface-variant">
                            Let scripts and other apps use the tracker as you. Send a token in the
                            <code class="text-on-surface">X-API-Token</code> header. Tokens don't expire, so rotate or
                            delete any you no longer trust, and edit one to limit it to the addresses that may use it.
                            <RouterLink
                                to="/docs"
                                target="_blank"
                                class="text-primary inline-flex items-center gap-0.5"
                            >
                                API documentation <Icon name="openInNew" :size="14" />
                            </RouterLink>
                        </p>

                        <div
                            v-if="issued"
                            class="bg-primary-container/40 border-primary/40 rounded-lg border p-4"
                            data-issued
                        >
                            <p class="type-title-sm">Copy “{{ issued.name }}” now</p>
                            <p class="type-body-sm text-on-surface-variant mt-1">
                                You won't be able to see this token again.
                            </p>
                            <div
                                class="bg-surface-container-lowest mt-3 flex items-center gap-2 rounded-md py-1 pr-1 pl-3"
                            >
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
                                    class="rounded-lg border p-3 text-left transition-colors"
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
                                    <span class="type-body-sm text-on-surface-variant mt-1 block">{{
                                        option.detail
                                    }}</span>
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
                            <h3 class="type-label-md text-on-surface-variant tracking-[0.8px] uppercase">
                                Your tokens
                            </h3>
                            <div v-if="tokens === null && !loadError" class="flex justify-center py-6"><Spinner /></div>
                            <div
                                v-else-if="loadError"
                                class="bg-surface-container-high flex items-center gap-3 rounded-lg py-2 pr-2 pl-4"
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
                                class="bg-surface-container-high type-body-md text-on-surface-variant rounded-lg px-4 py-4"
                            >
                                No tokens yet.
                            </p>
                            <ul v-else class="flex flex-col gap-2">
                                <li
                                    v-for="token in tokens"
                                    :key="token.id"
                                    class="bg-surface-container-high rounded-lg"
                                    data-token-row
                                >
                                    <div class="flex items-center gap-3 py-3 pr-2 pl-4">
                                        <div class="min-w-0 flex-1">
                                            <p class="flex items-center gap-2">
                                                <span class="type-title-sm truncate">{{ token.name }}</span>
                                                <span
                                                    class="type-label-sm shrink-0 rounded-sm px-1.5 py-0.5 uppercase"
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
                                            <p class="type-body-sm text-on-surface-variant mt-0.5">
                                                {{ usage(token) }}
                                            </p>
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
                                            class="text-primary type-label-lg hover:bg-on-surface/5 shrink-0 rounded-full px-3 py-2"
                                            :aria-label="`Request history for ${token.name}`"
                                            :title="`Request history for ${token.name}`"
                                            data-token-requests
                                            @click="requestsFor = token"
                                        >
                                            Activity
                                        </button>
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
                                        class="bg-surface-container-lowest border-outline-variant mx-2 mb-2 rounded-md border p-3"
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
                                                class="bg-surface-container-high type-body-sm flex items-center gap-1 rounded-sm py-1 pr-1 pl-2 font-mono"
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
                    </template>

                    <template v-else>
                        <p class="type-body-md text-on-surface-variant">
                            Every live token on the tracker, so anyone can check what integrations can read or write.
                            Secrets are never shown.
                        </p>
                        <div v-if="allLoading && allTokens === null" class="flex justify-center py-6">
                            <Spinner />
                        </div>
                        <div
                            v-else-if="allError && allTokens === null"
                            class="bg-surface-container-high flex items-center gap-3 rounded-lg py-2 pr-2 pl-4"
                        >
                            <Icon name="cloudOff" :size="20" class="text-on-surface-variant" />
                            <span class="type-body-md flex-1">{{ allError }}</span>
                            <button
                                class="text-primary type-label-lg hover:bg-on-surface/5 rounded-full px-3 py-2"
                                @click="loadAll"
                            >
                                Retry
                            </button>
                        </div>
                        <p
                            v-else-if="allTokens && allTokens.length === 0"
                            class="bg-surface-container-high type-body-md text-on-surface-variant rounded-lg px-4 py-4"
                        >
                            No tokens on the tracker yet.
                        </p>
                        <template v-else>
                            <div
                                v-if="allError"
                                class="bg-error-container text-on-error-container type-body-sm flex items-center gap-2 rounded-md px-3 py-2"
                            >
                                <Icon name="error" :size="16" />
                                <span class="flex-1">{{ allError }}</span>
                            </div>
                            <div v-for="group in allGroups" :key="group.userId" class="flex flex-col gap-2">
                                <h3 class="type-label-md text-on-surface-variant tracking-[0.8px] uppercase">
                                    {{ group.userName }}
                                </h3>
                                <ul class="flex flex-col gap-2">
                                    <li
                                        v-for="token in group.tokens"
                                        :key="token.id"
                                        class="bg-surface-container-high rounded-lg px-4 py-3"
                                        data-audit-token-row
                                    >
                                        <div class="flex items-center gap-3">
                                            <div class="min-w-0 flex-1">
                                                <p class="flex flex-wrap items-center gap-2">
                                                    <span class="type-title-sm truncate">{{ token.name }}</span>
                                                    <span
                                                        class="type-label-sm shrink-0 rounded-sm px-1.5 py-0.5 uppercase"
                                                        :class="
                                                            token.scope === 'write'
                                                                ? 'bg-error-container text-on-error-container'
                                                                : 'bg-secondary-container text-on-secondary-container'
                                                        "
                                                        >{{ token.scope }}</span
                                                    >
                                                </p>
                                                <p
                                                    class="type-body-sm text-on-surface-variant mt-0.5 truncate font-mono"
                                                >
                                                    {{ token.hint }}
                                                </p>
                                                <p class="type-body-sm text-on-surface-variant mt-0.5">
                                                    {{ usage(token) }}
                                                </p>
                                                <p
                                                    v-if="token.allowedIps.length"
                                                    class="type-body-sm text-on-surface-variant mt-0.5 truncate font-mono"
                                                    :title="token.allowedIps.join(', ')"
                                                >
                                                    From {{ token.allowedIps.join(', ') }}
                                                </p>
                                            </div>
                                            <button
                                                class="text-primary type-label-lg hover:bg-on-surface/5 shrink-0 rounded-full px-3 py-2"
                                                :aria-label="`Request history for ${token.name} by ${group.userName}`"
                                                data-audit-token-requests
                                                @click="requestsFor = token"
                                            >
                                                Activity
                                            </button>
                                        </div>
                                    </li>
                                </ul>
                            </div>
                        </template>
                    </template>
                </div>
            </section>
        </div>

        <ApiTokenRequestsDialog
            v-if="requestsFor"
            :token="requestsFor"
            :owner="ownerOf(requestsFor)"
            @close="requestsFor = null"
        />

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
