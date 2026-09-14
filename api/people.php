<?php
// Team, profiles, skills-per-person, availability, rota and capacity (TEAM-*).
// Actions: list | get | save | deactivate | set_skill | endorse_skill | add_availability | delete_availability |
//          set_rota | clear_rota | capacity | recompute_capacity | add_loan | end_loan | loans   (TEAM-09 loans)
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'list');
$today = today();
/** Loans (TEAM-09) are reported up to the end of the modelled horizon, like everything else the planner sees. */
function loan_horizon_end($conn, $wsId, $today) { return date('Y-m-d', strtotime(week_start($today) . ' +' . (int)current_policy($conn, $wsId)['model_horizon_weeks'] . ' weeks -1 day')); }
/**
 * Loan fields for one person: `loans` (every loan touching [$from,$to]), `on_loan_to` (the loan that
 * moves them elsewhere today, or null) and `loaned_from` (set when this person is in the caller's team
 * view only because of a loan into it — i.e. $teamIds given and their home team is not in it).
 */
function loan_fields(array $person, array $loans, $today, $teamIds = null) {
    $mine = array_values(array_filter($loans, fn($l) => $l['person_id'] === $person['id']));
    $active = null; foreach ($mine as $l) if ($l['from_date'] <= $today && $l['to_date'] >= $today) { $active = $l; break; }
    $set = $teamIds === null ? null : array_flip(array_map('intval', $teamIds));
    $loanedFrom = null;
    if ($set !== null && ($person['team_id'] === null || !isset($set[$person['team_id']]))) {
        foreach ($mine as $l) if (isset($set[$l['to_team_id']])) { $loanedFrom = $l; break; }
    }
    return ['loans' => $mine, 'on_loan_to' => $active, 'loaned_from' => $loanedFrom];
}
/**
 * Who may lend or recall (TEAM-09): a delivery lead or admin always; a team lead when their own person
 * sits in, or leads, either team. A team-lead account with no linked person has nothing to scope the
 * check to and passes on role alone.
 */
