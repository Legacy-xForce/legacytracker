import { createRouter, createWebHistory } from 'vue-router';
import { useSessionStore } from '../stores/session';

export const router = createRouter({
    history: createWebHistory(),
    routes: [
        { path: '/', name: 'map', component: () => import('../views/MapView.vue') },
        { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
        { path: '/access-denied', name: 'access-denied', component: () => import('../views/AccessDeniedView.vue') },
        { path: '/:rest(.*)*', redirect: '/' }
    ]
});

router.beforeEach((to) => {
    const session = useSessionStore();
    // A disabled account has no session but still gets told why.
    if (session.accessDenial) return to.name === 'access-denied' ? true : { name: 'access-denied' };
    if (!session.isAuthenticated) return to.name === 'login' ? true : { name: 'login' };
    return to.name === 'login' || to.name === 'access-denied' ? { name: 'map' } : true;
});
