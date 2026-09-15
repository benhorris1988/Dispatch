<?php
// The organisation chart over HTTP (ORG-01..05): org.php.
//   C:\xampp\php\php.exe tests\org_test.php [base=http://localhost:8090]
// Needs the local server and a seeded demo. Leaves the demo as it found it: every team it creates is
// deleted, every move is moved back, and Mei's loan is restored after the forced move that ends it.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require_once __DIR__ . '/_auth.php';   // sign-in helpers: there is no development login any more

$BASE = rtrim($argv[1] ?? (getenv('DISPATCH_BASE') ?: 'http://localhost:8090'), '/');
$pass = 0; $fail = 0;

function api($file, array $body, $token = null) {
    global $BASE;
    $headers = "Content-Type: application/json\r\n"; if ($token) $headers .= "Authorization: Bearer $token\r\n";
    $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers, 'content' => json_encode($body), 'ignore_errors' => true, 'timeout' => 60]]);
    $raw = @file_get_contents("$BASE/api/$file", false, $ctx);
    $code = 0; foreach ($http_response_header ?? [] as $h) if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int)$m[1];
    $j = json_decode((string)$raw, true);
    return [$code, is_array($j) ? $j : ['raw' => $raw]];
}
function check($label, $cond, $detail = '') { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label" . ($detail !== '' ? " -- $detail" : '') . "\n"; } return (bool)$cond; }
function short($v) { $s = json_encode($v, JSON_UNESCAPED_UNICODE); return strlen($s) > 300 ? substr($s, 0, 300) . '…' : $s; }
function section($t) { echo "\n== $t\n"; }
/** Depth-first walk of a tree response, so an assertion can talk about one team by name. */
function flatten(array $teams, array &$out = []) {
    foreach ($teams as $t) { $out[$t['name']] = $t; if (!empty($t['children'])) flatten($t['children'], $out); }
    return $out;
}

// ---- sign in --------------------------------------------------------------------------------
section('Sign in');
[$code] = api('auth.php', ['action' => 'providers']);
if ($code !== 200) { echo "No API at $BASE\n"; exit(2); }
$lead = token_for('delivery_lead');
$admin = token_for('admin');
$priya = token_for_email('priya.kaur@example.org');    // team_lead of Data Platform
$tariq = token_for_email('tariq.hussain@example.org'); // team_lead of Integration Platform
$mei = token_for_email('mei.chen@example.org');        // team_member inside Integration Platform
$jon = token_for_email('jon.okafor@example.org');      // team_member inside the Data Platform branch
if (!$lead || !$admin || !$priya || !$tariq || !$mei || !$jon) { echo "Missing seeded accounts - run seed_demo.php first\n"; exit(2); }
check('tokens for a delivery lead, an admin, two team leads and two members', true);

// ---- the tree ---------------------------------------------------------------------------------
section('tree: three levels, headcounts that include sub-teams, load per branch (ORG-01)');
[$code, $t] = api('org.php', ['action' => 'tree'], $jon);
check('tree 200 for an ordinary member', $code === 200 && isset($t['teams']), short($t));
$by = flatten($t['teams'] ?? []);
check('one root, Digital & Data', count($t['teams'] ?? []) === 1 && isset($by['Digital & Data']), short(array_keys($by)));
check('Data Platform sits under it, with two sub-teams', ($by['Data Platform']['parent_team_id'] ?? null) === ($by['Digital & Data']['id'] ?? -1) && count($by['Data Platform']['children'] ?? []) === 2, short(array_map(fn($c) => $c['name'], $by['Data Platform']['children'] ?? [])));
check('headcount is the team\'s own, headcount_all includes everything beneath', ($by['Data Platform']['headcount'] ?? -1) === 2 && ($by['Data Platform']['headcount_all'] ?? -1) === 8, short([$by['Data Platform']['headcount'] ?? null, $by['Data Platform']['headcount_all'] ?? null]));
check('the root counts all twelve', ($by['Digital & Data']['headcount_all'] ?? -1) === 12);
check('a branch with no committed work is at 0% load, one with work is not', ($by['Integration Platform']['load_pct'] ?? -1) === 0 && ($by['Data Platform']['load_pct'] ?? 0) > 0, short([$by['Data Platform']['load_pct'] ?? null, $by['Integration Platform']['load_pct'] ?? null]));
$everyone = []; foreach ($by as $team) foreach ($team['people'] ?? [] as $p) $everyone[$p['id']] = ($everyone[$p['id']] ?? 0) + 1;
check('every person appears exactly once, in their home team', count($everyone) === 12 && max($everyone) === 1, short(count($everyone)));
check('nobody is left without a team', ($t['unassigned_people'] ?? null) === []);
$pe = $by['Platform engineering'] ?? [];
check('a team node names its lead', ($pe['lead']['name'] ?? null) === 'Lena Torres' && ($pe['lead']['initials'] ?? null) === 'LT', short($pe['lead'] ?? null));
$lena = null; foreach ($pe['people'] ?? [] as $p) if ($p['name'] === 'Lena Torres') $lena = $p;
$hana = null; foreach ($pe['people'] ?? [] as $p) if ($p['name'] === 'Hana Novak') $hana = $p;
check('people carry their reporting line and their role family (ORG-02)', ($hana['manager_name'] ?? null) === 'Lena Torres' && ($hana['role_family_name'] ?? null) === 'Data engineering', short($hana));
check('the lead of the team is flagged as such', ($lena['is_lead'] ?? false) === true);
check('the three role families come back with the tree', count($t['role_families'] ?? []) === 3, short($t['role_families'] ?? null));
check('an ordinary member may edit nothing', ($t['can_edit_team_ids'] ?? null) === []);
[$code, $tl] = api('org.php', ['action' => 'tree'], $lead);
check('a delivery lead may edit everything', ($tl['can_edit_team_ids'] ?? null) === '*');
[$code, $tp] = api('org.php', ['action' => 'tree'], $priya);
$pTeams = flatten($tp['teams'] ?? []);
check('a team lead may edit their own branch and nothing else', is_array($tp['can_edit_team_ids'] ?? null)
    && count($tp['can_edit_team_ids']) === 3
    && in_array($pTeams['Data Platform']['id'], $tp['can_edit_team_ids'], true)
    && !in_array($pTeams['Integration Platform']['id'], $tp['can_edit_team_ids'], true), short($tp['can_edit_team_ids'] ?? null));
$rootId = $by['Digital & Data']['id']; $dpId = $by['Data Platform']['id']; $peId = $by['Platform engineering']['id'];
$aeId = $by['Analytics engineering']['id']; $ipId = $by['Integration Platform']['id'];

// ---- authority ---------------------------------------------------------------------------------
section('Authority runs down the tree, not across it (ORG-05)');
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Nope', 'parent_team_id' => $dpId], $jon);
check('a team member cannot create a team → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Nope', 'parent_team_id' => $ipId], $priya);
check('a team lead cannot create one in somebody else\'s branch → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Nope'], $priya);
check('nor at the top of the organisation → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Test squad', 'parent_team_id' => $peId, 'description' => 'Made by org_test.php'], $priya);
check('but may create one inside their own branch → 200', $code === 200 && isset($r['team']['id']), "$code " . short($r));
$squadId = $r['team']['id'] ?? null;
check('the new team knows where it sits', ($r['team']['parent_team_id'] ?? null) === $peId && str_contains($r['team']['path'] ?? '', 'Platform engineering'), short($r['team'] ?? null));
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Test squad', 'parent_team_id' => $peId], $priya);
check('a second team with the same name under the same parent → 409', $code === 409, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'save_team', 'name' => 'Test squad', 'parent_team_id' => $aeId], $priya);
check('but the same name in a different branch is fine', $code === 200, "$code " . short($r));
$squad2Id = $r['team']['id'] ?? null;

