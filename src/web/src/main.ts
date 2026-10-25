import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { CALLBACK_PATH } from './api/oidc';
import { assertMapboxConfigured } from './lib/mapbox';
import { router } from './router';
import { useSessionStore } from './stores/session';
import { applyTheme, getStoredTheme } from './theme/themes';
import '@fontsource-variable/roboto';
import 'mapbox-gl/dist/mapbox-gl.css';
import './style.css';

// Before the first paint so a non-default theme doesn't flash the teal one.
applyTheme(getStoredTheme());
// A missing public token means no map; fail with instructions instead of a blank canvas.
assertMapboxConfigured();

const app = createApp(App);
app.use(createPinia());

function mount() {
    app.use(router);
    app.mount('#app');
}

// Back from Legacy Auth, the callback route completes the sign-in. Otherwise resume a stored session
// before the first route is resolved, so a reload doesn't flash the login page.
if (window.location.pathname === CALLBACK_PATH) mount();
else void useSessionStore().restore().finally(mount);
