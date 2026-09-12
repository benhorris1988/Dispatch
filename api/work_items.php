<?php
// Pipeline: work items, readiness, dependencies, tasks, skills, comments, priority overrides (PIP-*, REQ-*, VIEW-08).
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/items_lib.php';
require_once __DIR__ . '/engine/priority.php';
$action = param('action', 'list');

// ---------------------------------------------------------------------------------------------
if ($action === 'list') {
    $where = ["wi.status <> 'cancelled'"]; $params = [];
    $pv = committed_plan_id($conn, $wsId) ?? -1;
    $hasPlan = "EXISTS (SELECT 1 FROM dbo.assignments a2 WHERE a2.work_item_id = wi.id AND a2.plan_version_id = $pv)";
    $status = param('status');
    if ($status && $status !== 'all') {
        if ($status === 'unscheduled') $where[] = "wi.status IN ('ready','needs_estimate','needs_benefit','draft','blocked') AND NOT $hasPlan";
        elseif ($status === 'scheduled') $where[] = "(wi.status = 'scheduled' OR (wi.status = 'ready' AND $hasPlan))";
        elseif ($status === 'open') $where[] = "wi.status NOT IN ('delivered','cancelled')";
        elseif ($status === 'cancelled') { $where = ["wi.status = 'cancelled'"]; }
        else { $where[] = "wi.status = ?"; $params[] = $status; }
    }
    if (($sch = param('scheduled')) !== null && $sch !== '') $where[] = ($sch === 'yes' ? '' : 'NOT ') . $hasPlan;
    if (($t = idp('type_id')) !== null) { $where[] = "wi.work_type_id = ?"; $params[] = (int)$t; }
    if ($s = param('size_stamp')) {
        if (strtoupper($s) === 'C') $where[] = "(sc.is_custom = 1 OR (wi.size_class_id IS NULL AND wi.custom_effort_days IS NOT NULL))";
        else { $where[] = "sc.stamp = ? AND sc.is_custom = 0"; $params[] = strtoupper($s); }
    }
    if (($sk = idp('skill_id')) !== null) { $where[] = "EXISTS (SELECT 1 FROM dbo.skill_requirements sr WHERE sr.work_item_id = wi.id AND sr.skill_id = ?)"; $params[] = (int)$sk; }
    if (($tm = idp('team_id')) !== null) { $where[] = "EXISTS (SELECT 1 FROM dbo.assignments a3 JOIN dbo.people p3 ON p3.id = a3.person_id WHERE a3.work_item_id = wi.id AND a3.plan_version_id = $pv AND p3.team_id = ?)"; $params[] = (int)$tm; }
    if (($qq = trim((string)param('q', ''))) !== '') { $where[] = "(wi.ref LIKE ? OR wi.title LIKE ? OR wi.tags LIKE ? OR wi.summary LIKE ?)"; $like = "%$qq%"; array_push($params, $like, $like, $like, $like); }
    $sortMap = ['priority_score' => 'wi.priority_score', 'priority' => 'wi.priority_score', 'ref' => 'wi.ref', 'title' => 'wi.title', 'type' => 'wt.sort_order', 'type_name' => 'wt.name',
        'size_stamp' => 'COALESCE(sc.min_days, wi.custom_effort_days)', 'size' => 'COALESCE(sc.min_days, wi.custom_effort_days)', 'benefit_value' => 'b.benefit_value', 'benefit' => 'b.benefit_value',
        'rom' => 'e.likely', 'rom_low' => 'e.likely', 'status' => 'wi.status', 'needed_by' => 'wi.needed_by', 'planned_from' => 'pl.planned_from', 'planned_to' => 'pl.planned_to',
        'created_at' => 'wi.created_at', 'updated_at' => 'wi.updated_at', 'progress_pct' => 'wi.progress_pct', 'health' => 'wi.health'];
    $sort = $sortMap[param('sort', 'priority_score')] ?? 'wi.priority_score';
    $dir = strtolower(param('dir', $sort === 'wi.priority_score' || $sort === 'b.benefit_value' ? 'desc' : 'asc')) === 'desc' ? 'DESC' : 'ASC';
    $limit = param('limit') !== null ? max(1, (int)param('limit')) : null;
    // Priority is the tie-breaker for every other sort, but SQL Server rejects a column
    // that appears twice in ORDER BY — so only add it when it is not already the key.
    $tieBreak = $sort === 'wi.priority_score' ? '' : ', wi.priority_score DESC';
    [$items, $total] = work_item_rows($conn, $wsId, implode(' AND ', $where), $params, "$sort $dir$tieBreak, wi.id", $limit, (int)param('offset', 0));

    // "Is it on the committed plan?" comes in as a LEFT JOIN rather than the EXISTS used in
    // the WHERE clause: SQL Server will not evaluate an aggregate over a subquery.
    $c = row($conn, "SELECT
        SUM(CASE WHEN wi.status <> 'cancelled' THEN 1 ELSE 0 END) AS [all],
        SUM(CASE WHEN wi.status IN ('ready','needs_estimate','needs_benefit','draft','blocked') AND sch.work_item_id IS NULL THEN 1 ELSE 0 END) AS unscheduled,
        SUM(CASE WHEN wi.status = 'scheduled' OR (wi.status = 'ready' AND sch.work_item_id IS NOT NULL) THEN 1 ELSE 0 END) AS scheduled,
        SUM(CASE WHEN wi.status = 'in_progress' THEN 1 ELSE 0 END) AS in_progress,
        SUM(CASE WHEN wi.status = 'delivered' THEN 1 ELSE 0 END) AS delivered,
        SUM(CASE WHEN wi.status = 'needs_estimate' THEN 1 ELSE 0 END) AS needs_estimate,
        SUM(CASE WHEN wi.status = 'needs_benefit' THEN 1 ELSE 0 END) AS needs_benefit,
        SUM(CASE WHEN wi.status = 'draft' THEN 1 ELSE 0 END) AS draft,
        SUM(CASE WHEN wi.status = 'blocked' THEN 1 ELSE 0 END) AS blocked,
        MAX(CASE WHEN wi.status = 'needs_estimate' THEN DATEDIFF(day, wi.updated_at, ?) END) AS oldest_estimate,
        MAX(CASE WHEN wi.status = 'needs_benefit' THEN DATEDIFF(day, wi.updated_at, ?) END) AS oldest_benefit
        FROM dbo.work_items wi
        LEFT JOIN (SELECT DISTINCT work_item_id FROM dbo.assignments WHERE plan_version_id = $pv) sch ON sch.work_item_id = wi.id
        WHERE wi.workspace_id = ?", [today(), today(), $wsId]);
    // Skills gap: open items with a required skill nobody active meets.
    $gap = row($conn, "SELECT COUNT(*) AS n, MAX(DATEDIFF(day, wi.updated_at, ?)) AS oldest FROM dbo.work_items wi WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')
        AND EXISTS (SELECT 1 FROM dbo.skill_requirements sr WHERE sr.work_item_id = wi.id AND NOT EXISTS (
            SELECT 1 FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id WHERE ps.skill_id = sr.skill_id AND ps.proficiency >= sr.min_proficiency AND p.active = 1 AND p.workspace_id = wi.workspace_id))", [today(), $wsId]);
    $counts = []; foreach (['all','unscheduled','scheduled','in_progress','delivered','needs_estimate','needs_benefit','draft','blocked'] as $k) $counts[$k] = (int)($c[$k] ?? 0);
    $counts['skills_gap'] = (int)$gap['n'];
    ok(['items' => $items, 'total' => $total, 'counts' => $counts, 'queue_health' => [
        'needs_estimate' => ['count' => $counts['needs_estimate'], 'oldest_days' => (int)($c['oldest_estimate'] ?? 0)],
        'needs_benefit' => ['count' => $counts['needs_benefit'], 'oldest_days' => (int)($c['oldest_benefit'] ?? 0)],
        'skills_gap' => ['count' => $counts['skills_gap'], 'oldest_days' => (int)($gap['oldest'] ?? 0)],
    ], 'committed_plan_version_id' => $pv >= 0 ? $pv : null]);
}

// ---------------------------------------------------------------------------------------------
if ($action === 'get') {
    $wi = load_item($conn, $wsId);
    ok(['item' => item_detail($conn, $wsId, $wi)]);
}

if ($action === 'create') {
    require_role('requester');
    $title = trim((string)require_param('title'));
    $typeId = (int)require_param('work_type_id');
    $type = row($conn, "SELECT * FROM dbo.work_types WHERE id = ? AND workspace_id = ? AND retired = 0", [$typeId, $wsId]);
    if (!$type) fail('Unknown work type', 404);
    // Size
    $stamp = param('size_stamp') ?: $type['default_size_stamp'];
    $custom = param('custom_effort_days');
    $sizeClassId = null;
    if ($stamp && strtoupper($stamp) !== 'C') {
        if ($type['allowed_sizes'] && !in_array(strtoupper($stamp), array_map('trim', explode(',', strtoupper($type['allowed_sizes']))), true)) fail("Size $stamp is not allowed for {$type['name']} (allowed: {$type['allowed_sizes']})", 400);
        $band = size_band_for_stamp($conn, $wsId, $typeId, $stamp);
        if (!$band) fail("Unknown size stamp $stamp", 400);
        $sizeClassId = (int)$band['id'];
    } elseif ($stamp && strtoupper($stamp) === 'C') {
        if ($custom === null || $custom === '') fail('custom_effort_days is required for a Custom size', 422);
        $band = size_band_for_stamp($conn, $wsId, $typeId, 'C');
        $sizeClassId = $band ? (int)$band['id'] : null;
    }
    $ref = allocate_ref($conn, $wsId, $type['prefix']);
    $isInterrupt = $type['policy'] === 'interrupt';
    $tags = param('tags'); if (is_array($tags)) $tags = implode(',', array_map('trim', $tags));
    $data = [
        'workspace_id' => $wsId, 'ref' => $ref, 'work_type_id' => $typeId, 'size_class_id' => $sizeClassId,
        'custom_effort_days' => ($custom !== null && $custom !== '') ? (float)$custom : null,
        'title' => $title, 'summary' => param('summary'), 'requirements_text' => param('requirements_text') ?: $type['requirements_template'],
        'tags' => $tags ?: null, 'status' => 'draft', 'requested_by' => param('requested_by') ?: $userName, 'sponsor' => param('sponsor'),
        'needed_by' => param('needed_by') ?: null, 'earliest_start' => param('earliest_start') ?: null,
        'owner_person_id' => idp('owner_person_id'), 'external_url' => param('external_url'),
        'severity' => $isInterrupt ? (param('severity') ?: 'P3') : param('severity'),
        'risk_weight' => param('risk_weight') !== null ? (float)param('risk_weight') : null,
        'created_by' => $userId,
    ];
    $id = insert($conn, 'work_items', $data);
    foreach ((array)param('skills', []) as $s) if (!empty($s['skill_id']))
        insert($conn, 'skill_requirements', ['work_item_id' => $id, 'skill_id' => (int)$s['skill_id'], 'min_proficiency' => (int)($s['min_proficiency'] ?? 2), 'effort_days' => $s['effort_days'] ?? null, 'note' => $s['note'] ?? null]);
    $ben = param('benefit');
    if (is_array($ben) && !$isInterrupt && (float)($ben['annual_value'] ?? 0) > 0) {
        insert($conn, 'benefits', ['workspace_id' => $wsId, 'work_item_id' => $id, 'type' => $ben['type'] ?? 'other', 'annual_value' => (float)$ben['annual_value'],
            'confidence' => $ben['confidence'] ?? 'medium', 'realisation_from' => $ben['realisation_from'] ?? null, 'owner_name' => $ben['owner_name'] ?? null,
            'owner_person_id' => $ben['owner_person_id'] ?? null, 'narrative' => $ben['narrative'] ?? null, 'status' => 'planned']);
    }
    $status = policy_status_after_intake($conn, $type, $id);
    update($conn, 'work_items', ['status' => $status, 'ready_at' => $status === 'ready' ? date('Y-m-d H:i:s') : null], 'id = ?', [$id]);
    compute_priority_for_item($conn, $wsId, $id);
    audit($conn, $wsId, 'create', 'work_item', $id, null, array_merge($data, ['status' => $status]), $ref);
    add_trigger($conn, $wsId, 'intake', $isInterrupt ? 'urgent' : 'batched', "$ref added" . ($isInterrupt ? " ({$data['severity']} {$type['name']})" : ''), 'work_item', $id);
    ok(['item' => item_detail($conn, $wsId, row($conn, "SELECT * FROM dbo.work_items WHERE id = ?", [$id]))]);
}

if ($action === 'update') {
    $wi = load_item($conn, $wsId);
    if (!has_role('team_lead')) {
        require_role('requester');
        if (!($wi['status'] === 'draft' && $wi['created_by'] !== null && (int)$wi['created_by'] === $userId)) fail('Forbidden: only a team lead can edit this item', 403);
    }
    $editable = ['title','summary','requirements_text','tags','requested_by','sponsor','needed_by','earliest_start','owner_person_id','external_url','external_ref','severity','risk_weight','custom_effort_days','work_type_id','size_stamp','health','protected_until'];
    $changes = []; $before = []; $after = [];
    foreach ($editable as $f) {
        if (!array_key_exists($f, body())) continue;
        $v = param($f);
        if ($f === 'tags' && is_array($v)) $v = implode(',', array_map('trim', $v));
        if ($f === 'size_stamp') {
            $typeId = (int)(param('work_type_id') ?: $wi['work_type_id']);
            $newId = null;
            if ($v && strtoupper($v) !== 'C') { $band = size_band_for_stamp($conn, $wsId, $typeId, $v); if (!$band) fail("Unknown size stamp $v", 400); $newId = (int)$band['id']; }
            elseif ($v) { $band = size_band_for_stamp($conn, $wsId, $typeId, 'C'); $newId = $band ? (int)$band['id'] : null; }
            if ($newId !== ($wi['size_class_id'] !== null ? (int)$wi['size_class_id'] : null)) { $changes['size_class_id'] = $newId; $before['size_class_id'] = $wi['size_class_id']; $after['size_class_id'] = $newId; }
            continue;
        }
        if ($f === 'work_type_id' && !row($conn, "SELECT id FROM dbo.work_types WHERE id = ? AND workspace_id = ?", [(int)$v, $wsId])) fail('Unknown work type', 404);
        if (in_array($f, ['needed_by','earliest_start','protected_until'], true) && $v === '') $v = null;
        if (in_array($f, ['risk_weight','custom_effort_days'], true) && $v !== null) $v = (float)$v;
        if (in_array($f, ['owner_person_id','work_type_id'], true) && $v !== null) $v = (int)$v;
        $old = $wi[$f]; if (is_string($old) && in_array($f, ['needed_by','earliest_start','protected_until'], true)) $old = substr($old, 0, 10);
        if ((string)$old === (string)$v) continue;
        $changes[$f] = $v; $before[$f] = $old; $after[$f] = $v;
    }
    if (!$changes) ok(['item' => item_detail($conn, $wsId, $wi), 'changed' => []]);
    $changes['updated_at'] = date('Y-m-d H:i:s');
    update($conn, 'work_items', $changes, 'id = ?', [$wi['id']]);
    foreach ($after as $f => $v) audit($conn, $wsId, 'update', 'work_item', $wi['id'], ['field' => $f, 'value' => $before[$f]], ['field' => $f, 'value' => $v], $wi['ref'], param('reason'));
    if (array_intersect(array_keys($after), ['needed_by','risk_weight','severity','custom_effort_days','size_class_id','work_type_id'])) compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['item' => item_detail($conn, $wsId, row($conn, "SELECT * FROM dbo.work_items WHERE id = ?", [$wi['id']])), 'changed' => array_keys($after)]);
}

if ($action === 'set_status') {
    $wi = load_item($conn, $wsId);
    $to = require_param('status');
    $valid = ['draft','needs_estimate','needs_benefit','ready','scheduled','in_progress','blocked','delivered','cancelled'];
    if (!in_array($to, $valid, true)) fail("Unknown status $to", 400);
    if (in_array($to, ['in_progress','delivered'], true)) require_role('team_member'); else require_role('team_lead');
    $from = $wi['status'];
    if ($from === $to) ok(['item' => item_detail($conn, $wsId, $wi)]);
    $type = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$wi['work_type_id']]);
    $readiness = readiness_for($conn, $wsId, $wi, $type);
    $allowed = [
        'draft' => ['needs_estimate','needs_benefit','ready','blocked','cancelled'],
        'needs_estimate' => ['needs_benefit','ready','draft','blocked','cancelled'],
        'needs_benefit' => ['needs_estimate','ready','draft','blocked','cancelled'],
        'ready' => ['scheduled','in_progress','needs_estimate','needs_benefit','draft','blocked','cancelled'],
        'scheduled' => ['ready','in_progress','blocked','cancelled'],
        'in_progress' => ['delivered','scheduled','blocked','cancelled'],
        'blocked' => ['ready','scheduled','in_progress','needs_estimate','needs_benefit','draft','cancelled'],
        'delivered' => [], 'cancelled' => ['draft'],
    ];
    if (!in_array($to, $allowed[$from] ?? [], true)) fail("Cannot move {$wi['ref']} from " . status_label($from) . ' to ' . status_label($to), 409);
    $set = ['status' => $to, 'updated_at' => date('Y-m-d H:i:s')];
    if (in_array($to, ['ready','scheduled','in_progress'], true) && !$readiness['ready'] && in_array($from, ['draft','needs_estimate','needs_benefit','blocked'], true)) {
        $missing = array_map(fn($i) => strtolower($i['label']), array_filter($readiness['items'], fn($i) => !$i['done']));
        fail(status_label($to) . ' needs the readiness checklist complete. Missing: ' . implode(', ', $missing) . '.', 409, ['readiness' => $readiness]);
    }
    if ($to === 'needs_benefit' && $type['requires_estimate'] && !scalar($conn, "SELECT COUNT(*) FROM dbo.estimates WHERE work_item_id = ?", [$wi['id']])) fail("{$type['name']} items need an estimate before the benefit case.", 409);
    if ($to === 'ready' && !$wi['ready_at']) $set['ready_at'] = date('Y-m-d H:i:s');
    if ($to === 'in_progress' && !$wi['started_at']) $set['started_at'] = today();
    if ($to === 'delivered') {
        $actual = param('actual_effort_days', $wi['actual_effort_days']);
        if ($actual === null || $actual === '') fail('Delivered needs the actual effort in days (actual_effort_days).', 409);
        $set['actual_effort_days'] = (float)$actual; $set['delivered_at'] = param('delivered_at') ?: today(); $set['progress_pct'] = 100;
        q($conn, "UPDATE dbo.dependencies SET cleared_at = ? WHERE from_work_item_id = ? AND cleared_at IS NULL", [today(), $wi['id']]);
        q($conn, "UPDATE dbo.benefits SET status = 'in_flight' WHERE work_item_id = ? AND status = 'planned'", [$wi['id']]);
        add_trigger($conn, $wsId, 'delivered', 'batched', "{$wi['ref']} delivered", 'work_item', $wi['id']);
    }
    if ($to === 'cancelled') add_trigger($conn, $wsId, 'manual', 'batched', "{$wi['ref']} cancelled", 'work_item', $wi['id']);
    update($conn, 'work_items', $set, 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'status', 'work_item', $wi['id'], ['field' => 'status', 'value' => $from], ['field' => 'status', 'value' => $to], $wi['ref'], param('reason'));
    compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['item' => item_detail($conn, $wsId, row($conn, "SELECT * FROM dbo.work_items WHERE id = ?", [$wi['id']]))]);
}

