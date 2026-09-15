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

    // Sign-in (ADM-01). There are no local passwords and no development sign-in: an account exists
    // because somebody signed in with an identity listed here. Accounts are created on first sign-in.
    //
    // Google: create an OAuth client per platform in the Google Cloud console and list every client
    // id here. THE WEB CLIENT ID MUST COME FIRST — the browser needs it to start the flow, and the
    // Android and iOS apps send it as their server client id so the token they obtain is addressed to
    // the same audience this API verifies. Any of the ids is accepted as the audience of a token.
    'google' => [
        'client_ids'    => [
            // '000000000000-web.apps.googleusercontent.com',       // Web application  (first: also the apps' server client id)
            // '000000000000-android.apps.googleusercontent.com',   // Android (package name + signing SHA-1)
            // '000000000000-ios.apps.googleusercontent.com',       // iOS (bundle id; also goes in Info.plist as GIDClientID)
        ],
        'hosted_domain' => '',   // e.g. 'example.org' to accept only that Workspace domain; '' = any Google account
        'workspace_id'  => 1,    // the workspace new accounts join
    ],

    // Lower-case emails that become administrators the first time they sign in (and are promoted on
    // their next sign-in if the account already exists). Without at least one of these, the first
    // person through the door arrives as a team member and nobody can grant anybody a role.
    'bootstrap_admins' => [
        // 'you@example.org',
    ],

    // Entra ID (OIDC) — not in use yet. The verifier and the group-to-role mapping are built and
    // tested; setting tenant_id and client_id turns on the 'Sign in with Microsoft' button and the
    // auth.php action 'oidc_login'.
    'entra' => [
        'tenant_id'    => '',
        'client_id'    => '',
        'workspace_id' => 1,
        'group_roles'  => [], // ['<group-object-id>' => 'delivery_lead', ...]
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
