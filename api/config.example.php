<?php
// Copy to config.php (gitignored) and fill in real values.
return [
    // HS256 signing secret for API JWTs: php -r "echo bin2hex(random_bytes(48));"
    'jwt_secret' => 'CHANGE_ME',
    'app_timezone' => 'Europe/London',
    // Optional: pin the planner's "today" (YYYY-MM-DD) for demos/tests. Omit for live use.
    // 'fake_today' => '2026-09-08',

    // Runtime SQL Server connection (least-privilege dispatch_app login).
    'db' => [
        'server'   => 'localhost\LIVE',
        'database' => 'DispatchDB',
        'uid'      => 'dispatch_app',
        'pwd'      => 'CHANGE_ME',
    ],
    // Admin connection for migrations / seeding (db_owner). CLI only.
    'db_admin' => [
        'server'   => 'localhost\LIVE',
        'database' => 'DispatchDB',
        'uid'      => 'dispatch_admin',
        'pwd'      => 'CHANGE_ME',
    ],

    // Dev sign-in. Production uses Entra ID (OIDC); locally any seeded user can be
    // picked from the sign-in screen while this is true. Set false to disable.
    'dev_login_enabled' => true,

    // Entra ID (OIDC) — optional. When tenant_id/client_id are set, auth.php action
    // 'oidc_login' accepts an ID token, verifies it against the tenant JWKS and maps
    // group claims to roles via 'group_roles'.
    'entra' => [
        'tenant_id'   => '',
        'client_id'   => '',
        'group_roles' => [], // ['<group-object-id>' => 'delivery_lead', ...]
    ],

    // Optional CP-SAT scheduling engine (engine/ — Python + OR-Tools). Empty = the
    // built-in PHP heuristic planner is used for every cycle.
    'engine_url' => 'http://127.0.0.1:8010',
    'engine_timeout_seconds' => 70,
];