function require_loan_authority($conn, $wsId, $fromTeamId, $toTeamId) {
    global $personId;
    if (has_role('delivery_lead')) return;
    require_role('team_lead');
    if ($personId === null) return;
    $me = row($conn, "SELECT team_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$personId, $wsId]);
    $myTeam = $me && $me['team_id'] !== null ? (int)$me['team_id'] : null;
    $leads = array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.teams WHERE workspace_id = ? AND lead_person_id = ?", [$wsId, $personId]));
    foreach ([(int)$fromTeamId, (int)$toTeamId] as $t) if ($t === $myTeam || in_array($t, $leads, true)) return;
    fail('Forbidden: only a lead of the lending or borrowing team (or a delivery lead) can do that', 403);
}
const LEVEL_NAMES = ['None', 'Aware', 'Practitioner', 'Independent', 'Expert'];
const NUMBER_WORDS = ['zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve'];
function number_word($n) { return $n >= 0 && $n < count(NUMBER_WORDS) ? NUMBER_WORDS[$n] : (string)$n; }

/** Own profile (team_member+) or team_lead+. */
function require_own_or_lead($targetPersonId) {
    global $personId;
    if (has_role('team_lead')) return;
    if (has_role('team_member') && $personId !== null && (int)$targetPersonId === (int)$personId) return;
    fail('Forbidden: you can only edit your own profile', 403);
}
function person_row($conn, $wsId, $id) {
    $p = row($conn, "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.id = ? AND p.workspace_id = ?", [$id, $wsId]);
    if (!$p) fail('Person not found', 404);
    return $p;
}
function four_week_window($today) { return [$today, date('Y-m-d', strtotime("$today +27 days"))]; }
function committed_assignments($conn, $wsId, $personId, $fromDate) {
    $pv = committed_plan_version_id($conn, $wsId);
    if ($pv === null) return [];
    $rows = rows($conn, "SELECT a.*, wi.ref, wi.title, wi.status AS item_status, wi.health, wi.progress_pct, wt.colour AS type_colour, wt.name AS type_name, sc.stamp AS size_stamp
        FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id
        LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        WHERE a.plan_version_id = ? AND a.person_id = ? AND a.to_date >= ? ORDER BY a.from_date, a.id", [$pv, $personId, $fromDate]);
    $out = [];
    foreach ($rows as $a) {
        $mates = rows($conn, "SELECT DISTINCT p.name FROM dbo.assignments b JOIN dbo.people p ON p.id = b.person_id WHERE b.plan_version_id = ? AND b.work_item_id = ? AND b.person_id <> ? AND b.is_reserve = 0", [$pv, $a['work_item_id'], $personId]);
        $out[] = ['id' => (int)$a['id'], 'plan_version_id' => (int)$a['plan_version_id'], 'work_item_id' => (int)$a['work_item_id'], 'ref' => $a['ref'], 'title' => $a['title'],
            'type_colour' => $a['type_colour'], 'type_name' => $a['type_name'], 'size_stamp' => $a['size_stamp'] !== null ? trim($a['size_stamp']) : null,
            'person_id' => (int)$a['person_id'], 'from_date' => substr($a['from_date'], 0, 10), 'to_date' => substr($a['to_date'], 0, 10),
            'allocation_pct' => (int)$a['allocation_pct'], 'state' => $a['state'], 'role_label' => $a['role_label'], 'locked' => $a['locked_until'] !== null && substr($a['locked_until'], 0, 10) >= today(),
            'fixed_person' => (bool)$a['fixed_person'], 'fixed_dates' => (bool)$a['fixed_dates'], 'is_reserve' => (bool)$a['is_reserve'], 'note' => $a['note'],
            'item_status' => $a['item_status'], 'health' => $a['health'], 'progress_pct' => (int)$a['progress_pct'],
            'with' => array_map(fn($m) => explode(' ', $m['name'])[0], $mates)];
    }
    return $out;
}
function skills_for_person($conn, $wsId, $pid) {
    $rows = rows($conn, "SELECT ps.*, s.name, s.category FROM dbo.person_skills ps JOIN dbo.skills s ON s.id = ps.skill_id
        WHERE ps.person_id = ? AND s.retired = 0 ORDER BY ps.proficiency DESC, s.sort_order, s.name", [$pid]);
    $threePlus = [];
    foreach (rows($conn, "SELECT ps.skill_id, COUNT(*) n FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE p.workspace_id = ? AND p.active = 1 AND ps.proficiency >= 3 GROUP BY ps.skill_id", [$wsId]) as $r) $threePlus[(int)$r['skill_id']] = (int)$r['n'];
    $names = [];
    foreach (rows($conn, "SELECT id, name FROM dbo.people WHERE workspace_id = ?", [$wsId]) as $r) $names[(int)$r['id']] = $r['name'];
    $out = [];
    foreach ($rows as $r) {
        $endorsers = [];
        foreach (csv_ids($r['endorsed_by']) as $eid) if (isset($names[$eid])) $endorsers[] = $names[$eid];
        $prof = (int)$r['proficiency'];
        $out[] = ['skill_id' => (int)$r['skill_id'], 'name' => $r['name'], 'category' => $r['category'], 'proficiency' => $prof, 'level_name' => LEVEL_NAMES[$prof] ?? (string)$prof,
            'endorsed_by' => $endorsers, 'certified' => (bool)$r['certified'],
            'development_target' => $r['development_target'] !== null ? (int)$r['development_target'] : null, 'pairing_enabled' => (bool)$r['pairing_enabled'],
            'single_point' => $prof >= 3 && ($threePlus[(int)$r['skill_id']] ?? 0) === 1, 'updated_at' => $r['updated_at']];
    }
    return $out;
}
function availability_shape(array $a) {
    return ['id' => (int)$a['id'], 'person_id' => (int)$a['person_id'], 'from_date' => substr($a['from_date'], 0, 10), 'to_date' => substr($a['to_date'], 0, 10),
        'type' => $a['type'], 'fraction' => (float)$a['fraction'], 'source' => $a['source'], 'label' => $a['label'] ?: ucfirst($a['type']), 'created_at' => $a['created_at']];
}

// ---------------------------------------------------------------------------------
if ($action === 'list') {
    [$from, $to] = four_week_window($today);
    $includeInactive = (bool)param('include_inactive', false);
    // TEAM-09: team_id / portfolio_id narrow the list to that scope's planning pool — home members plus
    // anyone loaned into it (flagged with loaned_from). Load is then the scope's share of each person.
    $scope = scope_team_ids($conn, $wsId, ['team_id' => param('team_id'), 'portfolio_id' => param('portfolio_id')]);
    if ($scope === null) fail('Team or portfolio not found', 404);
    $horizonEnd = loan_horizon_end($conn, $wsId, $today);
    $people = rows($conn, "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.workspace_id = ?" . ($includeInactive ? '' : ' AND p.active = 1') . " ORDER BY p.name", [$wsId]);
    if ($scope['team_ids'] !== null) {
        $pool = team_pool($conn, $wsId, $scope['team_ids'], $today, $horizonEnd);
        $people = array_values(array_filter($people, fn($p) => isset($pool[(int)$p['id']])));
        $tl = team_load($conn, $wsId, $scope['team_ids'], $from, $to);
        $load = array_map(fn($x) => $x['load_pct'], $tl['people']);
    } else {
        $load = load_pct_map($conn, $wsId, $from, $to);
    }
    $loans = loans_in_window($conn, $wsId, $today, $horizonEnd);
    $skills = [];
    foreach (rows($conn, "SELECT ps.person_id, ps.skill_id, ps.proficiency FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE p.workspace_id = ?", [$wsId]) as $r)
        $skills[(int)$r['person_id']][] = ['skill_id' => (int)$r['skill_id'], 'proficiency' => (int)$r['proficiency']];
    $rota = [];
    foreach (rows($conn, "SELECT person_id, week_start FROM dbo.incident_rota WHERE workspace_id = ? AND week_start >= ? ORDER BY week_start", [$wsId, week_start($today)]) as $r)
        $rota[(int)$r['person_id']][] = substr($r['week_start'], 0, 10);
    $out = [];
    foreach ($people as $p) {
        $s = person_shape($p);
        $s['load_pct'] = $load[$s['id']] ?? 0;
        $s['skills'] = $skills[$s['id']] ?? [];
        $s['on_rota_weeks'] = $rota[$s['id']] ?? [];
        $s += loan_fields($s, $loans, $today, $scope['team_ids']);
        $out[] = $s;
    }
    $teams = rows($conn, "SELECT t.id, t.name, t.lead_person_id, t.portfolio_id, pf.name AS portfolio_name FROM dbo.teams t LEFT JOIN dbo.portfolios pf ON pf.id = t.portfolio_id WHERE t.workspace_id = ? ORDER BY t.name", [$wsId]);
    foreach ($teams as &$t) { $t['id'] = (int)$t['id']; $t['lead_person_id'] = $t['lead_person_id'] !== null ? (int)$t['lead_person_id'] : null; $t['portfolio_id'] = $t['portfolio_id'] !== null ? (int)$t['portfolio_id'] : null; }
    unset($t);
    ok(['people' => $out, 'teams' => $teams, 'window' => ['from' => $from, 'to' => $to], 'scope' => array_intersect_key($scope, array_flip(['kind', 'team_id', 'portfolio_id', 'name', 'team_ids']))]);
}

if ($action === 'get') {
    $id = (int)require_param('id');
    $p = person_row($conn, $wsId, $id);
    $person = person_shape($p);
    $policy = current_policy($conn, $wsId);
    $ws = workspace_row($conn, $wsId);
    [$from, $to] = four_week_window($today);
    $loadPct = load_pct_map($conn, $wsId, $from, $to, [$id])[$id] ?? 0;
    $targetMin = (int)$policy['target_load_min']; $targetMax = (int)$policy['target_load_max'];
    $loadNote = $loadPct > $targetMax ? "Above {$targetMax}% target ceiling" : ($loadPct < $targetMin ? "Below {$targetMin}% target floor" : "Within {$targetMin}–{$targetMax}% target");

    $assignments = committed_assignments($conn, $wsId, $id, $today);
    $concurrentNow = count(array_unique(array_map(fn($a) => $a['work_item_id'], array_filter($assignments, fn($a) => !$a['is_reserve'] && $a['from_date'] <= $today && $a['to_date'] >= $today))));
    $concurrentMax = $person['max_concurrent'] ?? (int)$policy['max_concurrent_items'];

    // Change history: 8 weeks ending this week, from person_change_log.
    $thisWeek = week_start($today);
    $weeks = []; for ($i = 7; $i >= 0; $i--) $weeks[] = date('Y-m-d', strtotime("$thisWeek -$i weeks"));
    $histFrom = $weeks[0];
    $hist = [];
    foreach ($weeks as $w) $hist[$w] = ['week_start' => $w, 'label' => 'w' . date('W', strtotime($w)), 'changes' => 0, 'inside_freeze' => 0, 'assignment_days' => 0.0];
    foreach (rows($conn, "SELECT week_start, COUNT(*) n, SUM(CASE WHEN inside_freeze = 1 THEN 1 ELSE 0 END) f, SUM(assignment_days) d FROM dbo.person_change_log WHERE workspace_id = ? AND person_id = ? AND week_start >= ? GROUP BY week_start", [$wsId, $id, $histFrom]) as $r) {
        $w = substr($r['week_start'], 0, 10);
        if (isset($hist[$w])) { $hist[$w]['changes'] = (int)$r['n']; $hist[$w]['inside_freeze'] = (int)$r['f']; $hist[$w]['assignment_days'] = (float)$r['d']; }
    }
    $changes8w = array_sum(array_column($hist, 'changes'));
    $insideFreeze8w = array_sum(array_column($hist, 'inside_freeze'));
    // Team median (same team, else whole workspace) over the same 8 weeks.
    $teamSql = $person['team_id'] !== null ? "p.team_id = ?" : "1 = 1";
    $teamParams = [$histFrom, $wsId]; if ($person['team_id'] !== null) $teamParams[] = $person['team_id'];
    $counts = array_map(fn($r) => (int)$r['n'], rows($conn, "SELECT p.id, (SELECT COUNT(*) FROM dbo.person_change_log c WHERE c.person_id = p.id AND c.week_start >= ?) n FROM dbo.people p WHERE p.workspace_id = ? AND p.active = 1 AND $teamSql", $teamParams));
    sort($counts); $n = count($counts);
    $median = $n ? ($n % 2 ? $counts[intdiv($n, 2)] : ($counts[$n / 2 - 1] + $counts[$n / 2]) / 2) : 0;
    $medianDisplay = $median == floor($median) ? (int)$median : $median;
    $changesNote = $n > 1 ? ($changes8w <= min($counts) ? 'Lowest in team' : ($changes8w >= max($counts) ? 'Highest in team' : ($changes8w < $median ? 'Below team median' : 'Above team median'))) : null;
    $freezePart = $changes8w === 0 ? '' : ($insideFreeze8w === 0 ? ', all outside the freeze horizon' : ", " . number_word($insideFreeze8w) . " inside the freeze horizon");
    $stabilityNote = ucfirst(number_word($changes8w)) . ($changes8w === 1 ? ' change' : ' changes') . " in eight weeks$freezePart. Team median is " . number_word($medianDisplay) . '.';

    $rota = array_map(fn($r) => substr($r['week_start'], 0, 10), rows($conn, "SELECT week_start FROM dbo.incident_rota WHERE workspace_id = ? AND person_id = ? AND week_start >= ? ORDER BY week_start", [$wsId, $id, $thisWeek]));
    $nextRota = $rota[0] ?? null;
    $rotaPct = fmt_pct($policy['rota_reserve_pct']); $incPct = fmt_pct($policy['incident_reserve_pct']);

    $availability = array_map('availability_shape', rows($conn, "SELECT * FROM dbo.availability WHERE workspace_id = ? AND person_id = ? AND to_date >= ? ORDER BY from_date", [$wsId, $id, date('Y-m-d', strtotime("$today -90 days"))]));
    $skills = skills_for_person($conn, $wsId, $id);
    $hpd = (float)$ws['hours_per_day'];
    $patternNote = pattern_note($person['working_pattern'], $hpd);
    // TEAM-09: loans in the same window as availability (90 days back to the end of the horizon), the one active today as on_loan_to.
    $person += loan_fields($person, loans_in_window($conn, $wsId, date('Y-m-d', strtotime("$today -90 days")), loan_horizon_end($conn, $wsId, $today), [$id]), $today);

    ok(['person' => $person, 'skills' => $skills, 'assignments' => $assignments, 'availability' => $availability, 'rota' => $rota,
        'stats' => ['load_pct_4w' => $loadPct, 'load_note' => $loadNote, 'target_load_min' => $targetMin, 'target_load_max' => $targetMax,
            'concurrent_now' => $concurrentNow, 'concurrent_max' => $concurrentMax, 'concurrent_note' => $concurrentNow >= $concurrentMax ? 'At limit' : ($concurrentMax - $concurrentNow) . ' slot' . ($concurrentMax - $concurrentNow === 1 ? '' : 's') . ' free',
            'changes_8w' => $changes8w, 'changes_inside_freeze_8w' => $insideFreeze8w, 'team_median_changes_8w' => $medianDisplay, 'changes_note' => $changesNote,
            'next_rota_week' => $nextRota, 'next_rota_label' => $nextRota ? 'w/c ' . fmt_day($nextRota) : null, 'next_rota_note' => $nextRota ? "Reserve rises to {$rotaPct}% that week" : 'Not on the rota',
            'reserve_pct' => (float)$policy['incident_reserve_pct'], 'rota_reserve_pct' => (float)$policy['rota_reserve_pct'],
            'reserve_note' => "{$incPct}% held back every week; {$rotaPct}% on rota weeks"],
        'change_history' => array_values($hist), 'stability_note' => $stabilityNote,
        'pattern' => ['hours_label' => $person['pattern_label'] ?: $patternNote, 'hours_per_day' => $hpd,
            'max_concurrent_label' => ($concurrentMax . ' items') . ($person['max_concurrent'] === null ? " (team default {$policy['max_concurrent_items']})" : ''),
            'focus_label' => 'Minimum ' . ($person['min_focus_days'] ?? (int)$policy['min_focus_days']) . ' consecutive days per item'],
        'freeze_horizon_end' => freeze_horizon_end($conn, $wsId, $policy)]);
}

if ($action === 'capacity') {
    $from = require_param('from'); $to = require_param('to');
    $pid = param('person_id') !== null ? (int)param('person_id') : null;
    ensure_capacity($conn, $wsId, $from, $to);
    $ids = $pid !== null ? [$pid] : null;
    $cap = capacity_map($conn, $wsId, $from, $to, $ids);
    $ws = workspace_row($conn, $wsId);
    $asg = assigned_hours_map($conn, $wsId, $from, $to, $cap, $ids, (float)$ws['hours_per_day']);
    // TEAM-09: with team_id, each day also carries the share of it that belongs to that team (1 for a home
    // member with no loan, the loan's share for a borrowed person, 0 when the person is entirely elsewhere).
    $pool = null;
    if (param('team_id') !== null && param('team_id') !== '') {
        $scope = scope_team_ids($conn, $wsId, ['team_id' => param('team_id')]);
        if ($scope === null) fail('Team not found', 404);
        $pool = team_pool($conn, $wsId, $scope['team_ids'], $from, $to);
    }
    $days = [];
    foreach ($cap as $p => $ds) foreach ($ds as $day => $c) {
        $row = ['person_id' => $p, 'day' => $day, 'available_hours' => $c['available'], 'reserve_hours' => $c['reserve'], 'assigned_hours' => round($asg[$p][$day] ?? 0, 2)];
        if ($pool !== null) { $row['team_share'] = isset($pool[$p]) ? team_share_for($pool[$p], $day) : 0.0; $row['team_available_hours'] = round($c['available'] * $row['team_share'], 2); }
        $days[] = $row;
    }
    usort($days, fn($a, $b) => [$a['person_id'], $a['day']] <=> [$b['person_id'], $b['day']]);
    ok(['days' => $days]);
}

if ($action === 'loans') {
    // TEAM-09: loans touching [from, to] (default: today to the end of the modelled horizon), for one person, one team, or the workspace.
    $from = param('from', $today); $to = param('to', loan_horizon_end($conn, $wsId, $today));
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $from) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $to)) fail('Dates must be YYYY-MM-DD', 400);
    $pid = param('person_id') !== null && param('person_id') !== '' ? [(int)param('person_id')] : null;
    $tid = param('team_id') !== null && param('team_id') !== '' ? [(int)param('team_id')] : null;
    ok(['loans' => loans_in_window($conn, $wsId, $from, $to, $pid, $tid), 'window' => ['from' => $from, 'to' => $to]]);
}

