<?php
// Sign-in for the test suites (ADM-01). There is no development sign-in any more — the only way in
// through the front door is Google, which a suite cannot do — so tests mint their own tokens with
// tests/mint_token.php, which reaches the database directly and is CLI-only.
//
// Set DISPATCH_TEST_TOKEN_ADMIN, _DELIVERY_LEAD, _TEAM_LEAD, _TEAM_MEMBER … to skip the minting and
// use a token you already have (useful when the suites run somewhere the database is not).
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

/** Every active account, as mint_token.php --list reports them. Cached for the run. */
function test_users() {
    static $users = null;
    if ($users !== null) return $users;
    $raw = getenv('DISPATCH_TEST_USERS_JSON');
    if (!$raw) $raw = (string)shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/mint_token.php') . ' --list');
    $j = json_decode(trim($raw), true);
    $users = is_array($j) ? $j : [];
    return $users;
}

/** The first active account with this role, optionally one that is (or is not) linked to a person. */
function user_for($role, $withPerson = null) {
    foreach (test_users() as $u) {
        if ($u['role'] !== $role) continue;
        if ($withPerson !== null && ($u['person_id'] !== null) !== $withPerson) continue;
        return $u;
    }
    return null;
}

function user_for_email($email) {
    foreach (test_users() as $u) if (strcasecmp($u['email'], $email) === 0) return $u;
    return null;
}

/** A token for the first account with this role, or null if there is none. */
function token_for($role, $withPerson = null) {
    $env = getenv('DISPATCH_TEST_TOKEN_' . strtoupper($role));
    if ($env && $withPerson === null) return $env;
    $u = user_for($role, $withPerson);
    return $u ? token_for_email($u['email']) : null;
}

function token_for_email($email) {
    static $cache = [];
    $key = strtolower($email);
    if (isset($cache[$key])) return $cache[$key];
    $out = trim((string)shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/mint_token.php') . ' ' . escapeshellarg($email)));
    // A JWT and nothing else: anything the script printed to stdout by accident would be a confusing
    // 401 three assertions later.
    $cache[$key] = preg_match('/^[\w-]+\.[\w-]+\.[\w-]+$/', $out) ? $out : null;
    return $cache[$key];
}

/**
 * The account a suite should use as "an ordinary member": linked to a person so my_week and profile
 * endpoints have something to answer with.
 */
function token_for_member() { return token_for('team_member', true); }
