<?php
// Estimates (EST-*): versioned ROM estimates with PERT maths, class tolerance, cost, calibration, similar work.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/items_lib.php';
require_once __DIR__ . '/engine/priority.php';
$action = param('action', 'list');

if ($action === 'list') {
    [$items] = work_item_rows($conn, $wsId, "wi.status NOT IN ('delivered','cancelled') AND wt.policy = 'planned'", [],
        "CASE WHEN wi.status = 'needs_estimate' THEN 0 ELSE 1 END, COALESCE(e.created_at, wi.updated_at) DESC, wi.priority_score DESC");
    $ids = array_map(fn($i) => $i['id'], $items);
    $latest = [];
    if ($ids) foreach (rows($conn, "SELECT e.* FROM dbo.estimates e WHERE e.work_item_id IN (" . implode(',', $ids) . ") AND e.version = (SELECT MAX(version) FROM dbo.estimates x WHERE x.work_item_id = e.work_item_id)") as $e) $latest[(int)$e['work_item_id']] = $e;
    $rate = blended_day_rate($conn, $wsId);
    foreach ($items as &$it) {
        $e = $latest[$it['id']] ?? null;
        $d = $e ? estimate_derive($conn, $wsId, $e, $it['work_type_id'], $rate) : null;
        $it += ['estimate_class' => $d ? $d['estimate_class'] : null, 'class_label' => $d ? $d['class_label'] : null, 'likely' => $d ? $d['likely'] : null, 'optimistic' => $d ? $d['optimistic'] : null, 'pessimistic' => $d ? $d['pessimistic'] : null,
            'expected' => $d ? $d['expected'] : null, 'p80' => $d ? $d['p80'] : null, 'method' => $d ? $d['method'] : null, 'version' => $d ? (int)$d['version'] : 0,
            'estimate_updated_at' => $d ? $d['created_at'] : null, 'author_name' => $d ? $d['author_name'] : null, 'cost_likely' => $d ? $d['cost_likely'] : null, 'implied_stamp' => $d ? $d['implied_stamp'] : null,
            'waiting_days' => $it['status'] === 'needs_estimate' ? (int)floor((strtotime(today()) - strtotime(substr($it['updated_at'], 0, 10))) / 86400) : null];
    }
    unset($it);
    ok(['items' => $items, 'needing_estimate' => count(array_filter($items, fn($i) => $i['status'] === 'needs_estimate')), 'calibration' => calibration($conn, $wsId), 'day_rate' => $rate, 'classes' => class_list()]);
}

if ($action === 'get') {
    $wi = load_item_e($conn, $wsId);
    [$rowsOut] = work_item_rows($conn, $wsId, 'wi.id = ?', [$wi['id']]);
    $rate = blended_day_rate($conn, $wsId);
    $versions = array_map(fn($e) => estimate_derive($conn, $wsId, $e, $wi['work_type_id'], $rate), rows($conn, "SELECT * FROM dbo.estimates WHERE work_item_id = ? ORDER BY version DESC", [$wi['id']]));
    $tasks = rows($conn, "SELECT t.*, sc.stamp AS size_stamp, s.name AS skill_name FROM dbo.tasks t LEFT JOIN dbo.size_classes sc ON sc.id = t.size_class_id LEFT JOIN dbo.skills s ON s.id = t.skill_id WHERE t.work_item_id = ? ORDER BY t.sequence, t.id", [$wi['id']]);
    $bands = array_map(fn($b) => ['id' => (int)$b['id'], 'stamp' => $b['stamp'], 'name' => $b['name'], 'min_days' => $b['min_days'] !== null ? (float)$b['min_days'] : null, 'max_days' => $b['max_days'] !== null ? (float)$b['max_days'] : null,
        'planning_days' => $b['planning_days'] !== null ? (float)$b['planning_days'] : null, 'default_estimate_class' => (int)$b['default_estimate_class'], 'is_custom' => (bool)$b['is_custom']], size_bands($conn, $wsId, $wi['work_type_id']));
    ok(['item' => $rowsOut[0], 'latest' => $versions[0] ?? null, 'versions' => $versions, 'calibration' => calibration($conn, $wsId),
        'similar' => similar_for($conn, $wsId, $wi), 'day_rate' => $rate, 'classes' => class_list(), 'size_bands' => $bands,
        'skills' => rows($conn, "SELECT sr.skill_id, s.name, sr.min_proficiency, sr.effort_days FROM dbo.skill_requirements sr JOIN dbo.skills s ON s.id = sr.skill_id WHERE sr.work_item_id = ? ORDER BY s.name", [$wi['id']]),
        'tasks' => array_map(fn($t) => ['id' => (int)$t['id'], 'title' => $t['title'], 'size_stamp' => $t['size_stamp'], 'effort_days' => $t['effort_days'] !== null ? (float)$t['effort_days'] : null, 'skill_name' => $t['skill_name'], 'sequence' => (int)$t['sequence'], 'status' => $t['status']], $tasks),
        'tasks_rollup_days' => round(array_sum(array_map(fn($t) => (float)($t['effort_days'] ?? 0), $tasks)), 2)]);
}

