<?php
// Role families and loans over HTTP (ORG-02, TEAM-09, SCH-13): role_families.php and the loan actions
// of people.php.
//   C:\xampp\php\php.exe tests\role_family_test.php [base=http://localhost:8090]
// Needs the local server and a seeded demo. Leaves the demo as it found it: every loan it makes is
// ended or cancelled, and the person it moves between role families is moved back.
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

// ---- sign in --------------------------------------------------------------------------------
section('Sign in');
[$code] = api('auth.php', ['action' => 'providers']);
if ($code !== 200) { echo "No API at $BASE\n"; exit(2); }
$adminU = user_for('admin'); $leadU = user_for('delivery_lead'); $memberU = user_for('team_member', true);
if (!$adminU || !$leadU || !$memberU) { echo "No seeded users - run seed_demo.php first\n"; exit(2); }
$admin = token_for_email($adminU['email']); $lead = token_for_email($leadU['email']); $member = token_for_email($memberU['email']);
check('admin, delivery lead and team member tokens', $admin && $lead && $member);

// ---- the seeded shape ------------------------------------------------------------------------
section('Role families: a discipline spans the team tree (ORG-02)');
[$code, $rl] = api('role_families.php', ['action' => 'list'], $member);
check('list 200 for a team member (read-only for everyone)', $code === 200 && isset($rl['role_families']), short($rl));
$fams = [];
foreach ($rl['role_families'] ?? [] as $f) $fams[$f['name']] = $f;
check('the three seeded families are there', isset($fams['Data engineering'], $fams['Analytics'], $fams['Integration']), short(array_keys($fams)));
check('headcounts are 6 / 2 / 4', ($fams['Data engineering']['headcount'] ?? 0) === 6 && ($fams['Analytics']['headcount'] ?? 0) === 2 && ($fams['Integration']['headcount'] ?? 0) === 4,
    short(array_map(fn($f) => [$f['name'], $f['headcount']], array_values($fams))));
check('they add up to everybody, with nobody left out', array_sum(array_map(fn($f) => $f['headcount'], $fams)) === 12 && ($rl['unassigned_people'] ?? null) === []);
check('Data engineering reaches into more than one team — the thing a portfolio of whole teams could not say',
    count($fams['Data engineering']['teams_spanned'] ?? []) >= 3, short($fams['Data engineering']['teams_spanned'] ?? null));
check('Integration sits in one team', count($fams['Integration']['teams_spanned'] ?? []) === 1, short($fams['Integration']['teams_spanned'] ?? null));
check('each family carries its people with their home team', isset($fams['Analytics']['people'][0]['team_name']), short($fams['Analytics']['people'][0] ?? null));
$deId = $fams['Data engineering']['id']; $anId = $fams['Analytics']['id']; $inId = $fams['Integration']['id'];

// ---- the cross-team view ---------------------------------------------------------------------
section('Role family overview: the same person counted once, wherever they sit');
[$code, $ov] = api('role_families.php', ['action' => 'overview', 'role_family_id' => $deId], $lead);
check('overview 200', $code === 200 && isset($ov['teams'], $ov['totals'], $ov['loans']), short($ov));
$teams = $ov['teams'] ?? []; $tot = $ov['totals'] ?? [];
$fields = ['headcount', 'loaned_in', 'loaned_out', 'available_hours', 'assigned_hours', 'load_pct', 'single_skill_deps', 'single_skill_names', 'stability_index', 'open_proposals'];
$shaped = count($teams) >= 3;
foreach ($teams as $t) foreach ($fields as $f) if (!array_key_exists($f, $t)) $shaped = false;
check('each row carries headcount, loans, load, single-skill dependencies, stability and open proposals', $shaped, short(array_keys($teams[0] ?? [])));
check('rows are the teams the family reaches into, with a path for each', count(array_filter($teams, fn($t) => !empty($t['path']))) === count($teams), short(array_map(fn($t) => $t['path'], $teams)));
$sum = fn($k) => array_sum(array_map(fn($t) => $t[$k], $teams));
check('totals.headcount = Σ rows', ($tot['headcount'] ?? -1) === $sum('headcount'), short([$tot['headcount'] ?? null, $sum('headcount')]));
check('totals.available_hours = Σ rows', abs(($tot['available_hours'] ?? -1) - $sum('available_hours')) < 0.05, short([$tot['available_hours'] ?? null, $sum('available_hours')]));
check('totals.assigned_hours = Σ rows', abs(($tot['assigned_hours'] ?? -1) - $sum('assigned_hours')) < 0.05, short([$tot['assigned_hours'] ?? null, $sum('assigned_hours')]));
check('totals.load_pct is assigned ÷ available', ($tot['available_hours'] ?? 0) > 0 && ($tot['load_pct'] ?? -1) === (int)round($tot['assigned_hours'] / $tot['available_hours'] * 100));
check('totals.open_proposals = Σ rows', ($tot['open_proposals'] ?? -1) === $sum('open_proposals'));
check('a loan moves a person between teams, never between disciplines: nothing is loaned in or out of a family',
    ($tot['loaned_in'] ?? -1) === 0 && ($tot['loaned_out'] ?? -1) === 0, short([$tot['loaned_in'] ?? null, $tot['loaned_out'] ?? null]));
