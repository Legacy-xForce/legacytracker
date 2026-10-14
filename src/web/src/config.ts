const env = import.meta.env;

// Production unless a build says otherwise (see .env.example).
export const config = {
    backendUrl: env.VITE_BACKEND_URL || 'https://tracker.legacy-group.tech',
    authUrl: env.VITE_AUTH_URL || 'https://auth.legacy-group.tech',
    calendarUrl: env.VITE_CALENDAR_URL || 'https://calendar.legacy-group.tech'
};
