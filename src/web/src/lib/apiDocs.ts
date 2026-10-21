// The public API reference rendered at /docs. Kept beside the clients so it changes with them; the
// server's README holds the same contract in brief.

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

/** Who may call an endpoint: a read token, a write token, only a signed-in session, or anyone. */
export type Access = 'read' | 'write' | 'session' | 'public';

export interface Param {
    name: string;
    in: 'path' | 'query' | 'body';
    type: string;
    required?: boolean;
    description: string;
}

export interface Endpoint {
    id: string;
    method: HttpMethod;
    path: string;
    summary: string;
    description?: string;
    access: Access;
    params?: Param[];
    /** Example JSON request body. */
    body?: unknown;
    /** Example JSON response. */
    response?: unknown;
    /** Status codes beyond the common ones, with what they mean here. */
    errors?: [number, string][];
    /** Replaces the generated curl example (the WebSocket isn't a curl request). */
    example?: string;
}

export interface DocSection {
    id: string;
    title: string;
    intro?: string;
    endpoints: Endpoint[];
}

export const ACCESS_LABELS: Record<Access, string> = {
    read: 'Read token',
    write: 'Write token',
    session: 'Session only',
    public: 'Public'
};

export const ACCESS_DETAILS: Record<Access, string> = {
    read: 'Read and write tokens, and signed-in sessions.',
    write: 'Write tokens and signed-in sessions. Read tokens get 403.',
    session: 'Only a signed-in session (Authorization: Bearer). API tokens get 403.',
    public: 'No authentication.'
};

/** Status codes every endpoint may answer with. */
export const ERROR_CODES: [number, string][] = [
    [400, 'The request is malformed; `error` says what is wrong.'],
    [401, 'Missing, invalid, rotated or deleted credentials.'],
    [
        403,
        'The credential is valid but may not do this: a read-only token, a session-only endpoint, a person who hides from you (`not_sharing`), or an account without tracker access.'
    ],
    [404, 'Nothing with that id, or it is not yours.'],
    [409, 'Conflicts, such as a checkpoint name that is taken.'],
    [500, 'Something broke on our side. Retry later.']
];

const iso = '2026-10-20T08:15:00.000Z';
const userId = '01a15968-64aa-707d-8904-a6a408611289';

const rosterEntry = {
    user_id: userId,
    username: 'alice',
    sharing: true,
    latitude: 45.0703,
    longitude: 7.6869,
    speed: 0,
    heading: null,
    recorded_at: iso,
    here_since: '2026-10-20T07:40:12.000Z',
    battery_level: 81,
    is_charging: false,
    tracking_issues: [],
    last_seen_at: iso
};

const checkpoint = {
    id: '6a0c7f7e-3d8b-4a54-9d0e-55f6f1f0c2b1',
    name: 'Office',
    latitude: 45.0703,
    longitude: 7.6869,
    radius_m: 80,
    created_by: userId,
    created_at: iso,
    updated_at: iso,
    can_edit: true
};

const tokenSummary = {
    id: '0e7a3c3e-2f7b-4f63-9c55-0bb0a4f3c1d2',
    name: 'Home Assistant',
    scope: 'read',
    token_hint: 'legacy-tracker-01a1…1289',
    created_at: iso,
    last_used_at: null,
    rotated_at: null
};

const checkpointBody: Param[] = [
    {
        name: 'name',
        in: 'body',
        type: 'string',
        required: true,
        description: 'Up to 60 characters, unique ignoring case.'
    },
    { name: 'latitude', in: 'body', type: 'number', required: true, description: 'Centre, −90 to 90.' },
    { name: 'longitude', in: 'body', type: 'number', required: true, description: 'Centre, −180 to 180.' },
    { name: 'radius_m', in: 'body', type: 'integer', required: true, description: 'Radius in metres, 10 to 250.' }
];