check('Data engineering\'s single-skill dependencies include Terraform', in_array('Terraform L3', $tot['single_skill_names'] ?? [], true), short($tot['single_skill_names'] ?? null));
check('stability indices are percentages', !array_filter($teams, fn($t) => $t['stability_index'] < 0 || $t['stability_index'] > 100) && $tot['stability_index'] >= 0 && $tot['stability_index'] <= 100);
[$code, $ovIn] = api('role_families.php', ['action' => 'overview', 'role_family_id' => $inId], $lead);
check('Integration, with no committed work, is at 0% load', ($ovIn['totals']['load_pct'] ?? -1) === 0, short($ovIn['totals']['load_pct'] ?? null));
check('Mei\'s loan is listed against her family', count(array_filter($ovIn['loans'] ?? [], fn($l) => $l['person_name'] === 'Mei Chen' && $l['allocation_pct'] === 50)) === 1, short($ovIn['loans'] ?? null));
[$code] = api('role_families.php', ['action' => 'overview', 'role_family_id' => 999999], $lead);
check('unknown role family → 404', $code === 404);

// the scope machinery honours it too
[$code, $r] = api('people.php', ['action' => 'list', 'role_family_id' => $deId], $lead);
check('people.list role_family_id → the 6, none flagged as loaned in', $code === 200 && count($r['people'] ?? []) === 6 && !array_filter($r['people'], fn($p) => $p['loaned_from'] !== null), short(count($r['people'] ?? [])));
check('and the scope echoes back as a role family', ($r['scope']['kind'] ?? null) === 'role_family' && ($r['scope']['name'] ?? null) === 'Data engineering', short($r['scope'] ?? null));
[$code, $m] = api('skills.php', ['action' => 'matrix', 'role_family_id' => $deId], $lead);
check('skills.matrix role_family_id → the same 6, named after the family', $code === 200 && count($m['people'] ?? []) === 6 && ($m['summary']['team_name'] ?? null) === 'Data engineering', short(array_map(fn($p) => $p['name'], $m['people'] ?? [])));
[$code, $r] = api('replan.php', ['action' => 'preview', 'changes' => [], 'role_family_id' => $deId], $lead);
check('replan.preview accepts a role family scope', $code === 200 && ($r['scope']['kind'] ?? null) === 'role_family', "$code " . short($r['scope'] ?? $r));
[$code, $r] = api('replan.php', ['action' => 'preview', 'changes' => [], 'portfolio_id' => 1], $lead);
check('the removed portfolio_id is simply not a scope any more (the whole workspace is planned)', $code === 200 && ($r['scope']['kind'] ?? null) === 'workspace', "$code " . short($r['scope'] ?? $r));

