<script setup lang="ts">
import { errorMessage } from '../../lib/errors';
import { onMounted, ref } from 'vue';
import { listApiTokenRequests, type ApiToken, type ApiTokenRequest } from '../../api/apiTokens';
import { formatClock, formatShortDate } from '../../lib/format';
import Dialog from '../ui/Dialog.vue';
import Icon from '../ui/Icon.vue';
import StateBlock from '../ui/StateBlock.vue';
import Spinner from '../ui/Spinner.vue';

const props = defineProps<{ token: ApiToken; owner?: string | null }>();
const emit = defineEmits<{ close: [] }>();

const requests = ref<ApiTokenRequest[] | null>(null);
const nextBefore = ref<string | null>(null);
const hasMore = ref(false);
const loading = ref(false);
const loadingMore = ref(false);
const loadError = ref<string | null>(null);

async function load() {
    loading.value = true;
    loadError.value = null;
    try {
        const page = await listApiTokenRequests(props.token.id);
        requests.value = page.requests;
        nextBefore.value = page.nextBefore;
        hasMore.value = page.hasMore;
    } catch (error) {
        loadError.value = errorMessage(error);
    } finally {
        loading.value = false;
    }
}

async function loadMore() {
    if (!hasMore.value || loadingMore.value || !nextBefore.value) return;
    loadingMore.value = true;
    try {
        const page = await listApiTokenRequests(props.token.id, { before: nextBefore.value });
        requests.value = [...(requests.value ?? []), ...page.requests];
        nextBefore.value = page.nextBefore;
        hasMore.value = page.hasMore;
    } catch (error) {
        loadError.value = errorMessage(error);
    } finally {
        loadingMore.value = false;
    }
}

function when(timestamp: number): string {
    return `${formatShortDate(timestamp)}, ${formatClock(timestamp)}`;
}

function statusClass(status: number): string {
    return status >= 400
        ? 'bg-error-container text-on-error-container'
        : 'bg-secondary-container text-on-secondary-container';
}

onMounted(() => void load());
</script>

<template>
    <Dialog labelledby="token-requests-title" :z="1950" @close="emit('close')">
        <header class="flex items-center gap-3 px-6 pt-5 pb-2">
            <span
                class="bg-secondary-container text-on-secondary-container flex size-10 items-center justify-center rounded-full"
            >
                <Icon name="history" :size="22" />
            </span>
            <div class="min-w-0 flex-1">
                <h2 id="token-requests-title" class="type-title-lg truncate font-bold">Request history</h2>
                <p class="type-body-sm text-on-surface-variant truncate">{{ token.name }}</p>
                <p v-if="owner" class="type-body-sm text-on-surface-variant truncate">Owner: {{ owner }}</p>
            </div>
            <button
                class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full disabled:opacity-50"
                :disabled="loading"
                :aria-label="loading ? 'Refreshing request history' : 'Refresh request history'"
                :title="loading ? 'Refreshing…' : 'Refresh'"
                @click="load"
            >
                <Icon name="refresh" :size="20" />
            </button>
            <button
                class="text-on-surface-variant hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                aria-label="Close request history"
                @click="emit('close')"
            >
                <Icon name="close" />
            </button>
        </header>

        <div class="flex flex-col gap-4 px-6 pt-2 pb-6">
            <p class="type-body-md text-on-surface-variant">
                Every request made with <span class="text-on-surface">“{{ token.name }}”</span>, including ones refused
                by its scope or allowed addresses. Query strings are never stored.
            </p>

            <StateBlock v-if="loading && requests === null" kind="loading" />
            <StateBlock v-else-if="loadError && requests === null" kind="error" :message="loadError" @retry="load" />
            <StateBlock v-else-if="requests && requests.length === 0" kind="empty" data-empty-requests>
                No requests yet. Anything using this token will show up here.
            </StateBlock>
            <template v-else>
                <div
                    v-if="loadError"
                    class="bg-error-container text-on-error-container type-body-sm flex items-center gap-2 rounded-md px-3 py-2"
                >
                    <Icon name="error" :size="16" />
                    <span class="flex-1">{{ loadError }}</span>
                </div>
                <ul class="flex flex-col gap-2">
                    <li
                        v-for="request in requests ?? []"
                        :key="request.id"
                        class="bg-surface-container-high rounded-lg px-4 py-3"
                        data-request-row
                    >
                        <div class="flex items-center gap-2">
                            <span
                                class="bg-surface-container-lowest type-label-sm rounded-sm px-1.5 py-0.5 font-mono font-bold"
                                >{{ request.method }}</span
                            >
                            <span
                                class="type-label-sm rounded-sm px-1.5 py-0.5 font-mono font-bold"
                                :class="statusClass(request.statusCode)"
                                data-request-status
                                >{{ request.statusCode }}</span
                            >
                            <code class="type-body-sm min-w-0 flex-1 truncate" :title="request.path">{{
                                request.path
                            }}</code>
                        </div>
                        <p class="type-body-sm text-on-surface-variant mt-1">
                            {{ when(request.createdAt) }}
                            <template v-if="request.clientIp"> · {{ request.clientIp }}</template>
                            <template v-if="request.durationMs !== null"> · {{ request.durationMs }} ms </template>
                        </p>
                        <p
                            v-if="request.userAgent"
                            class="type-body-sm text-on-surface-variant truncate"
                            :title="request.userAgent"
                        >
                            {{ request.userAgent }}
                        </p>
                    </li>
                </ul>
                <div v-if="hasMore" class="flex justify-center">
                    <button
                        class="text-primary type-label-lg hover:bg-on-surface/5 flex items-center gap-2 rounded-full px-4 py-2 disabled:opacity-60"
                        :disabled="loadingMore"
                        @click="loadMore"
                    >
                        <Spinner v-if="loadingMore" :size="16" />
                        <Icon v-else name="history" :size="18" />
                        Load older
                    </button>
                </div>
            </template>
        </div>
    </Dialog>
</template>
