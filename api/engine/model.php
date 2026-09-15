<?php
// Engine model builder (section 8.2 / 8.3). Pure functions over $conn + arrays; no HTTP.
// build_model($conn, $wsId, $opts) returns the array described in docs/ENGINE_MODEL.md.
// Also exposes the shared time helpers used by planner/diff/summary (all work on the
// model's ordered list of working days so every module agrees on "day index").
require_once __DIR__ . '/../lib.php';
require_once __DIR__ . '/capacity.php';

/**
 * @param array $opts  scope_person_ids?:[int], include_item_ids?:[int] (force-include e.g. drafts for what-ifs),
 *                     exclude_item_ids?:[int], today?:'Y-m-d',
 *                     team_id?:int | role_family_id?:int  (TEAM-09 / SCH-13 / ORG-01 planning scope; neither = whole workspace)
 *
 * Scope (SCH-13). With neither option the model is what it always was: every active person as one
 * pool, team_id a label. With team_id the pool is the home members of that team AND every team
 * beneath it (ORG-01), plus anyone loaned INTO one of them — so planning a parent team plans its
 * sub-teams. With role_family_id the pool is the people in that discipline wherever they sit, all
 * home, share 1. In a scoped model:
 *   - every capacity entry carries `share` (0..1): the part of that person-day that belongs to the
 *     scope. A home member lent out at 50% has share 0.5 on the loan's days; a person loaned in at
 *     50% has share 0.5 on those days and 0 outside them. The planner books against
 *     share × (available − reserve), while allocation_pct stays a share of the WHOLE day, so a
 *     stored assignment reads the same in every view (a 50% loan can hold at most a 50% allocation).
 *   - an item with a committed row on an active person who is not a home member of the scope is
 *     `external`: another team's work (or shared with one). It is not re-planned here; its committed
 *     rows are locked so they still occupy the time they occupy, and rows on people outside the pool
 *     are passed through untouched so the candidate is still a complete workspace plan.
 *   - `scope` describes what was asked for; `scope.partial` is true whenever the pool is not the
 *     whole workspace.
 * Returns null for an unknown workspace, team or role family.
 */
