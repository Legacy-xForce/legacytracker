<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import ConfirmDialog from '../ui/ConfirmDialog.vue';
import Icon from '../ui/Icon.vue';
import Spinner from '../ui/Spinner.vue';
import TextField from '../ui/TextField.vue';
import { searchPlaces, type PlaceResult } from '../../lib/places';
import {
    CheckpointError,
    MAX_NAME_LENGTH,
    MAX_RADIUS_M,
    MIN_RADIUS_M,
    useCheckpointsStore,
    type Checkpoint
} from '../../stores/checkpoints';
import type { PlaceDraft } from './PlaceDraftLayer.vue';

const SEARCH_DEBOUNCE_MS = 700;
const DEFAULT_RADIUS_M = 100;

const props = defineProps<{
    /** What is under the crosshair: where a new place starts, and where an edited one moves to. */
    cursor: { latitude: number; longitude: number } | null;
}>();
const emit = defineEmits<{
    /** The place being drawn changed, or null when no editor is open. */
    draft: [draft: PlaceDraft | null];
    goto: [latitude: number, longitude: number];
}>();

const store = useCheckpointsStore();
const query = ref('');
const editing = ref<{ checkpoint: Checkpoint | null } | null>(null);
const name = ref('');
const radius = ref(DEFAULT_RADIUS_M);
const point = ref({ latitude: 0, longitude: 0 });
const nameError = ref<string | null>(null);
const saveError = ref<string | null>(null);
const saving = ref(false);
const pendingDelete = ref<Checkpoint | null>(null);
const deleting = ref(false);
const listError = ref<string | null>(null);

const visible = computed(() => {
    const needle = query.value.trim().toLowerCase();
    return store.checkpoints
        .filter((checkpoint) => !needle || checkpoint.name.toLowerCase().includes(needle))
        .sort((a, b) => a.name.localeCompare(b.name));
});
// Everyone can look at a place; the editor is read-only for ones they can't change.
const readOnly = computed(() => editing.value?.checkpoint != null && !editing.value.checkpoint.canEdit);

function publish() {
    emit('draft', editing.value ? { ...point.value, radius: radius.value } : null);
}

function open(checkpoint: Checkpoint | null) {
    editing.value = { checkpoint };
    name.value = checkpoint?.name ?? '';
    radius.value = checkpoint?.radius ?? DEFAULT_RADIUS_M;
    point.value = checkpoint
        ? { latitude: checkpoint.latitude, longitude: checkpoint.longitude }
        : (props.cursor ?? { latitude: 0, longitude: 0 });
    nameError.value = null;
    saveError.value = null;
    searchQuery.value = '';
    results.value = [];
    publish();
    if (checkpoint) emit('goto', checkpoint.latitude, checkpoint.longitude);
}

function close() {
    editing.value = null;
    publish();
}

// The point is whatever is under the crosshair, unless the viewer may not change this place.
watch(
    () => props.cursor,
    (cursor) => {
        if (!editing.value || readOnly.value || !cursor) return;
        point.value = { latitude: cursor.latitude, longitude: cursor.longitude };
        publish();
    }
);
watch(radius, publish);

async function save() {
    const current = editing.value;
    if (!current) return;
    const trimmed = name.value.trim().replace(/\s+/g, ' ');
    if (!trimmed) {
        nameError.value = 'Give the checkpoint a name.';
        return;
    }
    nameError.value = null;
    saveError.value = null;
    saving.value = true;
    const input = { name: trimmed, ...point.value, radius: Math.round(radius.value) };
    try {
        if (current.checkpoint) await store.update(current.checkpoint.id, input);
        else await store.create(input);
        close();
    } catch (error) {
        if (!(error instanceof CheckpointError)) throw error;
        if (error.nameTaken) nameError.value = error.message;
        else saveError.value = error.message;
    } finally {
        saving.value = false;
    }
}

async function confirmDelete() {
    const target = pendingDelete.value;
    if (!target) return;
    deleting.value = true;
    listError.value = null;
    try {
        await store.remove(target.id);
    } catch (error) {
        if (!(error instanceof CheckpointError)) throw error;
        listError.value = error.message;
    } finally {
        deleting.value = false;
        pendingDelete.value = null;
    }
}

// Search for a street or place and the crosshair jumps there.
const searchQuery = ref('');
const results = ref<PlaceResult[]>([]);
const searching = ref(false);
const searchError = ref<string | null>(null);
let debounce: ReturnType<typeof setTimeout> | undefined;

function onSearchInput() {
    clearTimeout(debounce);
    const value = searchQuery.value.trim();
    if (value.length < 3) {
        results.value = [];
        searchError.value = null;
        searching.value = false;
        return;
    }
    debounce = setTimeout(async () => {
        searching.value = true;
        searchError.value = null;
        try {
            const found = await searchPlaces(value);
            if (searchQuery.value.trim() !== value) return;
            results.value = found;
            searchError.value = found.length === 0 ? 'No places found.' : null;
        } catch {
            searchError.value = 'Search is unavailable.';
        } finally {
            searching.value = false;
        }
    }, SEARCH_DEBOUNCE_MS);
}

function pick(place: PlaceResult) {
    results.value = [];
    searchQuery.value = '';
    point.value = { latitude: place.latitude, longitude: place.longitude };
    publish();
    emit('goto', place.latitude, place.longitude);
}

onBeforeUnmount(() => {
    clearTimeout(debounce);
    // Leaving the tab with an editor open must not leave its circle on the map.
    if (editing.value) emit('draft', null);
});

