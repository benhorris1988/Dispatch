<?php
// The four policy switches, the seven notification kinds, the urgent cycle and the interrupt
// priority breakdown.
//   php tests/policy_notifications_test.php [base=http://localhost:8090]
//
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php).
// It mutates the demo hard — it commits plan versions, edits the scheduling policy, runs the
// nightly cycle twice and books sickness — so it runs LAST in tests/run_all.php, which re-seeds
// after it. Run seed_demo.php yourself if you interrupt it.
require_once __DIR__ . '/_auth.php';   // sign-in helpers: there is no development login any more

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 180]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr((string)$raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }
function note($t) { echo "  ..   $t\n"; }
function login($role) {
    global $token;
    $token = token_for($role);
    return $token ? user_for($role) : null;
}
function loginUser($userId) {
    global $token;
    $token = null;
    foreach (test_users() as $u) if ((int)$u['id'] === (int)$userId) { $token = token_for_email($u['email']); return; }
}
function myNotifications($kind = null) {
    [, $n] = api('notifications', ['action' => 'list', 'limit' => 200]);
    $rows = $n['notifications'] ?? [];
    return $kind === null ? $rows : array_values(array_filter($rows, fn($x) => $x['kind'] === $kind));
}
/** save_policy is admin-only (ADM-02), so borrow the admin account and hand the session back. */
function savePolicy(array $fields) {
    global $token, $adminId;
    $was = $token;
    loginUser($adminId);
    [, $r] = api('workspace_config', ['action' => 'save_policy'] + $fields);
    $token = $was;
    return $r['policy'] ?? null;
}

// ---------------------------------------------------------------------------------------------
section('Sign in');
$lead = login('delivery_lead');
check($lead !== null && !empty($token), 'signed in as the delivery lead');
$allUsers = ['users' => test_users()];
$usersByPerson = [];
foreach ($allUsers['users'] as $u) if ($u['person_id'] !== null) $usersByPerson[(int)$u['person_id']] = $u;
$admin = user_for('admin');
check($admin !== null, 'an admin account exists');
$adminId = $admin ? (int)$admin['id'] : null;

[, $sched] = api('plan', ['action' => 'schedule']);
$today = $sched['windows']['today'] ?? null;
$freezeEnd = $sched['windows']['freeze_end'] ?? null;
check($today && $freezeEnd && $freezeEnd > $today, "plan windows: today $today, freeze horizon ends $freezeEnd");
// A pair of working days comfortably inside the freeze horizon, for edits that must land there.
$insideFrom = date('Y-m-d', strtotime("$today +1 day"));
while (in_array(date('D', strtotime($insideFrom)), ['Sat', 'Sun'], true)) $insideFrom = date('Y-m-d', strtotime("$insideFrom +1 day"));
$insideTo = date('Y-m-d', strtotime("$insideFrom +1 day"));
while (in_array(date('D', strtotime($insideTo)), ['Sat', 'Sun'], true)) $insideTo = date('Y-m-d', strtotime("$insideTo +1 day"));
check($insideTo <= $freezeEnd, "$insideFrom..$insideTo is inside the freeze horizon");

// ---------------------------------------------------------------------------------------------
section('notify() reads notification_prefs (NOT-01 estimate_requested, NOT-02 channels)');
[, $queue] = api('work_items', ['action' => 'list', 'status' => 'needs_estimate']);
$target = $queue['items'][0] ?? null;
check($target !== null, 'the demo has an item waiting for an estimate (' . ($target['ref'] ?? '-') . ')');
// Unowned, so the request goes to the team leads — which includes the account running this test.
api('work_items', ['action' => 'update', 'id' => $target['id'], 'owner_person_id' => null]);

$before = count(myNotifications('estimate_requested'));
[, $req] = api('work_items', ['action' => 'request_estimate', 'id' => $target['id'], 'note' => 'Needed for the October cut']);
check(($req['to'] ?? '') === 'team_lead' && ($req['notified'] ?? 0) >= 1, "request_estimate notifies the team leads ({$req['notified']} sent)");
$mine = myNotifications('estimate_requested');
check(count($mine) === $before + 1, 'one estimate_requested notification arrived (' . count($mine) . ')');
check(($mine[0]['channel'] ?? '') === 'in_app', "default preferences deliver in-app (channel {$mine[0]['channel']})");
check(strpos($mine[0]['body'] ?? '', 'October cut') !== false, 'the requester’s note is carried in the body');

// email digest on, daily cadence -> the row says it rides the digest rather than arriving now
api('notifications', ['action' => 'save_prefs', 'kind' => 'estimate_requested', 'email_digest' => true, 'digest' => 'daily']);
api('work_items', ['action' => 'request_estimate', 'id' => $target['id']]);
$mine = myNotifications('estimate_requested');
check(count($mine) === $before + 2, 'a second request is recorded (' . count($mine) . ')');
check(($mine[0]['channel'] ?? '') === 'digest', "a daily email digest sets channel=digest (got {$mine[0]['channel']})");

