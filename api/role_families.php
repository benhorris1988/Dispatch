<?php
// Role families (ORG-02): a discipline people belong to — Data engineering, Analytics — spanning the
// team tree. Actions: list | overview{role_family_id} (everyone) | save | delete | set_person (admin)
//
// This replaces portfolios.php, which grouped whole TEAMS. A role family groups PEOPLE instead, so a
// team can contain three disciplines and a discipline can reach into six teams. That changes the
// arithmetic in one useful way: a loan moves a person between teams but never between disciplines, so
// every person counts exactly once for their family wherever they are sitting this fortnight.
//
// The overview keeps the envelope portfolios.php used — the family's people grouped by the team they
// sit in, each team's figures, then the family as a whole — because the two must agree: the totals are
// computed over the whole family rather than summed from the rows, and the suite checks they match.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'list');
$today = today();

function role_family_row($conn, $wsId, $id) {
    $rf = row($conn, "SELECT rf.*, lp.name AS lead_name, lp.initials AS lead_initials, lp.colour AS lead_colour
                      FROM dbo.role_families rf LEFT JOIN dbo.people lp ON lp.id = rf.lead_person_id
                      WHERE rf.id = ? AND rf.workspace_id = ?", [$id, $wsId]);
    if (!$rf) fail('Role family not found', 404);
    return $rf;
}
function role_family_shape(array $rf) {
    return ['id' => (int)$rf['id'], 'name' => $rf['name'], 'description' => $rf['description'],
        'lead_person_id' => $rf['lead_person_id'] !== null ? (int)$rf['lead_person_id'] : null,
        'lead_name' => $rf['lead_name'] ?? null, 'created_at' => $rf['created_at'] ?? null];
}
/** Active people in one family (or, with null, everyone with no family), in name order. */
function family_people_rows($conn, $wsId, $rfId) {
    $sql = "SELECT p.id, p.name, p.initials, p.colour, p.role_title, p.team_id, p.manager_person_id, p.role_family_id,
                   t.name AS team_name, m.name AS manager_name
            FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id LEFT JOIN dbo.people m ON m.id = p.manager_person_id
            WHERE p.workspace_id = ? AND p.active = 1 AND " . ($rfId === null ? "p.role_family_id IS NULL" : "p.role_family_id = ?");
    return rows($conn, $sql . " ORDER BY p.name", $rfId === null ? [$wsId] : [$wsId, (int)$rfId]);
}
function person_lite(array $p) {
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => $p['initials'] !== null ? trim((string)$p['initials']) : null,
        'colour' => $p['colour'], 'role_title' => $p['role_title'] ?? null,
        'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null, 'team_name' => $p['team_name'] ?? null,
        'manager_person_id' => isset($p['manager_person_id']) && $p['manager_person_id'] !== null ? (int)$p['manager_person_id'] : null,
        'manager_name' => $p['manager_name'] ?? null,
        'role_family_id' => isset($p['role_family_id']) && $p['role_family_id'] !== null ? (int)$p['role_family_id'] : null];
}
/** A scope over a fixed set of people, for scope_figures(). */
function person_scope(array $personIds) {
    return ['kind' => 'role_family', 'team_id' => null, 'role_family_id' => null, 'name' => null,
        'team_ids' => null, 'person_ids' => array_values(array_map('intval', $personIds))];
}

/**
 * The cross-team figures for one scope over [$from,$to] (the next four weeks). Called once per team a
 * family reaches into and once for the family as a whole, so the total row is computed exactly the way
 * a team row is rather than summed — and the test that the two agree is a real check on the arithmetic.
 *
 * This is the old portfolios.php team_figures(), taking a scope array instead of team ids so it serves
 * both a set of teams (a branch of the tree) and a set of people (a role family).
 */