// ---- moving teams --------------------------------------------------------------------------------
section('move_team: cycles refused, siblings renumbered (ORG-01)');
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $dpId, 'parent_team_id' => $squadId], $lead);
check('a team cannot be moved inside its own descendant → 409', $code === 409, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $dpId, 'parent_team_id' => $dpId], $lead);
check('nor inside itself → 409', $code === 409, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $squadId, 'parent_team_id' => $ipId], $priya);
check('a team lead cannot push their team into somebody else\'s branch → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $squadId, 'parent_team_id' => $aeId, 'sort_order' => 0], $lead);
check('a delivery lead can move it across branches → 200', $code === 200 && ($r['team']['parent_team_id'] ?? null) === $aeId, "$code " . short($r));
$order = [];
foreach ($r['siblings'] ?? [] as $s) $order[$s['id']] = $s['sort_order'];
check('siblings are renumbered from zero with no gaps', array_values($order) === range(0, count($order) - 1) && ($order[$squadId] ?? -1) === 0, short($order));
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $squadId, 'parent_team_id' => $peId], $lead);
check('and back again', $code === 200 && ($r['team']['parent_team_id'] ?? null) === $peId);
[$code, $r] = api('org.php', ['action' => 'move_team', 'team_id' => $squadId, 'parent_team_id' => 999999], $lead);
check('an unknown parent → 404', $code === 404, "$code " . short($r));