// in-app off -> nothing is written at all for this reader (the admin, who has not turned it off,
// still gets theirs — a preference is personal, not a global mute)
api('notifications', ['action' => 'save_prefs', 'kind' => 'estimate_requested', 'in_app' => false, 'email_digest' => false]);
[, $req3] = api('work_items', ['action' => 'request_estimate', 'id' => $target['id']]);
check((int)($req3['notified'] ?? -1) === (int)$req['notified'] - 1, "one fewer recipient is reported ({$req3['notified']} vs {$req['notified']})");
check(count(myNotifications('estimate_requested')) === $before + 2, 'and no notification row is written for the reader who turned it off');
api('notifications', ['action' => 'save_prefs', 'kind' => 'estimate_requested', 'in_app' => true, 'email_digest' => false, 'digest' => 'daily']);
[, $prefs] = api('notifications', ['action' => 'prefs']);
check(count($prefs['prefs'] ?? []) === 9, 'all nine notification kinds have preferences, the weekly digest and request_decided included (' . count($prefs['prefs'] ?? []) . ')');
check(in_array('digest', $prefs['kinds'] ?? [], true), 'digest is one of them (NOT-04)');

section('An item moving to needs_estimate raises estimate_requested (NOT-01)');
[, $ready] = api('work_items', ['action' => 'list', 'status' => 'ready']);
$mover = null;
foreach ($ready['items'] ?? [] as $i) if ($i['id'] !== $target['id']) { $mover = $i; break; }
check($mover !== null, 'a Ready item to move back into the queue (' . ($mover['ref'] ?? '-') . ')');
if ($mover) {
    api('work_items', ['action' => 'update', 'id' => $mover['id'], 'owner_person_id' => null]);
    $n0 = count(myNotifications('estimate_requested'));
    [, $st] = api('work_items', ['action' => 'set_status', 'id' => $mover['id'], 'status' => 'needs_estimate', 'reason' => 'scope changed']);
    check(($st['item']['status'] ?? '') === 'needs_estimate', 'the item is back in the estimate queue');
    $now = myNotifications('estimate_requested');
    check(count($now) === $n0 + 1, 'the status move raised estimate_requested (' . count($now) . ')');
    check(strpos($now[0]['title'] ?? '', $mover['ref']) !== false, "and names {$mover['ref']}");
}

// ---------------------------------------------------------------------------------------------
section('An incident renders a real priority breakdown (BEN-04)');
[, $open] = api('work_items', ['action' => 'list', 'status' => 'open']);
$incident = null;
foreach ($open['items'] ?? [] as $i) if (($i['type_policy'] ?? '') === 'interrupt') { $incident = $i; break; }
check($incident !== null, 'the demo has an open incident (' . ($incident['ref'] ?? '-') . ')');
if ($incident) {
    [, $g] = api('work_items', ['action' => 'get', 'id' => $incident['id']]);
    $t = $g['item']['priority_terms'] ?? [];
    $score = (float)($g['item']['priority_score'] ?? 0);
    check(isset($t['severity']['contribution']) && (float)$t['severity']['contribution'] > 0, 'severity is a term of its own (' . ($t['severity']['contribution'] ?? '-') . ')');
    check(($t['severity']['input'] ?? '') === ($g['item']['severity'] ?? 'x'), "severity term names the severity ({$t['severity']['input']})");
    // The five terms every breakdown renders must add up to the score the item is carrying;
    // before this they were five zeros against a score of 100.
    $sum = 0;
    foreach (['value', 'urgency', 'risk', 'leverage', 'age'] as $k) $sum += (float)($t[$k]['contribution'] ?? 0);
    check($sum > 0, "the rendered breakdown is not all zero (sums to $sum)");
    check(abs($sum - $score) < 0.05, "the breakdown reproduces the score ($sum vs $score)");
    check(($t['urgency']['alias_of'] ?? '') === 'severity', 'the term carrying it is flagged as an alias of severity, so nothing double-counts it');
}

// ---------------------------------------------------------------------------------------------
section('require_ack_inside_horizon ON: a committed change inside the horizon must be acknowledged (CHG-06)');
$pol = savePolicy(['require_ack_inside_horizon' => true, 'reestimate_class_threshold' => null]);
check(($pol['require_ack_inside_horizon'] ?? null) === true, 'the switch is on');