function scope_figures($conn, $wsId, array $scope, $today, $from, $to, $plannedEnd) {
    $load = scope_load($conn, $wsId, $scope, $from, $to);
    $pool = scope_pool($conn, $wsId, $scope, $today, $plannedEnd);
    $homeIds = array_keys(array_filter($pool, fn($e) => $e['home']));
    $poolIds = array_keys($pool);
    $out = ['headcount' => $load['headcount'], 'pool_size' => count($poolIds), 'loaned_in' => $load['loaned_in'], 'loaned_out' => $load['loaned_out'],
        'available_hours' => $load['available_hours'], 'assigned_hours' => $load['assigned_hours'], 'load_pct' => $load['load_pct'],
        'single_skill_deps' => 0, 'single_skill_names' => [], 'stability_index' => 100.0, 'moved_days_4w' => 0.0, 'total_days_4w' => 0.0,
        'open_proposals' => 0, 'people' => []];
    foreach ($load['people'] as $pid => $x) $out['people'][] = ['person_id' => $pid] + $x;
    if (!$poolIds) return $out;
    $in = implode(',', array_fill(0, count($poolIds), '?'));
    $pv = committed_plan_version_id($conn, $wsId);
    // Single-skill dependencies: skills required by this set's committed work in the planned window
    // that exactly one person in the pool holds at the required level (SCH-05 / watch list).
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
    foreach (rows($conn, "SELECT rf.*, lp.name AS lead_name FROM dbo.role_families rf LEFT JOIN dbo.people lp ON lp.id = rf.lead_person_id WHERE rf.workspace_id = ? ORDER BY rf.name", [$wsId]) as $rf) {
        $people = family_people_rows($conn, $wsId, (int)$rf['id']);
        $ids = array_map(fn($p) => (int)$p['id'], $people);
        $load = $ids ? scope_load($conn, $wsId, person_scope($ids), $from, $to) : ['headcount' => 0, 'load_pct' => 0, 'available_hours' => 0.0, 'assigned_hours' => 0.0];
        // Which teams the discipline reaches into, and how many of its people sit in each.
        $spanned = [];
        foreach ($people as $p) {
            $tid = $p['team_id'] !== null ? (int)$p['team_id'] : 0;
            if (!isset($spanned[$tid])) $spanned[$tid] = ['id' => $tid ?: null, 'name' => $p['team_name'] ?? 'No team', 'count' => 0];
            $spanned[$tid]['count']++;
        }
        $out[] = role_family_shape($rf) + ['headcount' => count($ids), 'load_pct' => $load['load_pct'],
            'available_hours' => $load['available_hours'], 'assigned_hours' => $load['assigned_hours'],
            'teams_spanned' => array_values($spanned), 'people' => array_map('person_lite', $people)];
    }
    $unassigned = array_map('person_lite', family_people_rows($conn, $wsId, null));
    ok(['role_families' => $out, 'unassigned_people' => $unassigned, 'window' => ['from' => $from, 'to' => $to]]);
}

if ($action === 'overview') {
    $id = (int)require_param('role_family_id');
    $rf = role_family_row($conn, $wsId, $id);
    $policy = current_policy($conn, $wsId);
    $from = $today; $to = date('Y-m-d', strtotime("$today +27 days"));
    $plannedEnd = date('Y-m-d', strtotime(week_start($today) . ' +' . (int)$policy['planning_horizon_weeks'] . ' weeks -1 day'));
    $people = family_people_rows($conn, $wsId, $id);
    $allIds = array_map(fn($p) => (int)$p['id'], $people);
    // Grouped by the team each person sits in, in tree order; people with no team make their own row.
    $c = team_closure($conn, $wsId);
    $byTeam = [];
    foreach ($people as $p) {
        $tid = $p['team_id'] !== null ? (int)$p['team_id'] : 0;
        $byTeam[$tid]['people'][] = $p;
        $byTeam[$tid]['name'] = $p['team_name'] ?? 'No team';
    }
    uksort($byTeam, fn($a, $b) => [$a ? team_path($conn, $wsId, $a) : 'zzz'] <=> [$b ? team_path($conn, $wsId, $b) : 'zzz']);
    $teams = [];
    foreach ($byTeam as $tid => $g) {
        $ids = array_map(fn($p) => (int)$p['id'], $g['people']);
        $lead = $tid && isset($c['teams'][$tid]) ? $c['teams'][$tid]['lead_person_id'] : null;
        $teams[] = ['id' => $tid ?: null, 'name' => $g['name'],
            'parent_team_id' => $tid && isset($c['teams'][$tid]) ? $c['teams'][$tid]['parent_team_id'] : null,
            'path' => $tid ? team_path($conn, $wsId, $tid) : 'No team',
            'lead_person_id' => $lead, 'in_family' => count($ids),
            'people_lite' => array_map('person_lite', $g['people'])]
            + scope_figures($conn, $wsId, person_scope($ids), $today, $from, $to, $plannedEnd);
    }
    $totals = scope_figures($conn, $wsId, person_scope($allIds), $today, $from, $to, $plannedEnd);
    unset($totals['people']);
    $loans = $allIds ? loans_in_window($conn, $wsId, $from, $plannedEnd, $allIds) : [];
    ok(['role_family' => role_family_shape($rf), 'teams' => $teams, 'totals' => $totals, 'loans' => $loans,
        'people' => array_map('person_lite', $people),
        'window' => ['from' => $from, 'to' => $to, 'planned_end' => $plannedEnd],
        'target_load_min' => (int)$policy['target_load_min'], 'target_load_max' => (int)$policy['target_load_max'],
        'definitions' => ['load' => 'Committed assignment hours ÷ available hours over the next four weeks. Everyone counts once for their role family wherever they sit, so a loan between teams changes nothing here.',
            'single_skill_deps' => 'Skills this group\'s committed work needs in the planned window that exactly one of them holds at the required level.',
            'stability_index' => 'STAB-08 for these people: 1 − moved assignment-days in the last four weeks ÷ their committed assignment-days over those weeks and the planned window.',
            'open_proposals' => 'Pending changes in the open proposal that name one of these people.']]);
}

