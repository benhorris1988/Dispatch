<?php
// CLI HTTP tests for resource_requests.php and engine/requests_lib.php (the demand side).
//   php tests/resource_requests_test.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php). Re-seed after
// running: the suite raises work items, approves requests and therefore commits plan versions.
//
// The authority rule under test is the one that matters: a request for somebody's time is decided
// by a lead ABOVE THAT PERSON, not by whoever happens to be a team lead. Sam Doyle leads Analytics
// engineering and must not be able to book Hana Novak, who sits in Platform engineering; Lena
// Torres (Hana's lead) and Priya Kaur (the lead above Lena) both must.
require_once __DIR__ . '/_auth.php';

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 90]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr($raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function near($a, $b, $tol, $label) { check(abs((float)$a - (float)$b) <= $tol, "$label (got " . var_export($a, true) . ", want ~$b +/-$tol)"); }
function section($t) { echo "\n== $t\n"; }
function login($email) { global $token; $token = token_for_email($email); return $token; }

const REQUESTER = 'procurement.requests@example.org';
const LENA      = 'lena.torres@example.org';      // leads Platform engineering (Hana, Jon)
const PRIYA     = 'priya.kaur@example.org';       // leads Data Platform, the team above Lena's
const SAM       = 'sam.doyle@example.org';        // leads Analytics engineering — a different branch
const HANA      = 'hana.novak@example.org';       // the person being asked for

section('accounts and people');
foreach ([REQUESTER, LENA, PRIYA, SAM, HANA] as $e) check(user_for_email($e) !== null, "account exists: $e");
check(login(REQUESTER) !== null, 'a token for the requester');

[, $P] = api('people', ['action' => 'list']);
$people = [];
foreach ($P['people'] as $p) $people[$p['name']] = $p;
check(isset($people['Hana Novak'], $people['Priya Kaur'], $people['Amira Mansour']), 'the demo people are present');
$hana = (int)$people['Hana Novak']['id'];
$priyaP = (int)$people['Priya Kaur']['id'];
check($people['Hana Novak']['team_name'] === 'Platform engineering', 'Hana sits in Platform engineering');

// ---------------------------------------------------------------------------------------------
section('the span: hours become dates against that person own capacity');
// Priya works Mon-Thu full and a half day on Friday (3.75h). Minus the 12% incident reserve that
// is 3.3 schedulable hours on a Friday and 6.6 on a Monday. 7.5 hours from Friday 11 September
// therefore lands on Friday AND Monday — the weekend is not a zero-hour working day, it is not a
// day at all — and the allocation is whatever books 7.5 hours across those two, not 100%.
$item = null;
[, $WI] = api('work_items', ['action' => 'list', 'status' => 'ready']);
foreach ($WI['items'] as $i) if ($i['ref'] === 'WI-1046') $item = $i;
check($item !== null, 'WI-1046 (Data quality scorecard) is ready and unscheduled');

login(PRIYA);   // a team lead may ask for anyone; the requester may only ask on their own work
[, $S] = api('resource_requests', ['action' => 'preview', 'work_item_id' => $item['id'], 'person_id' => $priyaP, 'hours' => 7.5, 'from_date' => '2026-09-11']);
check($S['span']['from'] === '2026-09-11' && $S['span']['to'] === '2026-09-14', "7.5h from Friday spans Fri 11 to Mon 14 (got {$S['span']['from']}..{$S['span']['to']})");
check(count($S['span']['days']) === 2, 'two working days, the weekend skipped entirely');
near($S['span']['days'][0]['schedulable'], 3.3, 0.01, 'Friday is a half day minus reserve');
near($S['span']['days'][1]['schedulable'], 6.6, 0.01, 'Monday is a full day minus reserve');
near($S['span']['schedulable_hours'], 9.9, 0.01, 'schedulable across the span');
check($S['span']['allocation_pct'] === 76, "allocation is derived, not assumed ({$S['span']['allocation_pct']}%)");
near($S['span']['booked_hours'], 7.5, 0.2, 'a request for 7.5 hours books 7.5 hours, not two whole days');
check($S['inside_freeze'] === true && $S['freeze_end'] === '2026-09-22', 'that window is inside the freeze horizon');

// With an end date given, the allocation is what fits the hours into it instead.
[, $S2] = api('resource_requests', ['action' => 'preview', 'work_item_id' => $item['id'], 'person_id' => $priyaP, 'hours' => 7.5, 'from_date' => '2026-09-14', 'to_date' => '2026-09-18']);
check($S2['span']['to'] === '2026-09-18', 'an end date is honoured');
check($S2['span']['allocation_pct'] < 76, "a longer window means a smaller share of each day ({$S2['span']['allocation_pct']}%)");
near($S2['span']['booked_hours'], 7.5, 0.4, 'still books the hours asked for');

// More hours than the window holds is a refusal that says so.
[, $S3] = api('resource_requests', ['action' => 'preview', 'work_item_id' => $item['id'], 'person_id' => $priyaP, 'hours' => 400, 'from_date' => '2026-09-14', 'to_date' => '2026-09-18'], 409);
check(strpos($S3['message'], 'more than that person has') !== false, 'asking for more hours than exist explains itself: ' . $S3['message']);

section('who may ask');
login(REQUESTER);
api('resource_requests', ['action' => 'preview', 'work_item_id' => $item['id'], 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-09-28'], 403);
[, $NEW] = api('work_items', ['action' => 'create', 'title' => 'Supplier onboarding data check', 'work_type_id' => $item['work_type_id'], 'size_stamp' => 'S', 'summary' => 'Raised by the requester suite.']);
$mine = (int)$NEW['item']['id'];
check($mine > 0, 'the requester can raise their own work item (' . $NEW['item']['ref'] . ')');
[, $OK] = api('resource_requests', ['action' => 'preview', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-09-28']);
check($OK['status'] === 'ok', 'and may ask for somebody on it');
check($OK['approver_label'] === 'Lena Torres, Priya Kaur or a delivery lead', "the requester is told who decides: {$OK['approver_label']}");
check($OK['inside_freeze'] === false, '28 September is outside the freeze horizon');

section('raising a request');
[, $C] = api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5,
    'from_date' => '2026-09-28', 'note' => 'Needs a pipeline engineer for the ingestion half.']);
$rid = (int)$C['request']['id'];
check($C['request']['status'] === 'pending', 'it lands pending');
check($C['request']['person']['name'] === 'Hana Novak' && $C['request']['hours'] === 7.5, 'it records who and how much');
check($C['request']['can_approve'] === false, 'the requester cannot approve their own request');
check($C['notified'] >= 1, "the approvers were told ({$C['notified']} notifications)");
api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 4,
    'from_date' => '2026-09-28'], 409);   // overlapping pending request for the same person on the same item

section('authority: only a lead above that person');
login(SAM);
[, $F] = api('resource_requests', ['action' => 'approve', 'id' => $rid], 403);
check(strpos($F['message'], 'Lena Torres') !== false, 'the refusal names who can decide: ' . $F['message']);
[, $SL] = api('resource_requests', ['action' => 'list', 'view' => 'for_me', 'status' => 'pending']);
$samSees = array_filter($SL['requests'], fn($r) => (int)$r['id'] === $rid);
check(!$samSees, 'and it is not in Sam\'s approval queue');

login(LENA);
[, $LL] = api('resource_requests', ['action' => 'list', 'view' => 'for_me', 'status' => 'pending']);
$lenaSees = array_values(array_filter($LL['requests'], fn($r) => (int)$r['id'] === $rid));
check(count($lenaSees) === 1, 'it IS in Lena\'s queue, because she leads Hana\'s team');
check($lenaSees && $lenaSees[0]['can_approve'] === true, 'and she is told she may decide it');
check($LL['counts']['pending_for_me'] >= 1, "the badge count agrees ({$LL['counts']['pending_for_me']})");

section('approving books the person');
[, $V0] = api('plan', ['action' => 'versions']);
$before = count($V0['versions']);
[, $A] = api('resource_requests', ['action' => 'approve', 'id' => $rid, 'reason' => 'Worth the day; the scorecard is blocked without it.']);
check($A['request']['status'] === 'approved', 'the request is approved');
check($A['request']['decided_by_name'] === 'Lena Torres', 'and carries who decided it');
check(!empty($A['plan_version']['id']), 'a new committed plan version was written');
check(!empty($A['plan_version']['assignment_id']), 'with the assignment it created');
check(isset($A['over_booked']), 'the response says whether the person is now over-booked');

[, $V1] = api('plan', ['action' => 'versions']);
check(count($V1['versions']) === $before + 1, 'exactly one new version');
$newest = $V1['versions'][0];
check($newest['status'] === 'committed' && $newest['engine'] === 'manual', 'it is committed, and recorded as a manual edit');
check(strpos((string)$newest['notes'], 'Approved resource request') !== false, 'its note says where it came from: ' . $newest['notes']);

[, $SCH] = api('plan', ['action' => 'schedule', 'from' => '2026-09-28', 'to' => '2026-10-09', 'item_id' => $mine]);
$booked = array_values(array_filter($SCH['assignments'], fn($a) => (int)$a['person_id'] === $hana));
check(count($booked) === 1, 'Hana has exactly one assignment on the item');
if ($booked) {
    check($booked[0]['from_date'] === '2026-09-28', "it starts when asked ({$booked[0]['from_date']})");
    check($booked[0]['fixed_person'] === true && $booked[0]['fixed_dates'] === true, 'it is FIXED, so the engine reproduces it rather than planning it away');
    check($booked[0]['role_label'] === 'requested', 'and is labelled as a request');
}

section('everybody who should hear about it, does');
login(REQUESTER);
[, $N1] = api('notifications', ['action' => 'list', 'limit' => 50]);
$decided = array_values(array_filter($N1['notifications'], fn($n) => $n['kind'] === 'request_decided'));
check(count($decided) >= 1, 'the requester has a request_decided notification');
check($decided && strpos($decided[0]['title'], 'Approved') === 0, "titled with the answer: {$decided[0]['title']}");
check($decided && $decided[0]['link'] === "/requests/$rid", 'linking to the request');

login(HANA);
[, $N2] = api('notifications', ['action' => 'list', 'limit' => 50]);
$assigned = array_values(array_filter($N2['notifications'], fn($n) => $n['kind'] === 'item_assigned' && strpos($n['title'], $NEW['item']['ref']) === 0));
check(count($assigned) >= 1, 'the person booked has an item_assigned notification');

section('declining');
login(REQUESTER);
[, $C2] = api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-10-12']);
$rid2 = (int)$C2['request']['id'];
login(LENA);
api('resource_requests', ['action' => 'decline', 'id' => $rid2], 422);                    // a decline owes the asker a reason
[, $D] = api('resource_requests', ['action' => 'decline', 'id' => $rid2, 'reason' => 'Hana is on the platform upgrade that fortnight.']);
check($D['request']['status'] === 'declined', 'declining records the decision');
check($D['request']['decision_reason'] !== null, 'with its reason');
api('resource_requests', ['action' => 'approve', 'id' => $rid2, 'reason' => 'changed my mind'], 409);   // already decided

section('inside the freeze horizon a reason is required');
login(REQUESTER);
[, $C3] = api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 3.5, 'from_date' => '2026-09-14']);
$rid3 = (int)$C3['request']['id'];
check($C3['inside_freeze'] === true, 'the request knows it is inside the freeze horizon');
login(LENA);
[, $FZ] = api('resource_requests', ['action' => 'approve', 'id' => $rid3], 409);
check(!empty($FZ['reason_required']) && strpos($FZ['message'], 'freeze horizon') !== false, 'approving it without a reason is refused: ' . $FZ['message']);
[, $FZ2] = api('resource_requests', ['action' => 'approve', 'id' => $rid3, 'reason' => 'Incident follow-up cannot wait for the next window.']);
check($FZ2['request']['status'] === 'approved', 'with a reason it goes through');
check($FZ2['inside_freeze'] === true, 'and is recorded as an inside-freeze decision');