// ---- mutations ---------------------------------------------------------------------
if ($action === 'save') {
    $id = param('id') !== null ? (int)param('id') : null;
    if ($id !== null) require_own_or_lead($id); else require_role('team_lead');
    $before = $id !== null ? person_row($conn, $wsId, $id) : null;
    $b = body(); $data = [];
    foreach (['name','role_title','tagline','pattern_label','prefers','avoid','line_manager','email','colour'] as $f) if (array_key_exists($f, $b)) $data[$f] = $b[$f] !== null ? trim((string)$b[$f]) : null;
    if (array_key_exists('initials', $b)) $data['initials'] = $b['initials'] !== null && $b['initials'] !== '' ? strtoupper(substr(trim($b['initials']), 0, 2)) : null;
    if (array_key_exists('team_id', $b)) {
        if (!has_role('team_lead') && (int)($b['team_id'] ?? 0) !== (int)($before['team_id'] ?? 0)) fail('Forbidden: only a team lead can move someone between teams', 403);
        $data['team_id'] = $b['team_id'] !== null && $b['team_id'] !== '' ? (int)$b['team_id'] : null;
    }
    if (array_key_exists('days_per_week', $b)) $data['days_per_week'] = (float)$b['days_per_week'];
    if (array_key_exists('working_pattern', $b)) {
        $wp = is_array($b['working_pattern']) ? $b['working_pattern'] : json_col($b['working_pattern']);
        $clean = []; foreach (['Mon','Tue','Wed','Thu','Fri','Sat','Sun'] as $d) if (isset($wp[$d])) $clean[$d] = (float)$wp[$d];
        if (!$clean) fail('working_pattern must map weekday names to hours', 400);
        $data['working_pattern'] = json_encode($clean);
        if (!array_key_exists('days_per_week', $b)) { $hpd = (float)workspace_row($conn, $wsId)['hours_per_day']; $data['days_per_week'] = $hpd > 0 ? round(array_sum($clean) / $hpd, 1) : 5; }
    }
    foreach (['max_concurrent','min_focus_days'] as $f) if (array_key_exists($f, $b)) $data[$f] = $b[$f] !== null && $b[$f] !== '' ? (int)$b[$f] : null;
    if (array_key_exists('protected_until', $b) && has_role('team_lead')) $data['protected_until'] = $b['protected_until'] ?: null;
    if (array_key_exists('active', $b) && has_role('admin')) $data['active'] = $b['active'] ? 1 : 0;
    if ($id !== null) {
        update($conn, 'people', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    } else {
        if (empty($data['name'])) fail('name is required', 422);
        if (empty($data['initials'])) { $parts = preg_split('/\s+/', trim($data['name'])); $data['initials'] = strtoupper(substr($parts[0], 0, 1) . substr(end($parts), 0, 1)); }
        $data['workspace_id'] = $wsId;
        $id = insert($conn, 'people', $data);
    }
    $after = person_row($conn, $wsId, $id);
    audit($conn, $wsId, $before ? 'update' : 'create', 'person', $id, $before ? person_shape($before) : null, person_shape($after), $after['name']);
    if (isset($data['working_pattern']) || isset($data['active'])) derive_capacity($conn, $wsId, $today, date('Y-m-d', strtotime("$today +12 weeks")), [$id]);
    ok(['person' => person_shape($after)]);
}

if ($action === 'deactivate') {
    require_role('admin');
    $id = (int)require_param('id');
    $before = person_row($conn, $wsId, $id);
    if ($personId !== null && $id === (int)$personId) fail('You cannot deactivate yourself', 409);
    update($conn, 'people', ['active' => 0], 'id = ?', [$id]);
    q($conn, "UPDATE dbo.users SET active = 0 WHERE workspace_id = ? AND person_id = ?", [$wsId, $id]);
    $flagged = committed_assignments($conn, $wsId, $id, $today);
    foreach ($flagged as $a) update($conn, 'assignments', ['note' => 'Person deactivated ' . $today . ' - needs reassignment'], 'id = ?', [$a['id']]);
    if ($flagged) add_trigger($conn, $wsId, 'leave', 'urgent', "{$before['name']} deactivated with " . count($flagged) . " future assignment" . (count($flagged) === 1 ? '' : 's'), 'person', $id, [$id]);
    q($conn, "DELETE FROM dbo.capacity_days WHERE workspace_id = ? AND person_id = ? AND day >= ?", [$wsId, $id, $today]);
    $after = person_row($conn, $wsId, $id);
    audit($conn, $wsId, 'update', 'person', $id, ['active' => true], ['active' => false, 'flagged_assignments' => count($flagged)], $before['name'], 'Deactivated (ADM-03)');
    // STAB-05: the leaver's future work is an urgent trigger. The scope is everyone still active
    // *plus* the leaver, because a cycle scoped to the leaver alone could only report their work
    // as unschedulable — the point of this cycle is to offer it to somebody else.
    $replan = null;
    if ($flagged) {
        $scope = array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.people WHERE workspace_id = ? AND active = 1", [$wsId]));
        $scope[] = $id;
        $replan = start_urgent_cycle($conn, $wsId, $scope);
    }
    ok(['person' => person_shape($after), 'flagged_assignments' => $flagged] + ($replan ? ['urgent_replan' => $replan] : []));
}

if ($action === 'set_skill') {
    $pid = (int)require_param('person_id'); $sid = (int)require_param('skill_id');
    require_own_or_lead($pid);
    $p = person_row($conn, $wsId, $pid);
    $skill = row($conn, "SELECT id, name FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$sid, $wsId]);
    if (!$skill) fail('Skill not found', 404);
    $prof = max(0, min(4, (int)require_param('proficiency')));
    $before = row($conn, "SELECT * FROM dbo.person_skills WHERE person_id = ? AND skill_id = ?", [$pid, $sid]);
    $data = ['proficiency' => $prof, 'updated_at' => date('Y-m-d H:i:s')];
    if (param('certified') !== null) $data['certified'] = param('certified') ? 1 : 0;
    if (array_key_exists('development_target', body())) $data['development_target'] = param('development_target') !== null && param('development_target') !== '' ? max(0, min(4, (int)param('development_target'))) : null;
    if (param('pairing_enabled') !== null) $data['pairing_enabled'] = param('pairing_enabled') ? 1 : 0;
    if ($before) {
        if ((int)$before['proficiency'] !== $prof) $data['endorsed_by'] = null; // a changed level needs re-endorsing
        update($conn, 'person_skills', $data, 'person_id = ? AND skill_id = ?', [$pid, $sid]);
    } else {
        q($conn, "INSERT INTO dbo.person_skills (person_id, skill_id, proficiency, certified, development_target, pairing_enabled) VALUES (?,?,?,?,?,?)",
            [$pid, $sid, $prof, $data['certified'] ?? 0, $data['development_target'] ?? null, $data['pairing_enabled'] ?? 0]);
    }
    $after = row($conn, "SELECT * FROM dbo.person_skills WHERE person_id = ? AND skill_id = ?", [$pid, $sid]);
    audit($conn, $wsId, $before ? 'update' : 'create', 'person_skill', $pid, $before, $after, "{$p['name']} · {$skill['name']}");
    $out = null; foreach (skills_for_person($conn, $wsId, $pid) as $s) if ($s['skill_id'] === $sid) $out = $s;
    ok(['skill' => $out]);
}

if ($action === 'endorse_skill') {
    require_role('team_lead');
    if ($personId === null) fail('Your account is not linked to a person, so it cannot endorse', 422);
    $pid = (int)require_param('person_id'); $sid = (int)require_param('skill_id');
    $p = person_row($conn, $wsId, $pid);
    $before = row($conn, "SELECT * FROM dbo.person_skills WHERE person_id = ? AND skill_id = ?", [$pid, $sid]);
    if (!$before) fail('That person has not recorded this skill yet', 404);
    $ids = csv_ids($before['endorsed_by']);
    if (!in_array((int)$personId, $ids, true)) $ids[] = (int)$personId;
    update($conn, 'person_skills', ['endorsed_by' => implode(',', $ids), 'updated_at' => date('Y-m-d H:i:s')], 'person_id = ? AND skill_id = ?', [$pid, $sid]);
    $after = row($conn, "SELECT * FROM dbo.person_skills WHERE person_id = ? AND skill_id = ?", [$pid, $sid]);
    $skillName = scalar($conn, "SELECT name FROM dbo.skills WHERE id = ?", [$sid]);
    audit($conn, $wsId, 'approve', 'person_skill', $pid, $before, $after, "{$p['name']} · $skillName", 'Endorsed');
    notify_person($conn, $wsId, $pid, 'skill_endorsed', "$userName endorsed your $skillName level", null, "/people/$pid");
    $out = null; foreach (skills_for_person($conn, $wsId, $pid) as $s) if ($s['skill_id'] === $sid) $out = $s;
    ok(['skill' => $out]);
}

if ($action === 'add_availability') {
    $pid = (int)require_param('person_id');
    require_own_or_lead($pid);
    $p = person_row($conn, $wsId, $pid);
    $from = require_param('from_date'); $to = param('to_date', $from);
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $from) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $to)) fail('Dates must be YYYY-MM-DD', 400);
    if ($to < $from) fail('to_date must not be before from_date', 400);
    $type = strtolower(trim(require_param('type')));
    if (!in_array($type, ['leave','training','sickness','other'], true)) fail('type must be leave, training, sickness or other', 400);
    $fraction = param('fraction') !== null ? max(0.05, min(1.0, (float)param('fraction'))) : 1.0;
    // ADM-05: the type is all we hold. Any reason/note in the request is deliberately dropped, never stored.
    $data = ['workspace_id' => $wsId, 'person_id' => $pid, 'from_date' => $from, 'to_date' => $to, 'type' => $type, 'fraction' => $fraction,
        'source' => 'manual', 'label' => ucfirst($type), 'created_by' => $userId];
    $id = insert($conn, 'availability', $data);
    $row = row($conn, "SELECT * FROM dbo.availability WHERE id = ?", [$id]);
    $shape = availability_shape($row);
    audit($conn, $wsId, 'create', 'availability', $id, null, $shape, "{$p['name']} · " . ucfirst($type) . ' ' . fmt_range($from, $to));
    $written = derive_capacity($conn, $wsId, $from, $to, [$pid]);
    $policy = current_policy($conn, $wsId);
    $freezeEnd = freeze_horizon_end($conn, $wsId, $policy);
    $class = $from <= $freezeEnd ? 'urgent' : 'batched';
    $days = working_days_between($from, $to, workspace_working_days($conn, $wsId));
    $triggerId = add_trigger($conn, $wsId, $type === 'sickness' ? 'sickness' : 'leave', $class, "{$p['name']} " . ucfirst($type) . ' ' . fmt_range($from, $to) . " ($days " . ($days === 1 ? 'day' : 'days') . ')', 'availability', $id, [$pid]);
    // STAB-05: sickness or leave inside the freeze horizon is urgent, and an urgent trigger starts
    // an immediate cycle scoped to the affected person. Everything above is already committed, and
    // start_urgent_cycle() never throws, so a replan problem cannot fail this request.
    $replan = $class === 'urgent' ? start_urgent_cycle($conn, $wsId, [$pid]) : null;
    ok(['availability' => $shape, 'days_written' => $written, 'trigger' => ['id' => $triggerId, 'class' => $class], 'freeze_horizon_end' => $freezeEnd]
        + ($replan ? ['urgent_replan' => $replan] : []));
}