/** Propose, then drag one change into the freeze horizon so the commit has something to ask about. */
function proposeAndEditIntoFreeze($insideFrom, $insideTo, $personId = null) {
    [, $prop] = api('replan', ['action' => 'propose', 'kind' => 'manual']);
    $all = array_merge($prop['changes'] ?? [], $prop['held'] ?? []);
    $pick = null;
    foreach ($all as $c) if (($c['before'] ?? null) === null && !empty($c['after']['person_id'])) { $pick = $c; break; }
    if (!$pick) foreach ($all as $c) if (!empty($c['after']['person_id'])) { $pick = $c; break; }
    if (!$pick) return [null, null];
    $pid = $personId ?? (int)$pick['after']['person_id'];
    [, $ed] = api('changes', ['action' => 'edit', 'change_id' => $pick['id'], 'reason' => 'Pulled into this week for the test',
        'after' => ['person_id' => $pid, 'from' => $insideFrom, 'to' => $insideTo, 'allocation_pct' => 50]]);
    return [$prop['proposal_id'], $ed['change'] ?? null];
}

[, $peek] = api('replan', ['action' => 'propose', 'kind' => 'manual']);
$peekAll = array_merge($peek['changes'] ?? [], $peek['held'] ?? []);
$peekPick = null;
foreach ($peekAll as $c) if (($c['before'] ?? null) === null && !empty($c['after']['person_id'])) { $peekPick = $c; break; }
check($peekPick !== null, 'a proposal offers a new assignment to edit (' . ($peekPick['work_item']['ref'] ?? '-') . ')');
$affectedPerson = $peekPick ? (int)$peekPick['after']['person_id'] : null;
$affectedUser = $affectedPerson !== null ? ($usersByPerson[$affectedPerson] ?? null) : null;
check($affectedUser !== null, 'the affected person has a user account (' . ($affectedUser['display_name'] ?? '-') . ')');

// NOT-03: set that person's digest preferences BEFORE the commit. change_committed inside the
// freeze horizon is urgent and must bypass the digest; item_assigned is not and must not.
if ($affectedUser) {
    loginUser((int)$affectedUser['id']);
    api('notifications', ['action' => 'save_prefs', 'kind' => 'change_committed', 'email_digest' => true, 'digest' => 'daily']);
    api('notifications', ['action' => 'save_prefs', 'kind' => 'item_assigned', 'email_digest' => true, 'digest' => 'daily']);
    loginUser((int)$lead['id']);
}

[$propId, $edited] = proposeAndEditIntoFreeze($insideFrom, $insideTo, $affectedPerson);
check($edited !== null && ($edited['inside_freeze'] ?? false) === true, 'the edited change now sits inside the freeze horizon');
[, $committed] = api('changes', ['action' => 'commit', 'proposal_id' => $propId]);
check((int)($committed['ack_required'] ?? 0) >= 1, 'the commit recorded that an acknowledgement is required (' . ($committed['ack_required'] ?? '-') . ')');
check((int)($committed['items_assigned'] ?? 0) >= 1, 'and raised item_assigned for the new assignee (' . ($committed['items_assigned'] ?? '-') . ')');
[, $got] = api('changes', ['action' => 'get', 'id' => $propId]);
check(count($got['awaiting_ack'] ?? []) >= 1, 'the proposal exposes what is awaiting acknowledgement (' . count($got['awaiting_ack'] ?? []) . ')');
check(($got['awaiting_ack'][0]['ack_required'] ?? false) === true && ($got['awaiting_ack'][0]['awaiting_ack'] ?? false) === true, 'the change carries ack_required and awaiting_ack');
check((int)($got['counts']['awaiting_ack'] ?? 0) >= 1, 'and the counts say how many');

if ($affectedUser) {
    loginUser((int)$affectedUser['id']);
    [, $mineC] = api('changes', ['action' => 'mine']);
    check(count($mineC['pending_ack'] ?? []) >= 1, "{$affectedUser['display_name']}'s My week shows the pending acknowledgement (" . count($mineC['pending_ack'] ?? []) . ')');
    $ackId = $mineC['pending_ack'][0]['id'] ?? null;
    $assigned = myNotifications('item_assigned');
    check(count($assigned) >= 1, 'they were told the item is theirs (' . count($assigned) . ' item_assigned)');
    check(($assigned[0]['channel'] ?? '') === 'digest', "and a non-urgent kind on a daily digest says so (channel {$assigned[0]['channel']})");
    $comm = myNotifications('change_committed');
    $urgent = array_values(array_filter($comm, fn($n) => $n['urgent'] === true));
    check(count($urgent) >= 1, 'the inside-freeze commit is flagged urgent (' . count($urgent) . ')');
    check(($urgent[0]['channel'] ?? '') === 'in_app', "and an urgent notification bypasses the digest (channel {$urgent[0]['channel']}) — NOT-03");
    if ($ackId !== null) {
        [, $ack] = api('changes', ['action' => 'acknowledge', 'change_id' => $ackId]);
        check(!empty($ack['change']['acknowledged_at']) && ($ack['change']['awaiting_ack'] ?? true) === false, 'acknowledging clears it');
        [, $mine2] = api('changes', ['action' => 'mine']);
        check(count($mine2['pending_ack'] ?? []) === count($mineC['pending_ack']) - 1, 'and it leaves the pending list');
    }
    api('notifications', ['action' => 'save_prefs', 'kind' => 'change_committed', 'email_digest' => false]);
    api('notifications', ['action' => 'save_prefs', 'kind' => 'item_assigned', 'email_digest' => false]);
    loginUser((int)$lead['id']);
}