function build_model($conn, $wsId, array $opts = []) {
    $ws = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]);
    if (!$ws) return null;
    $scope = scope_team_ids($conn, $wsId, $opts);
    if ($scope === null) return null;
    $today = $opts['today'] ?? today();
    $workingDays = array_map('trim', explode(',', $ws['working_days'] ?: 'Mon,Tue,Wed,Thu,Fri'));
    $hpd = (float)($ws['hours_per_day'] ?: 7.5);

    $pol = row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: [];
    $policy = model_policy($pol);

    // Committed plan version (baseline)
    $committedVersion = row($conn, "SELECT TOP 1 * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    $windows = model_windows($today, $policy, $workingDays, $committedVersion['committed_through'] ?? null);

    // Working-day grid. The workspace week, widened by any weekday one of this workspace's own
    // people works — a Saturday worker's Saturdays are real days with real capacity, and a grid
    // that omitted them would make that time invisible to the planner.
    $gridPatterns = [];
    foreach (rows($conn, "SELECT working_pattern FROM dbo.people WHERE workspace_id = ? AND active = 1", [$wsId]) as $gp) $gridPatterns[] = json_col($gp['working_pattern'], []);
    $workingDays = effective_working_days($workingDays, $gridPatterns);
    $days = [];
    $d = new DateTime($today); $end = new DateTime($windows['indicative_end']);
    while ($d <= $end) { if (in_array($d->format('D'), $workingDays, true)) $days[] = $d->format('Y-m-d'); $d->modify('+1 day'); }
    $dayIndex = array_flip($days);

    // People: the planning pool for the scope (see the docblock). $activeIds is everyone active in
    // the workspace, pool or not — needed to tell "another team's person" from "a leaver".
    $pool = scope_pool($conn, $wsId, $scope, $today, $windows['indicative_end']);
    $people = []; $activeIds = [];
    foreach (rows($conn, "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.workspace_id = ? AND p.active = 1 ORDER BY p.id", [$wsId]) as $p) {
        $pid = (int)$p['id']; $activeIds[$pid] = true;
        if (!isset($pool[$pid])) continue;
        $people[$pid] = [
            'id' => $pid, 'name' => $p['name'], 'initials' => trim((string)$p['initials']), 'colour' => $p['colour'],
            'role_title' => $p['role_title'], 'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null, 'team_name' => $p['team_name'],
            'home' => $pool[$pid]['home'],                       // false = in the pool only through a loan into the scope
            'loans' => array_map(fn($l) => array_intersect_key($l, array_flip(['id', 'from_team_id', 'to_team_id', 'from_date', 'to_date', 'allocation_pct', 'share'])), $pool[$pid]['loans']),
            'days_per_week' => (float)$p['days_per_week'],
            'max_concurrent' => (int)($p['max_concurrent'] ?: $policy['max_concurrent_items']),
            'min_focus_days' => (int)($p['min_focus_days'] ?: $policy['min_focus_days']),
            'prefers' => model_csv($p['prefers']), 'avoid' => model_csv($p['avoid']),
            'protected' => $p['protected_until'] !== null && $p['protected_until'] >= $today,
            'skills' => [], 'development' => [], 'capacity' => [], 'rota_weeks' => [],
        ];
    }
    if ($people) {
        foreach (rows($conn, "SELECT ps.* FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE p.workspace_id = ? AND p.active = 1", [$wsId]) as $s) {
            $pid = (int)$s['person_id']; if (!isset($people[$pid])) continue;
            $people[$pid]['skills'][(int)$s['skill_id']] = (int)$s['proficiency'];
            if ($s['development_target'] !== null || (int)$s['pairing_enabled']) {
                $people[$pid]['development'][(int)$s['skill_id']] = ['target' => $s['development_target'] !== null ? (int)$s['development_target'] : null, 'pairing_enabled' => (bool)$s['pairing_enabled']];
            }
        }
        foreach (rows($conn, "SELECT person_id, week_start FROM dbo.incident_rota WHERE workspace_id = ? AND week_start >= ? AND week_start <= ?", [$wsId, week_start($today), $windows['indicative_end']]) as $r) {
            $pid = (int)$r['person_id']; if (isset($people[$pid])) $people[$pid]['rota_weeks'][] = substr($r['week_start'], 0, 10);
        }
        // Capacity: derived rows first, fall back to working pattern − availability − reserve when absent.
        $capRows = rows($conn, "SELECT c.person_id, c.day, c.available_hours, c.reserve_hours FROM dbo.capacity_days c WHERE c.workspace_id = ? AND c.day >= ? AND c.day <= ?", [$wsId, $today, $windows['indicative_end']]);
        $have = [];
        foreach ($capRows as $c) {
            $pid = (int)$c['person_id']; if (!isset($people[$pid])) continue;
            $day = substr($c['day'], 0, 10);
            $people[$pid]['capacity'][$day] = ['available' => round((float)$c['available_hours'], 2), 'reserve' => round((float)$c['reserve_hours'], 2)];
            $have[$pid] = true;
        }
        $avail = rows($conn, "SELECT person_id, from_date, to_date, fraction FROM dbo.availability WHERE workspace_id = ? AND to_date >= ? AND from_date <= ?", [$wsId, $today, $windows['indicative_end']]);
        $rawPeople = rows($conn, "SELECT id, working_pattern, holiday_region FROM dbo.people WHERE workspace_id = ? AND active = 1", [$wsId]);
        $patterns = []; $regions = [];
        foreach ($rawPeople as $rp) { $patterns[(int)$rp['id']] = json_col($rp['working_pattern'], []); $regions[(int)$rp['id']] = $rp['holiday_region'] ?? null; }
        $holidays = holiday_map($conn, $wsId, $today, $windows['indicative_end']);
        foreach ($people as $pid => &$pp) {
            foreach ($days as $day) {
                if (isset($pp['capacity'][$day])) continue;
                if (!empty($have[$pid])) { $pp['capacity'][$day] = ['available' => 0.0, 'reserve' => 0.0]; continue; } // derived but missing day = none
                $fractions = [];
                foreach ($avail as $a) {
                    if ((int)$a['person_id'] === $pid && substr($a['from_date'], 0, 10) <= $day && substr($a['to_date'], 0, 10) >= $day) $fractions[] = (float)$a['fraction'];
                }
                // day_hours() is the one implementation: this branch used to MULTIPLY overlapping
                // fractions where derive_capacity() added them, so two half-days off read as a
                // quarter-day here and a whole day there.
                $hours = day_hours($patterns[$pid] ?? [], date('D', strtotime($day)), $fractions, holiday_label($holidays, $day, $regions[$pid] ?? null) !== null);
                $onRota = in_array(week_start($day), $pp['rota_weeks'], true);
                $reservePct = $onRota ? $policy['rota_reserve_pct'] : $policy['incident_reserve_pct'];
                $pp['capacity'][$day] = ['available' => round($hours, 2), 'reserve' => round($hours * $reservePct / 100, 2)];
            }
            // TEAM-09: the share of each day that belongs to the scope (1 everywhere for a workspace model).
            foreach ($pp['capacity'] as $day => &$c) $c['share'] = $scope['team_ids'] === null ? 1.0 : team_share_for($pool[$pid], $day);   // a role-family pool is share 1 by construction
            unset($c);
        }
        unset($pp);
    }

    // Skills catalogue
    $skillNames = [];
    foreach (rows($conn, "SELECT id, name FROM dbo.skills WHERE workspace_id = ?", [$wsId]) as $s) $skillNames[(int)$s['id']] = $s['name'];

    // Items
    $itemSql = "SELECT wi.*, wt.name AS type_name, wt.plural AS type_plural, wt.colour AS type_colour, wt.policy AS type_policy, wt.size_unit,
                       sc.stamp AS size_stamp, sc.name AS size_name, sc.granularity, sc.counts_for_wip, sc.planning_days, sc.is_custom
                FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id
                LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
                WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')";
    $items = [];
    $include = array_map('intval', $opts['include_item_ids'] ?? []);
    $exclude = array_map('intval', $opts['exclude_item_ids'] ?? []);
    $rawItems = rows($conn, $itemSql, [$wsId]);
    $itemIds = array_map(fn($r) => (int)$r['id'], $rawItems);
    $reqs = []; $deps = []; $ests = []; $benefits = [];
    if ($itemIds) {
        foreach (rows($conn, "SELECT sr.* FROM dbo.skill_requirements sr JOIN dbo.work_items wi ON wi.id = sr.work_item_id WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')", [$wsId]) as $r) $reqs[(int)$r['work_item_id']][] = $r;
        foreach (rows($conn, "SELECT d.* FROM dbo.dependencies d WHERE d.workspace_id = ? AND d.cleared_at IS NULL", [$wsId]) as $r) $deps[(int)$r['to_work_item_id']][] = ['from' => (int)$r['from_work_item_id'], 'type' => $r['type']];
        foreach (rows($conn, "SELECT e.* FROM dbo.estimates e JOIN dbo.work_items wi ON wi.id = e.work_item_id WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled') ORDER BY e.work_item_id, e.version DESC", [$wsId]) as $e) {
            $iid = (int)$e['work_item_id']; if (!isset($ests[$iid])) $ests[$iid] = $e;
        }
        foreach (rows($conn, "SELECT work_item_id, SUM(annual_value) AS v FROM dbo.benefits WHERE workspace_id = ? GROUP BY work_item_id", [$wsId]) as $b) $benefits[(int)$b['work_item_id']] = (float)$b['v'];
    }
    $deliveredIds = array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.work_items WHERE workspace_id = ? AND status IN ('delivered','cancelled')", [$wsId]));
    $deliveredSet = array_flip($deliveredIds);
    $schedulable = ['ready', 'scheduled', 'in_progress'];
    foreach ($rawItems as $r) {
        $iid = (int)$r['id'];
        if (in_array($iid, $exclude, true)) continue;
        $forced = in_array($iid, $include, true);
        $isInterrupt = ($r['type_policy'] ?? 'planned') === 'interrupt';
        $est = $ests[$iid] ?? null;
        $eff = model_remaining_effort($r, $est, $policy, $hpd);
        $skillEffort = null;
        if ($est && $est['skill_split']) {
            $split = json_col($est['skill_split'], []);
            $tot = 0; $tmp = [];
            foreach ($split as $s) { if (!empty($s['skill_id'])) { $tmp[(int)$s['skill_id']] = (float)$s['days']; $tot += (float)$s['days']; } }
            if ($tot > 0) { foreach ($tmp as $k => $v) $skillEffort[$k] = round($eff['remaining_days'] * $v / $tot, 2); }
        } elseif (!empty($reqs[$iid])) {
            $tot = 0; $tmp = [];
            foreach ($reqs[$iid] as $q) if ($q['effort_days'] !== null) { $tmp[(int)$q['skill_id']] = (float)$q['effort_days']; $tot += (float)$q['effort_days']; }
            if ($tot > 0 && count($tmp) === count($reqs[$iid])) { foreach ($tmp as $k => $v) $skillEffort[$k] = round($eff['remaining_days'] * $v / $tot, 2); }
        }
        $skills = [];
        foreach ($reqs[$iid] ?? [] as $q) $skills[] = ['skill_id' => (int)$q['skill_id'], 'name' => $skillNames[(int)$q['skill_id']] ?? ('skill ' . $q['skill_id']), 'min_proficiency' => (int)$q['min_proficiency']];
        // dependencies on delivered items are cleared implicitly
        $itemDeps = []; $softDeps = [];
        foreach ($deps[$iid] ?? [] as $dp) { if (isset($deliveredSet[$dp['from']])) continue; if ($dp['type'] === 'soft') $softDeps[] = $dp['from']; else $itemDeps[] = $dp['from']; }
        $priority = $r['priority_score'] !== null ? (float)$r['priority_score'] : ($isInterrupt ? model_severity_score($r['severity'], $policy) : 50.0);
        $granularity = $r['granularity'] ?: (($r['is_custom'] ?? 0) ? 'week' : 'day');
        $items[$iid] = [
            'id' => $iid, 'ref' => $r['ref'], 'title' => $r['title'], 'status' => $r['status'],
            'work_type_id' => (int)$r['work_type_id'], 'type_name' => $r['type_name'], 'type_colour' => $r['type_colour'],
            'policy' => $isInterrupt ? 'interrupt' : 'planned', 'severity' => $r['severity'],
            'size_stamp' => $r['size_stamp'], 'size_name' => $r['size_name'], 'granularity' => $granularity,
            'counts_for_wip' => $r['counts_for_wip'] === null ? true : (bool)$r['counts_for_wip'],
            'remaining_days' => $eff['remaining_days'], 'effort_source' => $eff['source'], 'estimate_days' => $eff['estimate_days'],
            'skill_effort' => $skillEffort, 'skills' => $skills,
            'deps' => $itemDeps, 'soft_deps' => $softDeps,
            'earliest_start' => $r['earliest_start'] ? substr($r['earliest_start'], 0, 10) : null,
            'needed_by' => $r['needed_by'] ? substr($r['needed_by'], 0, 10) : null,
            'priority' => $priority, 'progress_pct' => (int)$r['progress_pct'],
            'protected' => $r['protected_until'] !== null && $r['protected_until'] >= $today,
            'benefit_value' => $benefits[$iid] ?? 0.0,
            'requested_by' => $r['requested_by'], 'owner_person_id' => $r['owner_person_id'] !== null ? (int)$r['owner_person_id'] : null,
            'created_by' => $r['created_by'] !== null ? (int)$r['created_by'] : null,
            'tags' => model_csv($r['tags']),
            'small' => $eff['remaining_days'] <= $policy['small_fill_threshold_days'],
            'schedulable' => $forced || in_array($r['status'], $schedulable, true),
            'has_estimate' => $est !== null || $r['planning_days'] !== null || $r['custom_effort_days'] !== null,
        ];
    }

    // Committed assignments (baseline). Locked = fixed by a user or explicit locked_until.
    $committed = [];
    if ($committedVersion) {
        foreach (rows($conn, "SELECT a.* FROM dbo.assignments a WHERE a.plan_version_id = ? ORDER BY a.person_id, a.from_date", [(int)$committedVersion['id']]) as $a) {
            $committed[] = model_assignment_row($a, $today);
        }
    }

    // SCH-13: in a scoped model, work committed to someone who is not a home member of the scope is
    // another team's (or shared with one). Mark the item external and lock its rows: the planner keeps
    // them exactly and never re-plans the item. Rows on leavers (inactive) are not external — the
    // whole point of a leaver's row is that the work must be offered to someone else.
    $externalItems = [];
    if (scope_is_partial($scope)) {
        foreach ($committed as $a) {
            if (!isset($items[$a['work_item_id']]) || $a['to_date'] < $today) continue;
            $pid = $a['person_id'];
            if (isset($people[$pid]) && $people[$pid]['home']) continue;
            if (!isset($activeIds[$pid])) continue;
            $externalItems[$a['work_item_id']] = true;
        }
        foreach ($committed as &$a) if (isset($externalItems[$a['work_item_id']])) $a['locked'] = true;
        unset($a);
        foreach ($externalItems as $iid => $_) { $items[$iid]['external'] = true; $items[$iid]['schedulable'] = false; }
    }
    foreach ($items as &$it) if (!isset($it['external'])) $it['external'] = false;
    unset($it);

    return [
        'workspace_id' => $wsId, 'workspace_name' => $ws['name'], 'today' => $today,
        'hours_per_day' => $hpd, 'working_days' => $workingDays,
        'windows' => $windows, 'days' => $days, 'day_index' => $dayIndex,
        'policy' => $policy,
        'people' => $people, 'items' => $items, 'skill_names' => $skillNames,
        'committed' => $committed,
        'committed_version_id' => $committedVersion ? (int)$committedVersion['id'] : null,
        'committed_version_no' => $committedVersion ? (int)$committedVersion['version_no'] : 0,
        'scope_person_ids' => array_values(array_map('intval', $opts['scope_person_ids'] ?? [])),
        'scope' => $scope + ['partial' => scope_is_partial($scope), 'external_item_ids' => array_keys($externalItems)],
    ];
}