// team scope now means the team and everything beneath it (ORG-01)
[$code, $pl] = api('people.php', ['action' => 'list'], $lead);
$teamByName = []; foreach ($pl['teams'] ?? [] as $t) $teamByName[$t['name']] = $t;
$dpId = $teamByName['Data Platform']['id'] ?? null; $ipId = $teamByName['Integration Platform']['id'] ?? null;
$rootId = $teamByName['Digital & Data']['id'] ?? null;
check('the seeded tree is three levels deep', $dpId && $ipId && $rootId && ($teamByName['Platform engineering']['depth'] ?? -1) === 2, short(array_map(fn($t) => $t['name'] . '@' . $t['depth'], $pl['teams'] ?? [])));
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $dpId], $lead);
$home = array_values(array_filter($r['people'] ?? [], fn($p) => $p['loaned_from'] === null));
$in = array_values(array_filter($r['people'] ?? [], fn($p) => $p['loaned_from'] !== null));
check('people.list team_id → Data Platform and its sub-teams: 8 home plus Mei loaned in', count($home) === 8 && count($in) === 1 && $in[0]['name'] === 'Mei Chen' && ($in[0]['loaned_from']['from_team_name'] ?? null) === 'Integration Platform', short(array_map(fn($p) => $p['name'], $in)));
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $teamByName['Platform engineering']['id']], $lead);
check('a leaf team is just its own three', $code === 200 && count($r['people'] ?? []) === 3, short(count($r['people'] ?? [])));
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $ipId], $lead);
$meiHome = null; foreach ($r['people'] ?? [] as $p) if ($p['name'] === 'Mei Chen') $meiHome = $p;
check('seen from her own team Mei is not "loaned from", and on_loan_to is null today (the loan starts next week)', $meiHome && $meiHome['loaned_from'] === null && $meiHome['on_loan_to'] === null && count($meiHome['loans']) === 1, short($meiHome['loans'] ?? null));

