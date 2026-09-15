<?php
// Watch list (SCH-05, edge cases 8.13) + shared read helpers used by overview.php / reports.php.
// Pure PHP, no HTTP. Entry point: build_watch_list($conn, $wsId).
require_once __DIR__ . '/../lib.php';
require_once __DIR__ . '/capacity.php';   // day_hours(), holiday_map(): one implementation of "hours on a day"

// ---- shared read helpers ----------------------------------------------------------
function wl_policy($conn, $wsId) {
    static $c = [];
    if (!isset($c[$wsId])) {
        $p = row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: [];
        $p += ['freeze_horizon_days' => 10, 'planning_horizon_weeks' => 4, 'incident_reserve_pct' => 12, 'rota_reserve_pct' => 25,
               'target_load_min' => 80, 'target_load_max' => 90, 'propose_cadence' => 'daily 02:00'];
        $c[$wsId] = $p;
    }
    return $c[$wsId];
}
function wl_workspace($conn, $wsId) {
    static $c = [];
    if (!isset($c[$wsId])) $c[$wsId] = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]) ?: ['name' => '', 'hours_per_day' => 7.5, 'working_days' => 'Mon,Tue,Wed,Thu,Fri'];
    return $c[$wsId];
}
function wl_working_days($conn, $wsId) {
    $wd = wl_workspace($conn, $wsId)['working_days'] ?? 'Mon,Tue,Wed,Thu,Fri';
    return array_map('trim', explode(',', $wd));
}
/** Latest committed plan version row (or null). */
function wl_committed_plan($conn, $wsId) {
    static $c = [];
    if (!array_key_exists($wsId, $c)) $c[$wsId] = row($conn, "SELECT * FROM (SELECT TOP 1 * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY committed_at DESC, version_no DESC) x", [$wsId]);
    return $c[$wsId];
}
/** Active people keyed by id, working_pattern decoded. */
function wl_people($conn, $wsId, $includeInactive = false) {
    $sql = "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.workspace_id = ?" . ($includeInactive ? '' : ' AND p.active = 1') . " ORDER BY p.name";
    $out = [];
    foreach (rows($conn, $sql, [$wsId]) as $p) {
        $p['pattern'] = json_col($p['working_pattern'], ['Mon'=>7.5,'Tue'=>7.5,'Wed'=>7.5,'Thu'=>7.5,'Fri'=>7.5]);
        $out[(int)$p['id']] = $p;
    }
    return $out;
}
function wl_person_lite($p) {
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => trim((string)$p['initials']), 'colour' => $p['colour']];
}
/** capacity_days for a window: [person_id][day] => ['available'=>h,'reserve'=>h]. */
function wl_capacity_map($conn, $wsId, $from, $to) {
    $m = [];
    foreach (rows($conn, "SELECT person_id, CONVERT(char(10), day, 23) AS d, available_hours, reserve_hours FROM dbo.capacity_days WHERE workspace_id = ? AND day BETWEEN ? AND ?", [$wsId, $from, $to]) as $r)
        $m[(int)$r['person_id']][$r['d']] = ['available' => (float)$r['available_hours'], 'reserve' => (float)$r['reserve_hours']];
    return $m;
}
/** Availability (leave etc.) for a window: [person_id][day] => {fraction unavailable, type, label}. */
function wl_leave_map($conn, $wsId, $from, $to) {
    $m = [];
    foreach (rows($conn, "SELECT person_id, CONVERT(char(10), from_date, 23) f, CONVERT(char(10), to_date, 23) t, fraction, type, label FROM dbo.availability WHERE workspace_id = ? AND to_date >= ? AND from_date <= ?", [$wsId, $from, $to]) as $r) {
        for ($d = max($r['f'], $from); $d <= min($r['t'], $to); $d = date('Y-m-d', strtotime("$d +1 day"))) {
            $pid = (int)$r['person_id'];
            $m[$pid][$d] = ['fraction' => min(1.0, ($m[$pid][$d]['fraction'] ?? 0) + (float)$r['fraction']), 'type' => $r['type'], 'label' => $r['label'] ?: ucfirst($r['type'])];
        }
    }
    return $m;
}
/** Rota weeks: [person_id][week_start] => true. */
function wl_rota_map($conn, $wsId, $from, $to) {
    $m = [];
    foreach (rows($conn, "SELECT person_id, CONVERT(char(10), week_start, 23) w FROM dbo.incident_rota WHERE workspace_id = ? AND week_start BETWEEN ? AND ?", [$wsId, week_start($from), week_start($to)]) as $r)
        $m[(int)$r['person_id']][$r['w']] = true;
    return $m;
}
/** Pattern hours for a person on a day (0 on non-working days). */
function wl_pattern_hours($person, $day) {
    return (float)($person['pattern'][date('D', strtotime($day))] ?? 0);
}
/**
 * Available hours for a person on a day: capacity_days if derived, else the shared day_hours()
 * arithmetic over their pattern, their leave and the public-holiday calendar.
 *
 * $holidays is optional so callers written before holidays existed still work; without it a
 * derived row still carries the zero, because derive_capacity() applied the holiday when it wrote.
 */