function model_assignment_row(array $a, $today) {
    $lu = $a['locked_until'] ? substr($a['locked_until'], 0, 10) : null;
    return [
        'id' => (int)$a['id'], 'work_item_id' => (int)$a['work_item_id'], 'person_id' => (int)$a['person_id'],
        'from_date' => substr($a['from_date'], 0, 10), 'to_date' => substr($a['to_date'], 0, 10),
        'allocation_pct' => (int)$a['allocation_pct'], 'state' => $a['state'], 'role_label' => $a['role_label'],
        'locked' => (bool)($a['fixed_person'] || $a['fixed_dates'] || $a['fixed_by'] || ($lu && $lu >= $today)),
        'fixed_person' => (bool)$a['fixed_person'], 'fixed_dates' => (bool)$a['fixed_dates'],
        'is_reserve' => (bool)$a['is_reserve'], 'note' => $a['note'],
    ];
}

function model_policy(array $pol) {
    $ow = json_col($pol['objective_weights'] ?? null, []);
    $defaults = ['valueCompletion' => 1, 'lateness' => 3, 'unscheduledValue' => 5, 'loadImbalance' => 0.5, 'contextSwitching' => 0.5, 'stabilityPlanned' => 2, 'preferences' => 0.2];
    return [
        'version' => (int)($pol['version'] ?? 1),
        'freeze_horizon_days' => (int)($pol['freeze_horizon_days'] ?? 10),
        'planning_horizon_weeks' => (int)($pol['planning_horizon_weeks'] ?? 4),
        'model_horizon_weeks' => (int)($pol['model_horizon_weeks'] ?? 26),
        'change_budget_days' => (int)($pol['change_budget_days'] ?? 5),
        'min_improvement_pct' => (float)($pol['min_improvement_pct'] ?? 5),
        'incident_reserve_pct' => (float)($pol['incident_reserve_pct'] ?? 12),
        'rota_reserve_pct' => (float)($pol['rota_reserve_pct'] ?? 25),
        'max_concurrent_items' => (int)($pol['max_concurrent_items'] ?? 2),
        'min_focus_days' => (int)($pol['min_focus_days'] ?? 2),
        'plan_at' => $pol['plan_at'] ?? 'mostLikely',
        'solver_budget_seconds' => (int)($pol['solver_budget_seconds'] ?? 60),
        'small_fill_threshold_days' => (float)($pol['small_fill_threshold_days'] ?? 3),
        'target_load_min' => (int)($pol['target_load_min'] ?? 80),
        'target_load_max' => (int)($pol['target_load_max'] ?? 90),
        'auto_apply_outside_horizon' => (bool)($pol['auto_apply_outside_horizon'] ?? 0),
        'require_ack_inside_horizon' => (bool)($pol['require_ack_inside_horizon'] ?? 1),
        'pairing_cost_threshold_days' => (float)($ow['pairingCostThresholdDays'] ?? 2),
        'objective_weights' => array_merge($defaults, array_intersect_key($ow, $defaults)),
        'priority_weights' => json_col($pol['priority_weights'] ?? null, []),
    ];
}