// ---- loans ----------------------------------------------------------------------------------
section('Loans: dated, shared, non-overlapping, audited, triggering (TEAM-09)');
$jon = null; foreach ($home as $p) if (str_starts_with($p['name'], 'Jon')) $jon = $p;
check('Jon Okafor is inside the Data Platform branch', $jon !== null);
$jonTeamId = $jon['team_id'] ?? null;
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-12', 'to_date' => '2026-10-16', 'allocation_pct' => 50, 'reason' => 'Event streaming cover'], $member);
check('a team member cannot lend → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-16', 'to_date' => '2026-10-12'], $lead);
check('to_date before from_date → 400', $code === 400, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $jonTeamId, 'from_date' => '2026-10-12', 'to_date' => '2026-10-16'], $lead);
check('lending someone to their own team → 400', $code === 400, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-12', 'to_date' => '2026-10-16', 'allocation_pct' => 50, 'reason' => 'Event streaming cover'], $lead);
check('delivery lead lends Jon to Integration Platform for a week at 50% → 200', $code === 200 && isset($r['loan']['id']) && $r['loan']['allocation_pct'] === 50, "$code " . short($r));
$loanId = $r['loan']['id'] ?? null;
check('outside the freeze horizon the trigger is batched', ($r['trigger']['class'] ?? null) === 'batched' && is_int($r['trigger']['id'] ?? null), short($r['trigger'] ?? null));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-14', 'to_date' => '2026-10-20'], $lead);
check('an overlapping loan is refused → 409 naming the clash', $code === 409 && ($r['overlaps']['id'] ?? null) === $loanId, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'loans', 'person_id' => $jon['id']], $member);
check('loans{person_id} lists it', $code === 200 && count(array_filter($r['loans'] ?? [], fn($l) => $l['id'] === $loanId)) === 1, short($r));
[$code, $r] = api('people.php', ['action' => 'loans', 'team_id' => $ipId], $member);
check('loans{team_id} sees it from the borrowing side too', $code === 200 && count(array_filter($r['loans'] ?? [], fn($l) => $l['id'] === $loanId)) === 1);
[$code, $r] = api('people.php', ['action' => 'get', 'id' => $jon['id']], $lead);
check('get shows the loan (not active today, so on_loan_to is null)', $code === 200 && count(array_filter($r['person']['loans'] ?? [], fn($l) => $l['id'] === $loanId)) === 1 && $r['person']['on_loan_to'] === null, short($r['person']['loans'] ?? null));
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $ipId], $lead);
$jonIn = null; foreach ($r['people'] ?? [] as $p) if ($p['id'] === $jon['id']) $jonIn = $p;
check('Integration Platform\'s list now includes Jon, loaned in', $jonIn && ($jonIn['loaned_from']['id'] ?? null) === $loanId, short($jonIn['loaned_from'] ?? null));
// capacity moves for the loan's dates and share, and not outside them
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'team_id' => $ipId, 'from' => '2026-10-09', 'to' => '2026-10-19'], $lead);
$byDay = []; foreach ($c['days'] ?? [] as $d) $byDay[$d['day']] = $d;
check('capacity{team_id}: 0 of Jon belongs to Integration Platform before the loan', ($byDay['2026-10-09']['team_share'] ?? -1) == 0.0 && ($byDay['2026-10-09']['team_available_hours'] ?? -1) == 0.0, short($byDay['2026-10-09'] ?? null));
check('half of him during it', ($byDay['2026-10-12']['team_share'] ?? -1) == 0.5 && ($byDay['2026-10-12']['team_available_hours'] ?? -1) == 3.75, short($byDay['2026-10-12'] ?? null));
check('none after it', ($byDay['2026-10-19']['team_share'] ?? -1) == 0.0);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'team_id' => $jonTeamId, 'from' => '2026-10-12', 'to' => '2026-10-12'], $lead);
check('and his own team keeps the other half', ($c['days'][0]['team_share'] ?? -1) == 0.5);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => '2026-10-12', 'to' => '2026-10-12'], $lead);
check('capacity_days itself is untouched: the row still says 7.5 hours', ($c['days'][0]['available_hours'] ?? 0) == 7.5 && !isset($c['days'][0]['team_share']));
[$code, $m] = api('skills.php', ['action' => 'matrix', 'team_id' => $ipId], $lead);
check('skills.matrix team_id → the 4 Integration people plus Jon, flagged loaned_in', $code === 200 && count($m['people'] ?? []) === 5 && count(array_filter($m['people'], fn($p) => $p['loaned_in'])) === 1, short(array_map(fn($p) => $p['name'] . ($p['loaned_in'] ? '*' : ''), $m['people'] ?? [])));
check('and names the team', ($m['summary']['team_name'] ?? null) === 'Integration Platform');
// end early, never delete
[$code, $r] = api('people.php', ['action' => 'end_loan', 'id' => $loanId, 'to_date' => '2026-10-30'], $lead);
check('end_loan cannot extend → 400', $code === 400, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'end_loan', 'id' => $loanId, 'to_date' => '2026-10-14'], $member);
check('a team member cannot recall → 403', $code === 403);
[$code, $r] = api('people.php', ['action' => 'end_loan', 'id' => $loanId, 'to_date' => '2026-10-14'], $lead);
check('end_loan shortens it to 14 Oct → 200', $code === 200 && ($r['loan']['to_date'] ?? null) === '2026-10-14' && ($r['loan']['id'] ?? null) === $loanId, "$code " . short($r));
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'team_id' => $ipId, 'from' => '2026-10-15', 'to' => '2026-10-15'], $lead);
check('the day handed back belongs to his own team again', ($c['days'][0]['team_share'] ?? -1) == 0.0);
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-15', 'to_date' => '2026-10-16'], $lead);
check('the freed days can be lent again', $code === 200, "$code " . short($r));
$loan2 = $r['loan']['id'] ?? null;
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'person_loan'], $admin);
check('every loan mutation is audited (create, update, create)', $code === 200 && ($a['total'] ?? 0) >= 3, short($a['total'] ?? null));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-09-14', 'to_date' => '2026-09-15', 'allocation_pct' => 25], $lead);
check('a loan starting inside the freeze horizon raises an urgent trigger', $code === 200 && ($r['trigger']['class'] ?? null) === 'urgent' && array_key_exists('urgent_replan', $r), "$code " . short($r));
$loan3 = $r['loan']['id'] ?? null;
// cancel the future loans so the demo is as we found it
[$code, $r] = api('people.php', ['action' => 'end_loan', 'id' => $loan3], $lead);
check('ending a loan that has not started cancels it outright', $code === 200 && ($r['cancelled'] ?? false) === true, "$code " . short($r));
api('people.php', ['action' => 'end_loan', 'id' => $loan2], $lead);
api('people.php', ['action' => 'end_loan', 'id' => $loanId], $lead);
[$code, $r] = api('people.php', ['action' => 'loans', 'person_id' => $jon['id']], $lead);
check('Jon has no loans left', $code === 200 && ($r['loans'] ?? null) === [], short($r));
[$code, $r] = api('people.php', ['action' => 'end_loan', 'id' => $loanId], $lead);
check('ending it again → 404', $code === 404);

