<?php
// Workspace vocabulary and policy (CFG-01..10). Named workspace_config.php because api/config.php is the secrets file.
// Actions: get | save_work_type | reorder_work_types | retire_work_type | save_size_class | delete_size_class |
//          save_policy | export | import | save_workspace | save_day_rate
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'get');

const OPEN_STATUSES_SQL = "('draft','needs_estimate','needs_benefit','ready','scheduled','in_progress','blocked')";

function wt_shape(array $t) {
    $t['id'] = (int)$t['id']; $t['workspace_id'] = (int)$t['workspace_id'];
    foreach (['requires_estimate','requires_benefit','retired'] as $b) $t[$b] = (bool)$t[$b];
    $t['sort_order'] = (int)$t['sort_order'];
    $t['default_size_stamp'] = $t['default_size_stamp'] !== null ? trim($t['default_size_stamp']) : null;
    $t['allowed_sizes'] = $t['allowed_sizes'] !== null && $t['allowed_sizes'] !== '' ? array_values(array_filter(array_map('trim', explode(',', $t['allowed_sizes'])))) : null;
    return $t;
}
function sc_shape(array $s) {
    $s['id'] = (int)$s['id']; $s['workspace_id'] = (int)$s['workspace_id'];
    $s['work_type_id'] = $s['work_type_id'] !== null ? (int)$s['work_type_id'] : null;
    $s['stamp'] = trim($s['stamp']);
    foreach (['min_days','max_days','planning_days'] as $f) $s[$f] = $s[$f] !== null ? (float)$s[$f] : null;
    $s['default_estimate_class'] = (int)$s['default_estimate_class'];
    $s['counts_for_wip'] = (bool)$s['counts_for_wip']; $s['is_custom'] = (bool)$s['is_custom']; $s['sort_order'] = (int)$s['sort_order'];
    return $s;
}
function policy_shape(array $p) {
    foreach (['id','version','freeze_horizon_days','planning_horizon_weeks','model_horizon_weeks','change_budget_days','max_concurrent_items','min_focus_days','solver_budget_seconds','target_load_min','target_load_max'] as $f)
        if (isset($p[$f])) $p[$f] = (int)$p[$f];
    foreach (['min_improvement_pct','incident_reserve_pct','rota_reserve_pct','small_fill_threshold_days'] as $f) if (isset($p[$f])) $p[$f] = (float)$p[$f];
    foreach (['is_current','auto_apply_outside_horizon','require_ack_inside_horizon'] as $f) if (isset($p[$f])) $p[$f] = (bool)$p[$f];
    return $p;
}
function work_types($conn, $wsId) {
    return array_map('wt_shape', rows($conn, "SELECT t.*,
        (SELECT COUNT(*) FROM dbo.work_items w WHERE w.work_type_id = t.id) AS item_count,
        (SELECT COUNT(*) FROM dbo.work_items w WHERE w.work_type_id = t.id AND w.status IN " . OPEN_STATUSES_SQL . ") AS open_item_count
        FROM dbo.work_types t WHERE t.workspace_id = ? ORDER BY t.retired, t.sort_order, t.id", [$wsId]));
}
function interrupt_type_id($conn, $wsId) {
    $id = scalar($conn, "SELECT TOP 1 id FROM dbo.work_types WHERE workspace_id = ? AND policy = 'interrupt' AND retired = 0 ORDER BY sort_order, id", [$wsId]);
    return $id === null ? null : (int)$id;
}
function size_classes($conn, $wsId) {
    return array_map('sc_shape', rows($conn, "SELECT * FROM dbo.size_classes WHERE workspace_id = ? ORDER BY sort_order, is_custom, min_days, id", [$wsId]));
}
function fmt_num($n) { $n = (float)$n; return $n == floor($n) ? (string)(int)$n : rtrim(rtrim(number_format($n, 2, '.', ''), '0'), '.'); }
function get_config($conn, $wsId) {
    $ws = workspace_row($conn, $wsId);
    $ws['id'] = (int)$ws['id']; $ws['hours_per_day'] = (float)$ws['hours_per_day'];
    $ws['working_days_list'] = array_values(array_filter(array_map('trim', explode(',', $ws['working_days']))));
    $incId = interrupt_type_id($conn, $wsId);
    $all = size_classes($conn, $wsId);
    $sizes = []; $inc = [];
    foreach ($all as $s) { if ($incId !== null && $s['work_type_id'] === $incId) $inc[] = $s; else $sizes[] = $s; }
    $policy = policy_shape(current_policy($conn, $wsId));
    $rates = rows($conn, "SELECT * FROM dbo.day_rates WHERE workspace_id = ? ORDER BY effective_from DESC, id", [$wsId]);
    foreach ($rates as &$r) { $r['id'] = (int)$r['id']; $r['rate'] = (float)$r['rate']; $r['is_blended'] = (bool)$r['is_blended']; $r['effective_from'] = substr($r['effective_from'], 0, 10); }
    return ['workspace' => $ws, 'work_types' => work_types($conn, $wsId), 'size_classes' => $sizes, 'incident_size_classes' => $inc,
        'incident_work_type_id' => $incId, 'policy' => $policy, 'day_rates' => $rates,
        // Real connector state (ADM-06). The Settings panel used to hardcode this list and
        // showed three of them as Connected; nothing was, and nothing read the table.
        'integrations' => array_map(fn($r) => [
            'system' => $r['system'], 'enabled' => (bool)$r['enabled'],
            'last_sync_at' => $r['last_sync_at'], 'last_status' => $r['last_status'],
        ], rows($conn, "SELECT system, enabled, last_sync_at, last_status FROM dbo.integrations WHERE workspace_id = ? ORDER BY id", [$wsId]))];
}

if ($action === 'get') ok(get_config($conn, $wsId));

if ($action === 'export') ok(['config' => export_config($conn, $wsId)]);

// ---- everything below mutates -------------------------------------------------
require_role('admin');

if ($action === 'save_work_type') {
    $id = param('id') !== null ? (int)param('id') : null;
    $before = $id !== null ? row($conn, "SELECT * FROM dbo.work_types WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$before) fail('Work type not found', 404);
    $data = [];
    foreach (['name','plural','prefix','colour','policy','description','requirements_template','size_unit'] as $f) if (param($f) !== null) $data[$f] = trim((string)param($f));
    foreach (['requires_estimate','requires_benefit'] as $f) if (param($f) !== null) $data[$f] = param($f) ? 1 : 0;
    if (array_key_exists('default_size_stamp', body())) $data['default_size_stamp'] = param('default_size_stamp') !== null && param('default_size_stamp') !== '' ? strtoupper(substr(param('default_size_stamp'), 0, 1)) : null;
    if (array_key_exists('allowed_sizes', body())) { $a = param('allowed_sizes'); $data['allowed_sizes'] = is_array($a) ? (count($a) ? implode(',', $a) : null) : ($a === '' ? null : $a); }
    if (isset($data['policy']) && !in_array($data['policy'], ['planned','interrupt'], true)) fail('policy must be planned or interrupt', 400);
    if (isset($data['colour']) && !preg_match('/^#[0-9A-Fa-f]{6}$/', $data['colour'])) fail('colour must be #RRGGBB', 400);
    if (isset($data['size_unit']) && !in_array($data['size_unit'], ['days','hours'], true)) fail('size_unit must be days or hours', 400);
    if ($id !== null) {
        update($conn, 'work_types', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    } else {
        foreach (['name','prefix','colour'] as $f) if (empty($data[$f])) fail("$f is required", 422);
        $data['plural'] = $data['plural'] ?? $data['name'] . 's';
        $data['workspace_id'] = $wsId;
        $data['sort_order'] = 1 + (int)scalar($conn, "SELECT ISNULL(MAX(sort_order),0) FROM dbo.work_types WHERE workspace_id = ?", [$wsId]);
        $id = insert($conn, 'work_types', $data);
        // Make sure the prefix can allocate references.
        q($conn, "IF NOT EXISTS (SELECT 1 FROM dbo.ref_sequences WHERE workspace_id = ? AND prefix = ?) INSERT INTO dbo.ref_sequences (workspace_id, prefix, next_value) VALUES (?, ?, 1000)", [$wsId, $data['prefix'], $wsId, $data['prefix']]);
    }
    $after = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$id]);
    audit($conn, $wsId, 'config', 'work_type', $id, $before, $after, $after['name']);
    $wt = null; foreach (work_types($conn, $wsId) as $t) if ($t['id'] === $id) $wt = $t;
    ok(['work_type' => $wt]);
}

if ($action === 'reorder_work_types') {
    $ids = array_map('intval', (array)require_param('ids'));
    $before = rows($conn, "SELECT id, name, sort_order FROM dbo.work_types WHERE workspace_id = ? ORDER BY sort_order", [$wsId]);
    foreach ($ids as $i => $id) update($conn, 'work_types', ['sort_order' => $i + 1], 'id = ? AND workspace_id = ?', [$id, $wsId]);
    $after = rows($conn, "SELECT id, name, sort_order FROM dbo.work_types WHERE workspace_id = ? ORDER BY sort_order", [$wsId]);
    audit($conn, $wsId, 'config', 'work_type', null, $before, $after, 'Reorder work types');
    ok(['work_types' => work_types($conn, $wsId)]);
}

if ($action === 'retire_work_type') {
    $id = (int)require_param('id');
    $t = row($conn, "SELECT * FROM dbo.work_types WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$t) fail('Work type not found', 404);
    $open = rows($conn, "SELECT id, ref, title, status FROM dbo.work_items WHERE workspace_id = ? AND work_type_id = ? AND status IN " . OPEN_STATUSES_SQL . " ORDER BY ref", [$wsId, $id]);
    $retypeTo = param('retype_to_id') !== null ? (int)param('retype_to_id') : null;
    if ($open && $retypeTo === null) {
        fail(count($open) . ' open ' . (count($open) === 1 ? 'item uses' : 'items use') . " {$t['name']}. Re-type them to another work type to retire it.", 409,
            ['open_items' => array_map(fn($o) => ['id' => (int)$o['id'], 'ref' => $o['ref'], 'title' => $o['title'], 'status' => $o['status']], $open)]);
    }
    if ($open && $retypeTo !== null) {
        if ($retypeTo === $id) fail('retype_to_id must be a different work type', 400);
        $target = row($conn, "SELECT id, name FROM dbo.work_types WHERE id = ? AND workspace_id = ? AND retired = 0", [$retypeTo, $wsId]);
        if (!$target) fail('Target work type not found', 404);
        foreach ($open as $o) {
            update($conn, 'work_items', ['work_type_id' => $retypeTo, 'updated_at' => date('Y-m-d H:i:s')], 'id = ?', [$o['id']]);
            audit($conn, $wsId, 'update', 'work_item', (int)$o['id'], ['work_type_id' => $id, 'type_name' => $t['name']], ['work_type_id' => $retypeTo, 'type_name' => $target['name']], $o['ref'] . ' ' . $o['title'], 'Bulk re-type on retiring ' . $t['name']);
        }
    }
    update($conn, 'work_types', ['retired' => 1], 'id = ?', [$id]);
    $after = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$id]);
    audit($conn, $wsId, 'config', 'work_type', $id, $t, $after, $t['name'], $open ? 'Retired after re-typing ' . count($open) . ' open items' : null);
    ok(['work_type' => wt_shape($after), 'retyped' => count($open)]);
}

if ($action === 'save_size_class') {
    $id = param('id') !== null ? (int)param('id') : null;
    $before = $id !== null ? row($conn, "SELECT * FROM dbo.size_classes WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$before) fail('Size class not found', 404);
    $b = body();
    $data = [];
    if (isset($b['name'])) $data['name'] = trim($b['name']);
    if (isset($b['stamp'])) $data['stamp'] = strtoupper(substr(trim($b['stamp']), 0, 1));
    if (array_key_exists('work_type_id', $b)) $data['work_type_id'] = $b['work_type_id'] !== null && $b['work_type_id'] !== '' ? (int)$b['work_type_id'] : null;
    foreach (['min_days','max_days','planning_days'] as $f) if (array_key_exists($f, $b)) $data[$f] = $b[$f] !== null && $b[$f] !== '' ? (float)$b[$f] : null;
    if (isset($b['default_estimate_class'])) $data['default_estimate_class'] = max(1, min(5, (int)$b['default_estimate_class']));
    if (isset($b['granularity'])) { if (!in_array($b['granularity'], ['halfDay','day','week'], true)) fail('granularity must be halfDay, day or week', 400); $data['granularity'] = $b['granularity']; }
    if (array_key_exists('counts_for_wip', $b)) $data['counts_for_wip'] = $b['counts_for_wip'] ? 1 : 0;
    if (array_key_exists('is_custom', $b)) $data['is_custom'] = $b['is_custom'] ? 1 : 0;
    if (array_key_exists('sort_order', $b)) $data['sort_order'] = (int)$b['sort_order'];
    $merged = array_merge($before ?: ['work_type_id' => null, 'min_days' => null, 'max_days' => null, 'is_custom' => 0, 'name' => null, 'stamp' => null], $data);
    if (!$id) { if (empty($merged['name'])) fail('name is required', 422); if (empty($merged['stamp'])) fail('stamp is required', 422); }
    if ($merged['min_days'] !== null && $merged['max_days'] !== null && (float)$merged['max_days'] < (float)$merged['min_days']) fail('The end of the band must not be before its start', 400);

    // CFG-05: bands must not overlap within the same scope (workspace default, or the same work type override).
    if (!(int)$merged['is_custom']) {
        $scopeSql = $merged['work_type_id'] === null ? "work_type_id IS NULL" : "work_type_id = ?";
        $params = [$wsId]; if ($merged['work_type_id'] !== null) $params[] = (int)$merged['work_type_id'];
        $params[] = $id ?? -1;
        $others = rows($conn, "SELECT * FROM dbo.size_classes WHERE workspace_id = ? AND $scopeSql AND is_custom = 0 AND id <> ? ORDER BY min_days", $params);
        $unit = 'days';
        if ($merged['work_type_id'] !== null) { $u = scalar($conn, "SELECT size_unit FROM dbo.work_types WHERE id = ?", [(int)$merged['work_type_id']]); if ($u === 'hours') $unit = 'hours'; }
        $nMin = $merged['min_days'] !== null ? (float)$merged['min_days'] : 0.0;
        $nMax = $merged['max_days'] !== null ? (float)$merged['max_days'] : INF;
        foreach ($others as $o) {
            $oMin = $o['min_days'] !== null ? (float)$o['min_days'] : 0.0;
            $oMax = $o['max_days'] !== null ? (float)$o['max_days'] : INF;
            if ($nMin <= $oMax && $oMin <= $nMax) {
                $step = 1;
                $fixes = [];
                if ($oMax !== INF) $fixes[] = "the start of {$merged['name']} to " . fmt_num($oMax + $step) . " $unit";
                if ($nMin - $step >= $oMin) $fixes[] = "the end of {$o['name']} to " . fmt_num($nMin - $step);
                if (!$fixes) $fixes[] = "the start of {$o['name']} to " . fmt_num($nMax + $step) . " $unit";
                fail("This size band overlaps {$o['name']}. Change " . implode(' or ', $fixes) . '.', 409, ['overlaps' => sc_shape($o)]);
            }
        }
    }
    if ($id !== null) {
        update($conn, 'size_classes', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    } else {
        $data['workspace_id'] = $wsId;
        $data['work_type_id'] = $merged['work_type_id'];
        if (!isset($data['sort_order'])) $data['sort_order'] = 1 + (int)scalar($conn, "SELECT ISNULL(MAX(sort_order),0) FROM dbo.size_classes WHERE workspace_id = ?", [$wsId]);
        $id = insert($conn, 'size_classes', $data);
    }
    $after = row($conn, "SELECT * FROM dbo.size_classes WHERE id = ?", [$id]);
    audit($conn, $wsId, 'config', 'size_class', $id, $before, $after, $after['name']);
    ok(['size_class' => sc_shape($after)]);
}

if ($action === 'delete_size_class') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.size_classes WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Size class not found', 404);
    $n = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.work_items WHERE size_class_id = ?", [$id]) + (int)scalar($conn, "SELECT COUNT(*) FROM dbo.tasks WHERE size_class_id = ?", [$id]);
    if ($n) fail("$n " . ($n === 1 ? 'item uses' : 'items use') . " {$s['name']}. Re-size them before deleting it.", 409, ['in_use' => $n]);
    q($conn, "DELETE FROM dbo.size_classes WHERE id = ?", [$id]);
    audit($conn, $wsId, 'delete', 'size_class', $id, $s, null, $s['name']);
    ok();
}

if ($action === 'save_policy') {
    $cur = current_policy($conn, $wsId);
    $before = policy_shape($cur);
    $ints = ['freeze_horizon_days','planning_horizon_weeks','model_horizon_weeks','change_budget_days','max_concurrent_items','min_focus_days','solver_budget_seconds','target_load_min','target_load_max'];
    $decs = ['min_improvement_pct','incident_reserve_pct','rota_reserve_pct','small_fill_threshold_days'];
    $strs = ['propose_cadence','commit_cadence','plan_at'];
    $bits = ['auto_apply_outside_horizon','require_ack_inside_horizon'];
    $b = body();
    $new = [];
    foreach (array_merge($ints, $decs, $strs, $bits, ['reestimate_class_threshold']) as $f) $new[$f] = $cur[$f] ?? null;
    foreach ($ints as $f) if (isset($b[$f])) $new[$f] = (int)$b[$f];
    foreach ($decs as $f) if (isset($b[$f])) $new[$f] = (float)$b[$f];
    foreach ($strs as $f) if (isset($b[$f])) $new[$f] = (string)$b[$f];
    foreach ($bits as $f) if (array_key_exists($f, $b)) $new[$f] = $b[$f] ? 1 : 0;
    if (array_key_exists('reestimate_class_threshold', $b)) $new['reestimate_class_threshold'] = $b['reestimate_class_threshold'] !== null && $b['reestimate_class_threshold'] !== '' ? (int)$b['reestimate_class_threshold'] : null;
    if (!in_array($new['plan_at'], ['mostLikely','p80'], true)) fail('plan_at must be mostLikely or p80', 400);
    if ($new['target_load_min'] > $new['target_load_max']) fail('target_load_min must not exceed target_load_max', 400);
    $ow = isset($b['objective_weights']) && is_array($b['objective_weights']) ? array_merge($cur['objective_weights'], $b['objective_weights']) : $cur['objective_weights'];
    $pw = isset($b['priority_weights']) && is_array($b['priority_weights']) ? array_replace_recursive($cur['priority_weights'], $b['priority_weights']) : $cur['priority_weights'];
    $new['objective_weights'] = json_encode($ow, JSON_UNESCAPED_UNICODE);
    $new['priority_weights'] = json_encode($pw, JSON_UNESCAPED_UNICODE);
    $new['workspace_id'] = $wsId;
    $new['version'] = (int)($cur['version'] ?? 0) + 1;
    $new['is_current'] = 1;
    $new['created_by'] = $userId;
    q($conn, "UPDATE dbo.scheduling_policies SET is_current = 0 WHERE workspace_id = ?", [$wsId]);
    $newId = insert($conn, 'scheduling_policies', $new);
    $after = policy_shape(current_policy($conn, $wsId, true));   // true: re-read past the memo
    audit($conn, $wsId, 'config', 'policy', $newId, $before, $after, 'Scheduling policy v' . $after['version']);
    add_trigger($conn, $wsId, 'policy', 'manual', 'Scheduling policy changed (v' . $after['version'] . ')', 'policy', $newId);
    ok(['policy' => $after]);
}

if ($action === 'save_workspace') {
    $before = workspace_row($conn, $wsId);
    $data = [];
    if (param('name') !== null) $data['name'] = trim(param('name'));
    if (param('time_zone') !== null) $data['time_zone'] = trim(param('time_zone'));
    if (param('working_days') !== null) { $wd = param('working_days'); $data['working_days'] = is_array($wd) ? implode(',', $wd) : $wd; }
    if (param('hours_per_day') !== null) $data['hours_per_day'] = (float)param('hours_per_day');
    if (param('currency') !== null) $data['currency'] = strtoupper(substr(trim(param('currency')), 0, 3));
    update($conn, 'workspaces', $data, 'id = ?', [$wsId]);
    $after = workspace_row($conn, $wsId);
    audit($conn, $wsId, 'config', 'workspace', $wsId, $before, $after, $after['name']);
    ok(['workspace' => get_config($conn, $wsId)['workspace']]);
}

if ($action === 'save_day_rate') {
    $id = param('id') !== null ? (int)param('id') : null;
    $before = $id !== null ? row($conn, "SELECT * FROM dbo.day_rates WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$before) fail('Day rate not found', 404);
    $data = [];
    if (param('name') !== null) $data['name'] = trim(param('name'));
    if (param('rate') !== null) $data['rate'] = (float)param('rate');
    if (param('currency') !== null) $data['currency'] = strtoupper(substr(param('currency'), 0, 3));
    if (param('effective_from') !== null) $data['effective_from'] = param('effective_from');
    if (param('is_blended') !== null) $data['is_blended'] = param('is_blended') ? 1 : 0;
    if ($id !== null) update($conn, 'day_rates', $data, 'id = ?', [$id]);
    else {
        foreach (['name','rate'] as $f) if (!isset($data[$f])) fail("$f is required", 422);
        $data['workspace_id'] = $wsId; $data['effective_from'] = $data['effective_from'] ?? today();
        $id = insert($conn, 'day_rates', $data);
    }
    $after = row($conn, "SELECT * FROM dbo.day_rates WHERE id = ?", [$id]);
    audit($conn, $wsId, 'config', 'day_rate', $id, $before, $after, $after['name']);
    ok(['day_rate' => $after]);
}

if ($action === 'import') {
    $cfg = param('config');
    if (!is_array($cfg)) fail('config (object) is required', 422);
    $before = export_config($conn, $wsId);
    $summary = import_config($conn, $wsId, $cfg);
    $after = export_config($conn, $wsId);
    audit($conn, $wsId, 'config', 'workspace', $wsId, $before, $after, 'Configuration import', 'CFG-10 import');
    ok(['imported' => $summary, 'config' => get_config($conn, $wsId)]);
}

fail('Unknown action', 400);

// ---- Appendix A JSON shape ------------------------------------------------------
function export_config($conn, $wsId) {
    $c = get_config($conn, $wsId);
    $ws = $c['workspace'];
    $incName = null; foreach ($c['work_types'] as $t) if ($t['id'] === $c['incident_work_type_id']) $incName = $t['name'];
    $types = [];
    foreach ($c['work_types'] as $t) {
        if ($t['retired']) continue;
        $o = ['name' => $t['name'], 'plural' => $t['plural'], 'prefix' => $t['prefix'], 'colour' => $t['colour'], 'policy' => $t['policy'],
            'requiresEstimate' => $t['requires_estimate'], 'requiresBenefit' => $t['requires_benefit']];
        if ($t['default_size_stamp']) $o['defaultSize'] = $t['default_size_stamp'];
        if ($t['allowed_sizes']) $o['allowedSizes'] = $t['allowed_sizes'];
        if ($t['id'] === $c['incident_work_type_id'] && $c['incident_size_classes']) $o['sizeOverride'] = 'incidentSizes';
        if ($t['size_unit'] !== 'days') $o['sizeUnit'] = $t['size_unit'];
        if ($t['description']) $o['description'] = $t['description'];
        $types[] = $o;
    }
    $sizes = [];
    foreach ($c['size_classes'] as $s) {
        if ($s['work_type_id'] !== null) continue; // only the workspace default scope (overrides other than incidents are not in the Appendix A shape)
        $o = ['stamp' => $s['stamp'], 'name' => $s['name']];
        if ($s['is_custom']) $o['isCustom'] = true;
        else { $o['minDays'] = $s['min_days']; $o['maxDays'] = $s['max_days']; $o['planningDays'] = $s['planning_days']; $o['defaultEstimateClass'] = $s['default_estimate_class']; }
        $o['granularity'] = $s['granularity']; $o['countsForWip'] = $s['counts_for_wip'];
        $sizes[] = $o;
    }
    $inc = [];
    foreach ($c['incident_size_classes'] as $s) $inc[] = ['stamp' => $s['stamp'], 'name' => $s['name'], 'maxHours' => $s['max_days'], 'planningHours' => $s['planning_days']];
    $p = $c['policy'];
    return [
        'workspace' => ['name' => $ws['name'], 'timeZone' => $ws['time_zone'], 'workingWeek' => $ws['working_days_list'], 'hoursPerDay' => $ws['hours_per_day'], 'currency' => $ws['currency']],
        'workTypes' => $types, 'sizeClasses' => $sizes, 'incidentSizes' => $inc,
        'policy' => ['freezeHorizonDays' => $p['freeze_horizon_days'], 'planningHorizonWeeks' => $p['planning_horizon_weeks'], 'modelHorizonWeeks' => $p['model_horizon_weeks'],
            'changeBudgetDaysPerPersonPerWeek' => $p['change_budget_days'], 'minImprovementPct' => $p['min_improvement_pct'], 'incidentReservePct' => $p['incident_reserve_pct'],
            'rotaReservePct' => $p['rota_reserve_pct'], 'cadence' => ['propose' => $p['propose_cadence'], 'commit' => $p['commit_cadence']],
            'maxConcurrentItems' => $p['max_concurrent_items'], 'minFocusDays' => $p['min_focus_days'], 'planAt' => $p['plan_at'], 'solverBudgetSeconds' => $p['solver_budget_seconds'],
            'smallFillThresholdDays' => $p['small_fill_threshold_days'], 'targetLoadMin' => $p['target_load_min'], 'targetLoadMax' => $p['target_load_max']],
        'objectiveWeights' => $p['objective_weights'], 'priorityWeights' => $p['priority_weights'],
        'dayRates' => array_map(fn($r) => ['name' => $r['name'], 'rate' => $r['rate'], 'currency' => $r['currency'], 'effectiveFrom' => $r['effective_from'], 'isBlended' => $r['is_blended']], $c['day_rates']),
    ];
}

/** Upsert from the Appendix A shape: work types by name, size classes by stamp within scope, policy as a new version. */
function import_config($conn, $wsId, array $cfg) {
    global $userId;
    $summary = ['work_types' => 0, 'size_classes' => 0, 'incident_sizes' => 0, 'policy' => false, 'workspace' => false, 'day_rates' => 0];
    if (!empty($cfg['workspace']) && is_array($cfg['workspace'])) {
        $w = $cfg['workspace']; $data = [];
        if (isset($w['name'])) $data['name'] = $w['name'];
        if (isset($w['timeZone'])) $data['time_zone'] = $w['timeZone'];
        if (isset($w['workingWeek'])) $data['working_days'] = implode(',', (array)$w['workingWeek']);
        if (isset($w['hoursPerDay'])) $data['hours_per_day'] = (float)$w['hoursPerDay'];
        if (isset($w['currency'])) $data['currency'] = $w['currency'];
        update($conn, 'workspaces', $data, 'id = ?', [$wsId]); $summary['workspace'] = (bool)$data;
    }
    $incTypeId = null;
    foreach ((array)($cfg['workTypes'] ?? []) as $i => $t) {
        if (empty($t['name'])) continue;
        $data = ['name' => $t['name'], 'plural' => $t['plural'] ?? $t['name'] . 's', 'prefix' => $t['prefix'] ?? 'WI', 'colour' => $t['colour'] ?? '#3B6BD6',
            'policy' => ($t['policy'] ?? 'planned') === 'interrupt' ? 'interrupt' : 'planned',
            'requires_estimate' => !empty($t['requiresEstimate']) ? 1 : 0, 'requires_benefit' => !empty($t['requiresBenefit']) ? 1 : 0,
            'default_size_stamp' => $t['defaultSize'] ?? null, 'allowed_sizes' => !empty($t['allowedSizes']) ? implode(',', (array)$t['allowedSizes']) : null,
            'size_unit' => $t['sizeUnit'] ?? (!empty($t['sizeOverride']) ? 'hours' : 'days'), 'description' => $t['description'] ?? null, 'sort_order' => $i + 1, 'retired' => 0];
        $existing = scalar($conn, "SELECT id FROM dbo.work_types WHERE workspace_id = ? AND name = ?", [$wsId, $t['name']]);
        if ($existing) { update($conn, 'work_types', $data, 'id = ?', [(int)$existing]); $id = (int)$existing; }
        else { $data['workspace_id'] = $wsId; $id = insert($conn, 'work_types', $data); }
        q($conn, "IF NOT EXISTS (SELECT 1 FROM dbo.ref_sequences WHERE workspace_id = ? AND prefix = ?) INSERT INTO dbo.ref_sequences (workspace_id, prefix, next_value) VALUES (?, ?, 1000)", [$wsId, $data['prefix'], $wsId, $data['prefix']]);
        if (!empty($t['sizeOverride']) || $data['policy'] === 'interrupt') $incTypeId = $incTypeId ?? $id;
        $summary['work_types']++;
    }
    $upsertSize = function ($s, $typeId, $i) use ($conn, $wsId) {
        $data = ['name' => $s['name'] ?? ($s['stamp'] ?? '?'), 'stamp' => strtoupper(substr($s['stamp'] ?? 'C', 0, 1)),
            'min_days' => $s['minDays'] ?? $s['minHours'] ?? null, 'max_days' => $s['maxDays'] ?? $s['maxHours'] ?? null,
            'planning_days' => $s['planningDays'] ?? $s['planningHours'] ?? null, 'default_estimate_class' => (int)($s['defaultEstimateClass'] ?? 3),
            'granularity' => $s['granularity'] ?? 'day', 'counts_for_wip' => array_key_exists('countsForWip', $s) ? ($s['countsForWip'] ? 1 : 0) : 1,
            'is_custom' => !empty($s['isCustom']) ? 1 : 0, 'sort_order' => $i + 1];
        $scope = $typeId === null ? "work_type_id IS NULL" : "work_type_id = ?";
        $params = [$wsId, $data['stamp']]; if ($typeId !== null) $params[] = $typeId;
        $existing = scalar($conn, "SELECT id FROM dbo.size_classes WHERE workspace_id = ? AND stamp = ? AND $scope", $params);
        if ($existing) update($conn, 'size_classes', $data, 'id = ?', [(int)$existing]);
        else { $data['workspace_id'] = $wsId; $data['work_type_id'] = $typeId; insert($conn, 'size_classes', $data); }
    };
    foreach ((array)($cfg['sizeClasses'] ?? []) as $i => $s) { $upsertSize($s, null, $i); $summary['size_classes']++; }
    if ($incTypeId === null) $incTypeId = interrupt_type_id($conn, $wsId);
    if ($incTypeId !== null) foreach ((array)($cfg['incidentSizes'] ?? []) as $i => $s) {
        $s['name'] = $s['name'] ?? ['S' => 'Small', 'M' => 'Medium', 'L' => 'Large', 'C' => 'Custom'][strtoupper($s['stamp'] ?? '')] ?? $s['stamp'];
        $s['granularity'] = $s['granularity'] ?? 'halfDay';
        $upsertSize($s, $incTypeId, $i); $summary['incident_sizes']++;
    }
    if (!empty($cfg['policy']) || !empty($cfg['objectiveWeights']) || !empty($cfg['priorityWeights'])) {
        $cur = current_policy($conn, $wsId); $p = (array)($cfg['policy'] ?? []);
        $map = ['freezeHorizonDays' => 'freeze_horizon_days', 'planningHorizonWeeks' => 'planning_horizon_weeks', 'modelHorizonWeeks' => 'model_horizon_weeks',
            'changeBudgetDaysPerPersonPerWeek' => 'change_budget_days', 'minImprovementPct' => 'min_improvement_pct', 'incidentReservePct' => 'incident_reserve_pct',
            'rotaReservePct' => 'rota_reserve_pct', 'maxConcurrentItems' => 'max_concurrent_items', 'minFocusDays' => 'min_focus_days', 'planAt' => 'plan_at',
            'solverBudgetSeconds' => 'solver_budget_seconds', 'smallFillThresholdDays' => 'small_fill_threshold_days', 'targetLoadMin' => 'target_load_min', 'targetLoadMax' => 'target_load_max'];
        $new = [];
        foreach (['freeze_horizon_days','planning_horizon_weeks','model_horizon_weeks','change_budget_days','min_improvement_pct','incident_reserve_pct','rota_reserve_pct','propose_cadence','commit_cadence',
            'max_concurrent_items','min_focus_days','plan_at','solver_budget_seconds','small_fill_threshold_days','target_load_min','target_load_max','auto_apply_outside_horizon','require_ack_inside_horizon','reestimate_class_threshold'] as $f) $new[$f] = $cur[$f] ?? null;
        foreach ($map as $k => $f) if (isset($p[$k])) $new[$f] = $p[$k];
        if (isset($p['cadence']['propose'])) $new['propose_cadence'] = $p['cadence']['propose'];
        if (isset($p['cadence']['commit'])) $new['commit_cadence'] = $p['cadence']['commit'];
        $new['objective_weights'] = json_encode(array_merge($cur['objective_weights'], (array)($cfg['objectiveWeights'] ?? [])), JSON_UNESCAPED_UNICODE);
        $new['priority_weights'] = json_encode(array_replace_recursive($cur['priority_weights'], (array)($cfg['priorityWeights'] ?? [])), JSON_UNESCAPED_UNICODE);
        $new['workspace_id'] = $wsId; $new['version'] = (int)($cur['version'] ?? 0) + 1; $new['is_current'] = 1; $new['created_by'] = $userId;
        q($conn, "UPDATE dbo.scheduling_policies SET is_current = 0 WHERE workspace_id = ?", [$wsId]);
        insert($conn, 'scheduling_policies', $new);
        $summary['policy'] = true;
    }
    foreach ((array)($cfg['dayRates'] ?? []) as $r) {
        if (empty($r['name'])) continue;
        $data = ['name' => $r['name'], 'rate' => (float)($r['rate'] ?? 0), 'currency' => $r['currency'] ?? 'GBP', 'effective_from' => $r['effectiveFrom'] ?? today(), 'is_blended' => !empty($r['isBlended']) ? 1 : 0];
        $existing = scalar($conn, "SELECT id FROM dbo.day_rates WHERE workspace_id = ? AND name = ? AND effective_from = ?", [$wsId, $data['name'], $data['effective_from']]);
        if ($existing) update($conn, 'day_rates', $data, 'id = ?', [(int)$existing]); else { $data['workspace_id'] = $wsId; insert($conn, 'day_rates', $data); }
        $summary['day_rates']++;
    }
    return $summary;
}