/** Windows: committed = today..freeze_end, planned ..planned_end, indicative ..indicative_end (all inclusive dates). */
function model_windows($today, array $policy, array $workingDays, $committedThrough = null) {
    $ws = week_start($today);
    $freezeEnd = ($committedThrough && substr($committedThrough, 0, 10) >= $today) ? substr($committedThrough, 0, 10) : add_working_days($ws, $policy['freeze_horizon_days'] - 1, $workingDays);
    if ($freezeEnd < $today) $freezeEnd = add_working_days($today, $policy['freeze_horizon_days'] - 1, $workingDays);
    $plannedEnd = date('Y-m-d', strtotime($ws . ' +' . $policy['planning_horizon_weeks'] . ' weeks -1 day'));
    if ($plannedEnd < $freezeEnd) $plannedEnd = date('Y-m-d', strtotime(week_start($freezeEnd) . ' +6 days'));
    $indicativeEnd = date('Y-m-d', strtotime($ws . ' +' . $policy['model_horizon_weeks'] . ' weeks -1 day'));
    return ['today' => $today, 'freeze_end' => $freezeEnd, 'planned_end' => $plannedEnd, 'indicative_end' => $indicativeEnd];
}

/** State of an assignment starting on $date. */
function model_state_for($date, array $windows) {
    if ($date <= $windows['freeze_end']) return 'committed';
    if ($date <= $windows['planned_end']) return 'planned';
    return 'indicative';
}