section('require_ack_inside_horizon OFF: the same commit asks for nothing (CHG-06)');
$pol = savePolicy(['require_ack_inside_horizon' => false]);
check(($pol['require_ack_inside_horizon'] ?? null) === false, 'the switch is off');
[$propId2, $edited2] = proposeAndEditIntoFreeze($insideFrom, $insideTo);
check($edited2 !== null && ($edited2['inside_freeze'] ?? false) === true, 'a second change is edited into the freeze horizon');
[, $committed2] = api('changes', ['action' => 'commit', 'proposal_id' => $propId2]);
check((int)($committed2['ack_required'] ?? -1) === 0, 'no acknowledgement is requested (' . ($committed2['ack_required'] ?? '-') . ')');
[, $got2] = api('changes', ['action' => 'get', 'id' => $propId2]);
check(count($got2['awaiting_ack'] ?? []) === 0, 'and nothing is awaiting one');
savePolicy(['require_ack_inside_horizon' => true]);

// ---------------------------------------------------------------------------------------------
section("The weekly digest: next week's plan and what changed since the last one (NOT-04)");
// $affectedUser has just had a change committed for them (above), in real time, so it is
// inside the default "since" window of a first digest.
$digestUser = $affectedUser ?? $usersByPerson[array_key_first($usersByPerson)];
loginUser((int)$admin['id']);
[, $pv] = api('digest', ['action' => 'preview', 'user_id' => (int)$digestUser['id']]);
$d = $pv['digest'] ?? [];
check(($d['user']['id'] ?? 0) === (int)$digestUser['id'] && ($d['user']['person_id'] ?? null) !== null, "a team lead can preview {$digestUser['display_name']}'s digest");
$expectedFrom = date('Y-m-d', strtotime(date('Y-m-d', strtotime("$today monday this week")) . ' +7 days'));
check(($d['period']['week_from'] ?? '') === $expectedFrom && date('D', strtotime($d['period']['week_to'] ?? 'now')) === 'Sun', "next week runs from Monday {$d['period']['week_from']} to Sunday {$d['period']['week_to']}");
check(array_key_exists('last_digest_at', $d) && $d['last_digest_at'] === null && ($d['since_is_default'] ?? false) === true, 'no digest has gone out yet, so "since" defaults to a week ago');
check(is_array($d['next_week'] ?? null) && ($d['summary']['assignments'] ?? -1) === count($d['next_week']), "next week's assignments come from the committed plan (" . count($d['next_week'] ?? []) . ')');
$inWeek = true; foreach ($d['next_week'] ?? [] as $a) if ($a['in_week_from'] < $d['period']['week_from'] || $a['in_week_to'] > $d['period']['week_to'] || $a['days_in_week'] < 1 || $a['days_in_week'] > 5) $inWeek = false;
check($inWeek, 'each assignment is clipped to the week and carries 1-5 days in it');
check((int)($d['summary']['changes'] ?? 0) >= 1, 'the change committed above appears in "changes since" (' . ($d['summary']['changes'] ?? '-') . ')');
$hasHeadline = false; foreach ($d['changes'] ?? [] as $c) if (!empty($c['headline']) && !empty($c['at']) && !empty($c['link'])) $hasHeadline = true;
check($hasHeadline, 'with a headline, a time and a link to the change');
check(is_array($d['awaiting_ack'] ?? null) && is_array($d['watch_list'] ?? null) && is_array($d['carried_notifications'] ?? null), 'awaiting_ack, watch_list and carried_notifications sections are present');
check(strpos($d['text'] ?? '', "NEXT WEEK'S PLAN") !== false && strpos($d['text'] ?? '', 'CHANGES SINCE') !== false, 'the plain-text rendering has both sections');
check(strpos($d['html'] ?? '', htmlspecialchars($digestUser['display_name'], ENT_QUOTES)) !== false && strpos($d['html'] ?? '', '<table') !== false, 'the HTML rendering names the person and lays out the plan');
check(!empty($d['subject']) && !empty($d['summary_line']), 'subject: ' . ($d['subject'] ?? '-'));
check(array_key_exists('transport', $pv), 'the preview states the transport a send would use (' . var_export($pv['transport'] ?? null, true) . ')');
$transport = $pv['transport'] ?? null;

