import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { router } from './router';
import { useSessionStore } from './stores/session';
import { applyTheme, getStoredTheme } from './theme/themes';
import '@fontsource-variable/roboto';
import 'leaflet/dist/leaflet.css';
import './style.css';

// Before the first paint so a non-default theme doesn't flash the teal one.
applyTheme(getStoredTheme());

const app = createApp(App);
app.use(createPinia());

// Resume a stored session before the first route is resolved, so a reload doesn't flash the login page.
useSessionStore()
    .restore()
    .finally(() => {
        app.use(router);
        app.mount('#app');
    });
