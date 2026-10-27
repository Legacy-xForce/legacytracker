// The public API reference rendered at /docs with Scalar. This is the OpenAPI
// document the page consumes; keep it in step with the server routes and
// src/server/README.md when an endpoint changes.

const iso = '2026-10-20T08:15:00.000Z';
const userId = '01a15968-64aa-707d-8904-a6a408611289';
const otherUserId = '22222222-2222-4222-8222-222222222222';

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
    allowed_ips: [],
    created_at: iso,
    last_used_at: null,
    rotated_at: null
};

const errorSchema = {
    type: 'object',
    required: ['error'],
    properties: {
        error: { type: 'string', description: 'A short, human-readable reason.' }
    }
};

const errorResponse = (description: string) => ({
    description,
    content: {
        'application/json': {
            schema: { $ref: '#/components/schemas/Error' },
            example: { error: description }
        }
    }
});

/** Status codes every endpoint may answer with. */
const commonErrors = {
    '400': { $ref: '#/components/responses/BadRequest' },
    '401': { $ref: '#/components/responses/Unauthorized' },
    '403': { $ref: '#/components/responses/Forbidden' },
    '500': { $ref: '#/components/responses/InternalError' }
};

/** A read or write token, or a signed-in session. */
const tokenOrSession = [{ apiToken: [] }, { bearerAuth: [] }];
/** Routes that mint credentials deliberately refuse API tokens. */
const sessionOnly = [{ bearerAuth: [] }];

