<?php
// Portfolios and loans over HTTP (TEAM-09, SCH-13): portfolios.php and the loan actions of people.php.
//   C:\xampp\php\php.exe tests\portfolio_test.php [base=http://localhost:8090]
// Needs the local server and a seeded demo. Leaves the demo as it found it: every loan it makes is
// ended or cancelled, and the team it moves between portfolios is moved back.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

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
[$code, $r] = api('auth.php', ['action' => 'list_dev_users']);
if ($code !== 200 || empty($r['users'])) { echo "No API or no seeded users at $BASE\n"; exit(2); }
$users = $r['users'];
$pick = function ($role, $withPerson = null) use ($users) { foreach ($users as $u) if ($u['role'] === $role && ($withPerson === null || ($u['person_id'] !== null) === $withPerson)) return $u; return null; };
$login = function ($u) { [$c, $r] = api('auth.php', ['action' => 'dev_login', 'user_id' => $u['id']]); return $c === 200 ? $r['token'] : null; };
$adminU = $pick('admin'); $leadU = $pick('delivery_lead'); $memberU = $pick('team_member', true);
$admin = $login($adminU); $lead = $login($leadU); $member = $login($memberU);
check('admin, delivery lead and team member tokens', $admin && $lead && $member);

// ---- the seeded shape ------------------------------------------------------------------------
section('Portfolios list: the seeded portfolio holds both teams (TEAM-09)');
[$code, $pl] = api('portfolios.php', ['action' => 'list'], $member);
check('list 200 for a team member (read-only for everyone)', $code === 200 && isset($pl['portfolios']), short($pl));
$pf = null; foreach ($pl['portfolios'] ?? [] as $p) if ($p['name'] === 'Data & Integration') $pf = $p;
check('Data & Integration is there with two teams', $pf && $pf['team_count'] === 2, short($pf));
$dp = null; $ip = null; foreach ($pf['teams'] ?? [] as $t) { if ($t['name'] === 'Data Platform') $dp = $t; if ($t['name'] === 'Integration Platform') $ip = $t; }
check('Data Platform has 8 people, Integration Platform 4', ($dp['headcount'] ?? 0) === 8 && ($ip['headcount'] ?? 0) === 4, short([$dp['headcount'] ?? null, $ip['headcount'] ?? null]));
check('the portfolio headcount is the sum', ($pf['headcount'] ?? 0) === 12);
check('the seeded loan shows as one person loaned in to Data Platform and out of Integration Platform', ($dp['loaned_in'] ?? 0) === 1 && ($ip['loaned_out'] ?? 0) === 1, short([$dp, $ip]));
check('no team is left unassigned', ($pl['unassigned_teams'] ?? null) === []);
$pfId = $pf['id'] ?? null; $dpId = $dp['id'] ?? null; $ipId = $ip['id'] ?? null;

// ---- the cross-team view ---------------------------------------------------------------------
section('Portfolio overview: per-team figures side by side, and totals that agree (TEAM-09)');
[$code, $ov] = api('portfolios.php', ['action' => 'overview', 'portfolio_id' => $pfId], $lead);
check('overview 200', $code === 200 && isset($ov['teams'], $ov['totals'], $ov['loans']), short($ov));
$teams = $ov['teams'] ?? []; $tot = $ov['totals'] ?? [];
$fields = ['headcount', 'loaned_in', 'loaned_out', 'available_hours', 'assigned_hours', 'load_pct', 'single_skill_deps', 'single_skill_names', 'stability_index', 'open_proposals'];
$shaped = count($teams) === 2;
foreach ($teams as $t) foreach ($fields as $f) if (!array_key_exists($f, $t)) $shaped = false;
check('each team row carries headcount, loans, load, single-skill dependencies, stability and open proposals', $shaped, short(array_keys($teams[0] ?? [])));
$sum = fn($k) => array_sum(array_map(fn($t) => $t[$k], $teams));
check('totals.headcount = Σ teams', ($tot['headcount'] ?? -1) === $sum('headcount'), short([$tot['headcount'] ?? null, $sum('headcount')]));
check('totals.available_hours = Σ teams (a loaned person is split, never doubled)', abs(($tot['available_hours'] ?? -1) - $sum('available_hours')) < 0.05, short([$tot['available_hours'] ?? null, $sum('available_hours')]));
check('totals.assigned_hours = Σ teams', abs(($tot['assigned_hours'] ?? -1) - $sum('assigned_hours')) < 0.05, short([$tot['assigned_hours'] ?? null, $sum('assigned_hours')]));
check('totals.load_pct is assigned ÷ available', ($tot['available_hours'] ?? 0) > 0 && ($tot['load_pct'] ?? -1) === (int)round($tot['assigned_hours'] / $tot['available_hours'] * 100));
check('totals.open_proposals = Σ teams', ($tot['open_proposals'] ?? -1) === $sum('open_proposals'));
check('a loan inside the portfolio is neither in nor out of it', ($tot['loaned_in'] ?? -1) === 0 && ($tot['loaned_out'] ?? -1) === 0, short([$tot['loaned_in'] ?? null, $tot['loaned_out'] ?? null]));
$dpRow = null; $ipRow = null; foreach ($teams as $t) { if ($t['id'] === $dpId) $dpRow = $t; if ($t['id'] === $ipId) $ipRow = $t; }
check('Integration Platform, with no committed work, is at 0% load; Data Platform is not', ($ipRow['load_pct'] ?? -1) === 0 && ($dpRow['load_pct'] ?? 0) > 0, short([$dpRow['load_pct'] ?? null, $ipRow['load_pct'] ?? null]));
check('Data Platform\'s single-skill dependencies include Terraform', in_array('Terraform L3', $dpRow['single_skill_names'] ?? [], true), short($dpRow['single_skill_names'] ?? null));
check('the portfolio has no more single-skill dependencies than its weakest team', ($tot['single_skill_deps'] ?? 99) <= max($dpRow['single_skill_deps'] ?? 0, $ipRow['single_skill_deps'] ?? 0));
check('stability indices are percentages', !array_filter($teams, fn($t) => $t['stability_index'] < 0 || $t['stability_index'] > 100) && $tot['stability_index'] >= 0 && $tot['stability_index'] <= 100);
check('the seeded loan is listed', count(array_filter($ov['loans'], fn($l) => $l['person_name'] === 'Mei Chen' && $l['allocation_pct'] === 50)) === 1, short($ov['loans']));
[$code] = api('portfolios.php', ['action' => 'overview', 'portfolio_id' => 999999], $lead);
check('unknown portfolio → 404', $code === 404);