// ---- mutations (admin) --------------------------------------------------------------------------------
require_role('admin');

if ($action === 'save') {
    $id = param('id') !== null && param('id') !== '' ? (int)param('id') : null;
    $before = $id !== null ? role_family_row($conn, $wsId, $id) : null;
    $data = [];
    if (param('name') !== null) { $data['name'] = mb_substr(trim((string)param('name')), 0, 80); if ($data['name'] === '') fail('name is required', 422); }
    if (array_key_exists('description', body())) $data['description'] = param('description') !== null ? mb_substr(trim((string)param('description')), 0, 300) : null;
    if (array_key_exists('lead_person_id', body())) {
        $lead = param('lead_person_id');
        if ($lead !== null && $lead !== '') { if (!row($conn, "SELECT id FROM dbo.people WHERE id = ? AND workspace_id = ?", [(int)$lead, $wsId])) fail('Lead person not found', 404); $data['lead_person_id'] = (int)$lead; }
        else $data['lead_person_id'] = null;
    }
    if (isset($data['name'])) {
        $dup = scalar($conn, "SELECT id FROM dbo.role_families WHERE workspace_id = ? AND name = ? AND id <> ?", [$wsId, $data['name'], $id ?? -1]);
        if ($dup !== null) fail("A role family called {$data['name']} already exists", 409, ['existing_id' => (int)$dup]);
    }
    if ($id !== null) update($conn, 'role_families', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    else { if (empty($data['name'])) fail('name is required', 422); $data['workspace_id'] = $wsId; $id = insert($conn, 'role_families', $data); }
    $after = role_family_row($conn, $wsId, $id);
    audit($conn, $wsId, $before ? 'update' : 'create', 'role_family', $id, $before ? role_family_shape($before) : null, role_family_shape($after), $after['name']);
    ok(['role_family' => role_family_shape($after) + ['people' => array_map('person_lite', family_people_rows($conn, $wsId, $id))]]);
}

if ($action === 'delete') {
    $id = (int)require_param('id');
    $rf = role_family_row($conn, $wsId, $id);
    // Inactive people count too: the FK does not care whether somebody has left.
    $members = rows($conn, "SELECT p.id, p.name, p.initials, p.colour, p.role_title, p.team_id, p.role_family_id, t.name AS team_name
                            FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id
                            WHERE p.workspace_id = ? AND p.role_family_id = ? ORDER BY p.name", [$wsId, $id]);
    if ($members) fail(count($members) . ' ' . (count($members) === 1 ? 'person is' : 'people are') . " still in {$rf['name']}; move them first", 409, ['people' => array_map('person_lite', $members)]);
    q($conn, "DELETE FROM dbo.role_families WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    audit($conn, $wsId, 'delete', 'role_family', $id, role_family_shape($rf), null, $rf['name']);
    ok(['deleted' => $id]);
}

if ($action === 'set_person') {
    $personId = (int)require_param('person_id');
    $p = row($conn, "SELECT p.*, rf.name AS role_family_name FROM dbo.people p LEFT JOIN dbo.role_families rf ON rf.id = p.role_family_id WHERE p.id = ? AND p.workspace_id = ?", [$personId, $wsId]);
    if (!$p) fail('Person not found', 404);
    $rfId = param('role_family_id');
    $rf = null;
    if ($rfId !== null && $rfId !== '') { $rf = role_family_row($conn, $wsId, (int)$rfId); $rfId = (int)$rfId; } else $rfId = null;
    $before = ['role_family_id' => $p['role_family_id'] !== null ? (int)$p['role_family_id'] : null, 'role_family_name' => $p['role_family_name']];
    update($conn, 'people', ['role_family_id' => $rfId], 'id = ? AND workspace_id = ?', [$personId, $wsId]);
    $after = ['role_family_id' => $rfId, 'role_family_name' => $rf['name'] ?? null];
    audit($conn, $wsId, 'update', 'person', $personId, $before, $after,
        "{$p['name']}: " . ($before['role_family_name'] ?? 'no role family') . ' to ' . ($after['role_family_name'] ?? 'no role family'), 'Role family changed');
    $fresh = row($conn, "SELECT p.*, t.name AS team_name, m.name AS manager_name, rf.name AS role_family_name
                         FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id LEFT JOIN dbo.people m ON m.id = p.manager_person_id
                         LEFT JOIN dbo.role_families rf ON rf.id = p.role_family_id WHERE p.id = ?", [$personId]);
    ok(['person' => person_shape($fresh)]);
}

fail('Unknown action', 400);