// A team member cannot preview someone else's; a lead cannot send.
loginUser((int)$digestUser['id']);
[$code] = api('digest', ['action' => 'preview', 'user_id' => (int)$admin['id']], 403);
check($code === 403, "a team member cannot preview another user's digest");
[, $own] = api('digest', ['action' => 'preview']);
check(($own['digest']['user']['id'] ?? 0) === (int)$digestUser['id'], 'but can preview their own');
loginUser((int)$lead['id']);
[$code] = api('digest', ['action' => 'send', 'user_id' => (int)$digestUser['id']], 403);
check($code === 403, 'send is admin-only');

// Send to one person. There is no SMTP here, so it must land in-app and say so.
loginUser((int)$digestUser['id']); $digestsBefore = count(myNotifications('digest')); loginUser((int)$admin['id']);
[, $snd] = api('digest', ['action' => 'send', 'user_id' => (int)$digestUser['id']]);
$res = $snd['results'][0] ?? [];
check((int)($snd['recipients'] ?? 0) === 1 && ($res['user_id'] ?? 0) === (int)$digestUser['id'], 'one digest was addressed');
if ($transport === null) {
    check(($res['sent'] ?? true) === false && ($res['in_app'] ?? false) === true && ($res['delivered'] ?? false) === true, 'without a mail transport it is delivered in-app, and `sent` stays false');
    check(($res['reason'] ?? '') === 'no mail transport configured', 'the reason is stated: ' . ($res['reason'] ?? '-'));
    check((int)($snd['emailed'] ?? -1) === 0 && (int)($snd['in_app'] ?? 0) === 1 && !empty($snd['note']), 'the summary never claims an email went out');
    check(!empty($res['notification_id']), 'and names the notification row (' . ($res['notification_id'] ?? '-') . ')');
    loginUser((int)$digestUser['id']);
    $dg = myNotifications('digest');
    check(count($dg) === $digestsBefore + 1, "{$digestUser['display_name']} has a new in-app digest (" . count($dg) . ')');
    check(($dg[0]['title'] ?? '') === ($res['subject'] ?? 'x') && ($dg[0]['link'] ?? '') === '/my-week' && ($dg[0]['channel'] ?? '') === 'in_app', 'titled with the digest subject and linking to My week');
    check(strpos($dg[0]['body'] ?? '', 'next week') !== false, 'the body is the summary line: ' . substr($dg[0]['body'] ?? '-', 0, 90));
    loginUser((int)$admin['id']);
} else {
    note("a mail transport ($transport) is configured on this box; the in-app fallback assertions are skipped. sent=" . var_export($res['sent'] ?? null, true));
}
check(!empty($res['last_digest_at']) && $res['last_digest_at'] > ($d['since'] ?? ''), 'last_digest_at advanced to now (' . ($res['last_digest_at'] ?? '-') . ')');
[, $pv2] = api('digest', ['action' => 'preview', 'user_id' => (int)$digestUser['id']]);
$d2 = $pv2['digest'] ?? [];
check(($d2['last_digest_at'] ?? null) === ($res['last_digest_at'] ?? 'x') && ($d2['since'] ?? '') === ($res['last_digest_at'] ?? 'x') && ($d2['since_is_default'] ?? true) === false, 'the next digest starts where this one ended');
check((int)($d2['summary']['changes'] ?? -1) === 0, 'and nothing has changed for them since it went out');
[, $aud] = api('audit', ['action' => 'list', 'entity' => 'digest', 'limit' => 20]);
$sendEv = array_values(array_filter($aud['events'] ?? [], fn($e) => ($e['action'] ?? '') === 'send' && (int)($e['entity_id'] ?? 0) === (int)$digestUser['id']));
check(count($sendEv) >= 1 && array_key_exists('sent', $sendEv[0]['after'] ?? []) && array_key_exists('in_app', $sendEv[0]['after'] ?? []), 'the send is audited with what actually happened');

// Send to everyone opted in: the recipient set is "email_digest on for any kind, cadence not off".
[, $none] = api('digest', ['action' => 'send']);
$noneIds = array_column($none['results'] ?? [], 'user_id');
loginUser((int)$digestUser['id']);
api('notifications', ['action' => 'save_prefs', 'kind' => 'watch_list', 'email_digest' => true, 'digest' => 'weekly']);
loginUser((int)$admin['id']);
[, $all] = api('digest', ['action' => 'send']);
$allIds = array_column($all['results'] ?? [], 'user_id');
check(in_array((int)$digestUser['id'], $allIds, true) && !in_array((int)$digestUser['id'], $noneIds, true), 'turning an email digest on for any kind makes them a recipient of the weekly run');
check((int)($all['recipients'] ?? 0) === count($allIds) && (int)($all['recipients'] ?? 0) >= 1, 'recipients counted (' . ($all['recipients'] ?? '-') . ')');