/** Remaining effort in days per section 8.3: latest estimate (likely | p80), else size planning days, else custom effort, × (1 − progress). */
function model_remaining_effort(array $item, $est, array $policy, $hpd) {
    $days = null; $source = 'none';
    if ($est) {
        $likely = $est['likely'] !== null ? (float)$est['likely'] : null;
        if ($policy['plan_at'] === 'p80' && $est['optimistic'] !== null && $est['pessimistic'] !== null && $likely !== null) {
            $o = (float)$est['optimistic']; $p = (float)$est['pessimistic'];
            $expected = ($o + 4 * $likely + $p) / 6; $sd = ($p - $o) / 6;
            $days = $expected + 0.8416 * $sd; $source = 'estimate_p80';
        } elseif ($likely !== null) { $days = $likely; $source = 'estimate_likely'; }
    }
    if ($days === null && $item['planning_days'] !== null && !($item['is_custom'] ?? 0)) { $days = (float)$item['planning_days']; $source = 'size'; }
    if ($days === null && $item['custom_effort_days'] !== null) { $days = (float)$item['custom_effort_days']; $source = 'custom'; }
    if ($days === null && $item['planning_days'] !== null) { $days = (float)$item['planning_days']; $source = 'size'; }
    if ($days === null) { $days = 0.0; }
    if (($item['size_unit'] ?? 'days') === 'hours' && $source === 'size') $days = $days / $hpd;
    $progress = max(0, min(100, (int)($item['progress_pct'] ?? 0)));
    $remaining = round($days * (1 - $progress / 100) * 4) / 4; // quarter-day granularity
    return ['remaining_days' => max(0.0, $remaining), 'estimate_days' => round($days, 2), 'source' => $source];
}

