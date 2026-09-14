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

    // Optional shared secret letting a scheduler call replan.php run_nightly / digest.php send
    // over HTTP instead of the CLI wrappers (cron.php, cron_digest.php).
    // 'cron_key' => '',

    // Outbound mail (NOT-02 email channel, NOT-04 weekly digest) — ALL optional. With neither
    // block set there is no mail transport: the weekly digest is delivered in-app as a
    // notification of kind `digest`, and the API says so rather than claiming an email went out.
    // 'smtp' => [
    //     'host'      => 'smtp.office365.com',   // setting host selects SMTP
    //     'port'      => 587,
    //     'secure'    => 'tls',                  // tls (STARTTLS) | ssl | none; defaults from the port
    //     'user'      => 'dispatch@example.org', // omit for an unauthenticated relay
    //     'pass'      => 'CHANGE_ME',
    //     'from'      => 'dispatch@example.org',
    //     'from_name' => 'Dispatch',
    //     'timeout'   => 15,
    // ],
    // 'mail' => ['php_mail' => true, 'from' => 'dispatch@example.org'],   // or PHP's mail() via php.ini sendmail_path / SMTP

    // Push notifications (MOB-04) - optional. Devices register through devices.php whether
    // or not a sender exists; without one, queued deliveries are marked `unconfigured` with
    // the missing key named in last_status, and nothing is ever reported as sent.
    // Dispatched by cron_push.php (Task Scheduler, every minute).
    'push' => [
        // Android and web: a Firebase service-account JSON file (Project settings > Service
        // accounts > Generate new private key). The path, or the JSON string itself.
        'fcm_service_account_json' => '',
        // iOS: an APNs authentication key (.p8) with its key id and your team id.
        'apns_key_file'  => '',
        'apns_key_id'    => '',
        'apns_team_id'   => '',
        'apns_bundle_id' => 'uk.co.dispatch.app',
        'apns_sandbox'   => true,      // development builds use the sandbox gateway
        // Where a web push opens: the hosted web build, e.g. https://dispatch.example.org/mobile/build/web
        'web_base_url'   => '',
    ],
];