if ($action === 'save') {
    $wi = load_item_e($conn, $wsId);
    if (!has_role('team_lead') && !($personId !== null && $wi['owner_person_id'] !== null && (int)$wi['owner_person_id'] === (int)$personId)) fail('Forbidden: requires team_lead or the item owner', 403);
    $method = param('method', 'three_point');
    if (!in_array($method, ['size','three_point','rollup'], true)) fail('method must be size, three_point or rollup', 400);
    $prev = latest_estimate($conn, $wi['id']);
    $band = $wi['size_class_id'] !== null ? row($conn, "SELECT * FROM dbo.size_classes WHERE id = ?", [$wi['size_class_id']]) : null;
    $o = $m = $p = null; $reason = param('reason');
    if ($method === 'three_point') {
        $o = (float)require_param('optimistic'); $m = (float)require_param('likely'); $p = (float)require_param('pessimistic');
        if ($o <= 0 || $m <= 0 || $p <= 0) fail('Estimates must be positive', 400);
        if (!($o <= $m && $m <= $p)) fail('Optimistic ≤ most likely ≤ pessimistic is required', 400);
    } elseif ($method === 'size') {
        $stamp = param('size_stamp') ?: ($band['stamp'] ?? null);
        if (!$stamp) fail('size_stamp is required for a size-class estimate', 422);
        $sb = size_band_for_stamp($conn, $wsId, $wi['work_type_id'], $stamp);
        if (!$sb) fail("Unknown size stamp $stamp", 400);
        if ((int)$sb['is_custom']) { $m = (float)(param('likely') ?? $wi['custom_effort_days'] ?? 0); if ($m <= 0) fail('likely (custom effort) is required for a Custom size', 422); }
        else { $m = (float)($sb['planning_days'] ?? (($sb['min_days'] + ($sb['max_days'] ?? $sb['min_days'] * 2)) / 2)); $o = $sb['min_days'] !== null ? (float)$sb['min_days'] : null; $p = $sb['max_days'] !== null ? (float)$sb['max_days'] : null; }
        $band = $sb; $reason = $reason ?: "Size class {$sb['stamp']} planning value";
    } else {
        $m = (float)scalar($conn, "SELECT ISNULL(SUM(effort_days),0) FROM dbo.tasks WHERE work_item_id = ?", [$wi['id']]);
        if ($m <= 0) fail('Tasks have no effort to roll up', 409);
        $n = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.tasks WHERE work_item_id = ?", [$wi['id']]);
        $reason = $reason ?: "task roll-up from $n tasks";
    }
    $class = (int)(param('estimate_class') ?: ($prev['estimate_class'] ?? $band['default_estimate_class'] ?? 3));
    if ($class < 1 || $class > 5) fail('estimate_class must be 1..5', 400);
    $split = param('skill_split');
    $ver = (int)($prev['version'] ?? 0) + 1;
    $data = ['work_item_id' => $wi['id'], 'version' => $ver, 'method' => $method, 'optimistic' => $o, 'likely' => $m, 'pessimistic' => $p, 'estimate_class' => $class,
        'day_rate' => param('day_rate') !== null && param('day_rate') !== '' ? (float)param('day_rate') : null, 'assumptions' => param('assumptions'), 'reason' => $reason,
        'skill_split' => is_array($split) ? json_encode(array_values($split), JSON_UNESCAPED_UNICODE) : null, 'author_user_id' => $userId, 'author_name' => $userName];
    $eid = insert($conn, 'estimates', $data);
    // Skill split declares the skills the scheduler must match (EST-04): upsert effort on requirements.
    if (is_array($split)) foreach ($split as $s) if (!empty($s['skill_id'])) {
        $ex = row($conn, "SELECT id FROM dbo.skill_requirements WHERE work_item_id = ? AND skill_id = ?", [$wi['id'], (int)$s['skill_id']]);
        if ($ex) update($conn, 'skill_requirements', ['effort_days' => (float)($s['days'] ?? 0)], 'id = ?', [$ex['id']]);
        else insert($conn, 'skill_requirements', ['work_item_id' => $wi['id'], 'skill_id' => (int)$s['skill_id'], 'min_proficiency' => (int)($s['min_proficiency'] ?? 2), 'effort_days' => (float)($s['days'] ?? 0)]);
    }
    if ($method === 'rollup') update($conn, 'work_items', ['custom_effort_days' => round($m, 2)], 'id = ?', [$wi['id']]);
    q($conn, "UPDATE dbo.work_items SET updated_at = SYSDATETIME() WHERE id = ?", [$wi['id']]);
    audit($conn, $wsId, $prev ? 'update' : 'create', 'estimate', $eid, $prev ? ['field' => 'estimate', 'value' => ['version' => (int)$prev['version'], 'likely' => (float)$prev['likely'], 'optimistic' => $prev['optimistic'], 'pessimistic' => $prev['pessimistic'], 'class' => (int)$prev['estimate_class']]] : null,
        ['field' => 'estimate', 'value' => ['version' => $ver, 'method' => $method, 'likely' => $m, 'optimistic' => $o, 'pessimistic' => $p, 'class' => $class]], $wi['ref'], $reason);
    // STAB-09: upward re-estimate is a replan trigger.
    if ($prev && $prev['likely'] !== null && $m > (float)$prev['likely'])
        add_trigger($conn, $wsId, 'estimate', in_array($wi['status'], ['scheduled','in_progress'], true) ? 'batched' : 'batched', "{$wi['ref']} re-estimated from " . fmt_days((float)$prev['likely']) . ' to ' . fmt_days($m) . ' days', 'work_item', $wi['id']);
    $newStatus = progress_status_after_estimate($conn, $wsId, $wi);
    compute_priority_for_item($conn, $wsId, $wi['id']);
    $est = estimate_derive($conn, $wsId, row($conn, "SELECT * FROM dbo.estimates WHERE id = ?", [$eid]), $wi['work_type_id']);
    ok(['estimate' => $est, 'implied_stamp' => $est['implied_stamp'], 'status' => $newStatus ?: $wi['status'], 'version' => $ver]);
}