// people.php honours the same scope
[$code, $r] = api('people.php', ['action' => 'list', 'portfolio_id' => $pfId], $lead);
check('people.list portfolio_id → 12 people, none flagged as loaned in', $code === 200 && count($r['people'] ?? []) === 12 && !array_filter($r['people'], fn($p) => $p['loaned_from'] !== null), short(count($r['people'] ?? [])));
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $dpId], $lead);
$home = array_filter($r['people'] ?? [], fn($p) => $p['loaned_from'] === null); $in = array_values(array_filter($r['people'] ?? [], fn($p) => $p['loaned_from'] !== null));
check('people.list team_id → 8 home members plus Mei loaned in from Integration Platform', count($home) === 8 && count($in) === 1 && $in[0]['name'] === 'Mei Chen' && ($in[0]['loaned_from']['from_team_name'] ?? null) === 'Integration Platform', short(array_map(fn($p) => $p['name'], $in)));
$mei = $in[0] ?? null;
[$code, $r] = api('people.php', ['action' => 'list', 'team_id' => $ipId], $lead);
$meiHome = null; foreach ($r['people'] ?? [] as $p) if ($p['name'] === 'Mei Chen') $meiHome = $p;
check('seen from her own team Mei is not "loaned from", and on_loan_to is null today (the loan starts next week)', $meiHome && $meiHome['loaned_from'] === null && $meiHome['on_loan_to'] === null && count($meiHome['loans']) === 1, short($meiHome['loans'] ?? null));
check('teams carry their portfolio', count(array_filter($r['teams'] ?? [], fn($t) => $t['portfolio_id'] === $pfId)) === 2, short($r['teams'] ?? null));

// ---- loans ----------------------------------------------------------------------------------
section('Loans: dated, shared, non-overlapping, audited, triggering (TEAM-09)');
$jon = null; foreach ($home as $p) if (str_starts_with($p['name'], 'Jon')) $jon = $p;
check('Jon Okafor is a Data Platform home member', $jon !== null);
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-12', 'to_date' => '2026-10-16', 'allocation_pct' => 50, 'reason' => 'Event streaming cover'], $member);
check('a team member cannot lend → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-16', 'to_date' => '2026-10-12'], $lead);
check('to_date before from_date → 400', $code === 400, "$code " . short($r));
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $dpId, 'from_date' => '2026-10-12', 'to_date' => '2026-10-16'], $lead);
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
check('Integration Platform\'s list now includes Jon, loaned from Data Platform', $jonIn && ($jonIn['loaned_from']['id'] ?? null) === $loanId, short($jonIn['loaned_from'] ?? null));
// capacity moves for the loan's dates and share, and not outside them
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'team_id' => $ipId, 'from' => '2026-10-09', 'to' => '2026-10-19'], $lead);
$byDay = []; foreach ($c['days'] ?? [] as $d) $byDay[$d['day']] = $d;
check('capacity{team_id}: 0 of Jon belongs to Integration Platform before the loan', ($byDay['2026-10-09']['team_share'] ?? -1) == 0.0 && ($byDay['2026-10-09']['team_available_hours'] ?? -1) == 0.0, short($byDay['2026-10-09'] ?? null));
check('half of him during it', ($byDay['2026-10-12']['team_share'] ?? -1) == 0.5 && ($byDay['2026-10-12']['team_available_hours'] ?? -1) == 3.75, short($byDay['2026-10-12'] ?? null));
check('none after it', ($byDay['2026-10-19']['team_share'] ?? -1) == 0.0);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'team_id' => $dpId, 'from' => '2026-10-12', 'to' => '2026-10-12'], $lead);
check('and Data Platform keeps the other half', ($c['days'][0]['team_share'] ?? -1) == 0.5);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => '2026-10-12', 'to' => '2026-10-12'], $lead);
check('capacity_days itself is untouched: the row still says 7.5 hours', ($c['days'][0]['available_hours'] ?? 0) == 7.5 && !isset($c['days'][0]['team_share']));
// skills.php honours the scope
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
check('the day handed back belongs to Data Platform again', ($c['days'][0]['team_share'] ?? -1) == 0.0);
[$code, $r] = api('people.php', ['action' => 'add_loan', 'person_id' => $jon['id'], 'to_team_id' => $ipId, 'from_date' => '2026-10-15', 'to_date' => '2026-10-16'], $lead);
check('the freed days can be lent again', $code === 200, "$code " . short($r));
$loan2 = $r['loan']['id'] ?? null;
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'person_loan'], $admin);
check('every loan mutation is audited (create, update, create)', $code === 200 && ($a['total'] ?? 0) >= 3, short($a['total'] ?? null));
// inside the freeze horizon → urgent, and the scoped cycle runs (the workspace model moves nothing for a loan, so it reports skipped)
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

