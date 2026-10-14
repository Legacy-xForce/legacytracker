import { onBeforeUnmount, onMounted, ref } from 'vue';

/** The current time, refreshed on an interval, for labels like "here for 12m". */
export function useNow(intervalMs = 5_000) {
    const now = ref(Date.now());
    let timer: ReturnType<typeof setInterval> | undefined;
    onMounted(() => (timer = setInterval(() => (now.value = Date.now()), intervalMs)));
    onBeforeUnmount(() => clearInterval(timer));
    return now;
}
