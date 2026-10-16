/**
 * Phone settings that stop or delay location updates, as a device reports them (`tracking_issues`
 * on the stream). The codes are the server's closed set; this is the wording and fix steps for
 * each, ordered most blocking first. The phone app keeps the same copy.
 */
export const TRACKING_ISSUES = [
    'location_services_off',
    'location_permission',
    'background_location',
    'precise_location',
    'battery_optimization'
] as const;

export type TrackingIssue = (typeof TRACKING_ISSUES)[number];

/** Who the banner talks about: the viewer themselves ("You should…") or someone else. */
export interface Subject {
    name: string;
    self: boolean;
}

export interface IssueCopy {
    title: string;
    /** One sentence on what's wrong and what the person should do. */
    summary: string;
    /** How to fix it on the phone, in order. */
    steps: string[];
}

const KNOWN = new Set<string>(TRACKING_ISSUES);

/** Keeps the codes this client knows, in display order; anything else (newer builds) is ignored. */
export function parseTrackingIssues(value: unknown): TrackingIssue[] {
    if (!Array.isArray(value)) return [];
    return TRACKING_ISSUES.filter((issue) => value.includes(issue) && KNOWN.has(issue));
}

export function issueCopy(issue: TrackingIssue, { name, self }: Subject): IssueCopy {
    const who = self ? 'You' : name;
    const their = self ? 'your' : 'their';
    switch (issue) {
        case 'location_services_off':
            return {
                title: 'Location is turned off',
                summary: `Location is turned off for ${their} whole phone, so it can't be updated.`,
                steps: ['Open the phone’s Settings and go to Location.', 'Turn Location on.']
            };
        case 'location_permission':
            return {
                title: 'Location permission is missing',
                summary: `Legacy Tracker isn't allowed to use ${their} phone's location.`,
                steps: [
                    'Open the phone’s Settings and find Legacy Tracker under Apps.',
                    'Open its Location permission and choose “Allow all the time”.'
                ]
            };
        case 'background_location':
            return {
                title: 'Location only works while the app is open',
                summary: `${who} should allow Location “All the time” for Legacy Tracker, or updates stop when the app is closed.`,
                steps: [
                    'Open the phone’s Settings and find Legacy Tracker under Apps.',
                    'Open its Location permission and choose “Allow all the time”.'
                ]
            };
        case 'precise_location':
            return {
                title: 'Precise location is off',
                summary: `${who} should turn on Precise location for Legacy Tracker; approximate positions can't record routes.`,
                steps: [
                    'Open the phone’s Settings and find Legacy Tracker under Apps.',
                    'Open its Location permission and turn on “Use precise location”.'
                ]
            };
        case 'battery_optimization':
            return {
                title: 'Battery settings are delaying updates',
                summary: `${who} should update ${their} phone's Battery Optimization settings.`,
                steps: [
                    'Open the phone’s Settings and find Legacy Tracker under Apps.',
                    'Open Battery and choose “Unrestricted” (or turn battery optimization off for the app).'
                ]
            };
    }
}