if ($action === 'delete_availability') {
    $id = (int)require_param('id');
    $a = row($conn, "SELECT * FROM dbo.availability WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$a) fail('Availability record not found', 404);
    require_own_or_lead((int)$a['person_id']);
    if ($a['source'] !== 'manual') fail("This record came from {$a['source']} and can be corrected there but not deleted here", 409, ['source' => $a['source']]);
    q($conn, "DELETE FROM dbo.availability WHERE id = ?", [$id]);
    $shape = availability_shape($a);
    audit($conn, $wsId, 'delete', 'availability', $id, $shape, null, ucfirst($a['type']) . ' ' . fmt_range($shape['from_date'], $shape['to_date']));
    $written = derive_capacity($conn, $wsId, $shape['from_date'], $shape['to_date'], [(int)$a['person_id']]);
    add_trigger($conn, $wsId, 'leave', 'batched', 'Availability removed ' . fmt_range($shape['from_date'], $shape['to_date']), 'availability', $id, [(int)$a['person_id']]);
    ok(['days_written' => $written]);
}

if ($action === 'set_rota' || $action === 'clear_rota') {
    require_role('team_lead');
    $pid = (int)require_param('person_id'); $wk = week_start(require_param('week_start'));
    $p = person_row($conn, $wsId, $pid);
    $existing = row($conn, "SELECT * FROM dbo.incident_rota WHERE workspace_id = ? AND person_id = ? AND week_start = ?", [$wsId, $pid, $wk]);
    if ($action === 'set_rota') {
        if (!$existing) { $rid = insert($conn, 'incident_rota', ['workspace_id' => $wsId, 'person_id' => $pid, 'week_start' => $wk]); audit($conn, $wsId, 'create', 'incident_rota', $rid, null, ['person_id' => $pid, 'week_start' => $wk], "{$p['name']} · w/c " . fmt_day($wk)); }
    } else {
        if ($existing) { q($conn, "DELETE FROM dbo.incident_rota WHERE id = ?", [$existing['id']]); audit($conn, $wsId, 'delete', 'incident_rota', (int)$existing['id'], ['person_id' => $pid, 'week_start' => $wk], null, "{$p['name']} · w/c " . fmt_day($wk)); }
    }
    $written = derive_capacity($conn, $wsId, $wk, date('Y-m-d', strtotime("$wk +6 days")), [$pid]);
    $rota = array_map(fn($r) => substr($r['week_start'], 0, 10), rows($conn, "SELECT week_start FROM dbo.incident_rota WHERE workspace_id = ? AND person_id = ? AND week_start >= ? ORDER BY week_start", [$wsId, $pid, week_start($today)]));
    ok(['rota' => $rota, 'days_written' => $written]);
}

// ---- TEAM-09 loans -----------------------------------------------------------------------------------
// A loan moves a share of a person's time to another team for a dated period. Capacity rows are not
// touched (see capacity.php); what changes is who the hours belong to, so both teams' plans may move.
// That is a `leave`-class trigger, urgent when it starts inside the freeze horizon — the same rule as
// add_availability — because inside the horizon the borrowing team cannot wait for the nightly cycle.
if ($action === 'add_loan') {
    $pid = (int)require_param('person_id'); $toTeam = (int)require_param('to_team_id');
    $p = person_row($conn, $wsId, $pid);
    if (!(int)$p['active']) fail('An inactive person cannot be lent', 409);
    if ($p['team_id'] === null) fail('This person has no home team, so there is nothing to lend them from', 409);
    $fromTeam = (int)$p['team_id'];
    if ($fromTeam === $toTeam) fail('to_team_id is already this person\'s home team', 400);
    $to = row($conn, "SELECT id, name FROM dbo.teams WHERE id = ? AND workspace_id = ?", [$toTeam, $wsId]);
    if (!$to) fail('Team not found', 404);
    require_loan_authority($conn, $wsId, $fromTeam, $toTeam);
    $from = require_param('from_date'); $until = require_param('to_date');
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $from) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $until)) fail('Dates must be YYYY-MM-DD', 400);
    if ($until < $from) fail('to_date must not be before from_date', 400);
    $pct = param('allocation_pct') !== null && param('allocation_pct') !== '' ? (int)param('allocation_pct') : 100;
    if ($pct < 1 || $pct > 100) fail('allocation_pct must be between 1 and 100', 400);
    $overlap = row($conn, "SELECT l.*, tt.name AS to_team_name, tf.name AS from_team_name FROM dbo.person_loans l JOIN dbo.teams tt ON tt.id = l.to_team_id JOIN dbo.teams tf ON tf.id = l.from_team_id
                           WHERE l.workspace_id = ? AND l.person_id = ? AND l.from_date <= ? AND l.to_date >= ? ORDER BY l.from_date", [$wsId, $pid, $until, $from]);
    if ($overlap) fail("{$p['name']} is already on loan to {$overlap['to_team_name']} " . fmt_range(substr($overlap['from_date'], 0, 10), substr($overlap['to_date'], 0, 10)) . '; end that loan first', 409, ['overlaps' => loan_shape($overlap)]);
    $reason = param('reason') !== null ? mb_substr(trim((string)param('reason')), 0, 300) : null;
    $id = insert($conn, 'person_loans', ['workspace_id' => $wsId, 'person_id' => $pid, 'from_team_id' => $fromTeam, 'to_team_id' => $toTeam,
        'from_date' => $from, 'to_date' => $until, 'allocation_pct' => $pct, 'reason' => $reason !== '' ? $reason : null, 'created_by' => $userId]);
    $loan = loans_in_window($conn, $wsId, $from, $until, [$pid])[0] ?? null;
    $label = "{$p['name']} lent to {$to['name']} " . fmt_range($from, $until) . ($pct < 100 ? " ({$pct}%)" : '');
    audit($conn, $wsId, 'create', 'person_loan', $id, null, $loan, $label, $reason);
    $policy = current_policy($conn, $wsId);
    $freezeEnd = freeze_horizon_end($conn, $wsId, $policy);
    $class = $from <= $freezeEnd ? 'urgent' : 'batched';
    $triggerId = add_trigger($conn, $wsId, 'leave', $class, $label . " · capacity moves from {$p['team_name']} to {$to['name']}", 'person_loan', $id, [$pid]);
    $replan = $class === 'urgent' ? start_urgent_cycle($conn, $wsId, [$pid]) : null;
    ok(['loan' => $loan, 'trigger' => ['id' => $triggerId, 'class' => $class], 'freeze_horizon_end' => $freezeEnd] + ($replan ? ['urgent_replan' => $replan] : []));
}