defineExpose({ open });
</script>

<template>
    <div class="px-3 pb-4">
        <div v-if="editing" class="space-y-3 px-1" data-place-editor>
            <div class="flex items-center gap-1">
                <button
                    class="hover:bg-on-surface/6 -ml-2 flex size-10 items-center justify-center rounded-full"
                    aria-label="Back to places"
                    @click="close"
                >
                    <Icon name="arrowBack" />
                </button>
                <h3 class="type-title-md">
                    {{ !editing.checkpoint ? 'New checkpoint' : readOnly ? 'Checkpoint' : 'Edit checkpoint' }}
                </h3>
            </div>

            <template v-if="!readOnly">
                <TextField
                    v-model="searchQuery"
                    label="Search a street or place"
                    icon="search"
                    type="search"
                    autocomplete="off"
                    @input="onSearchInput"
                >
                    <template #suffix><Spinner v-if="searching" :size="18" class="text-primary mr-4" /></template>
                </TextField>
                <p v-if="searchError" class="type-body-sm text-on-surface-variant px-2">{{ searchError }}</p>
                <ul v-if="results.length" class="bg-surface-container-high overflow-hidden rounded-lg">
                    <li v-for="place in results" :key="`${place.latitude},${place.longitude}`">
                        <button
                            class="hover:bg-on-surface/6 type-body-md flex w-full items-center gap-3 px-4 py-2.5 text-left"
                            data-result
                            @click="pick(place)"
                        >
                            <Icon name="place" :size="20" />
                            <span class="line-clamp-2">{{ place.label }}</span>
                        </button>
                    </li>
                </ul>
                <p class="type-body-sm text-on-surface-variant px-2">Move the map to put the crosshair on the spot.</p>
            </template>

            <TextField
                v-model="name"
                label="Name"
                icon="place"
                :maxlength="MAX_NAME_LENGTH"
                :disabled="readOnly"
                name="checkpoint-name"
                @input="nameError = null"
            />
            <p v-if="nameError" class="type-body-sm text-error px-2" data-name-error>{{ nameError }}</p>

            <label class="type-label-lg block px-2">
                Radius: {{ Math.round(radius) }} m
                <input
                    v-model.number="radius"
                    type="range"
                    :min="MIN_RADIUS_M"
                    :max="MAX_RADIUS_M"
                    step="1"
                    :disabled="readOnly"
                    class="accent-primary mt-2 w-full"
                    aria-label="Radius in metres"
                />
            </label>

            <p v-if="saveError" class="type-body-sm text-error px-2">{{ saveError }}</p>
            <button
                v-if="!readOnly"
                class="bg-primary text-on-primary type-label-lg flex h-12 w-full items-center justify-center rounded-full disabled:opacity-60"
                :disabled="saving"
                data-save
                @click="save"
            >
                <Spinner v-if="saving" :size="20" />
                <template v-else>Save</template>
            </button>
        </div>

        <template v-else>
            <TextField v-model="query" label="Search checkpoints" icon="search" type="search" class="mb-3" />
            <button
                class="bg-primary-container text-on-primary-container type-label-lg mb-3 flex h-12 w-full items-center justify-center gap-2 rounded-full"
                data-add
                @click="open(null)"
            >
                <Icon name="add" :size="20" /> Add checkpoint
            </button>
            <p v-if="listError" class="type-body-sm text-error px-2 pb-2">{{ listError }}</p>
            <div v-if="!store.loaded" class="text-primary flex justify-center p-6"><Spinner :size="28" /></div>
            <p
                v-else-if="store.error && store.checkpoints.length === 0"
                class="type-body-md text-on-surface-variant p-4 text-center"
            >
                Couldn't load the checkpoints.
            </p>
            <p v-else-if="visible.length === 0" class="type-body-md text-on-surface-variant p-4 text-center">
                {{
                    store.checkpoints.length === 0
                        ? 'No checkpoints yet. Add one to see its name instead of the street when someone is there.'
                        : 'No checkpoints match your search.'
                }}
            </p>
            <ul v-else class="space-y-1">
                <li
                    v-for="checkpoint in visible"
                    :key="checkpoint.id"
                    class="hover:bg-on-surface/6 flex items-center gap-1 rounded-lg pr-1"
                    data-checkpoint
                >
                    <button
                        class="flex min-w-0 flex-1 items-center gap-3 px-3 py-2.5 text-left"
                        @click="open(checkpoint)"
                    >
                        <Icon name="place" class="text-primary" />
                        <span class="min-w-0">
                            <span class="type-title-sm block truncate">{{ checkpoint.name }}</span>
                            <span class="type-body-sm text-on-surface-variant block"
                                >{{ checkpoint.radius }} m radius</span
                            >
                        </span>
                    </button>
                    <button
                        v-if="checkpoint.canEdit"
                        class="hover:bg-on-surface/6 flex size-10 items-center justify-center rounded-full"
                        aria-label="Delete"
                        title="Delete"
                        data-delete
                        @click="pendingDelete = checkpoint"
                    >
                        <Icon name="trash" :size="22" />
                    </button>
                </li>
            </ul>
        </template>

        <ConfirmDialog
            v-if="pendingDelete"
            title="Delete checkpoint?"
            :message="`“${pendingDelete.name}” will be removed for everyone. Locations inside it go back to showing the street name.`"
            confirm-label="Delete"
            :busy="deleting"
            @confirm="confirmDelete"
            @cancel="pendingDelete = null"
        />
    </div>
</template>