if ($action === 'history') {
    $wi = load_item($conn, $wsId);
    $ev = rows($conn, "SELECT id, occurred_at, actor_name, action, entity, entity_id, before_json, after_json, reason FROM dbo.audit_events
        WHERE workspace_id = ? AND ((entity = 'work_item' AND entity_id = ?) OR (entity IN ('estimate','benefit','dependency','skill_requirement','task','comment','progress','priority_override','benefit_realisation','assignment') AND entity_label = ?)
            OR (entity = 'assignment' AND JSON_VALUE(after_json, '$.work_item_id') = ?))
        ORDER BY occurred_at DESC, id DESC", [$wsId, $wi['id'], $wi['ref'], (string)$wi['id']]);
    $out = [];
    foreach ($ev as $e) {
        $b = json_col($e['before_json'], null); $a = json_col($e['after_json'], null);
        $field = is_array($a) && isset($a['field']) ? $a['field'] : (is_array($b) && isset($b['field']) ? $b['field'] : null);
        $out[] = ['id' => (int)$e['id'], 'occurred_at' => substr($e['occurred_at'], 0, 19), 'actor_name' => $e['actor_name'], 'action' => $e['action'], 'entity' => $e['entity'], 'entity_id' => $e['entity_id'] !== null ? (int)$e['entity_id'] : null,
            'field' => $field, 'before' => $field ? ($b['value'] ?? null) : $b, 'after' => $field ? ($a['value'] ?? null) : $a, 'reason' => $e['reason']];
    }
    ok(['events' => $out]);
}

// ---- Tasks (PIP-06) -------------------------------------------------------------------------
if ($action === 'add_task' || $action === 'update_task') {
    require_role('team_member');
    if ($action === 'add_task') { $wi = load_item($conn, $wsId); $taskId = null; }
    else { $taskId = (int)require_param('task_id'); $t = row($conn, "SELECT t.*, wi.workspace_id FROM dbo.tasks t JOIN dbo.work_items wi ON wi.id = t.work_item_id WHERE t.id = ?", [$taskId]); if (!$t || (int)$t['workspace_id'] !== $wsId) fail('Task not found', 404); $wi = row($conn, "SELECT * FROM dbo.work_items WHERE id = ?", [$t['work_item_id']]); }
    $data = [];
    foreach (['title','effort_days','skill_id','sequence','status'] as $f) if (array_key_exists($f, body())) $data[$f] = param($f);
    if (array_key_exists('size_stamp', body())) { $band = param('size_stamp') ? size_band_for_stamp($conn, $wsId, $wi['work_type_id'], param('size_stamp')) : null; $data['size_class_id'] = $band ? (int)$band['id'] : null; if ($band && empty($data['effort_days']) && $band['planning_days'] !== null) $data['effort_days'] = (float)$band['planning_days']; }
    if ($taskId === null) {
        if (empty($data['title'])) fail('title is required', 422);
        $data['work_item_id'] = $wi['id']; $data['sequence'] = $data['sequence'] ?? ((int)scalar($conn, "SELECT ISNULL(MAX(sequence),0)+1 FROM dbo.tasks WHERE work_item_id = ?", [$wi['id']]));
        $taskId = insert($conn, 'tasks', $data);
        audit($conn, $wsId, 'create', 'task', $taskId, null, $data, $wi['ref']);
    } else {
        update($conn, 'tasks', $data, 'id = ?', [$taskId]);
        audit($conn, $wsId, 'update', 'task', $taskId, array_intersect_key($t, $data), $data, $wi['ref']);
    }
    ok(['task' => task_row($conn, $taskId), 'tasks' => tasks_for($conn, $wi['id'])]);
}
if ($action === 'delete_task') {
    require_role('team_member');
    $taskId = (int)require_param('task_id');
    $t = row($conn, "SELECT t.*, wi.workspace_id, wi.ref FROM dbo.tasks t JOIN dbo.work_items wi ON wi.id = t.work_item_id WHERE t.id = ?", [$taskId]);
    if (!$t || (int)$t['workspace_id'] !== $wsId) fail('Task not found', 404);
    q($conn, "DELETE FROM dbo.tasks WHERE id = ?", [$taskId]);
    audit($conn, $wsId, 'delete', 'task', $taskId, $t, null, $t['ref']);
    ok(['tasks' => tasks_for($conn, $t['work_item_id'])]);
}
if ($action === 'rollup_tasks') {
    require_role('team_lead');
    $wi = load_item($conn, $wsId);
    $tasks = tasks_for($conn, $wi['id']);
    $sum = 0; foreach ($tasks as $t) $sum += (float)($t['effort_days'] ?? 0);
    if ($sum <= 0) fail('Tasks have no effort to roll up', 409);
    $prev = latest_estimate($conn, $wi['id']);
    $class = (int)($prev['estimate_class'] ?? scalar($conn, "SELECT default_estimate_class FROM dbo.size_classes WHERE id = ?", [$wi['size_class_id']]) ?? 2);
    $tol = class_tolerance($class) / 100;
    $ver = (int)($prev['version'] ?? 0) + 1;
    $eid = insert($conn, 'estimates', ['work_item_id' => $wi['id'], 'version' => $ver, 'method' => 'rollup', 'optimistic' => round($sum * (1 - $tol), 2), 'likely' => round($sum, 2), 'pessimistic' => round($sum * (1 + $tol), 2),
        'estimate_class' => $class, 'day_rate' => $prev['day_rate'] ?? null, 'reason' => 'task roll-up from ' . count($tasks) . ' tasks', 'author_user_id' => $userId, 'author_name' => $userName]);
    update($conn, 'work_items', ['custom_effort_days' => round($sum, 2), 'updated_at' => date('Y-m-d H:i:s')], 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'create', 'estimate', $eid, null, ['version' => $ver, 'method' => 'rollup', 'likely' => $sum], $wi['ref']);
    if ($prev && $prev['likely'] !== null && $sum > (float)$prev['likely']) add_trigger($conn, $wsId, 'estimate', 'batched', "{$wi['ref']} re-estimated from " . rtrim(rtrim(number_format((float)$prev['likely'], 1), '0'), '.') . ' to ' . rtrim(rtrim(number_format($sum, 1), '0'), '.') . ' days', 'work_item', $wi['id']);
    progress_status_after_estimate($conn, $wsId, $wi);
    compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['estimate' => estimate_derive($conn, $wsId, row($conn, "SELECT * FROM dbo.estimates WHERE id = ?", [$eid]), $wi['work_type_id']), 'tasks_rollup_days' => round($sum, 2)]);
}

