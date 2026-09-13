<?php
// Data retention (ADM-05, NFR-DATA-02).
//   php tests/retention_test.php [base=http://localhost:8090]
//
// The demo has no data old enough to purge, so this backdates rows itself through the
// admin connection, runs the purge over HTTP, and asserts both halves of the contract:
// what goes, and — more importantly — what must not.
// Re-seed afterwards: this rewrites timestamps and deletes plan history.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

require __DIR__ . '/../migration_connect.php';   // $conn (db_owner), CLI-only
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

// Earlier suites in run_all.php commit plans and create work, and this one asserts exact
// counts to prove a purge leaves work, people and value alone. Seed first so it is testing
// retention rather than whatever the previous suite happened to leave behind.
echo "  ..   seeding a known state
";
exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../seed_demo.php') . ' 2>&1', $seedOut, $seedRc);
if ($seedRc !== 0) { fwrite(STDERR, "seed failed:
" . implode("
", array_slice($seedOut, -5)) . "
"); exit(2); }

[, $users] = api('auth', ['action' => 'list_dev_users']);
$admin = null; $lead = null;
foreach ($users['users'] ?? [] as $u) {
    if ($u['role'] === 'admin' && $admin === null) $admin = $u;
    if ($u['role'] === 'delivery_lead' && $lead === null) $lead = $u;
}
[, $a] = api('auth', ['action' => 'dev_login', 'user_id' => $admin['id']]);
$adminToken = $a['token'] ?? null;
[, $l] = api('auth', ['action' => 'dev_login', 'user_id' => $lead['id']]);
$leadToken = $l['token'] ?? null;
check(!empty($adminToken) && !empty($leadToken), 'signed in as admin and delivery lead');

$wsId = one($conn, "SELECT TOP 1 id FROM dbo.workspaces ORDER BY id");

section('The policy is readable and configurable (ADM-05)');
[$code, $g] = api('retention', ['action' => 'get'], $adminToken);
check($code === 200, "retention get responds (HTTP $code)");
check(($g['policy']['plan_history_months'] ?? 0) === 24, 'plan history defaults to 24 months (NFR-DATA-02)');
check(($g['policy']['audit_retention_years'] ?? 0) === 7, 'the audit trail defaults to 7 years (NFR-DATA-02)');

[$code] = api('retention', ['action' => 'save', 'plan_history_months' => 0], $adminToken);
check($code === 422, "a nonsensical period is refused (HTTP $code)");
[$code] = api('retention', ['action' => 'save', 'plan_history_months' => 6, 'audit_retention_years' => 3], $leadToken);
check($code === 403, "a delivery lead cannot change retention (HTTP $code)");
[$code, $saved] = api('retention', ['action' => 'save', 'plan_history_months' => 6, 'audit_retention_years' => 3], $adminToken);
check($code === 200 && ($saved['policy']['plan_history_months'] ?? 0) === 6, 'an admin can change it, and it is configurable');
check(one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND entity = 'retention'", [$wsId]) > 0, 'and the change is audited');

section('Nothing is purged while nothing is old enough');
[, $p0] = api('retention', ['action' => 'preview'], $adminToken);
check((int)($p0['plan_versions'] ?? -1) === 0, 'the seeded demo has no plan history past the policy');
$before = one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE workspace_id = ?", [$wsId]);
[, $r0] = api('retention', ['action' => 'purge', 'confirm' => true], $adminToken);
check(one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE workspace_id = ?", [$wsId]) === $before, 'a purge with nothing to do removes nothing');

section('Old plan history is purged, and the plan in use is not');
// Backdate every superseded version well past the policy.
x($conn, "UPDATE dbo.plan_versions SET generated_at = DATEADD(month, -18, generated_at) WHERE workspace_id = ? AND status = 'superseded'", [$wsId]);
$committedId = one($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed'", [$wsId]);
// Backdate the committed one too: age must not be enough to remove the plan people work to.
x($conn, "UPDATE dbo.plan_versions SET generated_at = DATEADD(month, -30, generated_at) WHERE id = ?", [$committedId]);
$newestSuperseded = one($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'superseded' ORDER BY id DESC", [$wsId]);
$supersededBefore = one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'superseded'", [$wsId]);
check($supersededBefore >= 2, "the demo has superseded history to work with ($supersededBefore)");

[, $prev] = api('retention', ['action' => 'preview'], $adminToken);
check(($prev['plan_versions'] ?? 0) > 0, 'the preview now finds history past the policy (' . ($prev['plan_versions'] ?? 0) . ')');
check(!in_array($committedId, $prev['plan_version_ids'] ?? [], true), 'the committed plan is never listed for purging, whatever its age');
check(!in_array($newestSuperseded, $prev['plan_version_ids'] ?? [], true), 'nor is the most recent superseded version, which is the fallback');
$countBeforePreview = one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE workspace_id = ?", [$wsId]);
check($countBeforePreview === $before, 'and a preview removes nothing');

[$code] = api('retention', ['action' => 'purge'], $adminToken);
check($code === 422, "a purge without confirmation is refused (HTTP $code)");

$assignmentsBefore = one($conn, "SELECT COUNT(*) FROM dbo.assignments WHERE plan_version_id IN (SELECT id FROM dbo.plan_versions WHERE workspace_id = ?)", [$wsId]);
[$code, $purged] = api('retention', ['action' => 'purge', 'confirm' => true], $adminToken);
check($code === 200, "the purge runs (HTTP $code)");
check(($purged['removed']['plan_versions'] ?? 0) > 0, 'and removed plan versions (' . ($purged['removed']['plan_versions'] ?? 0) . ')');
check(one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE id = ?", [$committedId]) === 1, 'the committed plan survived');
check(one($conn, "SELECT COUNT(*) FROM dbo.plan_versions WHERE id = ?", [$newestSuperseded]) === 1, 'the most recent superseded version survived');
check(one($conn, "SELECT COUNT(*) FROM dbo.assignments WHERE plan_version_id = ?", [$committedId]) > 0, "and the committed plan's assignments are intact");
$orphans = one($conn, "SELECT COUNT(*) FROM dbo.assignments a WHERE NOT EXISTS (SELECT 1 FROM dbo.plan_versions pv WHERE pv.id = a.plan_version_id)");
check($orphans === 0, 'no assignment was orphaned by the purge');

section('Work, people and value are never touched — this removes history, not the record');
check(one($conn, "SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id = ?", [$wsId]) === 88, 'every work item is still there');
check(one($conn, "SELECT COUNT(*) FROM dbo.people WHERE workspace_id = ?", [$wsId]) === 8, 'every person is still there');
check(one($conn, "SELECT COUNT(*) FROM dbo.benefits WHERE workspace_id = ?", [$wsId]) === 31, 'every benefit is still there');
check(one($conn, "SELECT COUNT(*) FROM dbo.estimates e JOIN dbo.work_items w ON w.id = e.work_item_id WHERE w.workspace_id = ?", [$wsId]) > 0, 'estimates are still there');

section('The audit trail is trimmed on its own, much slower, clock (NFR-DATA-02)');
$auditBefore = one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ?", [$wsId]);
// Age half the audit trail past the 3-year period set above.
x($conn, "UPDATE dbo.audit_events SET occurred_at = DATEADD(year, -5, occurred_at) WHERE workspace_id = ? AND id % 2 = 0", [$wsId]);
$expired = one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND occurred_at < DATEADD(year, -3, GETDATE())", [$wsId]);
check($expired > 0, "there are audit rows past the period ($expired)");
[, $p2] = api('retention', ['action' => 'preview'], $adminToken);
check(($p2['audit_events'] ?? 0) > 0, 'the preview finds them');
[, $r2] = api('retention', ['action' => 'purge', 'confirm' => true], $adminToken);
check(($r2['removed']['audit_events'] ?? 0) > 0, 'the purge removes them (' . ($r2['removed']['audit_events'] ?? 0) . ')');
$auditAfter = one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ?", [$wsId]);
check($auditAfter < $auditBefore, 'the trail is shorter than it was');
$evidence = one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND action = 'purge'", [$wsId]);
check($evidence > 0, 'and the purge recorded itself in the trail it trimmed, so there is evidence it happened');
$recentGone = one($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND occurred_at >= DATEADD(year, -3, GETDATE())", [$wsId]);
check($recentGone > 0, 'recent audit rows are untouched');

section('Restore');
echo "  ..   re-seeding\n";
exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../seed_demo.php') . ' 2>&1', $out, $rc);
check($rc === 0, 'the demo re-seeds cleanly after a purge');
x($conn, "UPDATE dbo.workspaces SET plan_history_months = 24, audit_retention_years = 7 WHERE id = ?", [$wsId]);

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