function model_severity_score($sev, array $policy) {
    $map = $policy['priority_weights']['severityScores'] ?? ['P1' => 100, 'P2' => 90, 'P3' => 70, 'P4' => 50];
    return (float)($map[$sev ?? ''] ?? 70);
}

function model_csv($v) {
    if ($v === null || trim((string)$v) === '') return [];
    return array_values(array_filter(array_map('trim', explode(',', $v)), fn($x) => $x !== ''));
}

/** Working-day indices covered by [from,to] within the model grid (days before today are dropped). */
function model_days_in(array $model, $from, $to) {
    $out = [];
    if ($to < $model['today']) return $out;
    $start = $from < $model['today'] ? $model['today'] : $from;
    foreach ($model['days'] as $i => $d) { if ($d < $start) continue; if ($d > $to) break; $out[] = $i; }
    return $out;
}

/** Stable hash of the inputs that matter for the plan (SCH-14). */
function model_inputs_hash(array $model) {
    $sig = ['today' => $model['today'], 'policy' => $model['policy'], 'people' => [], 'items' => [], 'committed' => $model['committed'],
        'scope' => array_intersect_key($model['scope'] ?? [], array_flip(['kind', 'team_id', 'role_family_id', 'team_ids', 'person_ids']))];
    foreach ($model['people'] as $p) { $c = $p; unset($c['capacity']); $c['cap_sum'] = array_sum(array_map(fn($x) => $x['available'] * ($x['share'] ?? 1), $p['capacity'])); $sig['people'][] = $c; }
    foreach ($model['items'] as $i) $sig['items'][] = $i;
    return hash('sha256', json_encode($sig));
}

/** Person-lite shape used in API payloads. */
function model_person_lite($p) {
    if (!$p) return null;
    return ['id' => $p['id'], 'name' => $p['name'], 'initials' => $p['initials'], 'colour' => $p['colour']];
}