// In-app off for the digest kind, and no mail: nothing can carry it, and last_digest_at must not move.
if ($transport === null) {
    loginUser((int)$digestUser['id']);
    api('notifications', ['action' => 'save_prefs', 'kind' => 'digest', 'in_app' => false]);
    loginUser((int)$admin['id']);
    [, $pvB] = api('digest', ['action' => 'preview', 'user_id' => (int)$digestUser['id']]);
    [, $off] = api('digest', ['action' => 'send', 'user_id' => (int)$digestUser['id']]);
    $ro = $off['results'][0] ?? [];
    check(($ro['delivered'] ?? true) === false && ($ro['in_app'] ?? true) === false && (int)($off['undelivered'] ?? 0) === 1, 'with in-app off and no mail, the digest is reported undelivered rather than pretended');
    check(strpos($ro['reason'] ?? '', 'turned off') !== false, 'and says why: ' . ($ro['reason'] ?? '-'));
    check(($ro['last_digest_at'] ?? 'x') === ($pvB['digest']['last_digest_at'] ?? 'y'), 'last_digest_at did not advance, so nothing is lost for the next one');
    loginUser((int)$digestUser['id']);
    api('notifications', ['action' => 'save_prefs', 'kind' => 'digest', 'in_app' => true]);
}
loginUser((int)$digestUser['id']);
api('notifications', ['action' => 'save_prefs', 'kind' => 'watch_list', 'email_digest' => false]);
loginUser((int)$lead['id']);

// ---------------------------------------------------------------------------------------------
section('reestimate_class_threshold blocks entry to the committed window (EST-09)');
[, $prop3] = api('replan', ['action' => 'propose', 'kind' => 'manual']);
$prop3Id = $prop3['proposal_id'];
$cand = null; $candClass = null;
foreach (array_merge($prop3['changes'] ?? [], $prop3['held'] ?? []) as $c) {
    if (empty($c['after']['person_id']) || ($c['before'] ?? null) !== null) continue;
    if (($c['after']['from'] ?? '') <= $freezeEnd) continue;            // must be entering the window, not already in it
    [, $e] = api('estimates', ['action' => 'get', 'work_item_id' => $c['work_item']['id']]);
    $cls = (int)($e['latest']['estimate_class'] ?? 0);
    if ($cls >= 2) { $cand = $c; $candClass = $cls; break; }
}
check($cand !== null, 'a new assignment for an item with a coarse estimate (' . ($cand['work_item']['ref'] ?? '-') . " class $candClass)");
if ($cand) {
    savePolicy(['reestimate_class_threshold' => $candClass - 1]);
    [, $wl] = api('replan', ['action' => 'watch_list']);
    $re = array_values(array_filter($wl['items'] ?? [], fn($w) => ($w['kind'] ?? '') === 'reestimate'));
    check(count($re) >= 1, 'the watch list reports what the threshold will block (' . count($re) . ' entries)');
    check(!empty($re[0]['suggestion']), 'with a way through: ' . ($re[0]['suggestion'] ?? '-'));
    api('changes', ['action' => 'edit', 'change_id' => $cand['id'], 'reason' => 'Pulled into the committed window',
        'after' => ['person_id' => (int)$cand['after']['person_id'], 'from' => $insideFrom, 'to' => $insideTo, 'allocation_pct' => 50]]);
    [$code, $blocked] = api('changes', ['action' => 'commit', 'proposal_id' => $prop3Id], 409);
    check(strpos($blocked['message'] ?? '', 'Re-estimate required') === 0, 'the commit is refused: ' . substr($blocked['message'] ?? '-', 0, 90));
    check(($blocked['reestimate_blocked'][0]['ref'] ?? '') === $cand['work_item']['ref'], 'and names the item and its class');
    savePolicy(['reestimate_class_threshold' => null]);
    [$code2, $now] = api('changes', ['action' => 'commit', 'proposal_id' => $prop3Id]);
    check($code2 === 200 && ($now['committed'] ?? 0) >= 1, 'with the threshold cleared the same commit succeeds');
    [, $wl2] = api('replan', ['action' => 'watch_list']);
    check(count(array_filter($wl2['items'] ?? [], fn($w) => ($w['kind'] ?? '') === 'reestimate')) === 0, 'and the watch list stops reporting it');
}

