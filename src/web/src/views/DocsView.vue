<script setup lang="ts">
import { nextTick, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import Icon from '../components/ui/Icon.vue';
import { config } from '../config';
import {
    ACCESS_DETAILS,
    ACCESS_LABELS,
    curlExample,
    DOC_SECTIONS,
    ERROR_CODES,
    type Access,
    type Endpoint,
    type HttpMethod
} from '../lib/apiDocs';
import { escapeHtml } from '../lib/format';
import { useSessionStore } from '../stores/session';

const session = useSessionStore();
const route = useRoute();
const baseUrl = config.backendUrl;

const NAV = [
    { id: 'overview', title: 'Overview' },
    { id: 'authentication', title: 'Authentication' },
    { id: 'errors', title: 'Errors' },
    ...DOC_SECTIONS.map(({ id, title }) => ({ id, title }))
];

// Theme tokens only, so the page follows the chosen theme, light ones included.
const METHOD_CLASSES: Record<HttpMethod, string> = {
    GET: 'bg-secondary-container text-on-secondary-container',
    POST: 'bg-primary-container text-on-primary-container',
    PUT: 'bg-surface-container-highest text-primary',
    PATCH: 'bg-surface-container-highest text-primary',
    DELETE: 'bg-error-container text-on-error-container'
};

const ACCESS_CLASSES: Record<Access, string> = {
    read: 'border-outline text-on-surface',
    write: 'border-primary text-primary',
    session: 'border-outline-variant text-on-surface-variant',
    public: 'border-outline-variant text-on-surface-variant'
};

/** Backticks in the static copy become inline code. */
function inline(text: string): string {
    return escapeHtml(text).replace(/`([^`]+)`/g, '<code>$1</code>');
}

function json(value: unknown): string {
    return JSON.stringify(value, null, 2);
}

function example(endpoint: Endpoint): string {
    return endpoint.example ?? curlExample(endpoint, baseUrl);
}

// The page loads lazily, after the browser has already looked for the #anchor.
onMounted(async () => {
    if (!route.hash) return;
    await nextTick();
    document.getElementById(decodeURIComponent(route.hash.slice(1)))?.scrollIntoView();
});
</script>

<template>
    <div class="docs h-full overflow-y-auto">
        <header
            class="bg-surface/90 border-outline-variant sticky top-0 z-10 flex h-14 items-center gap-3 border-b px-4 backdrop-blur sm:px-6"
        >
            <span
                class="bg-primary-container text-on-primary-container flex size-8 items-center justify-center rounded-full"
            >
                <Icon name="api" :size="18" />
            </span>
            <h1 class="type-title-md flex-1 truncate">Legacy Tracker API</h1>
            <RouterLink
                :to="session.isAuthenticated ? '/' : '/login'"
                class="text-primary type-label-lg hover:bg-on-surface/5 flex items-center gap-1 rounded-full px-3 py-2"
            >
                <Icon :name="session.isAuthenticated ? 'map' : 'person'" :size="18" />
                {{ session.isAuthenticated ? 'Open the map' : 'Sign in' }}
            </RouterLink>
        </header>

        <div class="mx-auto flex max-w-6xl gap-10 px-4 sm:px-6">
            <nav class="sticky top-14 hidden max-h-[calc(100vh-3.5rem)] w-56 shrink-0 overflow-y-auto py-8 lg:block">
                <p class="type-label-md text-on-surface-variant mb-2 px-3 tracking-[0.8px] uppercase">On this page</p>
                <a
                    v-for="item in NAV"
                    :key="item.id"
                    :href="`#${item.id}`"
                    class="type-body-md text-on-surface-variant hover:text-on-surface hover:bg-on-surface/5 block rounded-lg px-3 py-1.5"
                    >{{ item.title }}</a
                >
            </nav>

            <main class="min-w-0 flex-1 py-8 pb-24">
                <section id="overview" class="scroll-mt-20">
                    <h2 class="type-headline-sm font-bold">Overview</h2>
                    <p class="type-body-lg text-on-surface-variant mt-3">
                        Everything the phone app and the web map do goes through this REST and WebSocket API, so your
                        own scripts and integrations can do the same: read where people are, follow the live map, look
                        up trips, upload positions and manage checkpoints.
                    </p>
                    <h3 class="type-title-md mt-6">Base URL</h3>
                    <pre class="code scroll-panel mt-2"><code>{{ baseUrl }}</code></pre>
                    <p class="type-body-md text-on-surface-variant mt-3">
                        Requests and responses are JSON. Times are ISO 8601 in UTC, distances in metres and speeds in
                        metres per second.
                    </p>
                </section>

                <section id="authentication" class="mt-14 scroll-mt-20">
                    <h2 class="type-headline-sm font-bold">Authentication</h2>
                    <p class="type-body-lg text-on-surface-variant mt-3">
                        Integrations authenticate with a personal API token. Create one under
                        <strong class="text-on-surface">Profile → API tokens</strong> in the phone app, or
                        <strong class="text-on-surface">account menu → API tokens</strong> on the web map, and send it
                        in the <code>X-API-Token</code> header:
                    </p>
                    <pre
                        class="code mt-3"
                    ><code>X-API-Token: legacy-tracker-01a15968-64aa-707d-8904-a6a408611289</code></pre>
                    <p class="type-body-md text-on-surface-variant mt-3">
                        A token acts as you: it sees exactly what you see and can do what you can do, within its scope.
                        Unlike a sign-in session it never expires and is not refreshed, so treat it like a password. It
                        is shown once, when you create or rotate it; afterwards only a short hint such as
                        <code>legacy-tracker-01a1…1289</code> identifies it.
                    </p>

                    <div class="mt-5 grid gap-3 sm:grid-cols-2">
                        <div class="bg-surface-container rounded-2xl p-4">
                            <p class="flex items-center gap-2">
                                <span class="chip" :class="ACCESS_CLASSES.read">read</span>
                                <span class="type-title-sm">Read</span>
                            </p>
                            <p class="type-body-md text-on-surface-variant mt-2">
                                Every <code>GET</code> request, plus opening the live stream. Anything that changes data
                                answers <code>403</code>.
                            </p>
                        </div>
                        <div class="bg-surface-container rounded-2xl p-4">
                            <p class="flex items-center gap-2">
                                <span class="chip" :class="ACCESS_CLASSES.write">write</span>
                                <span class="type-title-sm">Write</span>
                            </p>
                            <p class="type-body-md text-on-surface-variant mt-2">
                                Everything your account can do, such as uploading positions, editing checkpoints or
                                deleting your history.
                            </p>
                        </div>
                    </div>

                    <ul class="type-body-md text-on-surface-variant mt-5 flex list-disc flex-col gap-2 pl-5">
                        <li>
                            Endpoints marked <span class="chip" :class="ACCESS_CLASSES.session">Session only</span> take
                            a signed-in session (<code>Authorization: Bearer &lt;access token&gt;</code> that Legacy
                            Auth issued to a Legacy Tracker app) and refuse API tokens, so a leaked token can't create
                            new tokens or register devices.
                        </li>
                        <li>
                            <strong class="text-on-surface">Rotate</strong> a token to replace its value: the old value
                            stops working immediately. <strong class="text-on-surface">Delete</strong> it to revoke it
                            for good. You can have up to 25.
                        </li>
                        <li>
                            Tokens belong to your tracker access. If an administrator removes it, your tokens are
                            deleted.
                        </li>
                        <li>If both headers are present, <code>X-API-Token</code> wins.</li>
                    </ul>
                </section>

                <section id="errors" class="mt-14 scroll-mt-20">
                    <h2 class="type-headline-sm font-bold">Errors</h2>
                    <p class="type-body-md text-on-surface-variant mt-3">
                        Errors carry a JSON body such as <code>{ "error": "This API token is read-only" }</code>.
                    </p>
                    <div class="bg-surface-container mt-4 overflow-x-auto rounded-2xl">
                        <table class="type-body-md w-full text-left">
                            <tbody>
                                <tr
                                    v-for="[status, meaning] in ERROR_CODES"
                                    :key="status"
                                    class="border-outline-variant border-b last:border-0"
                                >
                                    <td class="w-20 px-4 py-3 align-top font-mono">{{ status }}</td>
                                    <td class="text-on-surface-variant px-4 py-3" v-html="inline(meaning)" />
                                </tr>
                            </tbody>
                        </table>
                    </div>
                </section>

                <section v-for="section in DOC_SECTIONS" :id="section.id" :key="section.id" class="mt-14 scroll-mt-20">
                    <h2 class="type-headline-sm font-bold">{{ section.title }}</h2>
                    <p
                        v-if="section.intro"
                        class="type-body-md text-on-surface-variant mt-3"
                        v-html="inline(section.intro)"
                    />

                    <article
                        v-for="endpoint in section.endpoints"
                        :id="endpoint.id"
                        :key="endpoint.id"
                        class="bg-surface-container mt-5 scroll-mt-20 rounded-[20px] p-4 sm:p-5"
                        data-endpoint
                    >
                        <div class="flex flex-wrap items-center gap-2">
                            <span class="method" :class="METHOD_CLASSES[endpoint.method]">{{ endpoint.method }}</span>
                            <code class="type-body-md min-w-0 font-mono break-all">{{ endpoint.path }}</code>
                            <span
                                class="chip ml-auto"
                                :class="ACCESS_CLASSES[endpoint.access]"
                                :title="ACCESS_DETAILS[endpoint.access]"
                                >{{ ACCESS_LABELS[endpoint.access] }}</span
                            >
                        </div>
                        <h3 class="type-title-md mt-3">{{ endpoint.summary }}</h3>
                        <p
                            v-if="endpoint.description"
                            class="type-body-md text-on-surface-variant mt-1.5"
                            v-html="inline(endpoint.description)"
                        />

                        <div v-if="endpoint.params?.length" class="mt-4 overflow-x-auto">
                            <table class="type-body-sm w-full text-left">
                                <thead class="text-on-surface-variant">
                                    <tr>
                                        <th class="py-1.5 pr-3 font-medium">Parameter</th>
                                        <th class="hidden py-1.5 pr-3 font-medium sm:table-cell">In</th>
                                        <th class="py-1.5 pr-3 font-medium">Type</th>
                                        <th class="py-1.5 font-medium">Description</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <tr
                                        v-for="param in endpoint.params"
                                        :key="param.name"
                                        class="border-outline-variant border-t"
                                    >
                                        <td class="py-2 pr-3 align-top font-mono whitespace-nowrap">
                                            {{ param.name
                                            }}<span v-if="param.required" class="text-error" title="Required">*</span>
                                        </td>
                                        <td class="text-on-surface-variant hidden py-2 pr-3 align-top sm:table-cell">
                                            {{ param.in }}
                                        </td>
                                        <td
                                            class="text-on-surface-variant py-2 pr-3 align-top font-mono whitespace-nowrap"
                                        >
                                            {{ param.type }}
                                        </td>
                                        <td
                                            class="text-on-surface-variant py-2 align-top"
                                            v-html="inline(param.description)"
                                        />
                                    </tr>
                                </tbody>
                            </table>
                        </div>

                        <div class="mt-4 grid gap-3 xl:grid-cols-2">
                            <div class="min-w-0">
                                <p class="type-label-md text-on-surface-variant mb-1.5">Request</p>
                                <pre class="code scroll-panel"><code>{{ example(endpoint) }}</code></pre>
                            </div>
                            <div v-if="endpoint.response !== undefined" class="min-w-0">
                                <p class="type-label-md text-on-surface-variant mb-1.5">Response</p>
                                <pre class="code scroll-panel max-h-80"><code>{{ json(endpoint.response) }}</code></pre>
                            </div>
                        </div>

                        <ul
                            v-if="endpoint.errors?.length"
                            class="type-body-sm text-on-surface-variant mt-3 flex flex-col gap-1"
                        >
                            <li v-for="[status, meaning] in endpoint.errors" :key="status">
                                <span class="text-on-surface font-mono">{{ status }}</span> —
                                <span v-html="inline(meaning)" />
                            </li>
                        </ul>
                    </article>
                </section>
            </main>
        </div>
    </div>
</template>

<style scoped>
@reference '../style.css';

.docs :deep(code) {
    @apply text-on-surface bg-on-surface/8 rounded px-1 py-px font-mono text-[0.9em];
}

.code {
    @apply bg-surface-container-lowest overflow-auto rounded-xl p-3 text-[12.5px] leading-5;
}

.code code {
    @apply bg-transparent p-0 text-[12.5px];
}

.method {
    @apply rounded-md px-2 py-0.5 font-mono text-xs font-semibold;
}

.chip {
    @apply type-label-sm inline-block rounded-md border px-1.5 py-px;
}
</style>