export const DOC_SECTIONS: DocSection[] = [
    {
        id: 'profile',
        title: 'Profile',
        endpoints: [
            {
                id: 'get-profile',
                method: 'GET',
                path: '/api/v1/profile',
                summary: "The caller's profile",
                access: 'read',
                response: { id: userId, name: 'alice', avatar_url: '', role: 'user' }
            },
            {
                id: 'patch-profile',
                method: 'PATCH',
                path: '/api/v1/profile',
                summary: 'Change the display name or avatar',
                access: 'write',
                params: [
                    { name: 'name', in: 'body', type: 'string', description: 'New display name.' },
                    { name: 'avatar_url', in: 'body', type: 'string', description: 'New avatar URL.' }
                ],
                body: { name: 'Alice' },
                response: { id: userId, name: 'Alice', avatar_url: '', role: 'user' }
            }
        ]
    },
    {
        id: 'live',
        title: 'People and live positions',
        intro: "The live map is a WebSocket. Ask for a single-use ticket, then open the stream with it within 60 seconds: browsers cannot set headers on a WebSocket, so the ticket carries your identity. While at least one stream says its map is open, everyone's phone reports in realtime.",
        endpoints: [
            {
                id: 'stream-ticket',
                method: 'POST',
                path: '/api/v1/streams/ticket',
                summary: 'Get a WebSocket ticket',
                description:
                    'Allowed for read tokens: it changes nothing. A stream opened with a read token ignores location uploads.',
                access: 'read',
                response: { ticket: '3f1d2a57-7c7e-4f8e-8f43-0a1d6f9b2c11' }
            },
            {
                id: 'stream',
                method: 'GET',
                path: '/api/v1/stream?ticket={ticket}',
                summary: 'Open the live stream (WebSocket)',
                description:
                    'Upgrade to a WebSocket at wss://<host>/api/v1/stream?ticket=…. The server first sends a `snapshot` of everyone you can see, then one message per position or presence change. Send {"type":"map_active","active":true} while your map is on screen (and false when it is not) to put phones into realtime mode. People who hide their location from you appear with `sharing: false` and no coordinates. When the session that opened the stream signs out, the server sends {"type":"signed_out"} and closes it.',
                access: 'read',
                params: [
                    {
                        name: 'ticket',
                        in: 'query',
                        type: 'uuid',
                        required: true,
                        description: 'From POST /api/v1/streams/ticket; single use.'
                    }
                ],
                example: `const res = await fetch(\`\${BASE}/api/v1/streams/ticket\`, {
  method: 'POST',
  headers: { 'X-API-Token': TOKEN }
});
const { ticket } = await res.json();
const ws = new WebSocket(\`\${BASE.replace(/^http/, 'ws')}/api/v1/stream?ticket=\${ticket}\`);
ws.onopen = () => ws.send(JSON.stringify({ type: 'map_active', active: true }));
ws.onmessage = (event) => console.log(JSON.parse(event.data));`,
                response: { type: 'snapshot', users: [rosterEntry] }
            },
            {
                id: 'location-refresh',
                method: 'POST',
                path: '/api/v1/users/{userId}/location-refresh',
                summary: "Wake someone's phone for a fresh position",
                description: 'Waits up to 25 seconds for the phone to report in, then returns their current entry.',
                access: 'write',
                params: [
                    { name: 'userId', in: 'path', type: 'string', required: true, description: 'The person to locate.' }
                ],
                response: rosterEntry,
                errors: [
                    [403, '`not_sharing`: they hide their location from you.'],
                    [404, 'Unknown user.'],
                    [409, '`no_device`: they have no phone registered.'],
                    [504, '`device_unreachable`: the phone did not answer in time.']
                ]
            }
        ]
    },
    {
        id: 'location',
        title: 'Uploading locations',
        endpoints: [
            {
                id: 'post-location',
                method: 'POST',
                path: '/api/v1/location',
                summary: 'Upload one or more positions',
                description:
                    'Send one point or an array, in any order. Points are stored idempotently on their timestamp, so re-sending a batch is safe. `source: "live"` points are broadcast to viewers but never stored. `live_ttl_s` above zero means someone is watching and the uploader should report in realtime for that long.',
                access: 'write',
                params: [
                    { name: 'coords.latitude', in: 'body', type: 'number', required: true, description: 'Degrees.' },
                    { name: 'coords.longitude', in: 'body', type: 'number', required: true, description: 'Degrees.' },
                    { name: 'coords.speed', in: 'body', type: 'number', description: 'm/s.' },
                    { name: 'coords.heading', in: 'body', type: 'number', description: 'Degrees from north.' },
                    {
                        name: 'coords.accuracy',
                        in: 'body',
                        type: 'number',
                        description: 'Horizontal accuracy in metres.'
                    },
                    {
                        name: 'timestamp',
                        in: 'body',
                        type: 'ISO 8601',
                        required: true,
                        description: 'When the fix was taken.'
                    },
                    {
                        name: 'source',
                        in: 'body',
                        type: 'string',
                        description: '`trip_start`, `move`, `trip_end`, `ping`, `heartbeat` or `live`.'
                    },
                    { name: 'battery_level', in: 'body', type: 'integer', description: '0–100.' },
                    { name: 'is_charging', in: 'body', type: 'boolean', description: 'Whether the device is charging.' }
                ],
                body: [
                    {
                        coords: { latitude: 45.0703, longitude: 7.6869, speed: 12.5, heading: 270, accuracy: 4.8 },
                        timestamp: iso,
                        source: 'move',
                        battery_level: 81,
                        is_charging: false
                    }
                ],
                response: { received: 1, stored: 1, pacing: 'PASSIVE', live_ttl_s: 0 }
            }
        ]
    },
    {
        id: 'history',
        title: 'Trips and history',
        endpoints: [
            {
                id: 'get-history',
                method: 'GET',
                path: '/api/v1/history',
                summary: "Someone's trips in a time window",
                description:
                    'Stored points grouped into trips. Windows are capped at 30 days, or 93 days with `points=false`.',
                access: 'read',
                params: [
                    { name: 'user_id', in: 'query', type: 'string', description: 'Whose trips. Defaults to you.' },
                    { name: 'from', in: 'query', type: 'ISO 8601', description: 'Defaults to 7 days before `to`.' },
                    { name: 'to', in: 'query', type: 'ISO 8601', description: 'Defaults to now.' },
                    {
                        name: 'points',
                        in: 'query',
                        type: 'boolean',
                        description: '`false` leaves the points out (summaries only).'
                    }
                ],
                response: {
                    user_id: userId,
                    from: '2026-10-13T08:15:00.000Z',
                    to: iso,
                    sessions: [
                        {
                            start_at: '2026-10-19T17:02:10.000Z',
                            end_at: '2026-10-19T17:31:44.000Z',
                            duration_seconds: 1774,
                            distance_meters: 12400,
                            avg_speed: 7.0,
                            top_speed: 24.1,
                            point_count: 2,
                            points: [
                                {
                                    latitude: 45.0703,
                                    longitude: 7.6869,
                                    speed: 0,
                                    heading: null,
                                    accuracy: 5,
                                    recorded_at: '2026-10-19T17:02:10.000Z'
                                }
                            ]
                        }
                    ]
                },
                errors: [[403, '`not_sharing`: they hide their location from you.']]
            },
            {
                id: 'delete-history',
                method: 'DELETE',
                path: '/api/v1/history',
                summary: 'Erase your own stored points',
                description:
                    "Deletes your points between `from` and `to`, both inclusive. There is no `user_id`: nobody can erase someone else's history. Windows are capped at 30 days.",
                access: 'write',
                params: [
                    {
                        name: 'from',
                        in: 'query',
                        type: 'ISO 8601',
                        required: true,
                        description: 'Start of the window.'
                    },
                    { name: 'to', in: 'query', type: 'ISO 8601', required: true, description: 'End of the window.' }
                ],
                response: { deleted: 42 }
            },
            {
                id: 'leaderboard',
                method: 'GET',
                path: '/api/v1/leaderboard',
                summary: 'Who travelled furthest',
                description:
                    'Built from the same trips as the history, furthest first. Lists everyone with a trip in the window, plus you; people who hide from you are left out. Windows are capped at 366 days.',
                access: 'read',
                params: [
                    {
                        name: 'from',
                        in: 'query',
                        type: 'ISO 8601',
                        required: true,
                        description: 'Start of the window.'
                    },
                    { name: 'to', in: 'query', type: 'ISO 8601', required: true, description: 'End of the window.' }
                ],
                response: {
                    from: '2026-10-01T00:00:00.000Z',
                    to: '2026-11-01T00:00:00.000Z',
                    entries: [
                        {
                            user_id: userId,
                            username: 'alice',
                            rank: 1,
                            distance_meters: 312000,
                            duration_seconds: 21600,
                            avg_speed: 14.4,
                            top_speed: 36.1,
                            trip_count: 18
                        }
                    ]
                }
            }
        ]
    },
    {
        id: 'checkpoints',
        title: 'Checkpoints',
        intro: 'Shared named places ("Home", "Office") shown instead of a street name. Everyone can list and create them; only the creator or an admin can change or delete one (`can_edit`).',
        endpoints: [
            {
                id: 'list-checkpoints',
                method: 'GET',
                path: '/api/v1/checkpoints',
                summary: 'List all checkpoints',
                access: 'read',
                response: { checkpoints: [checkpoint] }
            },
            {
                id: 'create-checkpoint',
                method: 'POST',
                path: '/api/v1/checkpoints',
                summary: 'Create a checkpoint',
                access: 'write',
                params: checkpointBody,
                body: { name: 'Office', latitude: 45.0703, longitude: 7.6869, radius_m: 80 },
                response: checkpoint,
                errors: [[409, 'A checkpoint with that name already exists.']]
            },
            {
                id: 'update-checkpoint',
                method: 'PATCH',
                path: '/api/v1/checkpoints/{id}',
                summary: 'Change a checkpoint',
                description: 'Takes the same full body as creating one.',
                access: 'write',
                params: [
                    { name: 'id', in: 'path', type: 'uuid', required: true, description: 'Checkpoint id.' },
                    ...checkpointBody
                ],
                body: { name: 'Office', latitude: 45.0703, longitude: 7.6869, radius_m: 120 },
                response: { ...checkpoint, radius_m: 120 },
                errors: [
                    [403, 'You did not create it and are not an admin.'],
                    [409, 'Name already taken.']
                ]
            },
            {
                id: 'delete-checkpoint',
                method: 'DELETE',
                path: '/api/v1/checkpoints/{id}',
                summary: 'Delete a checkpoint',
                access: 'write',
                params: [{ name: 'id', in: 'path', type: 'uuid', required: true, description: 'Checkpoint id.' }],
                response: { deleted: true },
                errors: [[403, 'You did not create it and are not an admin.']]
            }
        ]
    },
    {
        id: 'sharing',
        title: 'Location sharing',
        intro: 'Your location is shared with everyone by default. You can hide it from specific people.',
        endpoints: [
            {
                id: 'get-sharing',
                method: 'GET',
                path: '/api/v1/sharing',
                summary: 'Who you hide from',
                access: 'read',
                response: { hidden_from: ['22222222-2222-4222-8222-222222222222'] }
            },
            {
                id: 'put-sharing',
                method: 'PUT',
                path: '/api/v1/sharing/{viewerId}',
                summary: 'Show or hide your location from someone',
                access: 'write',
                params: [
                    { name: 'viewerId', in: 'path', type: 'string', required: true, description: 'The other person.' },
                    {
                        name: 'enabled',
                        in: 'body',
                        type: 'boolean',
                        required: true,
                        description: '`false` hides you from them.'
                    }
                ],
                body: { enabled: false },
                response: { hidden_from: ['22222222-2222-4222-8222-222222222222'] }
            }
        ]
    },
    {
        id: 'devices',
        title: 'Devices and app updates',
        intro: 'These serve the phone app. Registering a device mints a long-lived upload credential, so it needs a signed-in session.',
        endpoints: [
            {
                id: 'register-device',
                method: 'POST',
                path: '/api/v1/devices',
                summary: 'Register a phone for background uploads',
                description:
                    'Only sessions of the Legacy Tracker phone app may register devices; a web session gets 403.',
                access: 'session',
                params: [
                    { name: 'platform', in: 'body', type: 'string', description: '`android` or `ios`.' },
                    { name: 'replaces', in: 'body', type: 'string', description: 'A previous device id to revoke.' }
                ],
                body: { platform: 'android' },
                response: { device_id: '8f6f…', device_token: '…' }
            },
            {
                id: 'delete-device',
                method: 'DELETE',
                path: '/api/v1/devices/{id}',
                summary: "Revoke a phone's upload credential",
                access: 'write',
                params: [{ name: 'id', in: 'path', type: 'string', required: true, description: 'Device id.' }],
                response: { revoked: true }
            },
            {
                id: 'fcm-token',
                method: 'POST',
                path: '/api/v1/fcm-token',
                summary: "Register a phone's push token",
                access: 'session',
                params: [
                    {
                        name: 'token',
                        in: 'body',
                        type: 'string',
                        required: true,
                        description: 'Firebase Cloud Messaging token.'
                    }
                ],
                body: { token: '…' },
                response: { ok: true }
            },
            {
                id: 'android-latest',
                method: 'GET',
                path: '/api/v1/app/android/latest',
                summary: 'The current Android release',
                description: '204 when none is published.',
                access: 'public',
                response: {
                    version_code: 11,
                    version_name: '1.5.0',
                    apk_url: 'https://github.com/…/app-release.apk',
                    sha256: '…',
                    size: 41234567,
                    notes: '…',
                    published_at: iso
                }
            }
        ]
    },
    {
        id: 'api-tokens',
        title: 'Managing API tokens',
        intro: 'Create and manage tokens from your profile in the phone app or the account menu on the web, or call these with a signed-in session. API tokens cannot manage tokens, so a leaked token cannot mint replacements.',
        endpoints: [
            {
                id: 'list-tokens',
                method: 'GET',
                path: '/api/v1/api-tokens',
                summary: 'List your tokens',
                description: 'Never includes the secret, only a short hint.',
                access: 'session',
                response: { tokens: [tokenSummary] }
            },
            {
                id: 'create-token',
                method: 'POST',
                path: '/api/v1/api-tokens',
                summary: 'Create a token',
                description: 'The full token is in this response only. Up to 25 tokens per account.',
                access: 'session',
                params: [
                    { name: 'name', in: 'body', type: 'string', description: 'A label, up to 60 characters.' },
                    {
                        name: 'scope',
                        in: 'body',
                        type: '"read" | "write"',
                        required: true,
                        description: 'What the token may do.'
                    }
                ],
                body: { name: 'Home Assistant', scope: 'read' },
                response: { ...tokenSummary, token: 'legacy-tracker-01a15968-64aa-707d-8904-a6a408611289' }
            },
            {
                id: 'rotate-token',
                method: 'POST',
                path: '/api/v1/api-tokens/{id}/rotate',
                summary: 'Rotate a token',
                description: 'Issues a new value; the old one stops working at once.',
                access: 'session',
                params: [{ name: 'id', in: 'path', type: 'uuid', required: true, description: 'Token id.' }],
                response: { ...tokenSummary, rotated_at: iso, token: 'legacy-tracker-5b0e2d1c-…' }
            },
            {
                id: 'delete-token',
                method: 'DELETE',
                path: '/api/v1/api-tokens/{id}',
                summary: 'Delete a token',
                access: 'session',
                params: [{ name: 'id', in: 'path', type: 'uuid', required: true, description: 'Token id.' }],
                response: { deleted: true }
            }
        ]
    }
];

/** A copy-pasteable request using an API token. */
export function curlExample(endpoint: Endpoint, baseUrl: string): string {
    const lines = [`curl${endpoint.method === 'GET' ? '' : ` -X ${endpoint.method}`} "${baseUrl}${endpoint.path}"`];
    if (endpoint.access === 'session') lines.push('  -H "Authorization: Bearer $ACCESS_TOKEN"');
    else if (endpoint.access !== 'public') lines.push('  -H "X-API-Token: $LEGACY_TRACKER_TOKEN"');
    if (endpoint.body !== undefined) {
        lines.push('  -H "Content-Type: application/json"');
        lines.push(`  -d '${JSON.stringify(endpoint.body)}'`);
    }
    return lines.join(' \\\n');
}
