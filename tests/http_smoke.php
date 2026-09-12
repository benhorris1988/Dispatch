<?php
// End-to-end HTTP tests for the plan lifecycle: propose -> review -> commit, plus the
// schedule view, what-if preview and the role boundaries around them.
//   php tests/http_smoke.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php).
// Re-seed afterwards: this commits plan versions and decides the open proposal.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr((string)$raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }
function login($role) {
    global $token;
    $token = null;
    [, $users] = api('auth', ['action' => 'list_dev_users']);
    foreach ($users['users'] ?? [] as $u) if ($u['role'] === $role) {
        [, $r] = api('auth', ['action' => 'dev_login', 'user_id' => $u['id']]);
        $token = $r['token'] ?? null;
        return $u;
    }
    return null;
}

section('Sign in as the delivery lead');
$lead = login('delivery_lead');
check($lead !== null, 'a delivery_lead dev user exists');
check(!empty($token), 'dev_login returns a token');
[, $me] = api('auth', ['action' => 'me']);
check(($me['user']['role'] ?? '') === 'delivery_lead', 'me reports the delivery lead role');

section('Schedule view (VIEW-01..03, SCH-09)');
[, $sch] = api('plan', ['action' => 'schedule']);
check(!empty($sch['people']), 'schedule returns lanes (' . count($sch['people'] ?? []) . ' people)');
check(!empty($sch['assignments']), 'schedule returns assignments (' . count($sch['assignments'] ?? []) . ')');
check(!empty($sch['weeks']), 'schedule returns week columns (' . count($sch['weeks'] ?? []) . ')');
$w = $sch['windows'] ?? [];
check(!empty($w['today']) && !empty($w['freeze_end']), 'schedule reports the plan windows');
check(($w['freeze_end'] ?? '') > ($w['today'] ?? ''), 'the freeze horizon ends after today');
$states = array_values(array_unique(array_map(fn($a) => $a['state'] ?? '?', $sch['assignments'] ?? [])));
check(empty(array_diff($states, ['committed', 'planned', 'indicative'])), 'every assignment is committed, planned or indicative (' . implode(',', $states) . ')');
// Certainty must decrease with distance: nothing committed may start after the freeze end.
$badState = 0;
foreach ($sch['assignments'] ?? [] as $a) if (($a['state'] ?? '') === 'committed' && ($a['from_date'] ?? '') > ($w['freeze_end'] ?? '9999')) $badState++;
check($badState === 0, 'nothing outside the freeze horizon is labelled committed');
$loads = array_filter(array_map(fn($p) => $p['load_pct'] ?? null, $sch['people'] ?? []), fn($x) => $x !== null);
check(count($loads) === count($sch['people'] ?? []), 'every lane header carries a load percentage');

section('Lock state drives the header pill');
[, $lock] = api('plan', ['action' => 'lock_state']);
check(!empty($lock['committed_through']), 'lock_state reports how far the plan is committed (' . ($lock['committed_through'] ?? '-') . ')');

section('What-if preview returns inside the interactive budget (SCH-08)');
$t0 = microtime(true);
[, $prev] = api('replan', ['action' => 'preview', 'changes' => []]);
$previewSeconds = microtime(true) - $t0;
check(isset($prev['summary_after']), 'preview returns a before-and-after summary');
printf("  ..   preview round trip %.2fs\n", $previewSeconds);
check($previewSeconds < 5.0, sprintf('preview is interactive (%.2fs including HTTP)', $previewSeconds));

section('Watch list (SCH-05)');
[, $watch] = api('replan', ['action' => 'watch_list']);
check(is_array($watch['items'] ?? null), 'watch list returns items (' . count($watch['items'] ?? []) . ')');

section('The open nightly proposal (CHG-01..04)');
[, $cur] = api('changes', ['action' => 'current']);
$proposal = $cur['proposal'] ?? null;
check($proposal !== null, 'there is a proposal to review');
check(!empty($cur['changes']) || !empty($cur['held']), 'it carries changes (' . count($cur['changes'] ?? []) . ' open, ' . count($cur['held'] ?? []) . ' held)');
$allChanges = array_merge($cur['changes'] ?? [], $cur['held'] ?? []);
foreach (array_slice($allChanges, 0, 3) as $c) {
    check(!empty($c['headline']), 'a change states what moves: ' . substr($c['headline'] ?? '', 0, 50));
    check(!empty($c['reason']), 'and why');
    check(array_key_exists('stability_cost_days', $c), 'and what it costs in stability');
}
$guardrails = array_values(array_unique(array_map(fn($c) => $c['guardrail_status'] ?? '?', $allChanges)));
check(empty(array_diff($guardrails, ['ok', 'needs_approval', 'held_budget', 'held_threshold'])), 'guardrail statuses are all known (' . implode(',', $guardrails) . ')');
$before = $proposal['summary_before'] ?? []; $after = $proposal['summary_after'] ?? [];
check(!empty($before) && !empty($after), 'the proposal summarises before and after');
foreach (['late_items', 'people_over_100', 'stability_index'] as $k) {
    check(array_key_exists($k, $before), "before-and-after reports $k");
}
$budget = $proposal['budget'] ?? [];
check(isset($budget['limit']), 'the change budget is shown (' . ($budget['used'] ?? '?') . ' of ' . ($budget['limit'] ?? '?') . ')');

