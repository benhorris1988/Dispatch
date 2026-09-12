<?php
// Schedule, versions, assignments (VIEW-01..05, SCH-06/07, CHG-05). Actions:
//   schedule{from?, to?, plan_version_id?, team_id?, type_id?, skill_id?, item_id?, overlay_proposal_id?}
//   versions  version{id}  restore{plan_version_id, reason}  move_assignment{...}  fix_assignment{...}  unfix{assignment_id}  lock_state
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/proposals.php';
$action = param('action', 'schedule');

if ($action === 'schedule') {
    $today = today();
    $from = param('from') ?: week_start($today);
    $to = param('to') ?: date('Y-m-d', strtotime(week_start($from) . ' +6 weeks -1 day'));
    if ($to < $from) fail('to must not be before from', 400);
    $ws = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $workingDays = array_map('trim', explode(',', $ws['working_days'] ?: 'Mon,Tue,Wed,Thu,Fri'));
    $hpd = (float)($ws['hours_per_day'] ?: 7.5);
    $policy = model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []);
    $pv = param('plan_version_id') ? row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ? AND workspace_id = ?", [(int)param('plan_version_id'), $wsId])
                                   : row($conn, "SELECT TOP 1 * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    $committed = row($conn, "SELECT TOP 1 committed_through FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    $windows = model_windows($today, $policy, $workingDays, $committed['committed_through'] ?? null);
    // weeks
    $weeks = []; $d = new DateTime(week_start($from));
    while ($d->format('Y-m-d') <= $to) { $ws0 = $d->format('Y-m-d'); $weeks[] = ['week_start' => $ws0, 'label' => 'w/c ' . ltrim($d->format('j M'), '0'), 'state' => model_state_for($ws0 < $today ? $today : $ws0, $windows), 'is_current' => $ws0 === week_start($today)]; $d->modify('+7 days'); }
    // people (+ filters)
    $pSql = "SELECT p.*, t.name AS team_name FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id WHERE p.workspace_id = ? AND p.active = 1"; $pParams = [$wsId];
    if (param('team_id')) { $pSql .= " AND p.team_id = ?"; $pParams[] = (int)param('team_id'); }
    $pSql .= " ORDER BY p.name";
    $peopleRows = rows($conn, $pSql, $pParams);
    $pids = array_map(fn($p) => (int)$p['id'], $peopleRows);
    // assignments
    $assignments = []; $capByPerson = [];
    if ($pv && $pids) {
        $aSql = "SELECT a.*, wi.ref, wi.title, wi.progress_pct, wt.colour AS type_colour, wt.name AS type_name, wt.id AS work_type_id, sc.stamp AS size_stamp, sc.name AS size_name
                 FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
                 WHERE a.plan_version_id = ? AND a.to_date >= ? AND a.from_date <= ? AND a.person_id IN (" . implode(',', $pids) . ")";
        $aParams = [(int)$pv['id'], $from, $to];
        if (param('type_id')) { $aSql .= " AND wi.work_type_id = ?"; $aParams[] = (int)param('type_id'); }
        if (param('item_id')) { $aSql .= " AND wi.id = ?"; $aParams[] = (int)param('item_id'); }
        if (param('skill_id')) { $aSql .= " AND EXISTS (SELECT 1 FROM dbo.skill_requirements sr WHERE sr.work_item_id = wi.id AND sr.skill_id = ?)"; $aParams[] = (int)param('skill_id'); }
        $aSql .= " ORDER BY a.person_id, a.from_date";
        foreach (rows($conn, $aSql, $aParams) as $a) $assignments[] = assignment_shape($a, $windows, $today);
    }
    // capacity over the visible range (available hours)
    if ($pids) {
        foreach (rows($conn, "SELECT person_id, SUM(available_hours) AS h FROM dbo.capacity_days WHERE workspace_id = ? AND day >= ? AND day <= ? AND person_id IN (" . implode(',', $pids) . ") GROUP BY person_id", [$wsId, $from, $to]) as $c) $capByPerson[(int)$c['person_id']] = (float)$c['h'];
    }
    $assignedHours = [];
    foreach ($assignments as $a) {
        $f = max($a['from_date'], $from); $t = min($a['to_date'], $to);
        $assignedHours[$a['person_id']] = ($assignedHours[$a['person_id']] ?? 0) + working_days_between($f, $t, $workingDays) * $a['allocation_pct'] / 100 * $hpd;
    }
    $people = [];
    foreach ($peopleRows as $p) {
        $pid = (int)$p['id'];
        $cap = $capByPerson[$pid] ?? null;
        if ($cap === null) { // fall back to pattern
            $pattern = json_col($p['working_pattern'], []); $cap = 0; $d = new DateTime($from); $end = new DateTime($to);
            while ($d <= $end) { $cap += (float)($pattern[$d->format('D')] ?? 0); $d->modify('+1 day'); }
        }
        $people[] = ['id' => $pid, 'name' => $p['name'], 'initials' => trim((string)$p['initials']), 'colour' => $p['colour'], 'role_title' => $p['role_title'], 'tagline' => $p['tagline'], 'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null, 'team_name' => $p['team_name'],
            'days_per_week' => (float)$p['days_per_week'], 'load_pct' => $cap > 0 ? round(($assignedHours[$pid] ?? 0) / $cap * 100) : 0, 'assigned_hours' => round($assignedHours[$pid] ?? 0, 1), 'available_hours' => round($cap, 1)];
    }
    $availability = $pids ? array_map(fn($r) => ['id' => (int)$r['id'], 'person_id' => (int)$r['person_id'], 'from_date' => substr($r['from_date'], 0, 10), 'to_date' => substr($r['to_date'], 0, 10), 'type' => $r['type'], 'fraction' => (float)$r['fraction'], 'label' => $r['label'] ?: ucfirst($r['type'])],
        rows($conn, "SELECT * FROM dbo.availability WHERE workspace_id = ? AND to_date >= ? AND from_date <= ? AND person_id IN (" . implode(',', $pids) . ")", [$wsId, $from, $to])) : [];
    $rota = array_map(fn($r) => ['person_id' => (int)$r['person_id'], 'week_start' => substr($r['week_start'], 0, 10)], rows($conn, "SELECT person_id, week_start FROM dbo.incident_rota WHERE workspace_id = ? AND week_start >= ? AND week_start <= ?", [$wsId, week_start($from), $to]));
    // unscheduled queue (open, ready, no assignment in this version)
    $unschedSql = "SELECT wi.id, wi.ref, wi.title, wi.status, wi.priority_score, wi.needed_by, wt.name AS type_name, wt.colour AS type_colour, sc.stamp AS size_stamp
                   FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
                   WHERE wi.workspace_id = ? AND wi.status IN ('ready','needs_estimate','needs_benefit','scheduled')" . ($pv ? " AND NOT EXISTS (SELECT 1 FROM dbo.assignments a WHERE a.plan_version_id = ? AND a.work_item_id = wi.id AND a.to_date >= ?)" : '') . " ORDER BY wi.priority_score DESC, wi.id";
    $unsched = rows($conn, $unschedSql, $pv ? [$wsId, (int)$pv['id'], $today] : [$wsId]);
    $unschedRows = array_map(fn($r) => ['id' => (int)$r['id'], 'ref' => $r['ref'], 'title' => $r['title'], 'status' => $r['status'], 'priority_score' => $r['priority_score'] !== null ? (float)$r['priority_score'] : null, 'needed_by' => $r['needed_by'] ? substr($r['needed_by'], 0, 10) : null, 'type_name' => $r['type_name'], 'type_colour' => $r['type_colour'], 'size_stamp' => $r['size_stamp']], array_slice($unsched, 0, (int)param('unscheduled_limit', 10)));
    $out = ['plan_version' => $pv ? ['id' => (int)$pv['id'], 'version_no' => (int)$pv['version_no'], 'status' => $pv['status'], 'committed_at' => $pv['committed_at'], 'committed_through' => $pv['committed_through'] ? substr($pv['committed_through'], 0, 10) : null, 'engine' => $pv['engine']] : null,
        'windows' => $windows, 'range' => ['from' => $from, 'to' => $to], 'weeks' => $weeks, 'people' => $people, 'assignments' => $assignments, 'availability' => $availability, 'rota' => $rota,
        'unscheduled' => $unschedRows, 'unscheduled_count' => count($unsched), 'moved_assignment_ids' => []];
    if (param('overlay_proposal_id')) {
        $prop = row($conn, "SELECT * FROM dbo.proposals WHERE id = ? AND workspace_id = ?", [(int)param('overlay_proposal_id'), $wsId]);
        if ($prop && $prop['candidate_plan_version_id']) {
            $cand = rows($conn, "SELECT a.*, wi.ref, wi.title, wi.progress_pct, wt.colour AS type_colour, wt.name AS type_name, sc.stamp AS size_stamp, sc.name AS size_name
                                 FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
                                 WHERE a.plan_version_id = ? AND a.to_date >= ? AND a.from_date <= ? ORDER BY a.person_id, a.from_date", [(int)$prop['candidate_plan_version_id'], $from, $to]);
            $baseKeys = []; foreach ($assignments as $a) $baseKeys["{$a['work_item_id']}:{$a['person_id']}"] = "{$a['from_date']}|{$a['to_date']}|{$a['allocation_pct']}";
            $overlay = []; $moved = []; $candKeys = [];
            foreach ($cand as $a) {
                $s = assignment_shape($a, $windows, $today); $k = "{$s['work_item_id']}:{$s['person_id']}"; $candKeys[$k] = true;
                $s['proposed'] = true;
                if (!isset($baseKeys[$k]) || $baseKeys[$k] !== "{$s['from_date']}|{$s['to_date']}|{$s['allocation_pct']}") { $moved[] = $s['id']; $s['changed'] = true; } else $s['changed'] = false;
                $overlay[] = $s;
            }
            $removed = []; foreach ($assignments as $a) if (!isset($candKeys["{$a['work_item_id']}:{$a['person_id']}"])) $removed[] = $a['id'];
            $out['overlay'] = ['proposal_id' => (int)$prop['id'], 'plan_version_id' => (int)$prop['candidate_plan_version_id'], 'assignments' => $overlay, 'removed_assignment_ids' => $removed];
            $out['moved_assignment_ids'] = $moved;
        }
    }
    ok($out);
}

if ($action === 'versions') {
    $vs = rows($conn, "SELECT pv.*, (SELECT COUNT(*) FROM dbo.assignments a WHERE a.plan_version_id = pv.id) AS assignment_count,
                              (SELECT COUNT(*) FROM dbo.change_proposals c JOIN dbo.proposals p ON p.id = c.proposal_id WHERE p.candidate_plan_version_id = pv.id) AS change_count,
                              u.display_name AS committed_by_name
                       FROM dbo.plan_versions pv LEFT JOIN dbo.users u ON u.id = pv.committed_by WHERE pv.workspace_id = ? ORDER BY pv.version_no DESC", [$wsId]);
    ok(['versions' => array_map('version_shape', $vs)]);
}
if ($action === 'version') {
    $v = row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ? AND workspace_id = ?", [(int)require_param('id'), $wsId]);
    if (!$v) fail('Version not found', 404);
    $policy = model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []);
    $ws = row($conn, "SELECT working_days FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $windows = model_windows(today(), $policy, array_map('trim', explode(',', $ws['working_days'])), $v['committed_through']);
    $as = rows($conn, "SELECT a.*, wi.ref, wi.title, wi.progress_pct, wt.colour AS type_colour, wt.name AS type_name, sc.stamp AS size_stamp, sc.name AS size_name FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id WHERE a.plan_version_id = ? ORDER BY a.person_id, a.from_date", [(int)$v['id']]);
    ok(['version' => version_shape($v), 'assignments' => array_map(fn($a) => assignment_shape($a, $windows, today()), $as)]);
}
if ($action === 'restore') {
    require_role('delivery_lead');
    $v = row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ? AND workspace_id = ?", [(int)require_param('plan_version_id'), $wsId]);
    if (!$v) fail('Version not found', 404);
    $reason = trim((string)require_param('reason'));
    $model = build_model($conn, $wsId);
    $src = version_rows($conn, (int)$v['id']);
    $vid = new_committed_version($conn, $wsId, $model, function (&$rows) use ($src) { $rows = $src; }, ['engine' => 'manual', 'notes' => "Restored from v{$v['version_no']}: " . mb_substr($reason, 0, 300)]);
    // people whose plan changed
    $after = version_rows($conn, $vid);
    $diff = diff_plans($model['committed'], array_map(fn($r) => $r + ['state' => 'planned'], $after), $model);
    foreach (array_unique(array_merge(...array_map(fn($c) => $c['affected_person_ids'], $diff ?: [[]]))) as $pid) notify_person($conn, $wsId, $pid, 'change_committed', "Plan restored to v{$v['version_no']}", $reason, '/schedule', 0);
    rollup_stability_week($conn, $wsId, build_model($conn, $wsId), plan_moved_days($model, $model['committed'], array_map(fn($r) => $r + ['state' => 'planned'], $after)));
    audit($conn, $wsId, 'commit', 'plan_version', $vid, ['restored_from' => (int)$v['id']], ['version_no' => $v['version_no']], "Restore v{$v['version_no']}", $reason);
    ok(['plan_version' => version_shape(row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ?", [$vid])), 'changes' => count($diff)]);
}

if ($action === 'move_assignment') {
    require_role('delivery_lead');
    $aid = (int)require_param('assignment_id');
    $from = require_param('from_date'); $to = require_param('to_date');
    if ($from > $to) fail('from_date must not be after to_date', 400);
    $newPid = param('person_id') ? (int)param('person_id') : null; $alloc = param('allocation_pct') ? (int)param('allocation_pct') : null;
    $preview = (bool)param('preview', false);
    $model = build_model($conn, $wsId);
    $orig = null; foreach ($model['committed'] as $a) if ($a['id'] === $aid) $orig = $a;
    if (!$orig) fail('Assignment not found in the committed plan', 404);
    $item = $model['items'][$orig['work_item_id']] ?? null;
    if (!$item) fail('This work item is no longer open', 409);
    $windows = $model['windows'];
    $insideFreeze = $from <= $windows['freeze_end'] || max($orig['from_date'], $model['today']) <= $windows['freeze_end'];
    $reason = trim((string)param('reason', ''));
    if ($insideFreeze && !$preview && $reason === '') {
        $nextMonday = date('Y-m-d', strtotime($windows['freeze_end'] . ' next monday'));
        fail('Inside the freeze horizon. Ask a delivery lead to approve with a reason, or move the start to Monday ' . date('j M', strtotime($nextMonday)) . ' or later.', 409, ['inside_freeze' => true, 'freeze_end' => $windows['freeze_end']]);
    }
    $res = preview_move($model, $aid, $from, $to, $newPid, $alloc);
    if (!$res) fail('Could not preview the move', 500);
    $moved = $res['moved'];
    // warnings on the moved row itself
    $warnings = [];
    $p = $model['people'][$moved['person_id']] ?? null;
    if (!$p) $warnings[] = 'The target person is not active';
    elseif (!pl_meets($p, $item['skills']) && !$item['skill_effort']) $warnings[] = "{$p['name']} does not meet the skill requirements for {$item['ref']}";
    foreach (plan_check_constraints(array_values(array_filter($res['assignments'], fn($x) => $x['person_id'] === $moved['person_id'])), $model) as $v) $warnings[] = $v;
    $warnings = array_values(array_unique($warnings));
    if ($item['needed_by'] && $to > $item['needed_by']) $warnings[] = "{$item['ref']} would finish after its needed-by date " . ex_date($item['needed_by']);
    $diff = diff_plans($model['committed'], $res['assignments'], $model);
    $knock = [];
    foreach ($diff as $c) {
        if ($c['work_item_id'] === $item['id']) continue; // the move itself
        $c = explain_change($c, $model, [], ['displacements' => $res['displacements'] ?? []]);
        $knock[] = ['ref' => $c['ref'], 'title' => $c['title'], 'person' => $c['person_name'], 'person_id' => $c['person_id'], 'kind' => $c['kind'], 'from' => $c['after']['from'] ?? null, 'to' => $c['after']['to'] ?? null, 'effect' => $c['headline'], 'stability_cost_days' => $c['stability_cost_days'], 'change' => $c];
    }
    $movedChange = null; foreach ($diff as $c) if ($c['work_item_id'] === $item['id']) { $movedChange = explain_change($c, $model, [], []); break; }
    $cost = $movedChange ? $movedChange['stability_cost_days'] : 0;
    if ($preview) ok(['knock_on' => array_map(fn($k) => array_diff_key($k, ['change' => 1]), $knock), 'stability_cost_days' => $cost, 'inside_freeze' => $insideFreeze, 'warnings' => $warnings, 'moved' => ['assignment_id' => $aid, 'person_id' => $moved['person_id'], 'from' => $from, 'to' => $to, 'allocation_pct' => $moved['allocation_pct']], 'headline' => $movedChange['headline'] ?? "Move {$item['ref']}", 'summary_after' => plan_summary($res['assignments'], $model)]);

    // ---- apply: new committed version = current + the move (+ knock-on when requested)
    $applyKnock = (bool)param('apply_knock_on', false);
    $edits = [['work_item_id' => $item['id'], 'kind' => $newPid && $newPid !== $orig['person_id'] ? 'reassign' : 'move', 'before' => ['person_id' => $orig['person_id'], 'from' => $orig['from_date'], 'to' => $orig['to_date'], 'allocation_pct' => $orig['allocation_pct']], 'after' => ['person_id' => $moved['person_id'], 'from' => $from, 'to' => $to, 'allocation_pct' => $moved['allocation_pct']]]];
    if ($applyKnock) foreach ($knock as $k) $edits[] = ['work_item_id' => $k['change']['work_item_id'], 'kind' => $k['kind'], 'before' => $k['change']['before'], 'after' => $k['change']['after']];
    $vid = new_committed_version($conn, $wsId, $model, function (&$rows) use ($edits) { foreach ($edits as $e) apply_change_to_rows($rows, $e); }, ['engine' => 'manual', 'notes' => 'Manual move of ' . $item['ref'] . ($reason ? ': ' . mb_substr($reason, 0, 300) : '')]);
    // record as a manual, already-decided proposal so it shows in history (SCH-07, 8.13 "manual edits are changes like any other")
    $pid = insert($conn, 'proposals', ['workspace_id' => $wsId, 'candidate_plan_version_id' => $vid, 'base_plan_version_id' => $model['committed_version_id'], 'kind' => 'manual', 'status' => 'decided', 'generated_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'engine' => 'manual', 'triggers' => json_encode([['type' => 'manual', 'label' => "$userName moved {$item['ref']} in the schedule"]])]);
    $wk = week_start($model['today']); $sort = 0;
    $all = $movedChange ? array_merge([$movedChange], $applyKnock ? array_map(fn($k) => $k['change'], $knock) : []) : [];
    foreach ($all as $c) {
        $cid = insert($conn, 'change_proposals', ['proposal_id' => $pid, 'workspace_id' => $wsId, 'person_id' => $c['person_id'], 'work_item_id' => $c['work_item_id'], 'kind' => $c['kind'], 'headline' => mb_substr($c['headline'], 0, 200),
            'before_json' => $c['before'] ? json_encode($c['before'], JSON_UNESCAPED_UNICODE) : null, 'after_json' => $c['after'] ? json_encode($c['after'], JSON_UNESCAPED_UNICODE) : null, 'reason' => mb_substr($reason ?: "Manual move by $userName", 0, 400),
            'stability_cost_days' => $c['stability_cost_days'], 'inside_freeze' => $c['inside_freeze'] ? 1 : 0, 'impact_chips' => json_encode($c['impact_chips'], JSON_UNESCAPED_UNICODE), 'affected_person_ids' => implode(',', $c['affected_person_ids']),
            'guardrail_status' => $c['inside_freeze'] ? 'needs_approval' : 'ok', 'guardrail_reason' => $c['inside_freeze'] ? "Approved by $userName: $reason" : null, 'decision' => 'accepted', 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason ?: null, 'sort_order' => $sort++]);
        foreach (array_unique(array_filter([(int)($c['before']['person_id'] ?? 0), (int)($c['after']['person_id'] ?? 0)])) as $pp) insert($conn, 'person_change_log', ['workspace_id' => $wsId, 'person_id' => $pp, 'work_item_id' => $c['work_item_id'], 'week_start' => week_start($c['after']['from'] ?? $c['before']['from'] ?? $model['today']), 'inside_freeze' => $c['inside_freeze'] ? 1 : 0, 'assignment_days' => $c['stability_cost_days'], 'reason' => mb_substr($reason ?: 'Manual move', 0, 300), 'change_proposal_id' => $cid]);
        foreach ($c['affected_person_ids'] as $pp) notify_person($conn, $wsId, $pp, 'change_committed', $c['headline'], $reason ?: "Moved by $userName in the schedule", '/schedule', $c['inside_freeze'] ? 1 : 0);
    }
    rollup_stability_week($conn, $wsId, build_model($conn, $wsId));
    audit($conn, $wsId, 'update', 'assignment', $aid, ['person_id' => $orig['person_id'], 'from' => $orig['from_date'], 'to' => $orig['to_date'], 'allocation_pct' => $orig['allocation_pct']], ['person_id' => $moved['person_id'], 'from' => $from, 'to' => $to, 'allocation_pct' => $moved['allocation_pct'], 'plan_version_id' => $vid, 'knock_on_applied' => $applyKnock], $item['ref'], $reason ?: null);
    ok(['plan_version' => version_shape(row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ?", [$vid])), 'proposal_id' => $pid, 'knock_on' => array_map(fn($k) => array_diff_key($k, ['change' => 1]), $knock), 'knock_on_applied' => $applyKnock, 'stability_cost_days' => $cost, 'inside_freeze' => $insideFreeze, 'warnings' => $warnings]);
}

if ($action === 'fix_assignment' || $action === 'unfix') {
    require_role('delivery_lead');
    $aid = (int)require_param('assignment_id');
    $a = row($conn, "SELECT a.*, wi.ref FROM dbo.assignments a JOIN dbo.plan_versions pv ON pv.id = a.plan_version_id JOIN dbo.work_items wi ON wi.id = a.work_item_id WHERE a.id = ? AND pv.workspace_id = ?", [$aid, $wsId]);
    if (!$a) fail('Assignment not found', 404);
    $data = $action === 'unfix' ? ['fixed_person' => 0, 'fixed_dates' => 0, 'fixed_by' => null] : ['fixed_person' => (int)(bool)param('fixed_person', true), 'fixed_dates' => (int)(bool)param('fixed_dates', true), 'fixed_by' => $userId];
    update($conn, 'assignments', $data, 'id = ?', [$aid]);
    audit($conn, $wsId, 'update', 'assignment', $aid, ['fixed_person' => (int)$a['fixed_person'], 'fixed_dates' => (int)$a['fixed_dates']], $data, $a['ref']);
    $policy = model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []);
    $ws = row($conn, "SELECT working_days FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $row2 = row($conn, "SELECT a.*, wi.ref, wi.title, wi.progress_pct, wt.colour AS type_colour, wt.name AS type_name, sc.stamp AS size_stamp, sc.name AS size_name FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id WHERE a.id = ?", [$aid]);
    ok(['assignment' => assignment_shape($row2, model_windows(today(), $policy, array_map('trim', explode(',', $ws['working_days']))), today())]);
}

if ($action === 'lock_state') {
    $pv = row($conn, "SELECT TOP 1 committed_through, committed_at, version_no FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    $pol = row($conn, "SELECT TOP 1 propose_cadence, commit_cadence FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: [];
    $last = scalar($conn, "SELECT MAX(generated_at) FROM dbo.proposals WHERE workspace_id = ? AND kind IN ('nightly','manual','urgent')", [$wsId]);
    $open = row($conn, "SELECT TOP 1 id FROM dbo.proposals WHERE workspace_id = ? AND status = 'open' ORDER BY generated_at DESC", [$wsId]);
    $openChanges = $open ? (int)scalar($conn, "SELECT COUNT(*) FROM dbo.change_proposals WHERE proposal_id = ? AND decision = 'pending'", [(int)$open['id']]) : 0;
    ok(['committed_through' => $pv && $pv['committed_through'] ? substr($pv['committed_through'], 0, 10) : null, 'committed_at' => $pv['committed_at'] ?? null, 'version_no' => $pv ? (int)$pv['version_no'] : null,
        'next_proposal_at' => next_cadence_time($pol['propose_cadence'] ?? 'daily 02:00'), 'next_commit_at' => next_cadence_time($pol['commit_cadence'] ?? 'weekly Mon 09:00'),
        'last_proposal_at' => $last, 'open_proposal_id' => $open ? (int)$open['id'] : null, 'open_changes' => $openChanges,
        'label' => $pv && $pv['committed_through'] ? 'Plan committed to ' . date('D j M', strtotime($pv['committed_through'])) : 'No committed plan']);
}
fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------------------------
function assignment_shape(array $a, array $windows, $today) {
    $from = substr($a['from_date'], 0, 10); $to = substr($a['to_date'], 0, 10);
    $lu = $a['locked_until'] ? substr($a['locked_until'], 0, 10) : null;
    return ['id' => (int)$a['id'], 'plan_version_id' => (int)$a['plan_version_id'], 'work_item_id' => (int)$a['work_item_id'], 'ref' => $a['ref'], 'title' => $a['title'],
        'type_colour' => $a['type_colour'] ?? null, 'type_name' => $a['type_name'] ?? null, 'size_stamp' => $a['size_stamp'] ?? null, 'size_name' => $a['size_name'] ?? null,
        'person_id' => (int)$a['person_id'], 'from_date' => $from, 'to_date' => $to, 'allocation_pct' => (int)$a['allocation_pct'],
        'state' => $a['state'] ?: model_state_for(max($from, $today), $windows), 'role_label' => $a['role_label'],
        'locked' => (bool)($a['fixed_person'] || $a['fixed_dates'] || ($lu && $lu >= $today) || max($from, $today) <= $windows['freeze_end']),
        'fixed_person' => (bool)$a['fixed_person'], 'fixed_dates' => (bool)$a['fixed_dates'], 'is_reserve' => (bool)$a['is_reserve'], 'note' => $a['note'], 'progress_pct' => isset($a['progress_pct']) ? (int)$a['progress_pct'] : null];
}
function version_shape(array $v) {
    return ['id' => (int)$v['id'], 'version_no' => (int)$v['version_no'], 'status' => $v['status'], 'engine' => $v['engine'], 'generated_at' => $v['generated_at'], 'committed_at' => $v['committed_at'],
        'committed_through' => $v['committed_through'] ? substr($v['committed_through'], 0, 10) : null, 'committed_by_name' => $v['committed_by_name'] ?? null, 'policy_version' => $v['policy_version'] !== null ? (int)$v['policy_version'] : null,
        'objective_score' => $v['objective_score'] !== null ? (float)$v['objective_score'] : null, 'objective_terms' => json_col($v['objective_terms'], null), 'stability_cost_days' => $v['stability_cost_days'] !== null ? (float)$v['stability_cost_days'] : null,
        'solver_stats' => json_col($v['solver_stats'], null), 'scenario_name' => $v['scenario_name'], 'notes' => $v['notes'], 'inputs_hash' => $v['inputs_hash'],
        'assignment_count' => isset($v['assignment_count']) ? (int)$v['assignment_count'] : null, 'change_count' => isset($v['change_count']) ? (int)$v['change_count'] : null];
}
/** "daily 02:00" | "weekly Mon 09:00" → next occurrence as a timestamp string (real clock, not fake_today). */
function next_cadence_time($cadence) {
    $now = new DateTime();
    if (preg_match('/^daily\s+(\d{1,2}):(\d{2})$/i', trim($cadence), $m)) { $t = (clone $now)->setTime((int)$m[1], (int)$m[2]); if ($t <= $now) $t->modify('+1 day'); return $t->format('Y-m-d H:i:s'); }
    if (preg_match('/^weekly\s+(\w{3})\s+(\d{1,2}):(\d{2})$/i', trim($cadence), $m)) { $t = new DateTime('this ' . $m[1]); $t->setTime((int)$m[2], (int)$m[3]); if ($t <= $now) $t->modify('+1 week'); return $t->format('Y-m-d H:i:s'); }
    return null;
}