// ---- moving people ---------------------------------------------------------------------------------
section('move_person: a home team change is a real change, and a running loan blocks it (ORG-03)');
$meiId = null; foreach ($by['Integration Platform']['people'] ?? [] as $p) if ($p['name'] === 'Mei Chen') $meiId = $p['id'];
$hanaId = $hana['id'];
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $hanaId, 'team_id' => $ipId], $priya);
check('a team lead cannot move somebody into another lead\'s team → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $meiId, 'team_id' => $aeId], $lead);
check('moving somebody with an outstanding loan → 409, naming the loan', $code === 409 && ($r['loans'][0]['person_name'] ?? null) === 'Mei Chen', "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $meiId, 'team_id' => $aeId, 'force' => true, 'reason' => 'Permanent move, agreed with both leads'], $lead);
check('with force it goes through and the loan is ended', $code === 200 && count($r['loans_ended'] ?? []) === 1 && ($r['person']['team_name'] ?? null) === 'Analytics engineering', "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'loans', 'person_id' => $meiId], $lead);
check('the loan that had not started is gone rather than left contradicting the move', ($r['loans'] ?? null) === [], short($r));
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $meiId, 'team_id' => $ipId, 'reason' => 'Undoing the test move'], $lead);
check('and she can be moved back', $code === 200 && ($r['person']['team_name'] ?? null) === 'Integration Platform', "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $meiId, 'to_team_id' => $dpId, 'from_date' => '2026-09-14', 'to_date' => '2026-09-25', 'allocation_pct' => 50, 'reason' => 'Reference data service API work (WI-1039)'], $lead);
check('the seeded loan is put back', $code === 200, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $hanaId, 'team_id' => $squadId], $priya);
check('a team lead can move somebody within their own branch', $code === 200 && ($r['person']['team_name'] ?? null) === 'Test squad', "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'move_person', 'person_id' => $hanaId, 'team_id' => $peId], $priya);
check('and back', $code === 200 && ($r['person']['team_name'] ?? null) === 'Platform engineering');

// ---- reporting lines -------------------------------------------------------------------------------
section('set_manager: no loops, no self-management (ORG-02)');
$priyaId = null; foreach ($by['Data Platform']['people'] ?? [] as $p) if ($p['name'] === 'Priya Kaur') $priyaId = $p['id'];
[$code, $r] = api('org.php', ['action' => 'set_manager', 'person_id' => $hanaId, 'manager_person_id' => $hanaId], $lead);
check('somebody cannot manage themselves → 409', $code === 409, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'set_manager', 'person_id' => $priyaId, 'manager_person_id' => $hanaId], $lead);
check('a loop — Priya reporting to Hana, who reports to Lena, who reports to Priya — → 409', $code === 409, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'set_manager', 'person_id' => $hanaId, 'manager_person_id' => $priyaId], $lead);
check('a sound line is accepted', $code === 200 && ($r['person']['manager_name'] ?? null) === 'Priya Kaur', "$code " . short($r));
check('the old free-text line_manager now reports the real manager', ($r['person']['line_manager'] ?? null) === 'Priya Kaur', short($r['person'] ?? null));
$lenaId = $lena['id'];
[$code, $r] = api('org.php', ['action' => 'set_manager', 'person_id' => $hanaId, 'manager_person_id' => $lenaId], $lead);
check('and put back', $code === 200 && ($r['person']['manager_name'] ?? null) === 'Lena Torres');