section('Guardrails cannot be bypassed (CHG-03, STAB-01)');
$held = null; $needsApproval = null; $clean = null;
foreach ($allChanges as $c) {
    $g = $c['guardrail_status'] ?? '';
    if ($g === 'needs_approval' && $needsApproval === null) $needsApproval = $c;
    if (in_array($g, ['held_budget', 'held_threshold'], true) && $held === null) $held = $c;
    if ($g === 'ok' && ($c['decision'] ?? 'pending') === 'pending' && $clean === null) $clean = $c;
}
if ($needsApproval) {
    [$code] = api('changes', ['action' => 'decide', 'change_id' => $needsApproval['id'], 'decision' => 'accepted'], null);
    check($code === 409 || $code === 422 || $code === 400, "accepting inside the freeze horizon without a reason is refused (HTTP $code)");
    [$code2] = api('changes', ['action' => 'decide', 'change_id' => $needsApproval['id'], 'decision' => 'accepted', 'reason' => 'Agreed with Amira at stand-up'], null);
    check($code2 === 200, "the same change is accepted with a named reason (HTTP $code2)");
} else {
    echo "  ..   no change needed approval in this proposal\n";
}
if ($held) {
    [$code3] = api('changes', ['action' => 'decide', 'change_id' => $held['id'], 'decision' => 'accepted', 'reason' => 'Trying to force it through'], null);
    check($code3 === 409 || $code3 === 403, "a guardrail-held change cannot be accepted by a delivery lead (HTTP $code3)");
} else {
    echo "  ..   no change was held by a guardrail in this proposal\n";
}

section('Accepting and committing creates a new plan version (CHG-05)');
[, $vs] = api('plan', ['action' => 'versions']);
$countBefore = count($vs['versions'] ?? []);
$committedBefore = null;
foreach ($vs['versions'] ?? [] as $v) if (($v['status'] ?? '') === 'committed') $committedBefore = $v['id'] ?? null;
check($committedBefore !== null, "a committed version exists before the commit (id $committedBefore)");

if ($clean) {
    [, $d] = api('changes', ['action' => 'decide', 'change_id' => $clean['id'], 'decision' => 'accepted']);
    check(($d['status'] ?? '') === 'ok', 'a guardrail-passing change is accepted');
}
[$cc, $commit] = api('changes', ['action' => 'commit', 'proposal_id' => $proposal['id']], null);
check($cc === 200, "commit succeeds (HTTP $cc)" . ($cc !== 200 ? ' :: ' . ($commit['message'] ?? '') : ''));

[, $vs2] = api('plan', ['action' => 'versions']);
$committedAfter = null;
foreach ($vs2['versions'] ?? [] as $v) if (($v['status'] ?? '') === 'committed') $committedAfter = $v['id'] ?? null;
check($committedAfter !== null, 'a committed version still exists after the commit');
check(count($vs2['versions'] ?? []) >= $countBefore, 'the previous version is retained, not overwritten (CHG-05)');
$superseded = array_values(array_filter($vs2['versions'] ?? [], fn($v) => ($v['status'] ?? '') === 'superseded'));
check(!empty($superseded), 'the superseded version remains viewable (' . count($superseded) . ')');

section('Proposing a replan (SCH-03)');
$t0 = microtime(true);
[, $prop] = api('replan', ['action' => 'propose', 'kind' => 'manual']);
$proposeSeconds = microtime(true) - $t0;
printf("  ..   propose round trip %.2fs\n", $proposeSeconds);
check(!empty($prop['proposal_id']), 'propose stores a proposal (id ' . ($prop['proposal_id'] ?? '-') . ')');
check(array_key_exists('improvement_pct', $prop), 'and reports the improvement it found');
check(is_array($prop['summary_after'] ?? null), 'and a resulting summary');
// The engine proposes; it must never have moved the committed plan itself.
[, $vs3] = api('plan', ['action' => 'versions']);
$committedNow = null;
foreach ($vs3['versions'] ?? [] as $v) if (($v['status'] ?? '') === 'committed') $committedNow = $v['id'] ?? null;
check($committedNow === $committedAfter, 'proposing did not change the committed plan (SCH-03)');

section('Role boundaries (ADM-02)');
$member = login('team_member');
check($member !== null, 'a team_member dev user exists');
[$rc] = api('replan', ['action' => 'propose', 'kind' => 'manual'], null);
check($rc === 403, "a team member cannot propose a replan (HTTP $rc)");
[, $mine] = api('changes', ['action' => 'mine']);
check(is_array($mine['changes'] ?? null), 'a team member can see the changes affecting them (' . count($mine['changes'] ?? []) . ')');
[, $myWeek] = api('overview', ['action' => 'my_week']);
check(isset($myWeek['week']['days']) && count($myWeek['week']['days']) >= 5, 'and their own week (' . count($myWeek['week']['days'] ?? []) . ' days)');

$token = null;
[$uc] = api('plan', ['action' => 'schedule'], null);
check($uc === 401, "an unauthenticated request is refused (HTTP $uc)");

echo "\n$pass passed, $fail failed\n";
echo "Re-seed before using the demo again: php seed_demo.php\n";
exit($fail ? 1 : 0);