// ---- administration ----------------------------------------------------------------------------
section('Role family administration is admin-only; a family with people cannot be deleted');
[$code, $r] = api('role_families.php', ['action' => 'save', 'name' => 'Test family'], $lead);
check('save as delivery lead → 403', $code === 403);
[$code, $r] = api('role_families.php', ['action' => 'save', 'name' => 'Test family', 'description' => 'Made by role_family_test.php'], $admin);
check('save as admin → 200', $code === 200 && isset($r['role_family']['id']), "$code " . short($r));
$testId = $r['role_family']['id'] ?? null;
[$code, $r] = api('role_families.php', ['action' => 'save', 'name' => 'Data engineering'], $admin);
check('duplicate name → 409', $code === 409);
[$code, $r] = api('role_families.php', ['action' => 'save', 'id' => $testId, 'lead_person_id' => $jon['id']], $admin);
check('save can set a lead', $code === 200 && ($r['role_family']['lead_name'] ?? null) === $jon['name'], short($r));
[$code, $r] = api('role_families.php', ['action' => 'set_person', 'person_id' => $jon['id'], 'role_family_id' => $testId], $lead);
check('set_person as delivery lead → 403', $code === 403);
[$code, $r] = api('role_families.php', ['action' => 'set_person', 'person_id' => $jon['id'], 'role_family_id' => $testId], $admin);
check('set_person moves Jon into the test family', $code === 200 && ($r['person']['role_family_id'] ?? null) === $testId, "$code " . short($r));
[$code, $r] = api('role_families.php', ['action' => 'overview', 'role_family_id' => $deId], $admin);
check('Data engineering is down to five', ($r['totals']['headcount'] ?? -1) === 5, short($r['totals']['headcount'] ?? null));
[$code, $r] = api('role_families.php', ['action' => 'delete', 'id' => $testId], $admin);
check('delete while somebody is in it → 409 naming them', $code === 409 && ($r['people'][0]['id'] ?? null) === $jon['id'], "$code " . short($r));
[$code, $r] = api('role_families.php', ['action' => 'set_person', 'person_id' => $jon['id'], 'role_family_id' => $deId], $admin);
check('set_person puts him back', $code === 200 && ($r['person']['role_family_name'] ?? null) === 'Data engineering', "$code " . short($r));
[$code, $r] = api('role_families.php', ['action' => 'delete', 'id' => $testId], $lead);
check('delete as delivery lead → 403', $code === 403);
[$code, $r] = api('role_families.php', ['action' => 'delete', 'id' => $testId], $admin);
check('delete once empty → 200', $code === 200, "$code " . short($r));
[$code, $r] = api('role_families.php', ['action' => 'list'], $lead);
$after = []; foreach ($r['role_families'] ?? [] as $f) $after[$f['name']] = $f['headcount'];
check('the demo is back as it was: 6 / 2 / 4 and nobody unassigned', $after === ['Analytics' => 2, 'Data engineering' => 6, 'Integration' => 4] && ($r['unassigned_people'] ?? null) === [], short($after));
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'role_family'], $admin);
check('role family mutations are audited', $code === 200 && ($a['total'] ?? 0) >= 3, short($a['total'] ?? null));

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