// ---- Dependencies (PIP-05) -------------------------------------------------------------------
if ($action === 'add_dependency') {
    require_role('team_lead');
    $from = (int)require_param('from_id'); $to = (int)require_param('to_id');
    $type = param('type', 'finish_start'); if (!in_array($type, ['finish_start','soft'], true)) fail('type must be finish_start or soft', 400);
    $a = row($conn, "SELECT id, ref FROM dbo.work_items WHERE id = ? AND workspace_id = ?", [$from, $wsId]);
    $b = row($conn, "SELECT id, ref FROM dbo.work_items WHERE id = ? AND workspace_id = ?", [$to, $wsId]);
    if (!$a || !$b) fail('Work item not found', 404);
    if (dependency_creates_cycle($conn, $wsId, $from, $to)) fail('This would create a dependency cycle', 409);
    if (row($conn, "SELECT id FROM dbo.dependencies WHERE from_work_item_id = ? AND to_work_item_id = ?", [$from, $to])) fail('That dependency already exists', 409);
    $id = insert($conn, 'dependencies', ['workspace_id' => $wsId, 'from_work_item_id' => $from, 'to_work_item_id' => $to, 'type' => $type]);
    audit($conn, $wsId, 'create', 'dependency', $id, null, ['from' => $a['ref'], 'to' => $b['ref'], 'type' => $type], $b['ref']);
    add_trigger($conn, $wsId, 'dependency', 'batched', "{$b['ref']} now depends on {$a['ref']}", 'work_item', $to);
    compute_priority_scores($conn, $wsId, [$from, $to]);
    ok(['dependency' => ['id' => $id, 'from_id' => $from, 'to_id' => $to, 'type' => $type], 'dependencies' => dependencies_for($conn, $wsId, $to)]);
}
if ($action === 'remove_dependency') {
    require_role('team_lead');
    $id = (int)require_param('id');
    $d = row($conn, "SELECT d.*, a.ref AS from_ref, b.ref AS to_ref FROM dbo.dependencies d JOIN dbo.work_items a ON a.id = d.from_work_item_id JOIN dbo.work_items b ON b.id = d.to_work_item_id WHERE d.id = ? AND d.workspace_id = ?", [$id, $wsId]);
    if (!$d) fail('Dependency not found', 404);
    q($conn, "DELETE FROM dbo.dependencies WHERE id = ?", [$id]);
    audit($conn, $wsId, 'delete', 'dependency', $id, ['from' => $d['from_ref'], 'to' => $d['to_ref']], null, $d['to_ref']);
    compute_priority_scores($conn, $wsId, [(int)$d['from_work_item_id'], (int)$d['to_work_item_id']]);
    ok(['dependencies' => dependencies_for($conn, $wsId, (int)$d['to_work_item_id'])]);
}