// ---------------------------------------------------------------------------------------------
section('The nightly cycle raises realisation_due and watch_list (NOT-01)');
$ownerPerson = array_key_first($usersByPerson);
$ownerUser = $usersByPerson[$ownerPerson];
[, $withBenefit] = api('work_items', ['action' => 'list', 'status' => 'open']);
$benefitItem = null;
foreach ($withBenefit['items'] ?? [] as $i) if (($i['type_policy'] ?? '') === 'planned') { $benefitItem = $i; break; }
[, $bs] = api('benefits', ['action' => 'save', 'work_item_id' => $benefitItem['id'], 'type' => 'cost_avoidance', 'annual_value' => 40000,
    'confidence' => 'medium', 'realisation_from' => date('Y-m-d', strtotime("$today -90 days")), 'owner_person_id' => $ownerPerson]);
check(!empty($bs['benefit']['id']), "a benefit whose realisation date has passed, owned by {$ownerUser['display_name']}");

loginUser((int)$admin['id']);
[, $n1] = api('replan', ['action' => 'run_nightly']);
$steps1 = $n1['results'][0]['steps'] ?? [];
check((int)($steps1['realisation_due']['notified'] ?? 0) >= 1, 'the overdue realisation is notified (' . ($steps1['realisation_due']['notified'] ?? '-') . ' of ' . ($steps1['realisation_due']['due'] ?? '-') . ' due)');
check((int)($steps1['watch_list_notices']['notified'] ?? 0) >= 1, 'watch-list entries naming a person are notified (' . ($steps1['watch_list_notices']['notified'] ?? '-') . ' of ' . ($steps1['watch_list_notices']['entries'] ?? '-') . ' entries)');

loginUser((int)$ownerUser['id']);
$rd = myNotifications('realisation_due');
check(count($rd) >= 1, "{$ownerUser['display_name']} was told a realisation is due (" . count($rd) . ')');
check(strpos($rd[0]['body'] ?? '', 'Realisation was due') === 0, 'saying when: ' . substr($rd[0]['body'] ?? '-', 0, 70));

loginUser((int)$admin['id']);
[, $n2] = api('replan', ['action' => 'run_nightly']);
$steps2 = $n2['results'][0]['steps'] ?? [];
check((int)($steps2['realisation_due']['notified'] ?? -1) === 0 && (int)($steps2['realisation_due']['already_told'] ?? 0) >= 1, 'a second night does not repeat the realisation reminder');
check((int)($steps2['watch_list_notices']['notified'] ?? -1) === 0 && (int)($steps2['watch_list_notices']['repeats_suppressed'] ?? 0) >= 1, 'nor the standing watch-list entries (' . ($steps2['watch_list_notices']['repeats_suppressed'] ?? '-') . ' suppressed)');

// ---------------------------------------------------------------------------------------------
section('auto_apply_outside_horizon OFF: the nightly cycle applies nothing (CHG-07)');
loginUser((int)$admin['id']);
savePolicy(['auto_apply_outside_horizon' => false]);
[, $night] = api('replan', ['action' => 'run_nightly']);
$aa = $night['results'][0]['steps']['auto_apply'] ?? null;
check(is_array($aa) && ($aa['enabled'] ?? null) === false, 'the nightly reports the switch as off');
check((int)($aa['applied'] ?? -1) === 0, 'and applies nothing');

section('auto_apply_outside_horizon ON: guardrail-passing changes outside the horizon go without review (CHG-07)');
savePolicy(['auto_apply_outside_horizon' => true]);
[, $nightHeld] = api('replan', ['action' => 'run_nightly']);
$aaHeld = $nightHeld['results'][0]['steps']['auto_apply'] ?? [];
check(($aaHeld['enabled'] ?? null) === true, 'the switch is read');
check((int)($aaHeld['applied'] ?? -1) === 0 && !empty($aaHeld['skipped']), 'a proposal below the minimum improvement is still not applied automatically (STAB-04): ' . ($aaHeld['skipped'] ?? '-'));

// Lower the improvement threshold so the proposal qualifies, and the same cycle must apply.
savePolicy(['min_improvement_pct' => -999]);
[, $night2] = api('replan', ['action' => 'run_nightly']);
$aa2 = $night2['results'][0]['steps']['auto_apply'] ?? [];
check(($aa2['enabled'] ?? null) === true, 'the nightly reads the switch as on');
check((int)($aa2['applied'] ?? 0) >= 1, 'and applies the changes that pass every guardrail outside the horizon (' . ($aa2['applied'] ?? '-') . ')');
check(!empty($aa2['plan_version_id']), 'into a new committed plan version (' . ($aa2['plan_version_id'] ?? '-') . ')');
[, $audit] = api('audit', ['action' => 'list', 'entity' => 'change_proposal', 'limit' => 200]);
$autos = array_values(array_filter($audit['events'] ?? [], fn($e) => ($e['action'] ?? '') === 'auto_apply'));
check(count($autos) >= 1, 'each one is audited as auto-applied (' . count($autos) . ' events)');
check(strpos($autos[0]['reason'] ?? '', 'CHG-07') !== false, 'with the reason on the row: ' . ($autos[0]['reason'] ?? '-'));
$insideAuto = array_values(array_filter($autos, fn($e) => !empty($e['after']['inside_freeze'])));
check(count($insideAuto) === 0, 'nothing inside the freeze horizon was auto-applied');
savePolicy(['auto_apply_outside_horizon' => false, 'min_improvement_pct' => 5]);

