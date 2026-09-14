<?php
// Skills catalogue + matrix (TEAM-01, TEAM-04, TEAM-05).
// Actions: list | matrix | save | merge | retire
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'list');
$today = today();
const MIN_QUALIFIED_LEVEL = 3;
const LEVEL_NAMES = ['None', 'Aware', 'Practitioner', 'Independent', 'Expert'];

/**
 * The people a skills view is about (TEAM-09): the whole workspace, or with team_id / portfolio_id the
 * scope's planning pool — home members plus anyone loaned in — with the share of each day that belongs
 * to the scope. Returns [pool (team_pool shape) | null, scope].
 */
function skills_scope($conn, $wsId, $today, $to) {
    $scope = scope_team_ids($conn, $wsId, ['team_id' => param('team_id'), 'portfolio_id' => param('portfolio_id')]);
    if ($scope === null) fail('Team or portfolio not found', 404);
    return [$scope['team_ids'] === null ? null : team_pool($conn, $wsId, $scope['team_ids'], $today, $to), $scope];
}

/** Skills with coverage + 6-week demand/supply. $pool (team_pool) restricts people and weights supply by the scope's share. */
function skills_with_stats($conn, $wsId, $today, $includeRetired = false, $pool = null) {
    $ws = workspace_row($conn, $wsId);
    $hpd = (float)$ws['hours_per_day'] ?: 7.5;
    $workingDays = workspace_working_days($conn, $wsId);
    $from = $today; $to = date('Y-m-d', strtotime("$today +41 days")); // 6 weeks
    ensure_capacity($conn, $wsId, $from, $to);
    $skills = rows($conn, "SELECT * FROM dbo.skills WHERE workspace_id = ?" . ($includeRetired ? '' : ' AND retired = 0') . " ORDER BY sort_order, name", [$wsId]);

    // Qualified people per skill (within the pool when scoped).
    $qualified = [];
    foreach (rows($conn, "SELECT ps.skill_id, ps.person_id FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE p.workspace_id = ? AND p.active = 1 AND ps.proficiency >= ?", [$wsId, MIN_QUALIFIED_LEVEL]) as $r) {
        if ($pool !== null && !isset($pool[(int)$r['person_id']])) continue;
        $qualified[(int)$r['skill_id']][] = (int)$r['person_id'];
    }
    // Supply: capacity days (available − reserve) per person over the window, × the scope's share of each day when scoped.
    $capDays = [];
    if ($pool === null) {
        foreach (rows($conn, "SELECT person_id, SUM(available_hours - reserve_hours) h FROM dbo.capacity_days WHERE workspace_id = ? AND day BETWEEN ? AND ? GROUP BY person_id", [$wsId, $from, $to]) as $r)
            $capDays[(int)$r['person_id']] = (float)$r['h'] / $hpd;
    } else {
        foreach (capacity_map($conn, $wsId, $from, $to, array_keys($pool)) as $pid => $days) {
            $h = 0.0; foreach ($days as $day => $c) $h += ($c['available'] - $c['reserve']) * team_share_for($pool[$pid], $day);
            $capDays[$pid] = $h / $hpd;
        }
    }

    // Demand: open items requiring each skill → planned assignment-days in the window from the committed plan; unscheduled → remaining planning days.
    $pv = committed_plan_version_id($conn, $wsId);
    $items = rows($conn, "SELECT wi.id, wi.progress_pct, wi.custom_effort_days, sc.planning_days, sc.is_custom,
            (SELECT TOP 1 e.likely FROM dbo.estimates e WHERE e.work_item_id = wi.id ORDER BY e.version DESC) AS likely
        FROM dbo.work_items wi LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')", [$wsId]);
    $planned = []; // item_id => days in window
    if ($pv !== null) {
        foreach (rows($conn, "SELECT work_item_id, from_date, to_date, allocation_pct FROM dbo.assignments WHERE plan_version_id = ? AND is_reserve = 0 AND from_date <= ? AND to_date >= ?", [$pv, $to, $from]) as $a) {
            $s = max($from, substr($a['from_date'], 0, 10)); $e = min($to, substr($a['to_date'], 0, 10));
            $planned[(int)$a['work_item_id']] = ($planned[(int)$a['work_item_id']] ?? 0) + working_days_between($s, $e, $workingDays) * (int)$a['allocation_pct'] / 100;
        }
    }
    $hasAny = []; // items with any committed assignment at all (scheduled beyond window shouldn't fall back)
    if ($pv !== null) foreach (rows($conn, "SELECT DISTINCT work_item_id FROM dbo.assignments WHERE plan_version_id = ? AND is_reserve = 0", [$pv]) as $r) $hasAny[(int)$r['work_item_id']] = true;
    $itemDays = []; $itemCount = [];
    foreach ($items as $it) {
        $id = (int)$it['id'];
        if (isset($hasAny[$id])) $days = $planned[$id] ?? 0;
        else {
            $effort = $it['likely'] ?? $it['custom_effort_days'] ?? $it['planning_days'] ?? 0;
            $days = (float)$effort * (1 - (int)$it['progress_pct'] / 100);
        }
        $itemDays[$id] = max(0, $days);
    }
    $demand = []; $demandItems = [];
    foreach (rows($conn, "SELECT sr.skill_id, sr.work_item_id, sr.effort_days FROM dbo.skill_requirements sr JOIN dbo.work_items wi ON wi.id = sr.work_item_id WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')", [$wsId]) as $r) {
        $sid = (int)$r['skill_id']; $iid = (int)$r['work_item_id'];
        $d = $itemDays[$iid] ?? 0;
        if ($r['effort_days'] !== null && !isset($hasAny[$iid]) && $d > 0) $d = min($d, (float)$r['effort_days']); // unscheduled: cap at the skill's own effort share
        $demand[$sid] = ($demand[$sid] ?? 0) + $d;
        if ($d > 0) $demandItems[$sid] = ($demandItems[$sid] ?? 0) + 1;
    }

    $out = [];
    foreach ($skills as $s) {
        $sid = (int)$s['id'];
        $q = $qualified[$sid] ?? [];
        $supply = 0; foreach ($q as $pid) $supply += $capDays[$pid] ?? 0;
        $dem = round($demand[$sid] ?? 0, 1);
        $out[] = ['id' => $sid, 'name' => $s['name'], 'category' => $s['category'], 'description' => $s['description'], 'retired' => (bool)$s['retired'], 'sort_order' => (int)$s['sort_order'],
            'people_at_3_plus' => count($q), 'qualified_person_ids' => $q, 'demand_days_6w' => $dem, 'demand_items_6w' => $demandItems[$sid] ?? 0,
            'supply_days_6w' => round($supply, 1), 'exceeds' => $dem > round($supply, 1), 'single_point' => count($q) === 1];
    }
    return [$out, ['from' => $from, 'to' => $to]];
}

if ($action === 'list') {
    [$pool, $scope] = skills_scope($conn, $wsId, $today, date('Y-m-d', strtotime("$today +41 days")));
    [$skills, $window] = skills_with_stats($conn, $wsId, $today, (bool)param('include_retired', false), $pool);
    ok(['skills' => $skills, 'window_6w' => $window, 'scope' => array_intersect_key($scope, array_flip(['kind', 'team_id', 'portfolio_id', 'name', 'team_ids']))]);
}

if ($action === 'matrix') {
    [$pool, $scope] = skills_scope($conn, $wsId, $today, date('Y-m-d', strtotime("$today +41 days")));
    [$skills, $window6] = skills_with_stats($conn, $wsId, $today, false, $pool);
    $ws = workspace_row($conn, $wsId);
    $hpd = (float)$ws['hours_per_day'] ?: 7.5;
    $workingDays = workspace_working_days($conn, $wsId);
    $policy = current_policy($conn, $wsId);
    $from4 = $today; $to4 = date('Y-m-d', strtotime("$today +27 days"));
    $people = rows($conn, "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.workspace_id = ? AND p.active = 1 ORDER BY p.name", [$wsId]);
    if ($pool !== null) {
        $people = array_values(array_filter($people, fn($p) => isset($pool[(int)$p['id']])));
        $load = array_map(fn($x) => $x['load_pct'], team_load($conn, $wsId, $scope['team_ids'], $from4, $to4)['people']);
    } else $load = load_pct_map($conn, $wsId, $from4, $to4);
    $peopleOut = []; $firstName = [];
    foreach ($people as $p) {
        $peopleOut[] = ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => trim((string)$p['initials']), 'colour' => $p['colour'], 'role_title' => $p['role_title'],
            'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null, 'team_name' => $p['team_name'], 'days_per_week' => (float)$p['days_per_week'], 'load_pct' => $load[(int)$p['id']] ?? 0,
            'loaned_in' => $pool !== null && !$pool[(int)$p['id']]['home']];
        $firstName[(int)$p['id']] = explode(' ', $p['name'])[0];
    }
    $cells = []; $development = [];
    $skillName = []; foreach ($skills as $s) $skillName[$s['id']] = $s['name'];
    foreach (rows($conn, "SELECT ps.* FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id JOIN dbo.skills s ON s.id = ps.skill_id WHERE p.workspace_id = ? AND p.active = 1 AND s.retired = 0", [$wsId]) as $r) {
        $pid = (int)$r['person_id']; $sid = (int)$r['skill_id'];
        if ($pool !== null && !isset($pool[$pid])) continue;
        $cells["$pid:$sid"] = ['proficiency' => (int)$r['proficiency'], 'certified' => (bool)$r['certified'],
            'development_target' => $r['development_target'] !== null ? (int)$r['development_target'] : null, 'pairing_enabled' => (bool)$r['pairing_enabled'],
            'endorsed' => $r['endorsed_by'] !== null && $r['endorsed_by'] !== ''];
        if ($r['development_target'] !== null && (int)$r['development_target'] > (int)$r['proficiency'] && isset($skillName[$sid])) {
            $pairing = (bool)$r['pairing_enabled'];
            $development[] = ['person_id' => $pid, 'person' => $firstName[$pid] ?? '', 'skill_id' => $sid, 'skill' => $skillName[$sid], 'from_level' => (int)$r['proficiency'], 'to_level' => (int)$r['development_target'],
                'pairing_enabled' => $pairing, 'note' => $pairing ? 'Scheduler prefers pairing ' . ($firstName[$pid] ?? 'them') . " on {$skillName[$sid]} tasks" : 'Not yet used in scheduling'];
        }
    }
    $single = []; $two = []; $well = 0;
    foreach ($skills as $s) { if ($s['people_at_3_plus'] === 1) $single[] = $s['name']; elseif ($s['people_at_3_plus'] === 2) $two[] = $s['name']; elseif ($s['people_at_3_plus'] >= 3) $well++; }

    // Availability, next 4 weeks: leave/training rows, part-time patterns, rota weeks.
    $avail = [];
    $nameOf = []; foreach ($people as $p) $nameOf[(int)$p['id']] = $p['name'];
    foreach (rows($conn, "SELECT a.* FROM dbo.availability a JOIN dbo.people p ON p.id = a.person_id WHERE a.workspace_id = ? AND p.active = 1 AND a.from_date <= ? AND a.to_date >= ? ORDER BY a.from_date", [$wsId, $to4, $from4]) as $a) {
        $pid = (int)$a['person_id']; $f = substr($a['from_date'], 0, 10); $t = substr($a['to_date'], 0, 10);
        if (!isset($nameOf[$pid])) continue;                  // outside the scope's pool
        $days = working_days_between(max($f, $from4), min($t, $to4), $workingDays) * (float)$a['fraction'];
        $days = round($days * 2) / 2;
        $kind = $a['type'] === 'training' ? 'training' : 'leave';
        $word = $a['type'] === 'sickness' ? 'sickness' : $a['type'];
        $label = $f <= $today ? "$word until " . fmt_day($t) : "$word " . fmt_range($f, $t);
        $avail[] = ['person_id' => $pid, 'person' => $nameOf[$pid] ?? '', 'label' => $label, 'from' => $f, 'to' => $t, 'type' => $a['type'], 'days' => $days,
            'badge' => ($days == floor($days) ? (int)$days : $days) . ($days == 1 ? ' day' : ' days'), 'kind' => $kind, 'source' => $a['source']];
    }
    foreach ($people as $p) {
        $wp = json_col($p['working_pattern'], []);
        $partial = []; $off = [];
        foreach (['Mon','Tue','Wed','Thu','Fri'] as $d) { $h = (float)($wp[$d] ?? 0); if ($h <= 0) $off[] = $d; elseif ($h < $hpd - 0.01) $partial[] = [$d, $h / $hpd]; }
        if (!$partial && !$off) continue;
        $dayName = ['Mon' => 'Mondays', 'Tue' => 'Tuesdays', 'Wed' => 'Wednesdays', 'Thu' => 'Thursdays', 'Fri' => 'Fridays'];
        $bits = [];
        foreach ($partial as [$d, $f]) $bits[] = rtrim(rtrim(number_format($f, 2, '.', ''), '0'), '.') . " day {$dayName[$d]}";
        foreach ($off as $d) $bits[] = "no {$dayName[$d]}";
        $avail[] = ['person_id' => (int)$p['id'], 'person' => $p['name'], 'label' => implode(', ', $bits) . ', ongoing', 'from' => null, 'to' => null, 'type' => 'pattern', 'days' => null, 'badge' => 'Pattern', 'kind' => 'pattern', 'source' => 'profile'];
    }
    $rotaPct = (float)$policy['rota_reserve_pct']; $rotaLabel = ($rotaPct == floor($rotaPct) ? (int)$rotaPct : $rotaPct) . '%';
    foreach (rows($conn, "SELECT r.person_id, r.week_start FROM dbo.incident_rota r JOIN dbo.people p ON p.id = r.person_id WHERE r.workspace_id = ? AND p.active = 1 AND r.week_start BETWEEN ? AND ? ORDER BY r.week_start", [$wsId, week_start($from4), $to4]) as $r) {
        $pid = (int)$r['person_id']; $w = substr($r['week_start'], 0, 10);
        if (!isset($nameOf[$pid])) continue;
        $avail[] = ['person_id' => $pid, 'person' => $nameOf[$pid] ?? '', 'label' => 'incident rota w/c ' . fmt_day($w), 'from' => $w, 'to' => date('Y-m-d', strtotime("$w +4 days")), 'type' => 'rota', 'days' => null,
            'badge' => "Reserve $rotaLabel", 'kind' => 'rota', 'source' => 'rota'];
    }
    usort($avail, fn($a, $b) => [$a['kind'] === 'pattern' ? 1 : 0, $a['from'] ?? '9999'] <=> [$b['kind'] === 'pattern' ? 1 : 0, $b['from'] ?? '9999']);

    $dvs = array_map(fn($s) => ['skill_id' => $s['id'], 'skill' => $s['name'], 'demand_days' => $s['demand_days_6w'], 'supply_days' => $s['supply_days_6w'], 'exceeds' => $s['exceeds']], $skills);
    ok(['skills' => $skills, 'people' => $peopleOut, 'cells' => $cells,
        'summary' => ['single_point_skills' => $single, 'two_person_skills' => $two, 'well_covered' => $well, 'people_count' => count($peopleOut), 'skills_count' => count($skills),
            'team_name' => $scope['name'] ?? ($peopleOut ? ($peopleOut[0]['team_name'] ?? null) : null), 'levels' => LEVEL_NAMES],
        'scope' => array_intersect_key($scope, array_flip(['kind', 'team_id', 'portfolio_id', 'name', 'team_ids'])),
        'availability_4w' => $avail, 'development' => $development, 'demand_vs_supply' => $dvs,
        'windows' => ['availability' => ['from' => $from4, 'to' => $to4], 'demand' => $window6]]);
}