// ---- Skill requirements (REQ-01) -------------------------------------------------------------
if ($action === 'set_skill_requirement') {
    require_role('team_lead');
    $wi = load_item($conn, $wsId);
    $skillId = (int)require_param('skill_id'); $min = max(1, min(4, (int)param('min_proficiency', 2)));
    if (!row($conn, "SELECT id FROM dbo.skills WHERE id = ? AND workspace_id = ?", [$skillId, $wsId])) fail('Unknown skill', 404);
    $ex = row($conn, "SELECT * FROM dbo.skill_requirements WHERE work_item_id = ? AND skill_id = ?", [$wi['id'], $skillId]);
    $data = ['min_proficiency' => $min, 'effort_days' => param('effort_days') !== null ? (float)param('effort_days') : ($ex['effort_days'] ?? null), 'note' => param('note', $ex['note'] ?? null)];
    if ($ex) { update($conn, 'skill_requirements', $data, 'id = ?', [$ex['id']]); $rid = (int)$ex['id']; }
    else { $rid = insert($conn, 'skill_requirements', $data + ['work_item_id' => $wi['id'], 'skill_id' => $skillId]); }
    audit($conn, $wsId, $ex ? 'update' : 'create', 'skill_requirement', $rid, $ex ? ['min_proficiency' => (int)$ex['min_proficiency'], 'effort_days' => $ex['effort_days']] : null, $data + ['skill_id' => $skillId], $wi['ref']);
    touch_item($conn, $wi['id']);
    ok(['skills' => skills_detail($conn, $wsId, $wi)]);
}
if ($action === 'remove_skill_requirement') {
    require_role('team_lead');
    $wi = load_item($conn, $wsId);
    $skillId = (int)require_param('skill_id');
    $ex = row($conn, "SELECT * FROM dbo.skill_requirements WHERE work_item_id = ? AND skill_id = ?", [$wi['id'], $skillId]);
    if (!$ex) fail('Skill requirement not found', 404);
    q($conn, "DELETE FROM dbo.skill_requirements WHERE id = ?", [$ex['id']]);
    audit($conn, $wsId, 'delete', 'skill_requirement', (int)$ex['id'], $ex, null, $wi['ref']);
    touch_item($conn, $wi['id']);
    ok(['skills' => skills_detail($conn, $wsId, $wi)]);
}