// ---- visibility -------------------------------------------------------------------------------------
section('set_visibility: everything is visible to everyone unless somebody says otherwise, with a reason (ORG-04)');
[$code, $r] = api('org.php', ['action' => 'set_visibility', 'team_id' => $ipId, 'visibility' => 'restricted'], $tariq);
check('restricting without a reason → 422', $code === 422, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'set_visibility', 'team_id' => $ipId, 'visibility' => 'invisible', 'reason' => 'x'], $tariq);
check('an unknown visibility → 400', $code === 400, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'set_visibility', 'team_id' => $ipId, 'visibility' => 'restricted', 'reason' => 'Reorganisation not announced yet'], $priya);
check('a lead cannot restrict a team outside their branch → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'set_visibility', 'team_id' => $ipId, 'visibility' => 'restricted', 'reason' => 'Reorganisation not announced yet'], $tariq);
check('its own lead can → 200', $code === 200 && ($r['team']['visibility'] ?? null) === 'restricted', "$code " . short($r));
$look = function ($token) use ($ipId) {
    [, $t] = api('org.php', ['action' => 'tree'], $token);
    $by = flatten($t['teams'] ?? []);
    return $by['Integration Platform'] ?? [];
};
$seen = ['another lead' => $look($priya), 'the delivery lead' => $look($lead), 'somebody inside' => $look($mei), 'its own lead' => $look($tariq), 'an administrator' => $look($admin)];
check('outsiders still see the team exists and where it sits, but not who is in it', ($seen['another lead']['restricted'] ?? false) === true && ($seen['another lead']['people'] ?? null) === [] && !empty($seen['another lead']['name']), short($seen['another lead']));
check('a delivery lead does not bypass it — that is what restricting is for', ($seen['the delivery lead']['restricted'] ?? false) === true, short($seen['the delivery lead']['restricted'] ?? null));
check('people inside the team see it in full', ($seen['somebody inside']['restricted'] ?? true) === false && count($seen['somebody inside']['people'] ?? []) === 4);
check('so does its lead', ($seen['its own lead']['restricted'] ?? true) === false);
check('and an administrator', ($seen['an administrator']['restricted'] ?? true) === false && ($seen['an administrator']['visibility_reason'] ?? null) === 'Reorganisation not announced yet');
[$code, $r] = api('org.php', ['action' => 'set_visibility', 'team_id' => $ipId, 'visibility' => 'everyone'], $tariq);
check('lifting the restriction clears the reason with it', $code === 200 && ($r['team']['visibility'] ?? null) === 'everyone' && array_key_exists('visibility_reason', $r['team'] ?? []) && $r['team']['visibility_reason'] === null, "$code " . short($r));
check('and everybody can see the team again', (($look($priya))['restricted'] ?? true) === false);

// ---- deleting -------------------------------------------------------------------------------------
section('delete_team: only when nothing depends on it');
[$code, $r] = api('org.php', ['action' => 'delete_team', 'team_id' => $dpId], $lead);
check('a team with people and sub-teams → 409, saying what is in the way', $code === 409 && count($r['children'] ?? []) === 2 && count($r['people'] ?? []) === 2, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'delete_team', 'team_id' => $squadId], $jon);
check('a team member cannot delete → 403', $code === 403);
[$code, $r] = api('org.php', ['action' => 'delete_team', 'team_id' => $squadId], $priya);
check('an empty team inside the lead\'s branch → 200', $code === 200 && ($r['deleted'] ?? null) === $squadId, "$code " . short($r));
[$code, $r] = api('org.php', ['action' => 'delete_team', 'team_id' => $squad2Id], $lead);
check('and the second one', $code === 200);
[$code, $r] = api('org.php', ['action' => 'delete_team', 'team_id' => $squadId], $lead);
check('deleting it again → 404', $code === 404);

// ---- audit ------------------------------------------------------------------------------------------
section('Everything above is on the record (ADM-04)');
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'team'], $admin);
check('team mutations are audited', $code === 200 && ($a['total'] ?? 0) >= 8, short($a['total'] ?? null));
$withReason = array_filter($a['events'] ?? [], fn($e) => !empty($e['reason']));
check('and the ones that need a reason carry one', count($withReason) >= 2, short(array_map(fn($e) => $e['reason'], array_slice($withReason, 0, 4))));

// ---- the demo is as we found it ---------------------------------------------------------------------
section('The demo is back where it started');
[$code, $t] = api('org.php', ['action' => 'tree'], $lead);
$by = flatten($t['teams'] ?? []);
check('five teams, three levels, twelve people, nobody unassigned',
    count($by) === 5 && ($by['Digital & Data']['headcount_all'] ?? 0) === 12 && ($t['unassigned_people'] ?? null) === []
    && ($by['Data Platform']['headcount_all'] ?? 0) === 8 && ($by['Integration Platform']['headcount'] ?? 0) === 4, short(array_keys($by)));

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
