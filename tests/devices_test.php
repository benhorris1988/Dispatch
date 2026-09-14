<?php
// Device registrations and push delivery (MOB-04).
//   php tests/devices_test.php [base=http://localhost:8090]
//
// Registers devices over HTTP as a team member, checks upsert, tenancy and unregister, then
// proves the honest half of push: with no sender configured, a queued delivery is marked
// `unconfigured` and names the missing key — it is never reported as sent. notify() in
// lib.php is exercised in-process against the admin connection to show a notification queues
// one push per active device, and cron_push.php is run as Task Scheduler would run it.
//
// Cleans up its own device rows: seed_demo.php does not wipe device_tokens or push_deliveries,
// and a token left behind would make the next re-seed fail on the users foreign key.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

require __DIR__ . '/../migration_connect.php';   // $conn (db_owner), CLI-only
require_once __DIR__ . '/../api/lib.php';
require_once __DIR__ . '/../api/engine/push_lib.php';
$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0;

function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }
function api($endpoint, array $body, $bearer = null) {
    global $BASE;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $h = ['Content-Type: application/json'];
    if ($bearer) $h[] = "Authorization: Bearer $bearer";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body),
        CURLOPT_HTTPHEADER => $h, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 60]);
    $raw = curl_exec($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    return [$code, json_decode($raw, true) ?? []];
}
function one($conn, $sql, $params = []) { $r = xrows($conn, $sql, $params); return $r ? (int)reset($r[0]) : 0; }
function ids(array $devices) { return array_map(fn($d) => (int)$d['id'], $devices); }

[, $users] = api('auth', ['action' => 'list_dev_users']);
$admin = null; $member = null;
foreach ($users['users'] ?? [] as $u) {
    if ($u['role'] === 'admin' && $admin === null) $admin = $u;
    if ($u['role'] === 'team_member' && $member === null) $member = $u;
}
if ($member === null) foreach ($users['users'] ?? [] as $u) if ($u['role'] === 'delivery_lead') { $member = $u; break; }
[, $a] = api('auth', ['action' => 'dev_login', 'user_id' => $admin['id']]);
$adminToken = $a['token'] ?? null;
[, $m] = api('auth', ['action' => 'dev_login', 'user_id' => $member['id']]);
$memberToken = $m['token'] ?? null;
check(!empty($adminToken) && !empty($memberToken), "signed in as admin and as {$member['display_name']} ({$member['role']})");
$memberId = (int)$member['id'];
$wsId = one($conn, "SELECT workspace_id FROM dbo.users WHERE id = ?", [$memberId]);

$T1 = 'test-android-' . bin2hex(random_bytes(48));
$T2 = 'test-ios-' . bin2hex(random_bytes(32));
$T3 = 'test-tenant-' . bin2hex(random_bytes(48));
$created = ['devices' => [], 'notifications' => [], 'users' => [], 'workspaces' => []];