if ($action === 'end_loan') {
    $id = (int)require_param('id');
    $l = row($conn, "SELECT l.*, tt.name AS to_team_name, tf.name AS from_team_name, p.name AS person_name FROM dbo.person_loans l JOIN dbo.teams tt ON tt.id = l.to_team_id JOIN dbo.teams tf ON tf.id = l.from_team_id JOIN dbo.people p ON p.id = l.person_id WHERE l.id = ? AND l.workspace_id = ?", [$id, $wsId]);
    if (!$l) fail('Loan not found', 404);
    require_loan_authority($conn, $wsId, (int)$l['from_team_id'], (int)$l['to_team_id']);
    $before = loan_shape($l);
    $pid = (int)$l['person_id'];
    $policy = current_policy($conn, $wsId);
    $freezeEnd = freeze_horizon_end($conn, $wsId, $policy);
    $until = param('to_date');
    if ($until !== null && $until !== '' && !preg_match('/^\d{4}-\d{2}-\d{2}$/', $until)) fail('to_date must be YYYY-MM-DD', 400);
    if ($before['from_date'] > $today && ($until === null || $until === '' || $until < $before['from_date'])) {
        // Not started yet: nothing happened, so there is no history to keep. Cancel it outright.
        q($conn, "DELETE FROM dbo.person_loans WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
        audit($conn, $wsId, 'delete', 'person_loan', $id, $before, null, "{$l['person_name']} · loan to {$l['to_team_name']} cancelled before it started");
        $class = $before['from_date'] <= $freezeEnd ? 'urgent' : 'batched';
        $triggerId = add_trigger($conn, $wsId, 'leave', $class, "{$l['person_name']}'s loan to {$l['to_team_name']} cancelled · capacity stays with {$l['from_team_name']}", 'person_loan', $id, [$pid]);
        $replan = $class === 'urgent' ? start_urgent_cycle($conn, $wsId, [$pid]) : null;
        ok(['loan' => null, 'cancelled' => true, 'trigger' => ['id' => $triggerId, 'class' => $class]] + ($replan ? ['urgent_replan' => $replan] : []));
    }
    if ($until === null || $until === '') $until = max($before['from_date'], date('Y-m-d', strtotime("$today -1 day")));   // "ends now": yesterday was the last day
    if ($until < $before['from_date']) fail('to_date must not be before from_date', 400);
    if ($until > $before['to_date']) fail('end_loan can only shorten a loan; make a new loan to extend it', 400);
    update($conn, 'person_loans', ['to_date' => $until], 'id = ? AND workspace_id = ?', [$id, $wsId]);
    $after = loans_in_window($conn, $wsId, $before['from_date'], $until, [$pid])[0] ?? null;
    audit($conn, $wsId, 'update', 'person_loan', $id, $before, $after, "{$l['person_name']} · loan to {$l['to_team_name']} now ends " . fmt_day($until), param('reason') !== null ? mb_substr((string)param('reason'), 0, 300) : null);
    // The days handed back run from the new end to the old one; urgent when any of them is inside the horizon.
    $class = $until <= $freezeEnd ? 'urgent' : 'batched';
    $triggerId = add_trigger($conn, $wsId, 'leave', $class, "{$l['person_name']}'s loan to {$l['to_team_name']} ends " . fmt_day($until) . " (was " . fmt_day($before['to_date']) . ") · capacity returns to {$l['from_team_name']}", 'person_loan', $id, [$pid]);
    $replan = $class === 'urgent' ? start_urgent_cycle($conn, $wsId, [$pid]) : null;
    ok(['loan' => $after, 'trigger' => ['id' => $triggerId, 'class' => $class]] + ($replan ? ['urgent_replan' => $replan] : []));
}

if ($action === 'recompute_capacity') {
    require_role('team_lead');
    $policy = current_policy($conn, $wsId);
    $from = param('from', week_start($today));
    $to = param('to', date('Y-m-d', strtotime($from . ' +' . (int)$policy['model_horizon_weeks'] . ' weeks -1 day')));
    $written = derive_capacity($conn, $wsId, $from, $to);
    audit($conn, $wsId, 'update', 'capacity', null, null, ['from' => $from, 'to' => $to, 'days_written' => $written], 'Capacity recomputed');
    ok(['days_written' => $written, 'from' => $from, 'to' => $to]);
}

fail('Unknown action', 400);

function fmt_pct($v) { $v = (float)$v; return $v == floor($v) ? (string)(int)$v : rtrim(rtrim(number_format($v, 2, '.', ''), '0'), '.'); }
/** "Mon–Thu full, Fri half day" style summary of a working pattern. */
function pattern_note(array $wp, $hpd) {
    $full = []; $part = []; $off = [];
    foreach (['Mon','Tue','Wed','Thu','Fri'] as $d) {
        $h = (float)($wp[$d] ?? 0);
        if ($h <= 0) $off[] = $d; elseif ($hpd > 0 && $h < $hpd - 0.01) $part[] = [$d, $h / $hpd]; else $full[] = $d;
    }
    if (!$part && !$off) return 'Full time, ' . count($full) . ' days';
    $bits = [];
    if ($full) $bits[] = (count($full) > 2 && $full === array_slice(['Mon','Tue','Wed','Thu','Fri'], 0, count($full)) ? $full[0] . '–' . end($full) : implode('/', $full)) . ' full';
    foreach ($part as [$d, $f]) $bits[] = "$d " . (abs($f - 0.5) < 0.05 ? 'half day' : round($f * 100) . '%');
    if ($off) $bits[] = implode('/', $off) . ' off';
    return implode(', ', $bits);
}