// ---- Discussion (PIP-09) ---------------------------------------------------------------------
if ($action === 'add_comment') {
    require_role('requester');
    $wi = load_item($conn, $wsId);
    $body = trim((string)require_param('body'));
    $cid = insert($conn, 'item_comments', ['workspace_id' => $wsId, 'work_item_id' => $wi['id'], 'author_user_id' => $userId, 'author_name' => $userName, 'body' => $body]);
    audit($conn, $wsId, 'create', 'comment', $cid, null, ['body' => mb_substr($body, 0, 200)], $wi['ref']);
    // @mentions: match "@First" or "@First Last" against people names.
    if (preg_match_all('/@([A-Za-z][\w\'-]*(?:\s+[A-Z][\w\'-]*)?)/u', $body, $m)) {
        foreach (array_unique($m[1]) as $name) {
            $p = row($conn, "SELECT TOP 1 id, name FROM dbo.people WHERE workspace_id = ? AND active = 1 AND (name = ? OR name LIKE ?) ORDER BY LEN(name)", [$wsId, $name, $name . '%']);
            if ($p) notify_person($conn, $wsId, (int)$p['id'], 'mention', "$userName mentioned you on {$wi['ref']}", mb_substr($body, 0, 300), "/items/{$wi['ref']}");
        }
    }
    ok(['comment' => row($conn, "SELECT id, author_name, body, created_at FROM dbo.item_comments WHERE id = ?", [$cid]), 'comments' => comments_for($conn, $wi['id'])]);
}

// ---- Priority override (BEN-07) --------------------------------------------------------------
if ($action === 'override_priority') {
    require_role('delivery_lead');
    $wi = load_item($conn, $wsId);
    $reason = trim((string)require_param('reason'));
    $expires = require_param('expires');
    if ($expires < today()) fail('The override expiry must be in the future', 400);
    $points = param('points'); $pinned = param('pinned_score');
    if (($points === null || $points === '') && ($pinned === null || $pinned === '')) fail('Give points (±20) or a pinned_score', 422);
    $set = ['priority_override_points' => ($points !== null && $points !== '') ? max(-20, min(20, (int)$points)) : null,
            'priority_pinned_score' => ($pinned !== null && $pinned !== '') ? max(0, min(100, (float)$pinned)) : null,
            'priority_override_reason' => $reason, 'priority_override_expires' => $expires, 'priority_override_by' => $userId, 'updated_at' => date('Y-m-d H:i:s')];
    update($conn, 'work_items', $set, 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'override', 'priority_override', $wi['id'], ['field' => 'priority_override', 'value' => ['points' => $wi['priority_override_points'], 'pinned' => $wi['priority_pinned_score']]], ['field' => 'priority_override', 'value' => ['points' => $set['priority_override_points'], 'pinned' => $set['priority_pinned_score'], 'expires' => $expires]], $wi['ref'], $reason);
    $terms = compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['priority_score' => $terms['scaled'] ?? null, 'priority_terms' => $terms]);
}
if ($action === 'clear_override') {
    require_role('delivery_lead');
    $wi = load_item($conn, $wsId);
    update($conn, 'work_items', ['priority_override_points' => null, 'priority_pinned_score' => null, 'priority_override_reason' => null, 'priority_override_expires' => null, 'priority_override_by' => null, 'updated_at' => date('Y-m-d H:i:s')], 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'override', 'priority_override', $wi['id'], ['field' => 'priority_override', 'value' => ['points' => $wi['priority_override_points'], 'pinned' => $wi['priority_pinned_score']]], ['field' => 'priority_override', 'value' => null], $wi['ref'], param('reason'));
    $terms = compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['priority_score' => $terms['scaled'] ?? null, 'priority_terms' => $terms]);
}

