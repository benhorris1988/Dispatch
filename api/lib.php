<?php
// Shared helpers: JSON responses, request body, query helpers, audit, dates, roles.

function dp_config() {
    static $cfg = null;
    if ($cfg === null) {
        $path = __DIR__ . '/config.php';
        if (!file_exists($path)) { fail('Server not configured', 500); }
        $cfg = require $path;
    }
    return $cfg;
}

function ok(array $data = []) {
    echo json_encode(array_merge(['status' => 'ok'], $data), JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    exit;
}
function fail($message, $code = 400, array $extra = []) {
    http_response_code($code);
    echo json_encode(array_merge(['status' => 'error', 'message' => $message], $extra), JSON_UNESCAPED_UNICODE);
    exit;
}

/** Parsed JSON body (POST) merged with query string (GET). */
function body() {
    static $b = null;
    if ($b === null) {
        $raw = file_get_contents('php://input');
        $j = $raw ? json_decode($raw, true) : null;
        $b = is_array($j) ? $j : [];
        foreach ($_GET as $k => $v) { if (!array_key_exists($k, $b)) $b[$k] = $v; }
    }
    return $b;
}
function param($key, $default = null) { $b = body(); return array_key_exists($key, $b) ? $b[$key] : $default; }
function require_param($key) {
    $v = param($key);
    if ($v === null || $v === '') fail("$key is required", 422);
    return $v;
}

/** Run a parameterised query; returns statement or fails with a 500. */
function q($conn, $sql, array $params = []) {
    $stmt = sqlsrv_query($conn, $sql, $params);
    if ($stmt === false) {
        $err = sqlsrv_errors();
        error_log("SQL error: " . print_r($err, true) . "\nSQL: $sql");
        fail('Database error: ' . ($err[0]['message'] ?? 'unknown'), 500);
    }
    return $stmt;
}
function rows($conn, $sql, array $params = []) {
    $stmt = q($conn, $sql, $params);
    $out = [];
    while ($r = sqlsrv_fetch_array($stmt, SQLSRV_FETCH_ASSOC)) $out[] = normalise_row($r);
    sqlsrv_free_stmt($stmt);
    return $out;
}
function row($conn, $sql, array $params = []) {
    $r = rows($conn, $sql, $params);
    return $r ? $r[0] : null;
}
function scalar($conn, $sql, array $params = []) {
    $r = row($conn, $sql, $params);
    return $r ? reset($r) : null;
}
/** INSERT into dbo.$table; returns the new identity. */
function insert($conn, $table, array $data) {
    $cols = array_keys($data);
    $sql = "INSERT INTO dbo.$table (" . implode(',', $cols) . ") OUTPUT INSERTED.id VALUES (" . implode(',', array_fill(0, count($cols), '?')) . ")";
    $stmt = q($conn, $sql, array_values($data));
    $id = null;
    if (sqlsrv_fetch($stmt)) $id = (int)sqlsrv_get_field($stmt, 0);
    sqlsrv_free_stmt($stmt);
    return $id;
}
function update($conn, $table, array $data, $where, array $whereParams) {
    if (!$data) return;
    $sets = [];
    foreach ($data as $k => $v) $sets[] = "$k = ?";
    q($conn, "UPDATE dbo.$table SET " . implode(', ', $sets) . " WHERE $where", array_merge(array_values($data), $whereParams));
}
function normalise_row(array $r) {
    foreach ($r as $k => $v) {
        if ($v instanceof DateTimeInterface) $r[$k] = $v->format('Y-m-d H:i:s');
        elseif (is_string($v) && strlen($v) < 20 && preg_match('/^-?\d+\.\d+$/', $v)) $r[$k] = (float)$v;
    }
    return $r;
}
function json_col($v, $default = []) {
    if ($v === null || $v === '') return $default;
    $d = json_decode($v, true);
    return is_array($d) ? $d : $default;
}
function csv_ids($v) {
    if ($v === null || $v === '') return [];
    return array_values(array_filter(array_map('intval', explode(',', $v))));
}

/** Append an audit event (ADM-04). */
function audit($conn, $wsId, $action, $entity, $entityId, $before, $after, $label = null, $reason = null) {
    global $userId, $userName;
    insert($conn, 'audit_events', [
        'workspace_id' => $wsId, 'actor_user_id' => $userId ?? null, 'actor_name' => $userName ?? null,
        'action' => $action, 'entity' => $entity, 'entity_id' => $entityId, 'entity_label' => $label,
        'before_json' => $before === null ? null : json_encode($before, JSON_UNESCAPED_UNICODE),
        'after_json' => $after === null ? null : json_encode($after, JSON_UNESCAPED_UNICODE),
        'reason' => $reason,
    ]);
}
// NOTE: ids are compared against null, never for truthiness. SQL Server identity columns
// can legitimately hand out 0 (a RESEED on a never-used table), and `if (!$id)` would then
// silently drop every notification aimed at that row.
function notify($conn, $wsId, $toUserId, $kind, $title, $body = null, $link = null, $urgent = 0) {
    if ($toUserId === null || $toUserId === '') return;
    insert($conn, 'notifications', ['workspace_id' => $wsId, 'user_id' => $toUserId, 'kind' => $kind,
        'title' => $title, 'body' => $body, 'link' => $link, 'urgent' => $urgent ? 1 : 0]);
}
/** Notify the user linked to a person (if any). */
function notify_person($conn, $wsId, $personId, $kind, $title, $body = null, $link = null, $urgent = 0) {
    if ($personId === null || $personId === '') return;
    $uid = scalar($conn, "SELECT id FROM dbo.users WHERE person_id = ? AND workspace_id = ? AND active = 1", [$personId, $wsId]);
    notify($conn, $wsId, $uid, $kind, $title, $body, $link, $urgent);
}
function add_trigger($conn, $wsId, $type, $class, $label, $entity = null, $entityId = null, $personIds = null) {
    return insert($conn, 'replan_triggers', ['workspace_id' => $wsId, 'type' => $type, 'class' => $class,
        'label' => $label, 'source_entity' => $entity, 'source_id' => $entityId,
        'person_ids' => $personIds ? implode(',', (array)$personIds) : null]);
}

/**
 * The workspace's current scheduling policy, JSON columns decoded, with the schema
 * defaults filled in when no row exists yet.
 *
 * This lives in lib.php — which every endpoint loads through db_connect.php — because it
 * is needed by both the engine and the item/estimate layer. Declaring it in each of those
 * made the winner depend on include order, and the two bodies disagreed about defaults.
 *
 * The result is memoised because the engine reads it inside per-item loops. Anything that
 * writes a new policy version MUST pass $fresh = true afterwards, or it will read back the
 * superseded row it just replaced.
 */
function current_policy($conn, $wsId, $fresh = false) {
    static $cache = [];
    if (!$fresh && array_key_exists($wsId, $cache)) return $cache[$wsId];
    $p = row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC, id DESC", [$wsId]);
    if (!$p) {
        $p = ['id' => null, 'version' => 0, 'is_current' => 1, 'freeze_horizon_days' => 10, 'planning_horizon_weeks' => 4, 'model_horizon_weeks' => 26,
            'change_budget_days' => 5, 'min_improvement_pct' => 5, 'incident_reserve_pct' => 12, 'rota_reserve_pct' => 25,
            'propose_cadence' => 'daily 02:00', 'commit_cadence' => 'weekly Mon 09:00', 'max_concurrent_items' => 2, 'min_focus_days' => 2,
            'plan_at' => 'mostLikely', 'solver_budget_seconds' => 60, 'small_fill_threshold_days' => 3, 'target_load_min' => 80,
            'target_load_max' => 90, 'auto_apply_outside_horizon' => 0, 'require_ack_inside_horizon' => 1, 'reestimate_class_threshold' => null,
            'objective_weights' => null, 'priority_weights' => null, 'created_at' => null, 'created_by' => null];
    }
    $p['objective_weights'] = json_col($p['objective_weights'] ?? null, ['valueCompletion'=>1,'lateness'=>3,'unscheduledValue'=>5,'loadImbalance'=>0.5,'contextSwitching'=>0.5,'stabilityPlanned'=>2,'preferences'=>0.2]);
    $p['priority_weights'] = json_col($p['priority_weights'] ?? null, ['value'=>40,'urgency'=>25,'riskCompliance'=>15,'dependencyLeverage'=>10,'age'=>10,'confidenceScale'=>['high'=>1,'medium'=>0.7,'low'=>0.4],'severityScores'=>['P1'=>100,'P2'=>90,'P3'=>70,'P4'=>50]]);
    $cache[$wsId] = $p;
    return $p;
}

/** The workspace's working week, e.g. ['Mon','Tue','Wed','Thu','Fri']. Canonical here for the same reason as current_policy(). */
function workspace_working_days($conn, $wsId) {
    static $cache = [];
    if (array_key_exists($wsId, $cache)) return $cache[$wsId];
    $s = scalar($conn, "SELECT working_days FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $d = array_values(array_filter(array_map('trim', explode(',', (string)$s))));
    return $cache[$wsId] = ($d ?: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
}

// ---- Working-day date helpers -------------------------------------------------
function is_working_day($date, $workingDays = ['Mon','Tue','Wed','Thu','Fri']) {
    return in_array(date('D', strtotime($date)), $workingDays, true);
}
function add_working_days($date, $n, $workingDays = ['Mon','Tue','Wed','Thu','Fri']) {
    $d = new DateTime($date); $step = $n >= 0 ? '+1' : '-1'; $n = abs($n);
    while ($n > 0) { $d->modify("$step day"); if (in_array($d->format('D'), $workingDays, true)) $n--; }
    return $d->format('Y-m-d');
}
function working_days_between($from, $to, $workingDays = ['Mon','Tue','Wed','Thu','Fri']) {
    if ($to < $from) return 0;
    $d = new DateTime($from); $end = new DateTime($to); $n = 0;
    while ($d <= $end) { if (in_array($d->format('D'), $workingDays, true)) $n++; $d->modify('+1 day'); }
    return $n;
}
function week_start($date) { $d = new DateTime($date); if ($d->format('D') !== 'Mon') $d->modify('last monday'); return $d->format('Y-m-d'); }
/** "Today" for the planner. config 'fake_today' pins it (demo/test); otherwise the real date. */
function today() { return dp_config()['fake_today'] ?? date('Y-m-d'); }

// ---- Role helpers (ADM-02) ------------------------------------------------------
const DP_ROLE_RANK = ['viewer'=>0,'requester'=>1,'team_member'=>2,'benefit_owner'=>3,'team_lead'=>4,'delivery_lead'=>5,'admin'=>6];
function require_role($minRole) {
    global $role;
    if ((DP_ROLE_RANK[$role ?? 'viewer'] ?? 0) < (DP_ROLE_RANK[$minRole] ?? 99)) fail("Forbidden: requires $minRole", 403);
}
function has_role($minRole) {
    global $role;
    return (DP_ROLE_RANK[$role ?? 'viewer'] ?? 0) >= (DP_ROLE_RANK[$minRole] ?? 99);
}
