<?php
// Portfolios: named groupings of teams for cross-team views and multi-team planning (TEAM-09, SCH-13).
// Actions: list | overview{portfolio_id} (everyone) | save | delete | add_team | remove_team (admin)
//
// A team sits in at most one portfolio (teams.portfolio_id). The overview is the cross-team view
// TEAM-09 asks for: each team's headcount, load, single-skill dependencies, stability and open
// proposals side by side, with the portfolio total underneath. Loans (dbo.person_loans) are honoured
// everywhere a figure is per team: a person lent at 50% counts half for each team, so the teams add
// up to the portfolio and nobody is counted twice.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'list');
$today = today();

function portfolio_row($conn, $wsId, $id) {
    $p = row($conn, "SELECT pf.*, lp.name AS lead_name FROM dbo.portfolios pf LEFT JOIN dbo.people lp ON lp.id = pf.lead_person_id WHERE pf.id = ? AND pf.workspace_id = ?", [$id, $wsId]);
    if (!$p) fail('Portfolio not found', 404);
    return $p;
}
function portfolio_shape(array $p) {
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'description' => $p['description'],
        'lead_person_id' => $p['lead_person_id'] !== null ? (int)$p['lead_person_id'] : null, 'lead_name' => $p['lead_name'] ?? null, 'created_at' => $p['created_at'] ?? null];
}
function team_rows($conn, $wsId, $portfolioId = null) {
    $sql = "SELECT t.id, t.name, t.lead_person_id, t.portfolio_id, lp.name AS lead_name, lp.initials AS lead_initials, lp.colour AS lead_colour
            FROM dbo.teams t LEFT JOIN dbo.people lp ON lp.id = t.lead_person_id WHERE t.workspace_id = ?";
    $params = [$wsId];
    if ($portfolioId !== null) { $sql .= " AND t.portfolio_id = ?"; $params[] = $portfolioId; }
    return rows($conn, $sql . " ORDER BY t.name", $params);
}
function team_lite(array $t) {
    return ['id' => (int)$t['id'], 'name' => $t['name'], 'portfolio_id' => $t['portfolio_id'] !== null ? (int)$t['portfolio_id'] : null,
        'lead_person_id' => $t['lead_person_id'] !== null ? (int)$t['lead_person_id'] : null,
        'lead' => $t['lead_person_id'] !== null ? ['id' => (int)$t['lead_person_id'], 'name' => $t['lead_name'], 'initials' => trim((string)$t['lead_initials']), 'colour' => $t['lead_colour']] : null];
}

/**
 * The cross-team figures for one set of teams over [$from,$to] (the next four weeks). Called once per
 * team and once for the portfolio as a whole, so the portfolio row is computed the same way as a team
 * row rather than summed — and the test that the two agree is a real check on the arithmetic.
 */
