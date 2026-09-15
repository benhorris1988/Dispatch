<?php
// Mint an API token for a seeded account, for tests and local poking about. CLI only.
//
// Sign-in is Google (ADM-01), which a test suite cannot perform: it would need a real Google account
// and a browser. This script goes around the front door rather than weakening it — it talks to the
// database directly with the admin connection that seeding uses, and signs exactly the token auth.php
// would have issued. Nothing here is reachable over HTTP.
//
//   php tests\mint_token.php delivery_lead                 -> a token for the first delivery lead
//   php tests\mint_token.php priya.kaur@example.org        -> a token for that account
//   php tests\mint_token.php team_member --with-person     -> one whose account is linked to a person
//   php tests\mint_token.php viewer --create               -> make the account if nobody has that role
//   php tests\mint_token.php admin --json                  -> {"token": ..., "user": {...}}
//   php tests\mint_token.php --list                        -> every active account, as JSON
require __DIR__ . '/../migration_connect.php';
require_once __DIR__ . '/../api/lib.php';
require_once __DIR__ . '/../api/jwt_lib.php';

$args = array_slice($argv, 1);
$flags = array_values(array_filter($args, fn($a) => str_starts_with($a, '--')));
$who = array_values(array_filter($args, fn($a) => !str_starts_with($a, '--')))[0] ?? null;
$json = in_array('--json', $flags, true);
$withPerson = in_array('--with-person', $flags, true) ? true : (in_array('--without-person', $flags, true) ? false : null);
$create = in_array('--create', $flags, true);

$select = "SELECT u.id, u.workspace_id, u.email, u.display_name, u.short_name, u.role, u.person_id, u.auth_provider,
                  p.name AS person_name, p.initials, p.colour, p.role_title, t.name AS team_name
           FROM dbo.users u LEFT JOIN dbo.people p ON p.id = u.person_id LEFT JOIN dbo.teams t ON t.id = p.team_id
           WHERE u.active = 1";

if (in_array('--list', $flags, true)) {
    $rows = xrows($conn, "$select ORDER BY CASE u.role WHEN 'admin' THEN 0 WHEN 'delivery_lead' THEN 1 WHEN 'team_lead' THEN 2 ELSE 3 END, u.display_name");
    foreach ($rows as &$r) { $r['id'] = (int)$r['id']; $r['workspace_id'] = (int)$r['workspace_id']; $r['person_id'] = $r['person_id'] !== null ? (int)$r['person_id'] : null; }
    unset($r);
    echo json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
    exit(0);
}
if ($who === null) { fwrite(STDERR, "usage: php tests/mint_token.php <email|role> [--with-person|--without-person] [--create] [--json]\n       php tests/mint_token.php --list\n"); exit(2); }

if (strpos($who, '@') !== false) {
    $rows = xrows($conn, "$select AND LOWER(u.email) = ?", [strtolower($who)]);
} else {
    $sql = "$select AND u.role = ?";
    if ($withPerson === true) $sql .= " AND u.person_id IS NOT NULL";
    if ($withPerson === false) $sql .= " AND u.person_id IS NULL";
    $rows = xrows($conn, "$sql ORDER BY u.id", [$who]);
}
$u = $rows[0] ?? null;

if (!$u && $create) {
    $wsId = (int)(xrows($conn, "SELECT TOP 1 id FROM dbo.workspaces ORDER BY id")[0]['id'] ?? 0);
    if (!$wsId) { fwrite(STDERR, "no workspace — run seed_demo.php first\n"); exit(2); }
    $email = strpos($who, '@') !== false ? strtolower($who) : strtolower($who) . '@test.local';
    $role = strpos($who, '@') !== false ? 'team_member' : $who;
    $id = xid($conn, 'users', ['workspace_id' => $wsId, 'email' => $email, 'display_name' => 'Test ' . str_replace('_', ' ', $role),
        'short_name' => 'Test', 'role' => $role, 'person_id' => null, 'active' => 1, 'auth_provider' => 'test']);
    $rows = xrows($conn, "$select AND u.id = ?", [$id]);
    $u = $rows[0] ?? null;
}
if (!$u) { fwrite(STDERR, "no active account matching '$who'" . ($withPerson === null ? '' : ($withPerson ? ' with a linked person' : ' without a linked person')) . "\n"); exit(2); }

$u['id'] = (int)$u['id'];
$u['workspace_id'] = (int)$u['workspace_id'];
$u['person_id'] = $u['person_id'] !== null ? (int)$u['person_id'] : null;
$token = issue_token($u);
if ($json) echo json_encode(['token' => $token, 'user' => $u], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
else echo $token, "\n";
