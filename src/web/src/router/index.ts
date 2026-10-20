import { createRouter, createWebHistory } from 'vue-router';
import { useSessionStore } from '../stores/session';

export const router = createRouter({
    history: createWebHistory(),
    routes: [
        { path: '/', name: 'map', component: () => import('../views/MapView.vue') },
        { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
        { path: '/access-denied', name: 'access-denied', component: () => import('../views/AccessDeniedView.vue') },
        // The API reference is public: integrators may read it before they have an account.
        { path: '/docs', name: 'docs', component: () => import('../views/DocsView.vue'), meta: { public: true } },
        { path: '/:rest(.*)*', redirect: '/' }
    ]
});

router.beforeEach((to) => {
    if (to.meta.public) return true;
    const session = useSessionStore();
    // A disabled account has no session but still gets told why.
    if (session.accessDenial) return to.name === 'access-denied' ? true : { name: 'access-denied' };
    if (!session.isAuthenticated) return to.name === 'login' ? true : { name: 'login' };
    return to.name === 'login' || to.name === 'access-denied' ? { name: 'map' } : true;
});