section('withdrawing, and the lead above the lead');
login(REQUESTER);
[, $C4] = api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-10-19']);
$rid4 = (int)$C4['request']['id'];
login(LENA);
api('resource_requests', ['action' => 'withdraw', 'id' => $rid4], 403);      // not hers to withdraw
login(REQUESTER);
[, $W] = api('resource_requests', ['action' => 'withdraw', 'id' => $rid4]);
check($W['request']['status'] === 'withdrawn', 'the person who asked can withdraw');

[, $C5] = api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-11-02']);
$rid5 = (int)$C5['request']['id'];
login(PRIYA);   // leads Data Platform, which is ABOVE Hana's Platform engineering
[, $A2] = api('resource_requests', ['action' => 'approve', 'id' => $rid5]);
check($A2['request']['status'] === 'approved', 'a lead further up the tree can approve too (ORG-05 runs down the tree)');

section('refusals that protect the plan');
login(REQUESTER);
api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 0, 'from_date' => '2026-10-05'], 400);
api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-09-01'], 400);
api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => 99999, 'hours' => 7.5, 'from_date' => '2026-10-05'], 404);
api('resource_requests', ['action' => 'create', 'work_item_id' => 99999, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-10-05'], 404);
login(PRIYA);
api('work_items', ['action' => 'set_status', 'id' => $mine, 'status' => 'cancelled', 'reason' => 'Suite tidy-up']);
api('resource_requests', ['action' => 'create', 'work_item_id' => $mine, 'person_id' => $hana, 'hours' => 7.5, 'from_date' => '2026-10-05'], 409);

section('views and the audit trail');
login(REQUESTER);
[, $MINE] = api('resource_requests', ['action' => 'list', 'view' => 'mine']);
check(count($MINE['requests']) >= 5, 'the requester sees their own requests (' . count($MINE['requests']) . ')');
$statuses = array_unique(array_map(fn($r) => $r['status'], $MINE['requests']));
check(in_array('approved', $statuses, true) && in_array('declined', $statuses, true) && in_array('withdrawn', $statuses, true), 'covering every decision: ' . implode(', ', $statuses));
api('resource_requests', ['action' => 'list', 'view' => 'all'], 403);                       // below team_lead
login(PRIYA);
[, $ALL] = api('resource_requests', ['action' => 'list', 'view' => 'all']);
check(count($ALL['requests']) >= count($MINE['requests']), 'a lead can see them all');
[, $G] = api('resource_requests', ['action' => 'get', 'id' => $rid]);
check((int)$G['request']['id'] === $rid && $G['request']['status'] === 'approved', 'get returns one request');

$token = token_for('admin');
[, $AU] = api('audit', ['action' => 'list', 'entity' => 'resource_request', 'limit' => 50]);
$actions = array_count_values(array_map(fn($e) => $e['action'], $AU['events']));
check(($actions['create'] ?? 0) >= 5, 'every request was audited as created');
check(($actions['approve'] ?? 0) >= 3, 'every approval was audited');
check(($actions['reject'] ?? 0) >= 1, 'the decline was audited');

echo "\n" . str_repeat('-', 60) . "\n";
echo "resource requests: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