if ($action === 'calibration') ok(['calibration' => calibration($conn, $wsId)]);

fail('Unknown action', 400);

// =============================================================================================
function load_item_e($conn, $wsId) {
    $id = idp('work_item_id') ?? idp('id'); $ref = param('ref');
    if ($id !== null) $wi = row($conn, "SELECT * FROM dbo.work_items WHERE id = ? AND workspace_id = ?", [(int)$id, $wsId]);
    elseif ($ref) $wi = row($conn, "SELECT * FROM dbo.work_items WHERE ref = ? AND workspace_id = ?", [strtoupper(trim($ref)), $wsId]);
    else fail('work_item_id is required', 422);
    if (!$wi) fail('Work item not found', 404);
    return $wi;
}
function fmt_days($d) { return rtrim(rtrim(number_format($d, 1, '.', ''), '0'), '.'); }

/** EST-07: actual ÷ latest most-likely, median by size stamp, delivered in the last 12 months. */
function calibration($conn, $wsId) {
    $since = date('Y-m-d', strtotime(today() . ' -12 months'));
    $rows = rows($conn, "SELECT CASE WHEN sc.is_custom = 1 OR (wi.size_class_id IS NULL AND wi.custom_effort_days IS NOT NULL) THEN 'C' ELSE sc.stamp END AS stamp, sc.name, wi.actual_effort_days, e.likely
        FROM dbo.work_items wi LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        OUTER APPLY (SELECT TOP 1 likely FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
        WHERE wi.workspace_id = ? AND wi.status = 'delivered' AND wi.actual_effort_days IS NOT NULL AND e.likely > 0 AND wi.delivered_at >= ?", [$wsId, $since]);
    $groups = []; $names = [];
    foreach ($rows as $r) { $st = $r['stamp'] ?: '?'; $groups[$st][] = (float)$r['actual_effort_days'] / (float)$r['likely']; $names[$st] = $st === 'C' ? 'Custom' : $r['name']; }
    $order = ['S' => 0, 'M' => 1, 'L' => 2, 'C' => 3];
    $by = [];
    foreach ($groups as $st => $ratios) { sort($ratios); $n = count($ratios); $med = $n % 2 ? $ratios[intdiv($n, 2)] : ($ratios[$n / 2 - 1] + $ratios[$n / 2]) / 2; $by[] = ['stamp' => $st, 'name' => $names[$st], 'n' => $n, 'median_ratio' => round($med, 2)]; }
    usort($by, fn($a, $b) => ($order[$a['stamp']] ?? 9) <=> ($order[$b['stamp']] ?? 9));
    $large = null; foreach ($by as $b) if ($b['stamp'] === 'L') $large = $b;
    $largeOver = $large ? (int)round(($large['median_ratio'] - 1) * 100) : null;
    $planAt = 'most_likely';
    if ($large && $largeOver >= 5) { $rec = "Large projects have finished {$largeOver}% over their most-likely estimate in the last 12 months ({$large['n']} items). Planning at P80 covers this."; $planAt = 'p80'; }
    elseif ($large && $largeOver <= -5) $rec = "Large projects have finished " . abs($largeOver) . "% under their most-likely estimate in the last 12 months ({$large['n']} items). Planning at most-likely is safe.";
    elseif ($by) $rec = 'Estimates have landed close to most-likely in the last 12 months (' . array_sum(array_column($by, 'n')) . ' items). Planning at most-likely is reasonable.';
    else $rec = 'Not enough delivered work in the last 12 months to calibrate yet.';
    return ['by_stamp' => $by, 'large_over_pct' => $largeOver, 'recommendation' => $rec, 'recommended_plan_at' => $planAt, 'items' => count($rows), 'since' => $since];
}

/** EST-08 similar delivered work: same stamp, overlapping skills, ordered by overlap. */
function similar_for($conn, $wsId, array $wi) {
    $stampSql = $wi['size_class_id'] !== null ? "wi.size_class_id IN (SELECT id FROM dbo.size_classes WHERE stamp = (SELECT stamp FROM dbo.size_classes WHERE id = ?) AND workspace_id = ?)" : "wi.size_class_id IS NULL";
    $params = $wi['size_class_id'] !== null ? [$wi['size_class_id'], $wsId] : [];
    return array_map(fn($r) => ['id' => (int)$r['id'], 'ref' => $r['ref'], 'title' => $r['title'], 'size_stamp' => $r['size_stamp'], 'estimated_days' => $r['estimated_days'] !== null ? (float)$r['estimated_days'] : null,
            'actual_days' => $r['actual_days'] !== null ? (float)$r['actual_days'] : null, 'delivered_at' => $r['delivered_at'], 'estimate_id' => $r['estimate_id'] !== null ? (int)$r['estimate_id'] : null, 'skill_overlap' => (int)$r['overlap'],
            'optimistic' => $r['optimistic'] !== null ? (float)$r['optimistic'] : null, 'pessimistic' => $r['pessimistic'] !== null ? (float)$r['pessimistic'] : null],
        rows($conn, "SELECT TOP 10 wi.id, wi.ref, wi.title, sc.stamp AS size_stamp, e.id AS estimate_id, e.likely AS estimated_days, e.optimistic, e.pessimistic, wi.actual_effort_days AS actual_days, wi.delivered_at,
              (SELECT COUNT(*) FROM dbo.skill_requirements a JOIN dbo.skill_requirements b ON b.skill_id = a.skill_id AND b.work_item_id = ? WHERE a.work_item_id = wi.id) AS overlap
            FROM dbo.work_items wi LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
            OUTER APPLY (SELECT TOP 1 id, likely, optimistic, pessimistic FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
            WHERE wi.workspace_id = ? AND wi.status = 'delivered' AND wi.id <> ? AND $stampSql
              AND EXISTS (SELECT 1 FROM dbo.skill_requirements a JOIN dbo.skill_requirements b ON b.skill_id = a.skill_id AND b.work_item_id = ? WHERE a.work_item_id = wi.id)
            ORDER BY overlap DESC, wi.delivered_at DESC", array_merge([$wi['id'], $wsId, $wi['id']], $params, [$wi['id']])));
}
