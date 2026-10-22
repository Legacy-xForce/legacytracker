const env = import.meta.env;

// Production unless a build says otherwise (see .env.example).
export const config = {
    backendUrl: env.VITE_BACKEND_URL || 'https://tracker.legacy-group.tech',
    // Legacy Auth: the OpenID Provider (issuer) the app signs in with.
    authUrl: env.VITE_AUTH_URL || 'https://auth.legacy-group.tech',
    // This app's public client at the OP. Its redirect URIs list `<origin>/callback` for every domain the app is served from.
    oidcClientId: env.VITE_OIDC_CLIENT_ID || 'tracker-spa',
    calendarUrl: env.VITE_CALENDAR_URL || 'https://calendar.legacy-group.tech',
    // The Legacy Calendar web app (not its API): where an event's "Open in Legacy Calendar" link goes.
    calendarWebUrl: env.VITE_CALENDAR_WEB_URL || 'https://legacy-calendar.pages.dev',
    // The default map style: a MapLibre style URL. OpenFreeMap is free and needs no API key;
    // point this at another style (or its own host) without touching the map code.
    mapStyleUrl: env.VITE_MAP_STYLE_URL || 'https://tiles.openfreemap.org/styles/liberty'
};
