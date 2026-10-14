import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { router } from './router';
import { useSessionStore } from './stores/session';
import './style.css';
import 'leaflet/dist/leaflet.css';

const app = createApp(App);
app.use(createPinia());

// Resume a stored session before the first route is resolved, so a reload doesn't flash the login page.
useSessionStore()
    .restore()
    .finally(() => {
        app.use(router);
        app.mount('#app');
    });