// ---------------------------------------------------------------------------------------------
section('An urgent trigger starts an immediate scoped cycle (STAB-05)');
loginUser((int)$lead['id']);
// Re-read the schedule: everything above has re-committed the plan several times.
[, $sched2] = api('plan', ['action' => 'schedule']);
$counts = [];
foreach ($sched2['assignments'] ?? [] as $a) {
    if (($a['from_date'] ?? '') > $freezeEnd || ($a['to_date'] ?? '') < $today) continue;   // must be inside the freeze horizon
    $counts[(int)$a['person_id']] = ($counts[(int)$a['person_id']] ?? 0) + 1;
}
arsort($counts);
$busiest = $counts ? (int)array_key_first($counts) : null;
check($busiest !== null, 'a person with committed work inside the freeze horizon to disrupt (person ' . $busiest . ', ' . ($counts[$busiest] ?? 0) . ' assignments)');
// The whole freeze horizon, so the cycle has something real to say.
[, $sick] = api('people', ['action' => 'add_availability', 'person_id' => $busiest, 'from_date' => $today, 'to_date' => $freezeEnd, 'type' => 'sickness']);
check(($sick['trigger']['class'] ?? '') === 'urgent', 'sickness inside the freeze horizon is an urgent trigger');
check(isset($sick['urgent_replan']), 'and the request reports that a cycle ran');
$ur = $sick['urgent_replan'] ?? [];
check(array_key_exists('proposal_id', $ur), 'the cycle reports its outcome: ' . json_encode($ur));
if (!empty($ur['proposal_id'])) {
    [, $cur] = api('changes', ['action' => 'current']);
    check((int)($cur['proposal']['id'] ?? 0) === (int)$ur['proposal_id'], 'the new proposal is the open one');
    check(($cur['proposal']['kind'] ?? '') === 'urgent', "and it is an urgent cycle ({$cur['proposal']['kind']})");
    check(in_array($busiest, $cur['proposal']['scope_person_ids'] ?? [], true), 'scoped to the affected person (' . implode(',', $cur['proposal']['scope_person_ids'] ?? []) . ')');
} else {
    note('the scoped cycle found nothing to change, so nothing was persisted: ' . json_encode($ur));
}

// An incident arriving does the same, from work_items.php.
[, $cfg] = api('workspace_config', ['action' => 'get']);
$incType = null;
foreach ($cfg['work_types'] ?? [] as $wt) if (($wt['policy'] ?? '') === 'interrupt') { $incType = $wt; break; }
check($incType !== null, 'the workspace has an interrupt work type (' . ($incType['name'] ?? '-') . ')');
if ($incType) {
    // Sized, so the incident carries effort the scoped cycle has to find room for.
    $incStamp = $incType['default_size_stamp'] ?? null;
    foreach ($cfg['incident_size_classes'] ?? $cfg['size_classes'] ?? [] as $sc) if (!$incStamp && empty($sc['is_custom'])) $incStamp = $sc['stamp'];
    [, $inc] = api('work_items', ['action' => 'create', 'title' => 'Nightly ingestion failed (test)', 'work_type_id' => $incType['id'],
        'severity' => 'P1', 'size_stamp' => $incStamp, 'summary' => 'Raised by tests/policy_notifications_test.php']);
    check(!empty($inc['item']['ref']), 'an incident is raised (' . ($inc['item']['ref'] ?? '-') . ')');
    check(isset($inc['urgent_replan']), 'and it starts an urgent cycle rather than waiting for the nightly run');
    check(array_key_exists('proposal_id', $inc['urgent_replan'] ?? []), 'reporting its outcome: ' . json_encode($inc['urgent_replan'] ?? null));
    // A replan that cannot run must never fail the intake: the item exists either way.
    [$c2, $back] = api('work_items', ['action' => 'get', 'ref' => $inc['item']['ref']]);
    check($c2 === 200 && ($back['item']['severity'] ?? '') === 'P1', 'the incident itself was stored regardless of the replan');
}

echo "\n$pass passed, $fail failed\n";
echo "Re-seed before using the demo again: php seed_demo.php\n";
exit($fail ? 1 : 0);