// ---- portfolio administration -----------------------------------------------------------------
section('Portfolio administration is admin-only; a portfolio with teams cannot be deleted');
[$code, $r] = api('portfolios.php', ['action' => 'save', 'name' => 'Test portfolio'], $lead);
check('save as delivery lead → 403', $code === 403);
[$code, $r] = api('portfolios.php', ['action' => 'save', 'name' => 'Test portfolio', 'description' => 'Made by portfolio_test.php'], $admin);
check('save as admin → 200', $code === 200 && isset($r['portfolio']['id']), "$code " . short($r));
$testId = $r['portfolio']['id'] ?? null;
[$code, $r] = api('portfolios.php', ['action' => 'save', 'name' => 'Data & Integration'], $admin);
check('duplicate name → 409', $code === 409);
[$code, $r] = api('portfolios.php', ['action' => 'save', 'id' => $testId, 'lead_person_id' => $jon['id']], $admin);
check('save can set a lead', $code === 200 && ($r['portfolio']['lead_name'] ?? null) === $jon['name'], short($r));
[$code, $r] = api('portfolios.php', ['action' => 'add_team', 'portfolio_id' => $testId, 'team_id' => $ipId], $lead);
check('add_team as delivery lead → 403', $code === 403);
[$code, $r] = api('portfolios.php', ['action' => 'add_team', 'portfolio_id' => $testId, 'team_id' => $ipId], $admin);
check('add_team moves Integration Platform into the test portfolio', $code === 200 && ($r['team']['portfolio_id'] ?? null) === $testId && count($r['portfolio']['teams'] ?? []) === 1, "$code " . short($r));
[$code, $r] = api('portfolios.php', ['action' => 'overview', 'portfolio_id' => $pfId], $lead);
check('Data & Integration now has one team, and Mei\'s loan now counts as loaned in from outside it', count($r['teams'] ?? []) === 1 && ($r['totals']['loaned_in'] ?? -1) === 1 && ($r['totals']['pool_size'] ?? -1) === 9, short($r['totals'] ?? null));
[$code, $r] = api('portfolios.php', ['action' => 'delete', 'id' => $testId], $admin);
check('delete while a team references it → 409 naming the team', $code === 409 && ($r['teams'][0]['id'] ?? null) === $ipId, "$code " . short($r));
[$code, $r] = api('portfolios.php', ['action' => 'remove_team', 'team_id' => $ipId], $admin);
check('remove_team → 200, team unassigned', $code === 200 && array_key_exists('portfolio_id', $r['team'] ?? []) && $r['team']['portfolio_id'] === null, "$code " . short($r));
[$code, $r] = api('portfolios.php', ['action' => 'remove_team', 'team_id' => $ipId], $admin);
check('remove_team again → 409', $code === 409);
[$code, $r] = api('portfolios.php', ['action' => 'delete', 'id' => $testId], $lead);
check('delete as delivery lead → 403', $code === 403);
[$code, $r] = api('portfolios.php', ['action' => 'delete', 'id' => $testId], $admin);
check('delete once empty → 200', $code === 200, "$code " . short($r));
[$code, $r] = api('portfolios.php', ['action' => 'add_team', 'portfolio_id' => $pfId, 'team_id' => $ipId], $admin);
check('Integration Platform put back into Data & Integration', $code === 200 && count($r['portfolio']['teams'] ?? []) === 2, "$code " . short($r));
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'portfolio'], $admin);
check('portfolio mutations are audited', $code === 200 && ($a['total'] ?? 0) >= 3, short($a['total'] ?? null));

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