// ---------------------------------------------------------------------------------------
section('Register, upsert, validate');
[$code, $r] = api('devices', ['action' => 'register', 'platform' => 'android', 'token' => $T1, 'device_label' => 'Pixel 8 (test)'], $memberToken);
check($code === 200 && ($r['created'] ?? null) === true, "register creates a device (HTTP $code)");
$d1 = $r['device']['id'] ?? null;
check($d1 !== null, 'and returns its id');
if ($d1 !== null) $created['devices'][] = (int)$d1;
check(($r['device']['platform'] ?? '') === 'android' && ($r['device']['device_label'] ?? '') === 'Pixel 8 (test)', 'with the platform and label given');
check(!str_contains(json_encode($r), $T1) && str_contains($r['device']['token_hint'] ?? '', '…'), 'the token is never returned whole, only a hint');
check(($r['device']['user_id'] ?? 0) === $memberId, 'and belongs to the signed-in user');
check(one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE entity = 'device_token' AND entity_id = ? AND action = 'create'", [$d1]) === 1, 'registration is audited');

[$code, $r] = api('devices', ['action' => 'register', 'platform' => 'android', 'token' => $T1, 'device_label' => 'Pixel 8 (renamed)'], $memberToken);
check($code === 200 && ($r['created'] ?? null) === false && ($r['device']['id'] ?? null) === $d1, 'registering the same token again upserts onto the same row');
check(($r['device']['device_label'] ?? '') === 'Pixel 8 (renamed)', 'and takes the new label');
check(one($conn, "SELECT COUNT(*) FROM dbo.device_tokens WHERE token = ?", [$T1]) === 1, 'so there is still exactly one row for that token');

[$code] = api('devices', ['action' => 'register', 'platform' => 'windows', 'token' => $T1], $memberToken);
check($code === 400, "an unknown platform is refused (HTTP $code)");
[$code] = api('devices', ['action' => 'register', 'platform' => 'ios', 'token' => 'short'], $memberToken);
check($code === 400, "a token that cannot be a registration token is refused (HTTP $code)");
[$code] = api('devices', ['action' => 'register', 'platform' => 'ios'], $memberToken);
check($code === 422, "a missing token is a 422 (HTTP $code)");
[$code] = api('devices', ['action' => 'register', 'platform' => 'ios', 'token' => $T2]);
check($code === 401, "no token, no registration (HTTP $code)");

[$code, $r] = api('devices', ['action' => 'register', 'platform' => 'ios', 'token' => $T2, 'device_label' => 'iPhone (test)'], $memberToken);
$d2 = $r['device']['id'] ?? null;
check($code === 200 && $d2 !== null, 'a second device registers');
if ($d2 !== null) $created['devices'][] = (int)$d2;

[$code, $r] = api('devices', ['action' => 'list'], $memberToken);
$mine = $r['devices'] ?? [];
check($code === 200 && in_array($d1, ids($mine), true) && in_array($d2, ids($mine), true), 'list shows both of my devices');
check(count(array_filter($mine, fn($d) => (int)$d['user_id'] !== $memberId)) === 0, "and nobody else's");
check(array_key_exists('configured', $r['push'] ?? []), 'and says whether the server has a push sender');
$serverConfigured = (bool)($r['push']['configured'] ?? false);

// ---------------------------------------------------------------------------------------
section('Who sees what');
[$code, $r] = api('devices', ['action' => 'list', 'all' => true], $adminToken);
$all = $r['devices'] ?? [];
$row1 = null; foreach ($all as $d) if ((int)$d['id'] === (int)$d1) $row1 = $d;
check($code === 200 && $row1 !== null, 'an admin listing the workspace sees the member\'s device');
check(($row1['user_name'] ?? null) === $member['display_name'], 'with the owner\'s name');
[, $r] = api('devices', ['action' => 'list'], $adminToken);
check(!in_array($d1, ids($r['devices'] ?? []), true), 'but an admin\'s own list is only their own devices');
[, $r] = api('devices', ['action' => 'list', 'all' => true], $memberToken);
check(count(array_filter($r['devices'] ?? [], fn($d) => (int)$d['user_id'] !== $memberId)) === 0, 'and all:true is ignored for a non-admin');

// ---------------------------------------------------------------------------------------
section('A queued push is marked unconfigured, with the reason, when there is no sender');
if ($serverConfigured) {
    echo "  ..   this server has a push sender configured; skipping the unconfigured-path checks\n";
} else {
    [$code, $r] = api('devices', ['action' => 'test_push'], $memberToken);
    check($code === 200 && ($r['queued'] ?? 0) === 2, "test_push queues one delivery per active device (HTTP $code, queued " . ($r['queued'] ?? '?') . ')');
    check(($r['result']['unconfigured'] ?? -1) === 2 && ($r['result']['sent'] ?? -1) === 0, 'and dispatch marks both unconfigured, none sent');
    $dels = $r['deliveries'] ?? [];
    check(count($dels) === 2, 'the two deliveries are returned');
    foreach ($dels as $d) {
        check(($d['status'] ?? '') === 'unconfigured', "delivery {$d['id']} ({$d['platform']}) is 'unconfigured'");
        check(str_contains((string)($d['last_status'] ?? ''), 'config.php'), "and last_status names the config key to set: \"{$d['last_status']}\"");
        check(($d['sent_at'] ?? null) === null, 'with no sent_at, because nothing was sent');
    }
    $ios = array_values(array_filter($dels, fn($d) => $d['platform'] === 'ios'));
    $android = array_values(array_filter($dels, fn($d) => $d['platform'] === 'android'));
    check($ios && str_contains($ios[0]['last_status'], 'apns'), 'the iOS delivery blames APNs');
    check($android && str_contains($android[0]['last_status'], 'fcm'), 'the Android delivery blames FCM');
    check(one($conn, "SELECT COUNT(*) FROM dbo.push_deliveries WHERE device_token_id IN (?, ?) AND status = 'sent'", [$d1, $d2]) === 0, 'and the table agrees: no row is sent');
    check(one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND entity = 'push' AND action = 'test'", [$wsId]) >= 1, 'the test push is audited');
    [$code, $r] = api('devices', ['action' => 'deliveries'], $memberToken);
    check($code === 200 && count($r['deliveries'] ?? []) >= 2, 'deliveries lists them for the owner');
}

// ---------------------------------------------------------------------------------------
section('notify() queues one push per active device (lib.php hook)');
$before = one($conn, "SELECT COUNT(*) FROM dbo.push_deliveries WHERE device_token_id IN (?, ?)", [$d1, $d2]);
$nid = notify($conn, $wsId, $memberId, 'item_assigned', 'Push hook test', 'A notification that should reach two devices.', '/items/WI-1042');
if ($nid !== null) $created['notifications'][] = (int)$nid;
check($nid !== null, 'notify() wrote the notification');
$queued = xrows($conn, "SELECT * FROM dbo.push_deliveries WHERE notification_id = ? ORDER BY id", [$nid]);
check(count($queued) === 2, 'and queued exactly two push deliveries for it');
check(count(array_filter($queued, fn($q) => $q['status'] === 'pending')) === 2, 'both pending until a dispatcher runs');
check(count(array_filter($queued, fn($q) => $q['link'] === '/items/WI-1042' && $q['title'] === 'Push hook test')) === 2, 'carrying the title and the deep link');
$rowIds = array_map(fn($q) => (int)$q['id'], $queued);

section('cron_push.php dispatches what is due');
exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../cron_push.php') . ' 2>&1', $cronOut, $cronRc);
$line = trim(implode("\n", $cronOut));
$json = json_decode(substr($line, strpos($line, '{') ?: 0), true);
check($cronRc === 0 && ($json['status'] ?? '') === 'ok', "cron_push.php runs and reports ok (exit $cronRc)");
if (!$serverConfigured) {
    check(isset($json['note']) && str_contains($json['note'], 'No push sender'), 'and says plainly that no sender is configured');
    $after = xrows($conn, "SELECT status, last_status FROM dbo.push_deliveries WHERE notification_id = ?", [$nid]);
    check(count(array_filter($after, fn($q) => $q['status'] === 'unconfigured')) === 2, 'the hook\'s two deliveries are now unconfigured');
    check(one($conn, "SELECT COUNT(*) FROM dbo.push_deliveries WHERE notification_id = ? AND status = 'sent'", [$nid]) === 0, 'and none is sent');
}
check(one($conn, "SELECT COUNT(*) FROM dbo.push_deliveries WHERE notification_id = ? AND status = 'pending'", [$nid]) === 0, 'nothing is left pending after a dispatch');

// ---------------------------------------------------------------------------------------
section('Tenancy: another workspace cannot see or touch these devices');
$ws2 = xid($conn, 'workspaces', ['name' => 'Tenancy test', 'time_zone' => 'Europe/London', 'working_days' => 'Mon,Tue,Wed,Thu,Fri', 'hours_per_day' => 7.5, 'currency' => 'GBP']);
$created['workspaces'][] = $ws2;
$u2 = xid($conn, 'users', ['workspace_id' => $ws2, 'email' => 'tenant-test@example.org', 'display_name' => 'Tenant Tester', 'role' => 'admin', 'active' => 1]);
$created['users'][] = $u2;
[, $l2] = api('auth', ['action' => 'dev_login', 'user_id' => $u2]);
$t2 = $l2['token'] ?? null;
check(!empty($t2), 'signed in as an admin of a second workspace');
[$code, $r] = api('devices', ['action' => 'register', 'platform' => 'android', 'token' => $T3, 'device_label' => 'Other tenant'], $t2);
$d3 = $r['device']['id'] ?? null;
check($code === 200 && $d3 !== null, 'they can register their own device');
if ($d3 !== null) $created['devices'][] = (int)$d3;
[, $r] = api('devices', ['action' => 'list', 'all' => true], $t2);
check(!in_array($d1, ids($r['devices'] ?? []), true) && !in_array($d2, ids($r['devices'] ?? []), true), 'their workspace listing has none of the first workspace\'s devices');
[, $r] = api('devices', ['action' => 'list', 'all' => true], $adminToken);
check(!in_array($d3, ids($r['devices'] ?? []), true), 'and the first workspace\'s admin cannot see theirs');
[$code] = api('devices', ['action' => 'unregister', 'token' => $T1], $t2);
check($code === 404, "an admin elsewhere cannot unregister a device in this workspace (HTTP $code)");
check(one($conn, "SELECT active FROM dbo.device_tokens WHERE id = ?", [$d1]) === 1, 'and it is still active');
[$code, $r] = api('devices', ['action' => 'test_push'], $t2);
check($code === 200 && ($r['queued'] ?? 0) === 1, 'their test push reaches only their device');
[, $r] = api('devices', ['action' => 'deliveries', 'all' => true], $adminToken);
check(count(array_filter($r['deliveries'] ?? [], fn($d) => (int)$d['device_token_id'] === (int)$d3)) === 0, 'and its deliveries are invisible to the first workspace');

// ---------------------------------------------------------------------------------------
section('Unregister');
[$code, $r] = api('devices', ['action' => 'unregister', 'token' => $T1], $memberToken);
check($code === 200 && ($r['device']['active'] ?? true) === false, "unregister deactivates (HTTP $code)");
check(one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE entity = 'device_token' AND entity_id = ? AND action = 'delete'", [$d1]) === 1, 'and is audited');
[$code] = api('devices', ['action' => 'unregister', 'token' => $T1], $memberToken);
check($code === 200, 'unregistering again is harmless');
check(one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE entity = 'device_token' AND entity_id = ? AND action = 'delete'", [$d1]) === 1, 'and not audited twice');
[$code] = api('devices', ['action' => 'unregister', 'token' => 'nothing-like-this-' . bin2hex(random_bytes(8))], $memberToken);
check($code === 404, "an unknown token is a 404 (HTTP $code)");
[$code, $r] = api('devices', ['action' => 'test_push'], $memberToken);
check($code === 200 && ($r['queued'] ?? 0) === 1, 'a test push now goes only to the device still registered');
[$code] = api('devices', ['action' => 'unregister', 'token' => $T2], $adminToken);
check($code === 200, 'an admin in the same workspace may unregister a member\'s device');
[$code] = api('devices', ['action' => 'test_push'], $memberToken);
check($code === 409, "with no active device a test push is refused with a reason (HTTP $code)");
$nid2 = notify($conn, $wsId, $memberId, 'item_assigned', 'After unregister', null, '/my-week');
if ($nid2 !== null) $created['notifications'][] = (int)$nid2;
check(one($conn, "SELECT COUNT(*) FROM dbo.push_deliveries WHERE notification_id = ?", [$nid2]) === 0, 'and notify() queues nothing to an unregistered device');

// ---------------------------------------------------------------------------------------
section('Clean up');
if ($created['devices']) {
    $in = implode(',', array_map('intval', $created['devices']));
    x($conn, "DELETE FROM dbo.push_deliveries WHERE device_token_id IN ($in)");
    x($conn, "DELETE FROM dbo.device_tokens WHERE id IN ($in)");
}
foreach ($created['notifications'] as $n) x($conn, "DELETE FROM dbo.notifications WHERE id = ?", [$n]);
foreach ($created['workspaces'] as $w) x($conn, "DELETE FROM dbo.audit_events WHERE workspace_id = ?", [$w]);
foreach ($created['users'] as $u) x($conn, "DELETE FROM dbo.users WHERE id = ?", [$u]);
foreach ($created['workspaces'] as $w) x($conn, "DELETE FROM dbo.workspaces WHERE id = ?", [$w]);
check(one($conn, "SELECT COUNT(*) FROM dbo.device_tokens WHERE token IN (?, ?, ?)", [$T1, $T2, $T3]) === 0, 'test devices removed');

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