// ---- Progress --------------------------------------------------------------------------------
if ($action === 'log_progress') {
    require_role('team_member');
    $wi = load_item($conn, $wsId);
    $pct = max(0, min(100, (int)require_param('progress_pct')));
    $lid = insert($conn, 'progress_logs', ['work_item_id' => $wi['id'], 'person_id' => $personId, 'progress_pct' => $pct, 'effort_days' => param('effort_days') !== null ? (float)param('effort_days') : null, 'note' => param('note')]);
    $set = ['progress_pct' => $pct, 'updated_at' => date('Y-m-d H:i:s')];
    if ($pct > 0 && in_array($wi['status'], ['ready','scheduled'], true)) { $set['status'] = 'in_progress'; $set['started_at'] = $wi['started_at'] ?: today(); }
    update($conn, 'work_items', $set, 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'progress', 'progress', $lid, ['field' => 'progress_pct', 'value' => (int)$wi['progress_pct']], ['field' => 'progress_pct', 'value' => $pct], $wi['ref'], param('note'));
    compute_priority_for_item($conn, $wsId, $wi['id']);
    ok(['item' => item_detail($conn, $wsId, row($conn, "SELECT * FROM dbo.work_items WHERE id = ?", [$wi['id']]))]);
}

// ---- Similar delivered work (EST-08) ----------------------------------------------------------
if ($action === 'similar') {
    $wi = load_item($conn, $wsId);
    ok(['items' => similar_items($conn, $wsId, $wi)]);
}