export const openApiDocument = {
    openapi: '3.1.0',
    info: {
        title: 'Legacy Tracker API',
        version: '1.6.0',
        license: {
            name: 'MIT',
            url: 'https://github.com/Legacy-xForce/legacytracker/blob/main/LICENSE.md'
        },
        description: [
            'Everything the phone app and the web map do goes through this REST and WebSocket API, so your own',
            'scripts and integrations can do the same: read where people are, follow the live map, look up trips,',
            'upload positions and manage checkpoints.',
            '',
            '## Authentication',
            '',
            'Integrations authenticate with a personal API token. Create one under **Profile → API tokens** in the',
            'phone app, or **account menu → API tokens** on the web map, and send it in the `X-API-Token` header:',
            '',
            '```http',
            'X-API-Token: legacy-tracker-01a15968-64aa-707d-8904-a6a408611289',
            '```',
            '',
            'A token acts as you: it sees exactly what you see and can do what you can do, within its scope. Unlike a',
            'sign-in session it never expires and is not refreshed, so treat it like a password. It is shown once,',
            'when you create or rotate it; afterwards only a short hint such as `legacy-tracker-01a1…1289` identifies it.',
            '',
            '- **read**: every `GET` request, plus opening the live stream. Anything that changes data answers `403`.',
            '- **write**: everything your account can do, such as uploading positions, editing checkpoints or deleting',
            '  your history.',
            '',
            'A token can also be limited to the addresses that may use it. List them (or CIDR prefixes such as',
            '`198.51.100.0/24`) in the token’s **Edit** panel and anything else is refused with `403`. An empty list,',
            'which is what every token starts with, allows any address.',
            '',
            'Endpoints marked **Session only** take a signed-in session (`Authorization: Bearer <access token>` that',
            'Legacy Auth issued to a Legacy Tracker app) and refuse API tokens, so a leaked token cannot create new',
            'tokens or register devices. If both headers are present, `X-API-Token` wins.',
            '',
            '## Errors',
            '',
            'Errors carry a JSON body such as `{ "error": "This API token is read-only" }`.',
            '',
            '| Status | Meaning |',
            '| --- | --- |',
            '| 400 | The request is malformed; `error` says what is wrong. |',
            '| 401 | Missing, invalid, rotated or deleted credentials. |',
            '| 403 | The credential is valid but may not do this: a read-only token, a token used from an address it does not allow, a session-only endpoint, a person who hides from you (`not_sharing`), or an account without tracker access. |',
            '| 404 | Nothing with that id, or it is not yours. |',
            '| 409 | Conflicts, such as a checkpoint name that is taken. |',
            '| 500 | Something broke on our side. Retry later. |',
            '| 503 | A dependency the endpoint needs is unavailable, such as the Mapbox token service. Retry later. |',
            '',
            'Requests and responses are JSON. Times are ISO 8601 in UTC, distances in metres and speeds in metres per second.'
        ].join('\n')
    },
    servers: [{ url: 'https://tracker.legacy-group.tech', description: 'Production' }],
    tags: [
        {
            name: 'Profile',
            description: 'The account behind the credential.'
        },
        {
            name: 'People and live positions',
            description:
                'The live map is a WebSocket. Ask for a single-use ticket, then open the stream with it within 60 seconds: browsers cannot set headers on a WebSocket, so the ticket carries your identity. While at least one stream says its map is open, everyone’s phone reports in realtime.'
        },
        {
            name: 'Uploading locations',
            description: 'What the phone app sends while it is moving or live.'
        },
        {
            name: 'Trips and history',
            description: 'Stored positions grouped into trips, and the leaderboard built from them.'
        },
        {
            name: 'Checkpoints',
            description:
                'Shared named places (“Home”, “Office”) shown instead of a street name. Everyone can list and create them; only the creator or an admin can change or delete one (`can_edit`).'
        },
        {
            name: 'Location sharing',
            description: 'Your location is shared with everyone by default. You can hide it from specific people.'
        },
        {
            name: 'Map rendering',
            description:
                'Short-lived Mapbox credentials for the phone app. Release builds contain no Mapbox token; the app asks for one before it creates the map. Web clients use their own public token and do not call this.'
        },
        {
            name: 'Devices and app updates',
            description:
                'These serve the phone app. Registering a device mints a long-lived upload credential, so it needs a signed-in session.'
        },
        {
            name: 'Managing API tokens',
            description:
                'Create and manage tokens from your profile in the phone app or the account menu on the web, or call these with a signed-in session. API tokens cannot manage tokens, so a leaked token cannot mint replacements. A token’s allowed addresses are edited from the web map or the phone app.'
        }
    ],
    paths: {
        '/api/v1/profile': {
            get: {
                tags: ['Profile'],
                operationId: 'get-profile',
                summary: 'The caller’s profile',
                security: tokenOrSession,
                responses: {
                    '200': {
                        description: 'The profile behind the session or token.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Profile' },
                                example: { id: userId, name: 'alice', avatar_url: '', role: 'user' }
                            }
                        }
                    },
                    ...commonErrors
                }
            },
            patch: {
                tags: ['Profile'],
                operationId: 'patch-profile',
                summary: 'Change the display name or avatar',
                security: tokenOrSession,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/ProfileUpdate' },
                            example: { name: 'Alice' }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'The updated profile.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Profile' },
                                example: { id: userId, name: 'Alice', avatar_url: '', role: 'user' }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/streams/ticket': {
            post: {
                tags: ['People and live positions'],
                operationId: 'stream-ticket',
                summary: 'Get a WebSocket ticket',
                description:
                    'Allowed for read tokens: it changes nothing. A stream opened with a read token ignores location uploads.',
                security: tokenOrSession,
                responses: {
                    '200': {
                        description: 'A single-use ticket, valid for 60 seconds.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/StreamTicket' },
                                example: { ticket: '3f1d2a57-7c7e-4f8e-8f43-0a1d6f9b2c11' }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/stream': {
            get: {
                tags: ['People and live positions'],
                operationId: 'stream',
                summary: 'Open the live stream (WebSocket)',
                description: [
                    'Upgrade to a WebSocket at `wss://<host>/api/v1/stream?ticket=…`. The server first sends a',
                    '`snapshot` of everyone you can see, then one message per position or presence change. Send',
                    '`{"type":"map_active","active":true}` while your map is on screen (and `false` when it is not) to',
                    'put phones into realtime mode. People who hide their location from you appear with `sharing: false`',
                    'and no coordinates. When the session that opened the stream signs out, the server sends',
                    '`{"type":"signed_out"}` and closes it.',
                    '',
                    '```js',
                    'const res = await fetch(`${BASE}/api/v1/streams/ticket`, {',
                    "  method: 'POST',",
                    "  headers: { 'X-API-Token': TOKEN }",
                    '});',
                    'const { ticket } = await res.json();',
                    "const ws = new WebSocket(`${BASE.replace(/^http/, 'ws')}/api/v1/stream?ticket=${ticket}`);",
                    "ws.onopen = () => ws.send(JSON.stringify({ type: 'map_active', active: true }));",
                    'ws.onmessage = (event) => console.log(JSON.parse(event.data));',
                    '```'
                ].join('\n'),
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'ticket',
                        in: 'query',
                        required: true,
                        description: 'From `POST /api/v1/streams/ticket`; single use.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                responses: {
                    '101': {
                        description:
                            'Switching protocols to WebSocket. The first message is a `snapshot`; later messages are position or presence changes.'
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/users/{userId}/location-refresh': {
            post: {
                tags: ['People and live positions'],
                operationId: 'location-refresh',
                summary: 'Wake someone’s phone for a fresh position',
                description: 'Waits up to 25 seconds for the phone to report in, then returns their current entry.',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'userId',
                        in: 'path',
                        required: true,
                        description: 'The person to locate.',
                        schema: { type: 'string' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The refreshed entry.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/RosterEntry' },
                                example: rosterEntry
                            }
                        }
                    },
                    ...commonErrors,
                    '403': errorResponse('`not_sharing`: they hide their location from you.'),
                    '404': errorResponse('Unknown user.'),
                    '409': errorResponse('`no_device`: they have no phone registered.'),
                    '504': errorResponse('`device_unreachable`: the phone did not answer in time.')
                }
            }
        },
        '/api/v1/location': {
            post: {
                tags: ['Uploading locations'],
                operationId: 'post-location',
                summary: 'Upload one or more positions',
                description: [
                    'Send one point or an array, in any order. Points are stored idempotently on their timestamp, so',
                    're-sending a batch is safe. `source: "live"` points are broadcast to viewers but never stored.',
                    '`live_ttl_s` above zero means someone is watching and the uploader should report in realtime for that long.'
                ].join(' '),
                security: tokenOrSession,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                oneOf: [
                                    { $ref: '#/components/schemas/LocationSample' },
                                    { type: 'array', items: { $ref: '#/components/schemas/LocationSample' } }
                                ]
                            },
                            examples: {
                                single: {
                                    summary: 'One point',
                                    value: [
                                        {
                                            coords: {
                                                latitude: 45.0703,
                                                longitude: 7.6869,
                                                speed: 12.5,
                                                heading: 270,
                                                accuracy: 4.8
                                            },
                                            timestamp: iso,
                                            source: 'move',
                                            battery_level: 81,
                                            is_charging: false
                                        }
                                    ]
                                },
                                batch: {
                                    summary: 'A batch of points',
                                    value: [
                                        {
                                            coords: {
                                                latitude: 45.0703,
                                                longitude: 7.6869,
                                                speed: 12.5,
                                                heading: 270,
                                                accuracy: 4.8
                                            },
                                            timestamp: '2026-10-20T08:15:00.000Z',
                                            source: 'move'
                                        },
                                        {
                                            coords: {
                                                latitude: 45.0711,
                                                longitude: 7.6882,
                                                speed: 0,
                                                heading: null,
                                                accuracy: 6
                                            },
                                            timestamp: '2026-10-20T08:15:30.000Z',
                                            source: 'trip_end'
                                        }
                                    ]
                                }
                            }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'How many points were accepted and stored.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/LocationUploadResult' },
                                example: { received: 1, stored: 1, pacing: 'PASSIVE', live_ttl_s: 0 }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/history': {
            get: {
                tags: ['Trips and history'],
                operationId: 'get-history',
                summary: 'Someone’s trips in a time window',
                description:
                    'Stored points grouped into trips. Windows are capped at 30 days, or 93 days with `points=false`.',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'user_id',
                        in: 'query',
                        description: 'Whose trips. Defaults to you.',
                        schema: { type: 'string', format: 'uuid' }
                    },
                    {
                        name: 'from',
                        in: 'query',
                        description: 'Defaults to 7 days before `to`.',
                        schema: { type: 'string', format: 'date-time' }
                    },
                    {
                        name: 'to',
                        in: 'query',
                        description: 'Defaults to now.',
                        schema: { type: 'string', format: 'date-time' }
                    },
                    {
                        name: 'points',
                        in: 'query',
                        description: '`false` leaves the points out (summaries only).',
                        schema: { type: 'boolean', default: true }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The trips in the window.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/HistoryResponse' },
                                example: {
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
                                }
                            }
                        }
                    },
                    ...commonErrors,
                    '403': errorResponse('`not_sharing`: they hide their location from you.')
                }
            },
            delete: {
                tags: ['Trips and history'],
                operationId: 'delete-history',
                summary: 'Erase your own stored points',
                description:
                    'Deletes your points between `from` and `to`, both inclusive. There is no `user_id`: nobody can erase someone else’s history. Windows are capped at 30 days.',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'from',
                        in: 'query',
                        required: true,
                        description: 'Start of the window.',
                        schema: { type: 'string', format: 'date-time' }
                    },
                    {
                        name: 'to',
                        in: 'query',
                        required: true,
                        description: 'End of the window.',
                        schema: { type: 'string', format: 'date-time' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'How many points were deleted.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['deleted'],
                                    properties: { deleted: { type: 'integer' } }
                                },
                                example: { deleted: 42 }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/leaderboard': {
            get: {
                tags: ['Trips and history'],
                operationId: 'leaderboard',
                summary: 'Who travelled furthest',
                description:
                    'Built from the same trips as the history, furthest first. Lists everyone with a trip in the window, plus you; people who hide from you are left out. Windows are capped at 366 days.',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'from',
                        in: 'query',
                        required: true,
                        description: 'Start of the window.',
                        schema: { type: 'string', format: 'date-time' }
                    },
                    {
                        name: 'to',
                        in: 'query',
                        required: true,
                        description: 'End of the window.',
                        schema: { type: 'string', format: 'date-time' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The ranking for the window.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/LeaderboardResponse' },
                                example: {
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
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/checkpoints': {
            get: {
                tags: ['Checkpoints'],
                operationId: 'list-checkpoints',
                summary: 'List all checkpoints',
                security: tokenOrSession,
                responses: {
                    '200': {
                        description: 'Every checkpoint, newest first.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['checkpoints'],
                                    properties: {
                                        checkpoints: {
                                            type: 'array',
                                            items: { $ref: '#/components/schemas/Checkpoint' }
                                        }
                                    }
                                },
                                example: { checkpoints: [checkpoint] }
                            }
                        }
                    },
                    ...commonErrors
                }
            },
            post: {
                tags: ['Checkpoints'],
                operationId: 'create-checkpoint',
                summary: 'Create a checkpoint',
                security: tokenOrSession,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/CheckpointInput' },
                            example: { name: 'Office', latitude: 45.0703, longitude: 7.6869, radius_m: 80 }
                        }
                    }
                },
                responses: {
                    '201': {
                        description: 'The created checkpoint.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Checkpoint' },
                                example: checkpoint
                            }
                        }
                    },
                    '409': errorResponse('A checkpoint with that name already exists.'),
                    ...commonErrors
                }
            }
        },
        '/api/v1/checkpoints/{id}': {
            patch: {
                tags: ['Checkpoints'],
                operationId: 'update-checkpoint',
                summary: 'Change a checkpoint',
                description: 'Takes the same full body as creating one.',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Checkpoint id.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/CheckpointInput' },
                            example: { name: 'Office', latitude: 45.0703, longitude: 7.6869, radius_m: 120 }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'The updated checkpoint.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Checkpoint' },
                                example: { ...checkpoint, radius_m: 120 }
                            }
                        }
                    },
                    ...commonErrors,
                    '403': errorResponse('You did not create it and are not an admin.'),
                    '409': errorResponse('Name already taken.')
                }
            },
            delete: {
                tags: ['Checkpoints'],
                operationId: 'delete-checkpoint',
                summary: 'Delete a checkpoint',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Checkpoint id.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The checkpoint was deleted.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['deleted'],
                                    properties: { deleted: { type: 'boolean' } }
                                },
                                example: { deleted: true }
                            }
                        }
                    },
                    ...commonErrors,
                    '403': errorResponse('You did not create it and are not an admin.')
                }
            }
        },
        '/api/v1/sharing': {
            get: {
                tags: ['Location sharing'],
                operationId: 'get-sharing',
                summary: 'Who you hide from',
                security: tokenOrSession,
                responses: {
                    '200': {
                        description: 'The people your location is hidden from.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Sharing' },
                                example: { hidden_from: [otherUserId] }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/sharing/{viewerId}': {
            put: {
                tags: ['Location sharing'],
                operationId: 'put-sharing',
                summary: 'Show or hide your location from someone',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'viewerId',
                        in: 'path',
                        required: true,
                        description: 'The other person.',
                        schema: { type: 'string' }
                    }
                ],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                type: 'object',
                                required: ['enabled'],
                                properties: {
                                    enabled: {
                                        type: 'boolean',
                                        description: '`false` hides you from them.'
                                    }
                                }
                            },
                            example: { enabled: false }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'The updated list of people you hide from.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Sharing' },
                                example: { hidden_from: [otherUserId] }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/devices': {
            post: {
                tags: ['Devices and app updates'],
                operationId: 'register-device',
                summary: 'Register a phone for background uploads',
                description:
                    'Only sessions of the Legacy Tracker phone app may register devices; a web session gets 403.',
                security: sessionOnly,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/DeviceRegistration' },
                            example: { platform: 'android' }
                        }
                    }
                },
                responses: {
                    '201': {
                        description: 'The new device id and its long-lived upload token.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/DeviceCredentials' },
                                example: { device_id: '8f6f…', device_token: '…' }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/devices/{id}': {
            delete: {
                tags: ['Devices and app updates'],
                operationId: 'delete-device',
                summary: 'Revoke a phone’s upload credential',
                security: tokenOrSession,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Device id.',
                        schema: { type: 'string' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The device credential was revoked.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['revoked'],
                                    properties: { revoked: { type: 'boolean' } }
                                },
                                example: { revoked: true }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/mapbox/token': {
            post: {
                tags: ['Map rendering'],
                operationId: 'mapbox-token',
                summary: 'Get a short-lived Mapbox token',
                description:
                    'Mints a temporary Mapbox token for the signed-in phone app. `503` when the server has no Mapbox credentials or Mapbox refuses the request. Never call this from a web client; the web uses its URL-restricted public token instead.',
                security: sessionOnly,
                responses: {
                    '200': {
                        description: 'A temporary token. The response is not cacheable.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/MapboxToken' },
                                example: {
                                    token: 'tk.eyJ1IjoibGVnYWN5LXRyYWNrZXIiLCJleHAiOjE3OTI5NDAwMDB9.signature',
                                    expires_at: '2026-10-25T13:00:00.000Z'
                                }
                            }
                        }
                    },
                    '503': errorResponse('Map rendering is not configured or temporarily unavailable.'),
                    ...commonErrors
                }
            }
        },
        '/api/v1/fcm-token': {
            post: {
                tags: ['Devices and app updates'],
                operationId: 'fcm-token',
                summary: 'Register a phone’s push token',
                security: sessionOnly,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                type: 'object',
                                required: ['token'],
                                properties: {
                                    token: {
                                        type: 'string',
                                        description: 'Firebase Cloud Messaging token.'
                                    }
                                }
                            },
                            example: { token: '…' }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'The token was stored.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['ok'],
                                    properties: { ok: { type: 'boolean' } }
                                },
                                example: { ok: true }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/app/android/latest': {
            get: {
                tags: ['Devices and app updates'],
                operationId: 'android-latest',
                summary: 'The current Android release',
                description: '204 when none is published.',
                security: [],
                responses: {
                    '200': {
                        description: 'The latest published Android release.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/AndroidRelease' },
                                example: {
                                    version_code: 11,
                                    version_name: '1.5.0',
                                    apk_url:
                                        'https://github.com/Legacy-xForce/legacytracker/releases/download/android-v1.5.0+11/app-release.apk',
                                    sha256: '…',
                                    size: 41234567,
                                    notes: '…',
                                    published_at: iso,
                                    min_supported_code: 0
                                }
                            }
                        }
                    },
                    '204': { description: 'No Android release is published yet.' },
                    ...commonErrors
                }
            }
        },
        '/api/v1/api-tokens': {
            get: {
                tags: ['Managing API tokens'],
                operationId: 'list-tokens',
                summary: 'List your tokens',
                description: 'Never includes the secret, only a short hint.',
                security: sessionOnly,
                responses: {
                    '200': {
                        description: 'Your tokens, newest first.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['tokens'],
                                    properties: {
                                        tokens: {
                                            type: 'array',
                                            items: { $ref: '#/components/schemas/ApiTokenSummary' }
                                        },
                                        your_ip: {
                                            type: 'string',
                                            description:
                                                'The address this request arrived from, so a restriction can be written down instead of guessed.'
                                        }
                                    }
                                },
                                example: { tokens: [tokenSummary], your_ip: '203.0.113.7' }
                            }
                        }
                    },
                    ...commonErrors
                }
            },
            post: {
                tags: ['Managing API tokens'],
                operationId: 'create-token',
                summary: 'Create a token',
                description: 'The full token is in this response only. Up to 25 tokens per account.',
                security: sessionOnly,
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/CreateApiToken' },
                            example: { name: 'Home Assistant', scope: 'read' }
                        }
                    }
                },
                responses: {
                    '201': {
                        description: 'The created token. `token` is shown only once.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/CreatedApiToken' },
                                example: {
                                    ...tokenSummary,
                                    token: 'legacy-tracker-01a15968-64aa-707d-8904-a6a408611289'
                                }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/api-tokens/{id}/rotate': {
            post: {
                tags: ['Managing API tokens'],
                operationId: 'rotate-token',
                summary: 'Rotate a token',
                description: 'Issues a new value; the old one stops working at once.',
                security: sessionOnly,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Token id.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The rotated token. `token` is shown only once.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/CreatedApiToken' },
                                example: {
                                    ...tokenSummary,
                                    rotated_at: iso,
                                    token: 'legacy-tracker-5b0e2d1c-…'
                                }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        },
        '/api/v1/api-tokens/{id}': {
            patch: {
                tags: ['Managing API tokens'],
                operationId: 'update-token',
                summary: 'Change the addresses a token may be used from',
                description:
                    'Replaces the allowlist, which applies to the very next request. An empty list means no restriction, and that is what every token starts with. Requests from outside the list get `403 { "error": "This API token is not allowed from your address" }`, and the server log names the address it saw.',
                security: sessionOnly,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Token id.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: { $ref: '#/components/schemas/UpdateApiToken' },
                            example: { allowed_ips: ['203.0.113.7', '198.51.100.0/24'] }
                        }
                    }
                },
                responses: {
                    '200': {
                        description: 'The token with the list as stored now.',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/ApiTokenSummary' },
                                example: { ...tokenSummary, allowed_ips: ['203.0.113.7', '198.51.100.0/24'] }
                            }
                        }
                    },
                    ...commonErrors
                }
            },
            delete: {
                tags: ['Managing API tokens'],
                operationId: 'delete-token',
                summary: 'Delete a token',
                security: sessionOnly,
                parameters: [
                    {
                        name: 'id',
                        in: 'path',
                        required: true,
                        description: 'Token id.',
                        schema: { type: 'string', format: 'uuid' }
                    }
                ],
                responses: {
                    '200': {
                        description: 'The token was deleted.',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['deleted'],
                                    properties: { deleted: { type: 'boolean' } }
                                },
                                example: { deleted: true }
                            }
                        }
                    },
                    ...commonErrors
                }
            }
        }
    },
    components: {
        securitySchemes: {
            apiToken: {
                type: 'apiKey',
                in: 'header',
                name: 'X-API-Token',
                description:
                    'Personal API token (`legacy-tracker-…`) created from Profile → API tokens. A `read` token may only perform `GET` requests and open the live stream; a `write` token may do anything the session can.'
            },
            bearerAuth: {
                type: 'http',
                scheme: 'bearer',
                bearerFormat: 'JWT',
                description:
                    'Access token issued by Legacy Auth to the Legacy Tracker app. Needed for the session-only endpoints that mint credentials.'
            }
        },
        schemas: {
            Error: errorSchema,
            MapboxToken: {
                type: 'object',
                required: ['token', 'expires_at'],
                properties: {
                    token: {
                        type: 'string',
                        description: 'Temporary Mapbox token (`tk.…`). Set it before creating the map.'
                    },
                    expires_at: {
                        type: 'string',
                        format: 'date-time',
                        description: 'When the token stops working. Renew before this.'
                    }
                }
            },
            Profile: {
                type: 'object',
                required: ['id', 'name', 'avatar_url', 'role'],
                properties: {
                    id: { type: 'string', format: 'uuid' },
                    name: { type: 'string' },
                    avatar_url: { type: 'string' },
                    role: { type: 'string', enum: ['user', 'admin'] }
                }
            },
            ProfileUpdate: {
                type: 'object',
                properties: {
                    name: { type: 'string', description: 'New display name.' },
                    avatar_url: { type: 'string', description: 'New avatar URL.' }
                }
            },
            RosterEntry: {
                type: 'object',
                required: ['user_id', 'username', 'sharing'],
                properties: {
                    user_id: { type: 'string', format: 'uuid' },
                    username: { type: 'string' },
                    sharing: {
                        type: 'boolean',
                        description: 'Whether this person shares their location with the caller.'
                    },
                    latitude: { type: 'number' },
                    longitude: { type: 'number' },
                    speed: { type: 'number', description: 'Metres per second.' },
                    heading: {
                        type: ['number', 'null'],
                        description: 'Degrees from north, or `null` when unknown.'
                    },
                    recorded_at: { type: 'string', format: 'date-time' },
                    here_since: {
                        type: 'string',
                        format: 'date-time',
                        description: 'When they arrived at their current place.'
                    },
                    battery_level: { type: 'integer', minimum: 0, maximum: 100 },
                    is_charging: { type: 'boolean' },
                    tracking_issues: {
                        type: 'array',
                        items: { type: 'string' },
                        description: 'Problems the phone reported, such as a missing permission.'
                    },
                    last_seen_at: { type: 'string', format: 'date-time' }
                }
            },
            StreamTicket: {
                type: 'object',
                required: ['ticket'],
                properties: {
                    ticket: { type: 'string', format: 'uuid' }
                }
            },
            LocationSample: {
                type: 'object',
                required: ['coords', 'timestamp'],
                properties: {
                    coords: {
                        type: 'object',
                        required: ['latitude', 'longitude'],
                        properties: {
                            latitude: { type: 'number', minimum: -90, maximum: 90 },
                            longitude: { type: 'number', minimum: -180, maximum: 180 },
                            speed: { type: 'number', description: 'Metres per second.' },
                            heading: {
                                type: ['number', 'null'],
                                description: 'Degrees from north.'
                            },
                            accuracy: { type: 'number', description: 'Horizontal accuracy in metres.' }
                        }
                    },
                    timestamp: {
                        type: 'string',
                        format: 'date-time',
                        description: 'When the fix was taken.'
                    },
                    source: {
                        type: 'string',
                        enum: ['trip_start', 'move', 'trip_end', 'ping', 'heartbeat', 'live'],
                        description: '`live` points are broadcast but never stored.'
                    },
                    battery_level: { type: 'integer', minimum: 0, maximum: 100 },
                    is_charging: { type: 'boolean' }
                }
            },
            LocationUploadResult: {
                type: 'object',
                required: ['received', 'stored', 'pacing', 'live_ttl_s'],
                properties: {
                    received: { type: 'integer' },
                    stored: { type: 'integer' },
                    pacing: {
                        type: 'string',
                        enum: ['PASSIVE', 'ACTIVE'],
                        description: 'How often the phone should keep reporting.'
                    },
                    live_ttl_s: {
                        type: 'integer',
                        description: 'Seconds to stay in realtime mode; `0` when nobody is watching.'
                    }
                }
            },
            HistoryPoint: {
                type: 'object',
                properties: {
                    latitude: { type: 'number' },
                    longitude: { type: 'number' },
                    speed: { type: 'number' },
                    heading: { type: ['number', 'null'] },
                    accuracy: { type: 'number' },
                    recorded_at: { type: 'string', format: 'date-time' }
                }
            },
            Trip: {
                type: 'object',
                properties: {
                    start_at: { type: 'string', format: 'date-time' },
                    end_at: { type: 'string', format: 'date-time' },
                    duration_seconds: { type: 'integer' },
                    distance_meters: { type: 'number' },
                    avg_speed: { type: 'number' },
                    top_speed: { type: 'number' },
                    point_count: { type: 'integer' },
                    points: {
                        type: 'array',
                        items: { $ref: '#/components/schemas/HistoryPoint' }
                    }
                }
            },
            HistoryResponse: {
                type: 'object',
                required: ['user_id', 'from', 'to', 'sessions'],
                properties: {
                    user_id: { type: 'string', format: 'uuid' },
                    from: { type: 'string', format: 'date-time' },
                    to: { type: 'string', format: 'date-time' },
                    sessions: {
                        type: 'array',
                        items: { $ref: '#/components/schemas/Trip' }
                    }
                }
            },
            LeaderboardEntry: {
                type: 'object',
                properties: {
                    user_id: { type: 'string', format: 'uuid' },
                    username: { type: 'string' },
                    rank: { type: 'integer' },
                    distance_meters: { type: 'number' },
                    duration_seconds: { type: 'integer' },
                    avg_speed: { type: 'number' },
                    top_speed: { type: 'number' },
                    trip_count: { type: 'integer' }
                }
            },
            LeaderboardResponse: {
                type: 'object',
                required: ['from', 'to', 'entries'],
                properties: {
                    from: { type: 'string', format: 'date-time' },
                    to: { type: 'string', format: 'date-time' },
                    entries: {
                        type: 'array',
                        items: { $ref: '#/components/schemas/LeaderboardEntry' }
                    }
                }
            },
            Checkpoint: {
                type: 'object',
                required: [
                    'id',
                    'name',
                    'latitude',
                    'longitude',
                    'radius_m',
                    'created_by',
                    'created_at',
                    'updated_at',
                    'can_edit'
                ],
                properties: {
                    id: { type: 'string', format: 'uuid' },
                    name: { type: 'string' },
                    latitude: { type: 'number' },
                    longitude: { type: 'number' },
                    radius_m: { type: 'integer', minimum: 10, maximum: 250 },
                    created_by: { type: 'string', format: 'uuid' },
                    created_at: { type: 'string', format: 'date-time' },
                    updated_at: { type: 'string', format: 'date-time' },
                    can_edit: {
                        type: 'boolean',
                        description: 'Whether the caller created it or is an admin.'
                    }
                }
            },
            CheckpointInput: {
                type: 'object',
                required: ['name', 'latitude', 'longitude', 'radius_m'],
                properties: {
                    name: {
                        type: 'string',
                        maxLength: 60,
                        description: 'Up to 60 characters, unique ignoring case.'
                    },
                    latitude: { type: 'number', minimum: -90, maximum: 90 },
                    longitude: { type: 'number', minimum: -180, maximum: 180 },
                    radius_m: { type: 'integer', minimum: 10, maximum: 250, description: 'Radius in metres.' }
                }
            },
            Sharing: {
                type: 'object',
                required: ['hidden_from'],
                properties: {
                    hidden_from: {
                        type: 'array',
                        items: { type: 'string', format: 'uuid' },
                        description: 'People who cannot see this caller’s location.'
                    }
                }
            },
            DeviceRegistration: {
                type: 'object',
                properties: {
                    platform: { type: 'string', enum: ['android', 'ios'] },
                    replaces: {
                        type: 'string',
                        description: 'A previous device id to revoke.'
                    }
                }
            },
            DeviceCredentials: {
                type: 'object',
                required: ['device_id', 'device_token'],
                properties: {
                    device_id: { type: 'string' },
                    device_token: { type: 'string' }
                }
            },
            AndroidRelease: {
                type: 'object',
                properties: {
                    version_code: { type: 'integer' },
                    version_name: { type: 'string' },
                    apk_url: { type: 'string', format: 'uri' },
                    sha256: { type: 'string' },
                    size: { type: 'integer' },
                    notes: { type: 'string' },
                    published_at: { type: 'string', format: 'date-time' },
                    min_supported_code: { type: 'integer' }
                }
            },
            ApiTokenSummary: {
                type: 'object',
                required: ['id', 'name', 'scope', 'token_hint', 'allowed_ips', 'created_at'],
                properties: {
                    id: { type: 'string', format: 'uuid' },
                    name: { type: 'string' },
                    scope: { type: 'string', enum: ['read', 'write'] },
                    token_hint: { type: 'string' },
                    allowed_ips: {
                        type: 'array',
                        items: { type: 'string' },
                        description:
                            'Addresses or CIDR prefixes allowed to use the token, as written by their owner. Empty means the token works from anywhere.'
                    },
                    created_at: { type: 'string', format: 'date-time' },
                    last_used_at: { type: ['string', 'null'], format: 'date-time' },
                    rotated_at: { type: ['string', 'null'], format: 'date-time' }
                }
            },
            CreatedApiToken: {
                allOf: [
                    { $ref: '#/components/schemas/ApiTokenSummary' },
                    {
                        type: 'object',
                        required: ['token'],
                        properties: {
                            token: {
                                type: 'string',
                                description: 'The secret. Returned only by this response.'
                            }
                        }
                    }
                ]
            },
            CreateApiToken: {
                type: 'object',
                required: ['scope'],
                properties: {
                    name: { type: 'string', maxLength: 60, description: 'A label.' },
                    scope: { type: 'string', enum: ['read', 'write'], description: 'What the token may do.' }
                }
            },
            UpdateApiToken: {
                type: 'object',
                required: ['allowed_ips'],
                properties: {
                    allowed_ips: {
                        type: 'array',
                        maxItems: 32,
                        items: { type: 'string', description: 'An IPv4 or IPv6 address, or `<address>/<prefix>`.' },
                        description: 'Replaces the list. An empty list means the token may be used from anywhere.'
                    }
                }
            }
        },
        responses: {
            BadRequest: errorResponse('The request is malformed; `error` says what is wrong.'),
            Unauthorized: errorResponse('Missing, invalid, rotated or deleted credentials.'),
            Forbidden: errorResponse(
                'The credential is valid but may not do this: a read-only token, a session-only endpoint, a person who hides from you (`not_sharing`), or an account without tracker access.'
            ),
            InternalError: errorResponse('Something broke on our side. Retry later.')
        }
    }
};