function wl_available_hours($person, $day, $capMap, $leaveMap, $holidays = []) {
    $pid = (int)$person['id'];
    if (isset($capMap[$pid][$day])) return $capMap[$pid][$day]['available'];
    $fraction = $leaveMap[$pid][$day]['fraction'] ?? null;
    $isHoliday = $holidays && holiday_label($holidays, $day, $person['holiday_region'] ?? null) !== null;
    return day_hours($person['pattern'] ?? [], date('D', strtotime($day)), $fraction === null ? [] : [$fraction], $isHoliday);
}
/** Reserve hours for a person on a day (12% or 25% when on rota). */
function wl_reserve_hours($person, $day, $capMap, $leaveMap, $policy, $onRota, $holidays = []) {
    $pid = (int)$person['id'];
    if (isset($capMap[$pid][$day])) return $capMap[$pid][$day]['reserve'];
    $pct = $onRota ? (float)$policy['rota_reserve_pct'] : (float)$policy['incident_reserve_pct'];
    return wl_available_hours($person, $day, $capMap, $leaveMap, $holidays) * $pct / 100;
}
/** Working days (list of Y-m-d) inside [$from,$to]. */
function wl_days_in($from, $to, $workingDays) {
    $out = [];
    if ($to < $from) return $out;
    for ($d = $from; $d <= $to; $d = date('Y-m-d', strtotime("$d +1 day"))) if (in_array(date('D', strtotime($d)), $workingDays, true)) $out[] = $d;
    return $out;
}
/** Working days of an assignment that fall inside [$from,$to]. */
function wl_assignment_days($a, $from, $to, $workingDays) {
    return wl_days_in(max($a['from_date'], $from), min($a['to_date'], $to), $workingDays);
}
/** Hours of an assignment inside a window (allocation % × pattern hours per working day). */
function wl_assignment_hours($a, $from, $to, $person, $workingDays) {
    $h = 0.0;
    foreach (wl_assignment_days($a, $from, $to, $workingDays) as $d) $h += wl_pattern_hours($person, $d) * (int)$a['allocation_pct'] / 100;
    return $h;
}
/** Committed-plan assignments (Assignment shape + item/type facts), optionally intersecting a window / person. */
function wl_committed_assignments($conn, $wsId, $from = null, $to = null, $personId = null) {
    $pv = wl_committed_plan($conn, $wsId);
    if (!$pv) return [];
    $sql = "SELECT a.id, a.plan_version_id, a.work_item_id, a.person_id, CONVERT(char(10), a.from_date, 23) from_date, CONVERT(char(10), a.to_date, 23) to_date,
                   a.allocation_pct, a.state, a.role_label, CONVERT(char(10), a.locked_until, 23) locked_until, a.fixed_person, a.fixed_dates, a.is_reserve, a.note,
                   wi.ref, wi.title, wi.status, wi.health, wi.progress_pct, CONVERT(char(10), wi.needed_by, 23) needed_by,
                   wt.id AS work_type_id, wt.name AS type_name, wt.colour AS type_colour, wt.policy AS type_policy, sc.stamp AS size_stamp, sc.name AS size_name
            FROM dbo.assignments a
            JOIN dbo.work_items wi ON wi.id = a.work_item_id
            JOIN dbo.work_types wt ON wt.id = wi.work_type_id
            LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
            WHERE a.plan_version_id = ?";
    $p = [(int)$pv['id']];
    if ($from !== null) { $sql .= " AND a.to_date >= ?"; $p[] = $from; }
    if ($to !== null)   { $sql .= " AND a.from_date <= ?"; $p[] = $to; }
    if ($personId !== null) { $sql .= " AND a.person_id = ?"; $p[] = (int)$personId; }
    $sql .= " ORDER BY a.from_date, a.to_date, a.id";
    $out = [];
    foreach (rows($conn, $sql, $p) as $a) {
        foreach (['id','plan_version_id','work_item_id','person_id','allocation_pct','progress_pct','work_type_id'] as $k) $a[$k] = $a[$k] === null ? null : (int)$a[$k];
        $a['locked'] = $a['locked_until'] !== null && $a['locked_until'] >= today();
        foreach (['fixed_person','fixed_dates','is_reserve'] as $k) $a[$k] = (bool)$a[$k];
        $a['size_stamp'] = $a['size_stamp'] === null ? null : trim($a['size_stamp']);
        $out[] = $a;
    }
    return $out;
}
/** Item status label for lists: Blocked > At risk > In progress > On track. */
function wl_status_label($status, $health) {
    if ($status === 'blocked' || $health === 'blocked') return 'Blocked';
    if ($health === 'late' || $health === 'at_risk') return 'At risk';
    if ($status === 'in_progress') return 'In progress';
    if ($status === 'delivered') return 'Delivered';
    return 'On track';
}
function wl_fmt_day($date) { return date('D j M', strtotime($date)); }
function wl_first_name($name) { return explode(' ', trim((string)$name))[0]; }
function wl_level_label($n) { return 'L' . (int)$n; }