function team_figures($conn, $wsId, array $teamIds, $today, $from, $to, $plannedEnd) {
    $load = team_load($conn, $wsId, $teamIds, $from, $to);
    $pool = team_pool($conn, $wsId, $teamIds, $today, $plannedEnd);
    $homeIds = array_keys(array_filter($pool, fn($e) => $e['home']));
    $poolIds = array_keys($pool);
    // loaned_in / loaned_out count people, over the same four weeks as the load and as portfolios.php `list`:
    // someone in the pool only through a loan into this set, and a home member with a loan out of it.
    $out = ['headcount' => $load['headcount'], 'pool_size' => count($poolIds), 'loaned_in' => $load['loaned_in'], 'loaned_out' => $load['loaned_out'],
        'available_hours' => $load['available_hours'], 'assigned_hours' => $load['assigned_hours'], 'load_pct' => $load['load_pct'],
        'single_skill_deps' => 0, 'single_skill_names' => [], 'stability_index' => 100.0, 'moved_days_4w' => 0.0, 'total_days_4w' => 0.0,
        'open_proposals' => 0, 'people' => []];
    foreach ($load['people'] as $pid => $x) $out['people'][] = ['person_id' => $pid] + $x;
    if (!$poolIds) return $out;
    $in = implode(',', array_fill(0, count($poolIds), '?'));
    $pv = committed_plan_version_id($conn, $wsId);
    // Single-skill dependencies: skills required by this set's committed work in the planned window
    // that exactly one person in the pool holds at the required level (SCH-05 / watch list, per team).
    if ($pv !== null) {
        $reqs = rows($conn, "SELECT DISTINCT sr.skill_id, sr.min_proficiency, s.name FROM dbo.assignments a JOIN dbo.skill_requirements sr ON sr.work_item_id = a.work_item_id JOIN dbo.skills s ON s.id = sr.skill_id JOIN dbo.work_items wi ON wi.id = a.work_item_id
                             WHERE a.plan_version_id = ? AND a.person_id IN ($in) AND a.to_date >= ? AND a.from_date <= ? AND wi.status NOT IN ('delivered','cancelled')", array_merge([$pv], $poolIds, [$today, $plannedEnd]));
        $levels = [];
        foreach (rows($conn, "SELECT person_id, skill_id, proficiency FROM dbo.person_skills WHERE person_id IN ($in)", $poolIds) as $r) $levels[(int)$r['skill_id']][(int)$r['person_id']] = (int)$r['proficiency'];
        $single = [];
        foreach ($reqs as $r) {
            $n = 0; foreach ($levels[(int)$r['skill_id']] ?? [] as $lvl) if ($lvl >= (int)$r['min_proficiency']) $n++;
            if ($n === 1) $single[$r['name'] . ' L' . (int)$r['min_proficiency']] = true;
        }
        $out['single_skill_names'] = array_keys($single); $out['single_skill_deps'] = count($single);
    }
    // Stability (STAB-08 restricted to these people): 1 − moved assignment-days over the last four weeks
    // ÷ the set's committed assignment-days over the same four weeks plus the planned window.
    if ($homeIds) {
        $hin = implode(',', array_fill(0, count($homeIds), '?'));
        $wk = week_start($today); $wkFrom = date('Y-m-d', strtotime("$wk -3 weeks"));
        $moved = (float)(scalar($conn, "SELECT ISNULL(SUM(assignment_days), 0) FROM dbo.person_change_log WHERE workspace_id = ? AND week_start BETWEEN ? AND ? AND person_id IN ($hin)", array_merge([$wsId, $wkFrom, $wk], $homeIds)) ?? 0);
        $total = 0.0;
        if ($pv !== null) {
            $wd = workspace_working_days($conn, $wsId);
            foreach (rows($conn, "SELECT from_date, to_date, allocation_pct FROM dbo.assignments WHERE plan_version_id = ? AND is_reserve = 0 AND person_id IN ($hin) AND to_date >= ? AND from_date <= ?", array_merge([$pv], $homeIds, [$wkFrom, $plannedEnd])) as $a) {
                $s = max($wkFrom, substr($a['from_date'], 0, 10)); $e = min($plannedEnd, substr($a['to_date'], 0, 10));
                $total += working_days_between($s, $e, $wd) * (int)$a['allocation_pct'] / 100;
            }
        }
        $out['moved_days_4w'] = round($moved, 2); $out['total_days_4w'] = round($total, 2);
        $out['stability_index'] = $total > 0 ? round(max(0, 1 - $moved / $total) * 100, 1) : 100.0;
        $out['open_proposals'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.change_proposals c JOIN dbo.proposals p ON p.id = c.proposal_id WHERE c.workspace_id = ? AND p.status = 'open' AND c.decision = 'pending' AND c.person_id IN ($hin)", array_merge([$wsId], $homeIds));
    }
    return $out;
}

// ---------------------------------------------------------------------------------------------------
if ($action === 'list') {
    $from = $today; $to = date('Y-m-d', strtotime("$today +27 days"));
    $out = [];
    foreach (rows($conn, "SELECT pf.*, lp.name AS lead_name FROM dbo.portfolios pf LEFT JOIN dbo.people lp ON lp.id = pf.lead_person_id WHERE pf.workspace_id = ? ORDER BY pf.name", [$wsId]) as $pf) {
        $shape = portfolio_shape($pf);
        $teams = []; $ids = [];
        foreach (team_rows($conn, $wsId, (int)$pf['id']) as $t) {
            $tl = team_load($conn, $wsId, [(int)$t['id']], $from, $to);
            $teams[] = team_lite($t) + ['headcount' => $tl['headcount'], 'loaned_in' => $tl['loaned_in'], 'loaned_out' => $tl['loaned_out'], 'load_pct' => $tl['load_pct'], 'available_hours' => $tl['available_hours'], 'assigned_hours' => $tl['assigned_hours']];
            $ids[] = (int)$t['id'];
        }
        $all = $ids ? team_load($conn, $wsId, $ids, $from, $to) : ['headcount' => 0, 'load_pct' => 0, 'available_hours' => 0.0, 'assigned_hours' => 0.0];
        $out[] = $shape + ['teams' => $teams, 'team_count' => count($teams), 'headcount' => $all['headcount'], 'load_pct' => $all['load_pct'], 'available_hours' => $all['available_hours'], 'assigned_hours' => $all['assigned_hours']];
    }
    $unassigned = array_map('team_lite', array_filter(team_rows($conn, $wsId), fn($t) => $t['portfolio_id'] === null));
    ok(['portfolios' => $out, 'unassigned_teams' => array_values($unassigned), 'window' => ['from' => $from, 'to' => $to]]);
}

if ($action === 'overview') {
    $id = (int)require_param('portfolio_id');
    $pf = portfolio_row($conn, $wsId, $id);
    $policy = current_policy($conn, $wsId);
    $from = $today; $to = date('Y-m-d', strtotime("$today +27 days"));
    $plannedEnd = date('Y-m-d', strtotime(week_start($today) . ' +' . (int)$policy['planning_horizon_weeks'] . ' weeks -1 day'));
    $teams = []; $ids = [];
    foreach (team_rows($conn, $wsId, $id) as $t) {
        $teams[] = team_lite($t) + team_figures($conn, $wsId, [(int)$t['id']], $today, $from, $to, $plannedEnd);
        $ids[] = (int)$t['id'];
    }
    $totals = $ids ? team_figures($conn, $wsId, $ids, $today, $from, $to, $plannedEnd) : team_figures($conn, $wsId, [-1], $today, $from, $to, $plannedEnd);
    unset($totals['people']);
    // Loans between the portfolio's teams, and in or out of it, active or upcoming in the window.
    $loans = $ids ? loans_in_window($conn, $wsId, $from, $plannedEnd, null, $ids) : [];
    $tmin = (int)$policy['target_load_min']; $tmax = (int)$policy['target_load_max'];
    ok(['portfolio' => portfolio_shape($pf), 'teams' => $teams, 'totals' => $totals, 'loans' => $loans,
        'window' => ['from' => $from, 'to' => $to, 'planned_end' => $plannedEnd], 'target_load_min' => $tmin, 'target_load_max' => $tmax,
        'definitions' => ['load' => 'Committed assignment hours ÷ available hours over the next four weeks, each person weighted by the share of their time that belongs to the team (loans).',
            'single_skill_deps' => 'Skills the team\'s committed work needs in the planned window that exactly one person in the team (including anyone loaned in) holds at the required level.',
            'stability_index' => 'STAB-08 for the team\'s own people: 1 − moved assignment-days in the last four weeks ÷ their committed assignment-days over those weeks and the planned window.',
            'open_proposals' => 'Pending changes in the open proposal that name one of the team\'s own people.']]);
}

// ---- mutations (admin) --------------------------------------------------------------------------------
require_role('admin');

if ($action === 'save') {
    $id = param('id') !== null && param('id') !== '' ? (int)param('id') : null;
    $before = $id !== null ? portfolio_row($conn, $wsId, $id) : null;
    $data = [];
    if (param('name') !== null) { $data['name'] = mb_substr(trim((string)param('name')), 0, 80); if ($data['name'] === '') fail('name is required', 422); }
    if (array_key_exists('description', body())) $data['description'] = param('description') !== null ? mb_substr(trim((string)param('description')), 0, 300) : null;
    if (array_key_exists('lead_person_id', body())) {
        $lead = param('lead_person_id');
        if ($lead !== null && $lead !== '') { if (!row($conn, "SELECT id FROM dbo.people WHERE id = ? AND workspace_id = ?", [(int)$lead, $wsId])) fail('Lead person not found', 404); $data['lead_person_id'] = (int)$lead; }
        else $data['lead_person_id'] = null;
    }
    if (isset($data['name'])) {
        $dup = scalar($conn, "SELECT id FROM dbo.portfolios WHERE workspace_id = ? AND name = ? AND id <> ?", [$wsId, $data['name'], $id ?? -1]);
        if ($dup !== null) fail("A portfolio called {$data['name']} already exists", 409, ['existing_id' => (int)$dup]);
    }
    if ($id !== null) update($conn, 'portfolios', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    else { if (empty($data['name'])) fail('name is required', 422); $data['workspace_id'] = $wsId; $id = insert($conn, 'portfolios', $data); }
    $after = portfolio_row($conn, $wsId, $id);
    audit($conn, $wsId, $before ? 'update' : 'create', 'portfolio', $id, $before ? portfolio_shape($before) : null, portfolio_shape($after), $after['name']);
    ok(['portfolio' => portfolio_shape($after) + ['teams' => array_map('team_lite', team_rows($conn, $wsId, $id))]]);
}

if ($action === 'delete') {
    $id = (int)require_param('id');
    $pf = portfolio_row($conn, $wsId, $id);
    $teams = team_rows($conn, $wsId, $id);
    if ($teams) fail(count($teams) . ' team' . (count($teams) === 1 ? ' still belongs' : 's still belong') . " to {$pf['name']}; remove them first", 409, ['teams' => array_map('team_lite', $teams)]);
    q($conn, "DELETE FROM dbo.portfolios WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    audit($conn, $wsId, 'delete', 'portfolio', $id, portfolio_shape($pf), null, $pf['name']);
    ok(['deleted' => $id]);
}

if ($action === 'add_team' || $action === 'remove_team') {
    $teamId = (int)require_param('team_id');
    $t = row($conn, "SELECT t.*, pf.name AS portfolio_name FROM dbo.teams t LEFT JOIN dbo.portfolios pf ON pf.id = t.portfolio_id WHERE t.id = ? AND t.workspace_id = ?", [$teamId, $wsId]);
    if (!$t) fail('Team not found', 404);
    $before = ['team_id' => $teamId, 'portfolio_id' => $t['portfolio_id'] !== null ? (int)$t['portfolio_id'] : null, 'portfolio_name' => $t['portfolio_name']];
    if ($action === 'add_team') {
        $pid = (int)require_param('portfolio_id');
        $pf = portfolio_row($conn, $wsId, $pid);
        update($conn, 'teams', ['portfolio_id' => $pid], 'id = ? AND workspace_id = ?', [$teamId, $wsId]);
        $after = ['team_id' => $teamId, 'portfolio_id' => $pid, 'portfolio_name' => $pf['name']];
        audit($conn, $wsId, 'update', 'team', $teamId, $before, $after, "{$t['name']} → {$pf['name']}", $before['portfolio_id'] !== null && $before['portfolio_id'] !== $pid ? "Moved from {$before['portfolio_name']}" : 'Added to portfolio');
        ok(['team' => team_lite(team_rows_one($conn, $wsId, $teamId)), 'portfolio' => portfolio_shape($pf) + ['teams' => array_map('team_lite', team_rows($conn, $wsId, $pid))]]);
    }
    if ($t['portfolio_id'] === null) fail("{$t['name']} is not in a portfolio", 409);
    update($conn, 'teams', ['portfolio_id' => null], 'id = ? AND workspace_id = ?', [$teamId, $wsId]);
    audit($conn, $wsId, 'update', 'team', $teamId, $before, ['team_id' => $teamId, 'portfolio_id' => null, 'portfolio_name' => null], "{$t['name']} removed from {$t['portfolio_name']}");
    ok(['team' => team_lite(team_rows_one($conn, $wsId, $teamId))]);
}

fail('Unknown action', 400);

function team_rows_one($conn, $wsId, $teamId) {
    foreach (team_rows($conn, $wsId) as $t) if ((int)$t['id'] === (int)$teamId) return $t;
    fail('Team not found', 404);
}