// ---- Bulk (PIP-10) ---------------------------------------------------------------------------
if ($action === 'bulk') {
    require_role('team_lead');
    $ids = array_values(array_filter(array_map('intval', (array)require_param('ids'))));
    if (!$ids) fail('ids is required', 422);
    $op = require_param('op'); $value = param('value');
    $in = implode(',', $ids);
    $items = rows($conn, "SELECT * FROM dbo.work_items WHERE workspace_id = ? AND id IN ($in)", [$wsId]);
    if (count($items) !== count($ids)) fail('One or more items were not found', 404);
    $done = 0;
    foreach ($items as $wi) {
        $set = [];
        switch ($op) {
            case 'retype':
                $t = row($conn, "SELECT id, prefix FROM dbo.work_types WHERE id = ? AND workspace_id = ?", [(int)$value, $wsId]); if (!$t) fail('Unknown work type', 404);
                if ((int)$wi['work_type_id'] === (int)$t['id']) continue 2;
                $set['work_type_id'] = (int)$t['id'];
                audit($conn, $wsId, 'update', 'work_item', $wi['id'], ['field' => 'work_type_id', 'value' => (int)$wi['work_type_id']], ['field' => 'work_type_id', 'value' => (int)$t['id']], $wi['ref'], 'bulk retype');
                break;
            case 'resize':
                $band = size_band_for_stamp($conn, $wsId, $wi['work_type_id'], (string)$value); if (!$band) fail("Unknown size stamp $value", 400);
                $set['size_class_id'] = (int)$band['id'];
                audit($conn, $wsId, 'update', 'work_item', $wi['id'], ['field' => 'size_class_id', 'value' => $wi['size_class_id']], ['field' => 'size_class_id', 'value' => (int)$band['id']], $wi['ref'], 'bulk resize');
                break;
            case 'tag':
                $tags = array_values(array_filter(array_map('trim', explode(',', (string)$wi['tags']))));
                foreach ((array)$value as $tg) { $tg = trim((string)$tg); if ($tg !== '' && !in_array($tg, $tags, true)) $tags[] = $tg; }
                $set['tags'] = implode(',', $tags);
                audit($conn, $wsId, 'update', 'work_item', $wi['id'], ['field' => 'tags', 'value' => $wi['tags']], ['field' => 'tags', 'value' => $set['tags']], $wi['ref'], 'bulk tag');
                break;
            case 'cancel':
                if (in_array($wi['status'], ['delivered','cancelled'], true)) continue 2;
                $set['status'] = 'cancelled';
                audit($conn, $wsId, 'status', 'work_item', $wi['id'], ['field' => 'status', 'value' => $wi['status']], ['field' => 'status', 'value' => 'cancelled'], $wi['ref'], param('reason', 'bulk cancel'));
                break;
            case 'assign_owner':
                $pid = (int)$value; if (!row($conn, "SELECT id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$pid, $wsId])) fail('Unknown person', 404);
                $set['owner_person_id'] = $pid;
                audit($conn, $wsId, 'update', 'work_item', $wi['id'], ['field' => 'owner_person_id', 'value' => $wi['owner_person_id']], ['field' => 'owner_person_id', 'value' => $pid], $wi['ref'], 'bulk assign owner');
                break;
            default: fail("Unknown bulk op $op", 400);
        }
        $set['updated_at'] = date('Y-m-d H:i:s');
        update($conn, 'work_items', $set, 'id = ?', [$wi['id']]);
        $done++;
    }
    if (in_array($op, ['retype','resize','cancel'], true)) compute_priority_scores($conn, $wsId, $ids);
    ok(['updated' => $done]);
}

if ($action === 'recompute_priorities') {
    require_role('delivery_lead');
    $r = compute_priority_scores($conn, $wsId);
    audit($conn, $wsId, 'recompute', 'priority', null, null, ['updated' => $r['updated'], 'max_raw' => $r['max_raw'], 'p90' => $r['p90']], 'priority scores');
    ok(['updated' => $r['updated'], 'max_raw' => $r['max_raw'], 'p90' => $r['p90']]);
}

fail('Unknown action', 400);

// =============================================================================================
function load_item($conn, $wsId) {
    $id = idp('id'); $ref = param('ref');
    if ($id !== null) $wi = row($conn, "SELECT * FROM dbo.work_items WHERE id = ? AND workspace_id = ?", [(int)$id, $wsId]);
    elseif ($ref) $wi = row($conn, "SELECT * FROM dbo.work_items WHERE ref = ? AND workspace_id = ?", [strtoupper(trim($ref)), $wsId]);
    else fail('id or ref is required', 422);
    if (!$wi) fail('Work item not found', 404);
    return $wi;
}
function touch_item($conn, $id) { q($conn, "UPDATE dbo.work_items SET updated_at = SYSDATETIME() WHERE id = ?", [$id]); }
function status_label($s) { return ['draft' => 'Draft', 'needs_estimate' => 'Needs estimate', 'needs_benefit' => 'Needs benefit case', 'ready' => 'Ready', 'scheduled' => 'Scheduled', 'in_progress' => 'In progress', 'blocked' => 'Blocked', 'delivered' => 'Delivered', 'cancelled' => 'Cancelled'][$s] ?? $s; }

/** Next ref for a prefix (PIP-02): WI-1072 / INC-4472 / SR-0216. Atomic on ref_sequences. */
function allocate_ref($conn, $wsId, $prefix) {
    $stmt = q($conn, "UPDATE dbo.ref_sequences SET next_value = next_value + 1 OUTPUT DELETED.next_value WHERE workspace_id = ? AND prefix = ?", [$wsId, $prefix]);
    $n = null; if (sqlsrv_fetch($stmt)) $n = (int)sqlsrv_get_field($stmt, 0); sqlsrv_free_stmt($stmt);
    if ($n === null) {
        $max = (int)scalar($conn, "SELECT MAX(TRY_CAST(SUBSTRING(ref, LEN(?) + 2, 10) AS INT)) FROM dbo.work_items WHERE workspace_id = ? AND ref LIKE ?", [$prefix, $wsId, "$prefix-%"]);
        $n = $max ? $max + 1 : 1000;
        q($conn, "INSERT INTO dbo.ref_sequences (workspace_id, prefix, next_value) VALUES (?, ?, ?)", [$wsId, $prefix, $n + 1]);
    }
    return sprintf('%s-%04d', $prefix, $n);
}

function tasks_for($conn, $itemId) {
    return array_map(fn($t) => ['id' => (int)$t['id'], 'title' => $t['title'], 'size_stamp' => $t['size_stamp'], 'effort_days' => $t['effort_days'] !== null ? (float)$t['effort_days'] : null, 'skill_id' => $t['skill_id'] !== null ? (int)$t['skill_id'] : null, 'skill_name' => $t['skill_name'], 'sequence' => (int)$t['sequence'], 'status' => $t['status']],
        rows($conn, "SELECT t.*, sc.stamp AS size_stamp, s.name AS skill_name FROM dbo.tasks t LEFT JOIN dbo.size_classes sc ON sc.id = t.size_class_id LEFT JOIN dbo.skills s ON s.id = t.skill_id WHERE t.work_item_id = ? ORDER BY t.sequence, t.id", [$itemId]));
}
function task_row($conn, $taskId) { $t = row($conn, "SELECT work_item_id FROM dbo.tasks WHERE id = ?", [$taskId]); foreach (tasks_for($conn, $t['work_item_id']) as $x) if ($x['id'] === (int)$taskId) return $x; return null; }
function comments_for($conn, $itemId) {
    return array_map(fn($c) => ['id' => (int)$c['id'], 'author_name' => $c['author_name'], 'body' => $c['body'], 'created_at' => substr($c['created_at'], 0, 19)],
        rows($conn, "SELECT id, author_name, body, created_at FROM dbo.item_comments WHERE work_item_id = ? ORDER BY created_at, id", [$itemId]));
}
function dependencies_for($conn, $wsId, $itemId) {
    $shape = fn($r) => ['id' => (int)$r['id'], 'dependency_id' => (int)$r['dependency_id'], 'ref' => $r['ref'], 'title' => $r['title'], 'type' => $r['type'], 'dep_type' => $r['dep_type'], 'status' => $r['status'], 'health' => $r['health'], 'needed_by' => $r['needed_by'], 'planned_to' => $r['planned_to'], 'cleared_at' => $r['cleared_at']];
    $pv = committed_plan_id($conn, $wsId) ?? -1;
    $sel = "SELECT d.id AS dependency_id, d.type AS dep_type, d.cleared_at, wi.id, wi.ref, wi.title, wt.name AS type, wi.status, wi.health, wi.needed_by,
        (SELECT MAX(a.to_date) FROM dbo.assignments a WHERE a.work_item_id = wi.id AND a.plan_version_id = $pv) AS planned_to
        FROM dbo.dependencies d JOIN dbo.work_items wi ON wi.id = %s JOIN dbo.work_types wt ON wt.id = wi.work_type_id WHERE d.workspace_id = ? AND %s = ? ORDER BY wi.needed_by, wi.ref";
    return ['needs' => array_map($shape, rows($conn, sprintf($sel, 'd.from_work_item_id', 'd.to_work_item_id'), [$wsId, $itemId])),
            'unblocks' => array_map($shape, rows($conn, sprintf($sel, 'd.to_work_item_id', 'd.from_work_item_id'), [$wsId, $itemId]))];
}
function skills_detail($conn, $wsId, array $wi) {
    $out = [];
    foreach (rows($conn, "SELECT sr.*, s.name FROM dbo.skill_requirements sr JOIN dbo.skills s ON s.id = sr.skill_id WHERE sr.work_item_id = ? ORDER BY sr.min_proficiency DESC, s.name", [$wi['id']]) as $r) {
        $min = (int)$r['min_proficiency'];
        $q = qualified_people($conn, $wsId, (int)$r['skill_id'], $min);
        $out[] = ['skill_id' => (int)$r['skill_id'], 'name' => $r['name'], 'min_proficiency' => $min, 'effort_days' => $r['effort_days'] !== null ? (float)$r['effort_days'] : null, 'note' => $r['note'],
            'coverage_count' => count($q), 'coverage_label' => coverage_label($q, $min), 'single_point' => count($q) === 1, 'gap' => count($q) === 0,
            'qualified' => array_map(fn($p) => ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => $p['initials'], 'colour' => $p['colour'], 'proficiency' => (int)$p['proficiency']], $q)];
    }
    return $out;
}
function similar_items($conn, $wsId, array $wi) {
    $stampSql = $wi['size_class_id'] !== null ? "wi.size_class_id IN (SELECT id FROM dbo.size_classes WHERE stamp = (SELECT stamp FROM dbo.size_classes WHERE id = ?) AND workspace_id = ?)" : "wi.size_class_id IS NULL";
    $params = $wi['size_class_id'] !== null ? [$wi['size_class_id'], $wsId] : [];
    $sql = "SELECT TOP 10 wi.id, wi.ref, wi.title, sc.stamp AS size_stamp, e.id AS estimate_id, e.likely AS estimated_days, wi.actual_effort_days AS actual_days, wi.delivered_at,
          (SELECT COUNT(*) FROM dbo.skill_requirements a JOIN dbo.skill_requirements b ON b.skill_id = a.skill_id AND b.work_item_id = ? WHERE a.work_item_id = wi.id) AS overlap
        FROM dbo.work_items wi LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        OUTER APPLY (SELECT TOP 1 id, likely FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
        WHERE wi.workspace_id = ? AND wi.status = 'delivered' AND wi.id <> ? AND $stampSql
          AND EXISTS (SELECT 1 FROM dbo.skill_requirements a JOIN dbo.skill_requirements b ON b.skill_id = a.skill_id AND b.work_item_id = ? WHERE a.work_item_id = wi.id)
        ORDER BY overlap DESC, wi.delivered_at DESC";
    return array_map(fn($r) => ['id' => (int)$r['id'], 'ref' => $r['ref'], 'title' => $r['title'], 'size_stamp' => $r['size_stamp'], 'estimated_days' => $r['estimated_days'] !== null ? (float)$r['estimated_days'] : null,
            'actual_days' => $r['actual_days'] !== null ? (float)$r['actual_days'] : null, 'delivered_at' => $r['delivered_at'], 'estimate_id' => $r['estimate_id'] !== null ? (int)$r['estimate_id'] : null, 'skill_overlap' => (int)$r['overlap']],
        rows($conn, $sql, array_merge([$wi['id'], $wsId, $wi['id']], $params, [$wi['id']])));
}

/** Full `get` shape. */
function item_detail($conn, $wsId, array $wi) {
    [$rowsOut] = work_item_rows($conn, $wsId, 'wi.id = ?', [$wi['id']]);
    $item = $rowsOut[0];
    $type = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$wi['work_type_id']]);
    $policy = current_policy($conn, $wsId);
    $wd = workspace_working_days($conn, $wsId);
    $terms = json_col($wi['priority_terms'], null);
    $item += [
        'summary' => $wi['summary'], 'requirements_text' => $wi['requirements_text'], 'severity' => $wi['severity'],
        'risk_weight' => $wi['risk_weight'] !== null ? (float)$wi['risk_weight'] : null,
        'priority_terms' => $terms,
        'priority_override' => ['points' => $wi['priority_override_points'] !== null ? (int)$wi['priority_override_points'] : null, 'pinned_score' => $wi['priority_pinned_score'] !== null ? (float)$wi['priority_pinned_score'] : null,
            'reason' => $wi['priority_override_reason'], 'expires' => $wi['priority_override_expires'], 'by' => $wi['priority_override_by'] !== null ? (int)$wi['priority_override_by'] : null,
            'active' => ($wi['priority_override_points'] !== null || $wi['priority_pinned_score'] !== null) && (!$wi['priority_override_expires'] || $wi['priority_override_expires'] >= today())],
        'external_url' => $wi['external_url'], 'external_ref' => $wi['external_ref'], 'delivered_at' => $wi['delivered_at'], 'started_at' => $wi['started_at'],
        'actual_effort_days' => $wi['actual_effort_days'] !== null ? (float)$wi['actual_effort_days'] : null, 'ready_at' => $wi['ready_at'] ? substr($wi['ready_at'], 0, 19) : null,
        'requires_estimate' => (bool)$type['requires_estimate'], 'requires_benefit' => (bool)$type['requires_benefit'],
        'created_by' => $wi['created_by'] !== null ? (int)$wi['created_by'] : null,
    ];
    $item['skills'] = skills_detail($conn, $wsId, $wi);
    $item['dependencies'] = dependencies_for($conn, $wsId, $wi['id']);
    // Plan facts
    $pv = committed_plan_id($conn, $wsId);
    $assignments = $pv !== null ? rows($conn, "SELECT a.*, p.name AS person_name, p.initials, p.colour FROM dbo.assignments a JOIN dbo.people p ON p.id = a.person_id WHERE a.plan_version_id = ? AND a.work_item_id = ? ORDER BY a.from_date, p.name", [$pv, $wi['id']]) : [];
    $item['assignments'] = array_map(fn($a) => ['id' => (int)$a['id'], 'plan_version_id' => (int)$a['plan_version_id'], 'work_item_id' => (int)$a['work_item_id'], 'ref' => $wi['ref'], 'title' => $wi['title'], 'type_colour' => $type['colour'], 'type_name' => $type['name'], 'size_stamp' => $item['size_stamp'],
        'person_id' => (int)$a['person_id'], 'person_name' => $a['person_name'], 'initials' => $a['initials'], 'colour' => $a['colour'], 'from_date' => $a['from_date'], 'to_date' => $a['to_date'], 'allocation_pct' => (int)$a['allocation_pct'], 'state' => $a['state'], 'role_label' => $a['role_label'],
        'locked' => $a['locked_until'] !== null && $a['locked_until'] >= today(), 'fixed_person' => (bool)$a['fixed_person'], 'fixed_dates' => (bool)$a['fixed_dates'], 'is_reserve' => (bool)$a['is_reserve'], 'note' => $a['note']], $assignments);
    $slack = ($item['planned_to'] && $wi['needed_by']) ? ($wi['needed_by'] >= $item['planned_to'] ? working_days_between($item['planned_to'], $wi['needed_by'], $wd) - 1 : -working_days_between($wi['needed_by'], $item['planned_to'], $wd)) : null;
    $changes30 = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.person_change_log WHERE workspace_id = ? AND work_item_id = ? AND changed_at >= DATEADD(day, -30, ?)", [$wsId, $wi['id'], today()]);
    $item['plan'] = ['planned_from' => $item['planned_from'], 'planned_to' => $item['planned_to'], 'assignees' => $item['assignees'], 'changes_30d' => $changes30,
        'stability_label' => $changes30 >= 3 ? 'Moving' : 'Steady', 'enters_committed_on' => $item['planned_from'] ? week_start($item['planned_from']) : null,
        'slack_days' => $slack, 'slack_label' => slack_label($slack), 'needed_by' => $wi['needed_by'],
        'committed' => $item['planned_from'] !== null && $item['planned_from'] <= add_working_days(today(), (int)($policy['freeze_horizon_days'] ?? 10), $wd)];
    // Estimate
    $latest = latest_estimate($conn, $wi['id']);
    $item['estimate'] = $latest ? estimate_derive($conn, $wsId, $latest, $wi['work_type_id']) : null;
    $item['estimate_count'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.estimates WHERE work_item_id = ?", [$wi['id']]);
    // Benefits
    $bens = rows($conn, "SELECT b.*, p.name AS owner_person_name FROM dbo.benefits b LEFT JOIN dbo.people p ON p.id = b.owner_person_id WHERE b.work_item_id = ? ORDER BY b.annual_value DESC", [$wi['id']]);
    $total = 0; $confRank = ['high' => 3, 'medium' => 2, 'low' => 1]; $weighted = 0;
    foreach ($bens as &$b) { $b = benefit_shape($b); $total += $b['annual_value']; $weighted += $b['annual_value'] * ($confRank[$b['confidence']] ?? 2); }
    unset($b);
    $item['benefits'] = $bens; $item['benefit_total'] = (int)round($total);
    $avg = $total > 0 ? $weighted / $total : null;
    $item['benefit_confidence'] = $avg === null ? null : ($avg >= 2.5 ? 'high' : ($avg >= 1.5 ? 'medium' : 'low'));
    $item['benefit_realised_from'] = $bens ? min(array_filter(array_column($bens, 'realisation_from')) ?: [null]) : null;
    // Payback is the blended cost of the work (PERT expected days x day rate - the figure the item
    // page shows as "Blended cost") divided by one month of the annual benefit. cost_likely is the
    // cost at the most-likely estimate and is a narrower figure; it is not what payback is quoted on.
    $est = $item['estimate'];
    $blendedCost = ($est && $est['expected'] !== null && $est['day_rate'] !== null) ? (float)$est['expected'] * (float)$est['day_rate'] : null;
    $item['blended_cost'] = $blendedCost === null ? null : (int)round($blendedCost);
    $item['payback_months'] = ($blendedCost && $total > 0) ? round($blendedCost / ($total / 12), 1) : null;
    // Tasks, comments, readiness, history count
    $item['tasks'] = tasks_for($conn, $wi['id']);
    $item['tasks_rollup_days'] = round(array_sum(array_map(fn($t) => (float)($t['effort_days'] ?? 0), $item['tasks'])), 2);
    $item['comments'] = comments_for($conn, $wi['id']);
    $item['readiness'] = readiness_for($conn, $wsId, $wi, $type);
    $item['history_count'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND ((entity = 'work_item' AND entity_id = ?) OR entity_label = ?)", [$wsId, $wi['id'], $wi['ref']]);
    return $item;
}