// ---- the watch list ---------------------------------------------------------------
/** @return array of {kind, title, body, suggestion, link, tone} (+ a few machine-readable extras) */
function build_watch_list($conn, $wsId) {
    $today = today();
    $policy = wl_policy($conn, $wsId);
    $wd = wl_working_days($conn, $wsId);
    $people = wl_people($conn, $wsId);
    $items = [];

    // Skill matrix: [skill_id] => [person_id => proficiency] (active people only)
    $skillNames = [];
    foreach (rows($conn, "SELECT id, name FROM dbo.skills WHERE workspace_id = ? AND retired = 0", [$wsId]) as $s) $skillNames[(int)$s['id']] = $s['name'];
    $matrix = [];
    foreach (rows($conn, "SELECT ps.person_id, ps.skill_id, ps.proficiency FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE p.workspace_id = ? AND p.active = 1", [$wsId]) as $r)
        $matrix[(int)$r['skill_id']][(int)$r['person_id']] = (int)$r['proficiency'];

    $sixWeeksEnd = add_working_days($today, 30, $wd);
    $committed = wl_committed_assignments($conn, $wsId, $today, null);
    $assignedItemIds = [];               // items with committed assignments in the next 6 weeks
    $itemPeople = [];                    // item_id => [person_id => true]
    $itemFinish = [];                    // item_id => max to_date
    foreach ($committed as $a) {
        if ($a['from_date'] <= $sixWeeksEnd) $assignedItemIds[$a['work_item_id']] = true;
        $itemPeople[$a['work_item_id']][$a['person_id']] = true;
        if (!isset($itemFinish[$a['work_item_id']]) || $a['to_date'] > $itemFinish[$a['work_item_id']]) $itemFinish[$a['work_item_id']] = $a['to_date'];
    }

    // 1. single_point: skills held at L3+ by exactly one active person and demanded by scheduled work in 6 weeks.
    $reqs = rows($conn, "SELECT sr.work_item_id, sr.skill_id, sr.min_proficiency, wi.ref, wi.status, CONVERT(char(10), wi.needed_by, 23) needed_by, wi.priority_score
                         FROM dbo.skill_requirements sr JOIN dbo.work_items wi ON wi.id = sr.work_item_id
                         WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled','draft')
                         ORDER BY wi.needed_by, wi.priority_score DESC", [$wsId]);
    $bySkill = [];
    foreach ($reqs as $r) $bySkill[(int)$r['skill_id']][] = $r;
    foreach ($skillNames as $sid => $sname) {
        $holders = array_filter($matrix[$sid] ?? [], fn($lvl) => $lvl >= 3);
        if (count($holders) !== 1) continue;
        $holderId = (int)array_key_first($holders);
        $needing = array_values(array_filter($bySkill[$sid] ?? [], fn($r) => isset($assignedItemIds[(int)$r['work_item_id']]) || in_array($r['status'], ['scheduled','in_progress'], true)));
        if (!$needing) continue;
        // closest candidate to pair: the highest sub-L3 holder
        $cands = array_filter($matrix[$sid] ?? [], fn($lvl, $pid) => $pid !== $holderId && $lvl >= 1, ARRAY_FILTER_USE_BOTH);
        arsort($cands);
        $pairId = $cands ? (int)array_key_first($cands) : null;
        // the item to pair on: one the holder is assigned to (or the first needing item)
        $pairItem = null;
        foreach ($needing as $r) if (isset($itemPeople[(int)$r['work_item_id']][$holderId])) { $pairItem = $r['ref']; break; }
        $pairItem = $pairItem ?? $needing[0]['ref'];
        $n = count($needing);
        $items[] = [
            'kind' => 'single_point',
            'title' => "$sname L3 is a single point of failure.",
            'body' => "$n scheduled " . ($n === 1 ? 'item needs' : 'items need') . " it in the next 6 weeks; only " . wl_first_name($people[$holderId]['name'] ?? 'one person') . " qualifies.",
            'suggestion' => $pairId ? "Consider pairing " . wl_first_name($people[$pairId]['name']) . " on $pairItem." : "Consider developing a second person in $sname.",
            'link' => '/team', 'tone' => 'warn',
            'skill_id' => $sid, 'person_id' => $holderId, 'item_ref' => $pairItem,
        ];
    }

    // 2. no_estimate: items waiting for a ROM.
    $ne = row($conn, "SELECT COUNT(*) AS n, MIN(created_at) AS oldest FROM dbo.work_items WHERE workspace_id = ? AND status = 'needs_estimate'", [$wsId]);
    if ($ne && (int)$ne['n'] > 0) {
        $n = (int)$ne['n'];
        $waited = (int)floor((strtotime($today) - strtotime(substr($ne['oldest'], 0, 10))) / 86400);
        $items[] = [
            'kind' => 'no_estimate',
            'title' => "$n " . ($n === 1 ? 'item has' : 'items have') . " no ROM.",
            'body' => ($n === 1 ? 'It cannot' : 'They cannot') . " be scheduled until estimated. Oldest has waited " . max(0, $waited) . " days.",
            'suggestion' => 'Open the estimate queue.', 'link' => '/estimates', 'tone' => 'warn', 'count' => $n,
        ];
    }

    // 3. over_capacity: anyone above 100% in any week of the committed+planned window.
    $freezeEnd = add_working_days($today, max(1, (int)$policy['freeze_horizon_days']) - 1, $wd);
    $plannedEnd = add_working_days($freezeEnd, 5 * (int)$policy['planning_horizon_weeks'], $wd);
    $capMap = wl_capacity_map($conn, $wsId, $today, $plannedEnd);
    $leaveMap = wl_leave_map($conn, $wsId, $today, $plannedEnd);
    $byPersonWeek = [];
    foreach ($committed as $a) {
        if (!isset($people[$a['person_id']]) || $a['from_date'] > $plannedEnd) continue;
        foreach (wl_assignment_days($a, $today, $plannedEnd, $wd) as $d) {
            $ws = week_start($d);
            $byPersonWeek[$a['person_id']][$ws] = ($byPersonWeek[$a['person_id']][$ws] ?? 0) + wl_pattern_hours($people[$a['person_id']], $d) * $a['allocation_pct'] / 100;
        }
    }
    foreach ($byPersonWeek as $pid => $weeks) {
        ksort($weeks);
        foreach ($weeks as $ws => $assigned) {
            $avail = 0.0;
            foreach (wl_days_in(max($ws, $today), min($plannedEnd, date('Y-m-d', strtotime("$ws +6 days"))), $wd) as $d) $avail += wl_available_hours($people[$pid], $d, $capMap, $leaveMap);
            if ($avail <= 0 && $assigned <= 0) continue;
            $pct = $avail > 0 ? (int)round($assigned / $avail * 100) : 999;
            if ($pct > 100) {
                $first = wl_first_name($people[$pid]['name']);
                $items[] = [
                    'kind' => 'over_capacity',
                    'title' => "$first is at {$pct}% in w/c " . date('j M', strtotime($ws)) . ".",
                    'body' => "Committed assignments total " . round($assigned, 1) . " hours against " . round($avail, 1) . " available that week.",
                    'suggestion' => "Review $first" . "'s lane; planned work is only displaced through an accepted proposal.",
                    'link' => '/schedule', 'tone' => 'bad', 'person_id' => $pid, 'week_start' => $ws, 'load_pct' => $pct,
                ];
                break; // one entry per person
            }
        }
    }

    // 4. late: planned finish after needed_by (or cached health = late).
    $open = rows($conn, "SELECT id, ref, title, health, status, CONVERT(char(10), needed_by, 23) needed_by
                         FROM dbo.work_items WHERE workspace_id = ? AND status NOT IN ('delivered','cancelled','draft') AND needed_by IS NOT NULL ORDER BY needed_by", [$wsId]);
    foreach ($open as $it) {
        $finish = $itemFinish[(int)$it['id']] ?? null;
        $lateBy = ($finish && $finish > $it['needed_by']) ? working_days_between($it['needed_by'], $finish, $wd) - 1 : 0;
        if ($lateBy <= 0 && $it['health'] !== 'late') continue;
        $body = $finish
            ? "{$it['ref']} is planned to finish " . wl_fmt_day($finish) . ", " . ($lateBy > 0 ? "$lateBy working " . ($lateBy === 1 ? 'day' : 'days') . " after" : 'against') . " its needed-by of " . wl_fmt_day($it['needed_by']) . "."
            : "{$it['ref']} was needed by " . wl_fmt_day($it['needed_by']) . " and has no committed assignment.";
        $items[] = [
            'kind' => 'late',
            'title' => "{$it['ref']} will miss its needed-by date.",
            'body' => $body,
            'suggestion' => 'Add capacity, descope, or move the date.',
            'link' => "/items/{$it['ref']}", 'tone' => 'bad', 'item_ref' => $it['ref'], 'late_days' => $lateBy,
        ];
    }

    // 5. skills_gap: ready (unscheduled) items whose required skill has no active person at the level.
    $readyReqs = array_filter($reqs, fn($r) => $r['status'] === 'ready' && !isset($assignedItemIds[(int)$r['work_item_id']]));
    foreach ($readyReqs as $r) {
        $sid = (int)$r['skill_id']; $min = (int)$r['min_proficiency'];
        $qualified = array_filter($matrix[$sid] ?? [], fn($lvl) => $lvl >= $min);
        if ($qualified) continue;
        $closest = $matrix[$sid] ?? [];
        arsort($closest);
        $closest = array_slice($closest, 0, 3, true);
        $names = [];
        foreach ($closest as $pid => $lvl) if (isset($people[$pid])) $names[] = wl_first_name($people[$pid]['name']) . ' (' . wl_level_label($lvl) . ')';
        $sname = $skillNames[$sid] ?? 'a skill';
        $bestId = $closest ? (int)array_key_first($closest) : null;
        $items[] = [
            'kind' => 'skills_gap',
            'title' => "No one holds $sname at " . wl_level_label($min) . " for {$r['ref']}.",
            'body' => $names ? "Closest: " . implode(', ', $names) . "." : "Nobody on the team has $sname.",
            'suggestion' => $bestId ? "Pair " . wl_first_name($people[$bestId]['name']) . " with an external expert as development, or lower the requirement to " . wl_level_label($closest[$bestId]) . "." : "Recruit or contract for $sname, or descope {$r['ref']}.",
            'link' => "/items/{$r['ref']}", 'tone' => 'bad', 'item_ref' => $r['ref'], 'skill_id' => $sid, 'min_proficiency' => $min,
        ];
    }

    return $items;
}
