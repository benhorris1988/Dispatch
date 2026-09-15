<?php
// Overview (VIEW-06, web-01) and the mobile "My week" (section 9.5). Actions:
//   get                        -> headline measures, committed deliveries, proposals, watch list, effort by week
//   my_week {week_start?, person_id?} -> a person's week from the committed plan
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/watchlist.php';
$action = param('action', 'get');

$today = today();
$policy = wl_policy($conn, $wsId);
$ws = wl_workspace($conn, $wsId);
$wd = wl_working_days($conn, $wsId);
$hoursPerDay = (float)($ws['hours_per_day'] ?? 7.5);
$people = wl_people($conn, $wsId);
$plan = wl_committed_plan($conn, $wsId);
$freezeEnd = add_working_days($today, max(1, (int)$policy['freeze_horizon_days']) - 1, $wd);   // last day of the committed window
$plannedEnd = add_working_days($freezeEnd, 5 * (int)$policy['planning_horizon_weeks'], $wd);
$thisMon = week_start($today);
$thisFri = date('Y-m-d', strtotime("$thisMon +4 days"));

if ($action === 'get') {
    // ---- committed deliveries: items landing in the committed window ------------------------------
    $all = wl_committed_assignments($conn, $wsId, $today, null);
    $finish = []; $assignees = []; $itemFacts = [];
    foreach ($all as $a) {
        $wi = $a['work_item_id'];
        if (!isset($finish[$wi]) || $a['to_date'] > $finish[$wi]) $finish[$wi] = $a['to_date'];
        if (isset($people[$a['person_id']]) && !isset($assignees[$wi][$a['person_id']])) $assignees[$wi][$a['person_id']] = wl_person_lite($people[$a['person_id']]);
    }
    $landing = rows($conn, "SELECT wi.id, wi.ref, wi.title, wi.work_type_id, wt.name AS type_name, wt.colour AS type_colour, wt.policy AS type_policy,
                                   sc.stamp AS size_stamp, sc.name AS size_name, sc.is_custom, wi.custom_effort_days, wi.status, wi.health, wi.priority_score, wi.progress_pct,
                                   CONVERT(char(10), wi.needed_by, 23) needed_by, CONVERT(char(10), wi.earliest_start, 23) earliest_start,
                                   wi.requested_by, wi.sponsor, wi.owner_person_id
                            FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
                            WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled','draft')", [$wsId]);
    $items = [];
    foreach ($landing as $it) {
        $id = (int)$it['id'];
        $pf = $finish[$id] ?? null;
        // A delivery lands in the committed window when its committed assignments finish inside it, or
        // when it is needed inside it. The date shown is the earliest of those that actually falls in
        // the window - a later needed_by on work that finishes this week must not leak outside it.
        $inWindow = [];
        if ($pf !== null && $pf >= $today && $pf <= $freezeEnd) $inWindow[] = $pf;
        if ($it['needed_by'] !== null && $it['needed_by'] >= $today && $it['needed_by'] <= $freezeEnd) $inWindow[] = $it['needed_by'];
        if (!$inWindow) continue;
        $due = min($inWindow);
        $items[] = [
            'id' => $id, 'ref' => $it['ref'], 'title' => $it['title'], 'work_type_id' => (int)$it['work_type_id'],
            'type_name' => $it['type_name'], 'type_colour' => $it['type_colour'], 'type_policy' => $it['type_policy'],
            'size_stamp' => $it['size_stamp'] === null ? null : trim($it['size_stamp']), 'size_name' => $it['size_name'], 'is_custom' => (bool)$it['is_custom'],
            'custom_effort_days' => $it['custom_effort_days'], 'status' => $it['status'], 'health' => $it['health'],
            'priority_score' => $it['priority_score'], 'progress_pct' => (int)$it['progress_pct'],
            'needed_by' => $it['needed_by'], 'earliest_start' => $it['earliest_start'], 'planned_to' => $pf,
            'planned_from' => null, 'requested_by' => $it['requested_by'], 'sponsor' => $it['sponsor'],
            'assignees' => array_values($assignees[$id] ?? []),
            'owner' => !empty($assignees[$id]) ? array_values($assignees[$id])[0]['name'] : null,
            'due' => $due,
            'due_label' => $due === $today ? 'Today' : wl_fmt_day($due),
            'status_label' => wl_status_label($it['status'], $it['health']),
        ];
    }
    foreach ($all as $a) foreach ($items as &$it) if ($it['id'] === $a['work_item_id'] && ($it['planned_from'] === null || $a['from_date'] < $it['planned_from'])) $it['planned_from'] = $a['from_date'];
    unset($it);
    usort($items, fn($x, $y) => [$x['due'], $x['ref']] <=> [$y['due'], $y['ref']]);
    $dueThisWeek = count(array_filter($items, fn($i) => $i['due'] <= $thisFri));
    $prevFrom = add_working_days($today, -10, $wd); $prevTo = add_working_days($today, -1, $wd);
    $deliveredPrev = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id = ? AND status = 'delivered' AND delivered_at BETWEEN ? AND ?", [$wsId, $prevFrom, $prevTo]);

    // ---- team load over committed + planned window --------------------------------------------------
    $capMap = wl_capacity_map($conn, $wsId, $today, $plannedEnd);
    $leaveMap = wl_leave_map($conn, $wsId, $today, $plannedEnd);
    $assignedH = 0.0; $availH = 0.0;
    foreach ($all as $a) if (isset($people[$a['person_id']]) && $a['from_date'] <= $plannedEnd) $assignedH += wl_assignment_hours($a, $today, $plannedEnd, $people[$a['person_id']], $wd);
    foreach ($people as $p) foreach (wl_days_in($today, $plannedEnd, $wd) as $d) $availH += wl_available_hours($p, $d, $capMap, $leaveMap);
    $loadPct = $availH > 0 ? (int)round($assignedH / $availH * 100) : 0;
    $tmin = (int)$policy['target_load_min']; $tmax = (int)$policy['target_load_max'];
    $band = $loadPct < $tmin ? 'Below band' : ($loadPct > $tmax ? 'Above band' : 'Within band');

    // ---- stability index (STAB-08): rolling 4 weeks vs the 4 before --------------------------------
    $sw = rows($conn, "SELECT TOP 8 CONVERT(char(10), week_start, 23) week_start, total_assignment_days, moved_assignment_days FROM dbo.stability_weeks WHERE workspace_id = ? AND week_start <= ? ORDER BY week_start DESC", [$wsId, $thisMon]);
    $idx = function(array $weeks) { $t = 0; $m = 0; foreach ($weeks as $w) { $t += (float)$w['total_assignment_days']; $m += (float)$w['moved_assignment_days']; } return $t > 0 ? round((1 - $m / $t) * 100) : null; };
    $cur = $idx(array_slice($sw, 0, 4)); $prev = $idx(array_slice($sw, 4, 4));
    $stability = ['index_pct' => $cur, 'delta_pts' => ($cur !== null && $prev !== null) ? (int)($cur - $prev) : null,
        'definition' => 'Plan stability index = 1 − (assignment-days changed inside the committed and planned windows ÷ total assignment-days in those windows), rolling four weeks. Indicative assignments are excluded.'];

    // ---- reserve this week ------------------------------------------------------------------------
    $rota = wl_rota_map($conn, $wsId, $thisMon, $thisFri);
    $reserveH = 0.0; $usedH = 0.0;
    foreach ($people as $pid => $p) foreach (wl_days_in($thisMon, $thisFri, $wd) as $d) $reserveH += wl_reserve_hours($p, $d, $capMap, $leaveMap, $policy, isset($rota[$pid][$thisMon]));
    $weekAssign = wl_committed_assignments($conn, $wsId, $thisMon, $thisFri);
    foreach ($weekAssign as $a) if (($a['is_reserve'] || $a['type_policy'] === 'interrupt') && isset($people[$a['person_id']])) $usedH += wl_assignment_hours($a, $thisMon, $thisFri, $people[$a['person_id']], $wd);
    $openIncidents = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id WHERE wi.workspace_id = ? AND wt.policy = 'interrupt' AND wi.status NOT IN ('delivered','cancelled','draft')", [$wsId]);
    $reserve = ['used_pct' => $reserveH > 0 ? (int)round($usedH / $reserveH * 100) : 0, 'reserve_pct' => (float)$policy['incident_reserve_pct'],
                'used_hours' => round($usedH, 1), 'reserve_hours' => round($reserveH, 1), 'open_incidents' => $openIncidents];

    // ---- pending proposals -----------------------------------------------------------------------
    $prop = row($conn, "SELECT TOP 1 id, kind, generated_at FROM dbo.proposals WHERE workspace_id = ? AND status = 'open' ORDER BY generated_at DESC", [$wsId]);
    $changes = [];
    if ($prop) {
        foreach (rows($conn, "SELECT c.id, c.person_id, c.headline, c.reason, c.kind, c.inside_freeze, c.guardrail_status, c.stability_cost_days, c.work_item_id, wi.ref
                              FROM dbo.change_proposals c LEFT JOIN dbo.work_items wi ON wi.id = c.work_item_id
                              WHERE c.proposal_id = ? AND c.workspace_id = ? AND c.decision = 'pending' ORDER BY c.sort_order, c.id", [(int)$prop['id'], $wsId]) as $c) {
            $reason = (string)$c['reason'];
            $changes[] = ['id' => (int)$c['id'], 'person' => isset($people[(int)$c['person_id']]) ? wl_person_lite($people[(int)$c['person_id']]) : null,
                'headline' => $c['headline'], 'sub' => mb_strlen($reason) > 90 ? rtrim(mb_substr($reason, 0, 89)) . '…' : $reason,
                'kind' => $c['kind'], 'ref' => $c['ref'], 'inside_freeze' => (bool)$c['inside_freeze'], 'guardrail_status' => $c['guardrail_status'], 'stability_cost_days' => (float)$c['stability_cost_days']];
        }
    }

    // ---- effort by week (6 weeks) -----------------------------------------------------------------
    $types = rows($conn, "SELECT id, name, plural, colour FROM dbo.work_types WHERE workspace_id = ? AND retired = 0 ORDER BY sort_order, id", [$wsId]);
    $sixEnd = date('Y-m-d', strtotime("$thisMon +41 days"));
    $capMap6 = wl_capacity_map($conn, $wsId, $thisMon, $sixEnd);
    $leaveMap6 = wl_leave_map($conn, $wsId, $thisMon, $sixEnd);
    $sixAssign = wl_committed_assignments($conn, $wsId, $thisMon, $sixEnd);
    $effort = [];
    for ($w = 0; $w < 6; $w++) {
        $wsStart = date('Y-m-d', strtotime("$thisMon +" . (7 * $w) . " days")); $wsEnd = date('Y-m-d', strtotime("$wsStart +6 days"));
        $byType = [];
        foreach ($types as $t) $byType[(int)$t['id']] = ['type_id' => (int)$t['id'], 'type' => $t['plural'] ?: $t['name'], 'colour' => $t['colour'], 'days' => 0.0];
        $assignedDays = 0.0;
        foreach ($sixAssign as $a) {
            if (!isset($people[$a['person_id']])) continue;
            $days = count(wl_assignment_days($a, $wsStart, $wsEnd, $wd)) * $a['allocation_pct'] / 100;
            if ($days <= 0) continue;
            $assignedDays += $days;
            if (isset($byType[$a['work_type_id']])) $byType[$a['work_type_id']]['days'] += $days;
        }
        $capDays = 0.0;
        foreach ($people as $p) foreach (wl_days_in($wsStart, $wsEnd, $wd) as $d) $capDays += wl_available_hours($p, $d, $capMap6, $leaveMap6) / $hoursPerDay;
        foreach ($byType as &$bt) $bt['days'] = round($bt['days'], 1);
        unset($bt);
        $effort[] = ['week_start' => $wsStart, 'label' => 'w/c ' . date('j M', strtotime($wsStart)), 'by_type' => array_values($byType),
                     'assigned_days' => round($assignedDays, 1), 'capacity_days' => round($capDays, 1), 'unallocated_days' => round(max(0, $capDays - $assignedDays), 1)];
    }

    // ---- next proposal from cadence e.g. 'daily 02:00' -------------------------------------------
    $cad = (string)$policy['propose_cadence'];
    $hm = preg_match('/(\d{1,2}):(\d{2})/', $cad, $m) ? sprintf('%02d:%02d', $m[1], $m[2]) : '02:00';
    $now = $today . ' ' . date('H:i:s');   // demo "today" keeps the real clock
    $next = "$today $hm:00";
    if ($next <= $now) $next = date('Y-m-d', strtotime("$today +1 day")) . " $hm:00";
    if (stripos($cad, 'weekly') !== false && preg_match('/\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/i', $cad, $dm)) {
        while (strcasecmp(date('D', strtotime($next)), $dm[1]) !== 0) $next = date('Y-m-d', strtotime(substr($next, 0, 10) . ' +1 day')) . " $hm:00";
    }

    ok([
        'today' => $today,
        'today_label' => date('l j F Y', strtotime($today)),
        'workspace_name' => $ws['name'],
        'people_count' => count($people),
        'plan_pill' => $plan ? 'Plan committed to ' . wl_fmt_day($plan['committed_through'] ? substr($plan['committed_through'], 0, 10) : $freezeEnd) : 'No committed plan',
        'committed' => ['count' => count($items), 'due_this_week' => $dueThisWeek, 'delta_vs_last_fortnight' => count($items) - $deliveredPrev,
                        'window_from' => $today, 'window_to' => $freezeEnd, 'window_label' => 'Landing by ' . wl_fmt_day($freezeEnd),
                        'working_days' => (int)$policy['freeze_horizon_days'], 'items' => $items],
        'load' => ['pct' => $loadPct, 'target_min' => $tmin, 'target_max' => $tmax, 'band_label' => $band,
                   'assigned_hours' => round($assignedH, 1), 'available_hours' => round($availH, 1), 'window_from' => $today, 'window_to' => $plannedEnd],
        'stability' => $stability,
        'reserve' => $reserve,
        'proposals' => ['count' => count($changes), 'proposal_id' => $prop ? (int)$prop['id'] : null, 'items' => $changes],
        'watch_list' => build_watch_list($conn, $wsId),
        'effort_by_week' => $effort,
        'next_proposal_at' => $next,
        'next_proposal_label' => date('H:i D', strtotime($next)),
    ]);
}

if ($action === 'my_week') {
    // Whose week? Own person by default; team leads may look at anyone's via person_id.
    $target = $personId;
    $reqPerson = param('person_id');
    if ($reqPerson !== null && (int)$reqPerson !== (int)$personId) {
        if (!has_role('team_lead')) fail('Forbidden: only team leads can view another person\'s week', 403);
        $target = (int)$reqPerson;
    }
    if (!$target) fail('Your account is not linked to a person', 403);
    $person = wl_people($conn, $wsId, true)[$target] ?? null;
    if (!$person) fail('Person not found', 404);

    $weekStart = week_start(param('week_start') ?: $today);
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $weekStart)) fail('week_start must be YYYY-MM-DD', 400);
    $weekEnd = date('Y-m-d', strtotime("$weekStart +4 days"));
    $capMap = wl_capacity_map($conn, $wsId, $weekStart, $weekEnd);
    $leaveMap = wl_leave_map($conn, $wsId, $weekStart, $weekEnd);
    $rota = wl_rota_map($conn, $wsId, $weekStart, $weekEnd);
    $myHolidays = holiday_map($conn, $wsId, $weekStart, $weekEnd);
    $onRota = isset($rota[$target][$weekStart]);

    $mine = wl_committed_assignments($conn, $wsId, $weekStart, $weekEnd, $target);
    // co-assignees on the same items (any overlap with the week)
    $others = [];
    if ($mine) {
        $ids = array_flip(array_map(fn($a) => $a['work_item_id'], $mine));
        foreach (wl_committed_assignments($conn, $wsId, $weekStart, $weekEnd) as $o)
            if ($o['person_id'] !== $target && isset($ids[$o['work_item_id']]) && isset($people[$o['person_id']]))
                $others[$o['work_item_id']][$o['person_id']] = wl_first_name($people[$o['person_id']]['name']);
    }
    $days = []; $weekAvail = 0.0; $weekAssigned = 0.0; $usedReserve = 0.0; $reserveWeek = 0.0;
    foreach (['Mon','Tue','Wed','Thu','Fri'] as $i => $dow) {
        $d = date('Y-m-d', strtotime("$weekStart +$i days"));
        $avail = wl_available_hours($person, $d, $capMap, $leaveMap, $myHolidays);
        $reserveWeek += wl_reserve_hours($person, $d, $capMap, $leaveMap, $policy, $onRota, $myHolidays);
        $assigned = 0.0; $list = [];
        foreach ($mine as $a) {
            if ($a['from_date'] > $d || $a['to_date'] < $d) continue;
            $h = wl_pattern_hours($person, $d) * $a['allocation_pct'] / 100;
            $assigned += $h;
            if ($a['is_reserve'] || $a['type_policy'] === 'interrupt') $usedReserve += $h;
            $list[] = $a + [
                'pct_of_day' => $a['allocation_pct'],
                'hours' => round($h, 1),
                'day_n' => working_days_between($a['from_date'], $d, $wd),
                'day_total' => working_days_between($a['from_date'], $a['to_date'], $wd),
                'with' => array_values($others[$a['work_item_id']] ?? []),
                'status_label' => wl_status_label($a['status'], $a['health']),
                'due' => $a['needed_by'] ?? $a['to_date'],
                'due_label' => 'Due ' . wl_fmt_day($a['needed_by'] ?? $a['to_date']),
                'state_label' => $a['state'] === 'committed' ? 'Committed' : ($a['state'] === 'indicative' ? 'Indicative' : 'Planned'),
            ];
        }
        $weekAvail += $avail; $weekAssigned += $assigned;
        $leave = $leaveMap[$target][$d] ?? null;
        // A bank holiday is a day off nobody booked, so it reads as one: the card says what it is
        // rather than leaving an unexplained empty day.
        $holiday = holiday_label($myHolidays, $d, $person['holiday_region'] ?? null);
        $days[] = ['date' => $d, 'label' => date('D j', strtotime($d)), 'dow' => $dow, 'day_num' => (int)date('j', strtotime($d)), 'is_today' => $d === $today,
                   'assignments' => $list, 'hours_available' => round($avail, 1), 'hours_assigned' => round($assigned, 1),
                   'leave' => $holiday !== null || ($leave !== null && $leave['fraction'] >= 0.5),
                   'leave_label' => $holiday ?? ($leave ? $leave['label'] : null),
                   'holiday' => $holiday];
    }

    // pending changes that touch this person
    $changes = [];
    $prop = row($conn, "SELECT TOP 1 id FROM dbo.proposals WHERE workspace_id = ? AND status = 'open' ORDER BY generated_at DESC", [$wsId]);
    if ($prop) {
        foreach (rows($conn, "SELECT c.*, wi.ref, wi.title FROM dbo.change_proposals c LEFT JOIN dbo.work_items wi ON wi.id = c.work_item_id
                              WHERE c.proposal_id = ? AND c.workspace_id = ? AND c.decision = 'pending' ORDER BY c.sort_order, c.id", [(int)$prop['id'], $wsId]) as $c) {
            $affected = csv_ids($c['affected_person_ids']);
            if ((int)$c['person_id'] !== $target && !in_array($target, $affected, true)) continue;
            $changes[] = ['id' => (int)$c['id'], 'proposal_id' => (int)$c['proposal_id'], 'kind' => $c['kind'], 'headline' => $c['headline'], 'sub' => $c['reason'], 'reason' => $c['reason'],
                'person' => isset($people[(int)$c['person_id']]) ? wl_person_lite($people[(int)$c['person_id']]) : null,
                'work_item' => $c['work_item_id'] ? ['id' => (int)$c['work_item_id'], 'ref' => $c['ref'], 'title' => $c['title']] : null,
                'before' => json_col($c['before_json'], null), 'after' => json_col($c['after_json'], null),
                'stability_cost_days' => (float)$c['stability_cost_days'], 'inside_freeze' => (bool)$c['inside_freeze'],
                'impact_chips' => json_col($c['impact_chips']), 'guardrail_status' => $c['guardrail_status'], 'decision' => $c['decision'], 'acknowledged_at' => $c['acknowledged_at']];
        }
    }

    // coming up: next assignments after this week
    $coming = [];
    foreach (wl_committed_assignments($conn, $wsId, date('Y-m-d', strtotime("$weekEnd +1 day")), null, $target) as $a) {
        if ($a['from_date'] <= $weekEnd) continue;
        $coming[] = $a + ['state_label' => $a['state'] === 'committed' ? 'Committed' : ($a['state'] === 'indicative' ? 'Indicative' : 'Planned'),
                          'range_label' => date('D j', strtotime($a['from_date'])) . ' – ' . wl_fmt_day($a['to_date'])];
        if (count($coming) >= 6) break;
    }

    $reservePct = $onRota ? (float)$policy['rota_reserve_pct'] : (float)$policy['incident_reserve_pct'];
    ok([
        'person' => wl_person_lite($person) + ['role_title' => $person['role_title'], 'team_name' => $person['team_name'], 'first_name' => wl_first_name($person['name'])],
        'week' => ['week_start' => $weekStart, 'week_end' => $weekEnd, 'label' => date('D j', strtotime($weekStart)) . ' – ' . wl_fmt_day($weekEnd), 'days' => $days],
        'changes_affecting' => $changes,
        'reserve' => ['pct' => $reservePct, 'on_rota' => $onRota, 'hours_week' => round($reserveWeek, 1), 'used_hours' => round($usedReserve, 1)],
        'coming_up' => $coming,
        'load_pct' => $weekAvail > 0 ? (int)round($weekAssigned / $weekAvail * 100) : 0,
        'hours_available' => round($weekAvail, 1), 'hours_assigned' => round($weekAssigned, 1),
    ]);
}

fail('Unknown action', 400);