// ---- mutations (admin) --------------------------------------------------------------
require_role('admin');

if ($action === 'save') {
    $id = param('id') !== null ? (int)param('id') : null;
    $before = $id !== null ? row($conn, "SELECT * FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$before) fail('Skill not found', 404);
    $data = [];
    foreach (['name','category','description'] as $f) if (param($f) !== null) $data[$f] = trim((string)param($f));
    if (param('sort_order') !== null) $data['sort_order'] = (int)param('sort_order');
    if (isset($data['name'])) {
        $dup = scalar($conn, "SELECT id FROM dbo.skills WHERE workspace_id = ? AND name = ? AND id <> ?", [$wsId, $data['name'], $id ?? -1]);
        if ($dup) fail("A skill called {$data['name']} already exists", 409, ['existing_id' => (int)$dup]);
    }
    if ($id !== null) update($conn, 'skills', $data, 'id = ?', [$id]);
    else {
        if (empty($data['name'])) fail('name is required', 422);
        $data['workspace_id'] = $wsId;
        if (!isset($data['sort_order'])) $data['sort_order'] = 1 + (int)scalar($conn, "SELECT ISNULL(MAX(sort_order),0) FROM dbo.skills WHERE workspace_id = ?", [$wsId]);
        $id = insert($conn, 'skills', $data);
    }
    $after = row($conn, "SELECT * FROM dbo.skills WHERE id = ?", [$id]);
    audit($conn, $wsId, $before ? 'update' : 'create', 'skill', $id, $before, $after, $after['name']);
    $after['id'] = (int)$after['id']; $after['retired'] = (bool)$after['retired']; $after['sort_order'] = (int)$after['sort_order'];
    ok(['skill' => $after]);
}

if ($action === 'merge') {
    $fromId = (int)require_param('from_id'); $intoId = (int)require_param('into_id');
    if ($fromId === $intoId) fail('from_id and into_id must differ', 400);
    $from = row($conn, "SELECT * FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$fromId, $wsId]);
    $into = row($conn, "SELECT * FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$intoId, $wsId]);
    if (!$from || !$into) fail('Skill not found', 404);
    // person_skills: keep the higher proficiency where both exist.
    q($conn, "UPDATE t SET t.proficiency = CASE WHEN f.proficiency > t.proficiency THEN f.proficiency ELSE t.proficiency END,
                 t.certified = CASE WHEN f.certified = 1 THEN 1 ELSE t.certified END, t.updated_at = SYSDATETIME()
              FROM dbo.person_skills t JOIN dbo.person_skills f ON f.person_id = t.person_id AND f.skill_id = ? WHERE t.skill_id = ?", [$fromId, $intoId]);
    q($conn, "DELETE f FROM dbo.person_skills f WHERE f.skill_id = ? AND EXISTS (SELECT 1 FROM dbo.person_skills t WHERE t.person_id = f.person_id AND t.skill_id = ?)", [$fromId, $intoId]);
    q($conn, "UPDATE dbo.person_skills SET skill_id = ? WHERE skill_id = ?", [$intoId, $fromId]);
    // skill_requirements: keep the stricter minimum where both exist.
    q($conn, "UPDATE t SET t.min_proficiency = CASE WHEN f.min_proficiency > t.min_proficiency THEN f.min_proficiency ELSE t.min_proficiency END
              FROM dbo.skill_requirements t JOIN dbo.skill_requirements f ON f.work_item_id = t.work_item_id AND f.skill_id = ? WHERE t.skill_id = ?", [$fromId, $intoId]);
    q($conn, "DELETE f FROM dbo.skill_requirements f WHERE f.skill_id = ? AND EXISTS (SELECT 1 FROM dbo.skill_requirements t WHERE t.work_item_id = f.work_item_id AND t.skill_id = ?)", [$fromId, $intoId]);
    q($conn, "UPDATE dbo.skill_requirements SET skill_id = ? WHERE skill_id = ?", [$intoId, $fromId]);
    q($conn, "UPDATE dbo.tasks SET skill_id = ? WHERE skill_id = ?", [$intoId, $fromId]);
    update($conn, 'skills', ['retired' => 1], 'id = ?', [$fromId]);
    audit($conn, $wsId, 'update', 'skill', $intoId, ['merged_from' => $from], ['into' => $into], "{$from['name']} → {$into['name']}", 'Merged skills');
    ok(['merged_into' => $intoId, 'retired' => $fromId]);
}

if ($action === 'retire') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Skill not found', 404);
    $retired = !((bool)param('unretire', false));
    update($conn, 'skills', ['retired' => $retired ? 1 : 0], 'id = ?', [$id]);
    $after = row($conn, "SELECT * FROM dbo.skills WHERE id = ?", [$id]);
    audit($conn, $wsId, 'update', 'skill', $id, $s, $after, $s['name'], $retired ? 'Retired' : 'Restored');
    ok(['skill' => $after]);
}

fail('Unknown action', 400);
