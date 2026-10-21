import { createRouter, createWebHistory } from 'vue-router';
import { useSessionStore } from '../stores/session';

export const router = createRouter({
    history: createWebHistory(),
    routes: [
        { path: '/', name: 'map', component: () => import('../views/MapView.vue') },
        { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
        // Legacy Auth sends the browser back here with the authorization code (see api/oidc.ts).
        {
            path: '/callback',
            name: 'callback',
            component: () => import('../views/CallbackView.vue'),
            meta: { public: true }
        },
        // The API reference is public: integrators may read it before they have an account.
        { path: '/docs', name: 'docs', component: () => import('../views/DocsView.vue'), meta: { public: true } },
        { path: '/:rest(.*)*', redirect: '/' }
    ]
});

router.beforeEach((to) => {
    if (to.meta.public) return true;
    const session = useSessionStore();
    if (!session.isAuthenticated) return to.name === 'login' ? true : { name: 'login' };
    return to.name === 'login' ? { name: 'map' } : true;
});
