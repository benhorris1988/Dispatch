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
    // Inside a best-effort side job (see start_urgent_cycle) a failure must not end the
    // request that triggered it: throw so the caller can swallow it, rather than printing
    // an error envelope over a response that has not been written yet.
    if (!empty($GLOBALS['dp_soft_fail'])) throw new RuntimeException($message, $code);
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
/**
 * A user's channel preferences for one notification kind (NOT-02). A missing row is not
 * "no preference": it is the documented default that notifications.php also shows, so the
 * two never disagree about what an untouched account receives.
 */
function notification_pref($conn, $userId, $kind) {
    static $cache = [];
    $key = "$userId:$kind";
    if (!array_key_exists($key, $cache)) {
        $r = $userId === null ? null : row($conn, "SELECT in_app, push, email_digest, teams, digest FROM dbo.notification_prefs WHERE user_id = ? AND kind = ?", [$userId, $kind]);
        $cache[$key] = ['in_app' => $r ? (int)$r['in_app'] : 1, 'push' => $r ? (int)$r['push'] : 1,
            'email_digest' => $r ? (int)$r['email_digest'] : 0, 'teams' => $r ? (int)$r['teams'] : 0,
            'digest' => $r ? $r['digest'] : 'daily', 'is_default' => $r === null];
    }
    return $cache[$key];
}
// NOTE: ids are compared against null, never for truthiness. SQL Server identity columns
// can legitimately hand out 0 (a RESEED on a never-used table), and `if (!$id)` would then
// silently drop every notification aimed at that row.
/**
 * Raise an in-app notification, honouring the recipient's per-kind preferences (NOT-01/02/03).
 *
 * The row IS the in-app copy, so in-app is the floor: when a user has turned in-app off for
 * that kind nothing is written at all. `channel` records the route their own switches select:
 *   'digest' — an email digest on a daily or weekly cadence will carry it, so it is not immediate;
 *   'teams'  — routed to Microsoft Teams;
 *   'in_app' — delivered now, in the app.
 * An urgent notification never rides a digest (NOT-03) and therefore stays 'in_app'.
 * Push is deliberately never claimed here: there is no APNs/FCM sender in this build (MOB-04),
 * and a channel value is a statement about where a notification went.
 *
 * @return int|null the new notification id, or null when a preference suppressed it.
 */
function notify($conn, $wsId, $toUserId, $kind, $title, $body = null, $link = null, $urgent = 0) {
    if ($toUserId === null || $toUserId === '') return null;
    $pref = notification_pref($conn, $toUserId, $kind);
    if (!$pref['in_app']) return null;
    $channel = 'in_app';
    if (!$urgent) {
        if ($pref['email_digest'] && in_array($pref['digest'], ['daily', 'weekly'], true)) $channel = 'digest';
        elseif ($pref['teams']) $channel = 'teams';
    }
    return insert($conn, 'notifications', ['workspace_id' => $wsId, 'user_id' => $toUserId, 'kind' => $kind,
        'title' => mb_substr((string)$title, 0, 200), 'body' => $body === null ? null : mb_substr((string)$body, 0, 600),
        'link' => $link, 'urgent' => $urgent ? 1 : 0, 'channel' => $channel]);
}
/** Notify the user linked to a person (if any). */
function notify_person($conn, $wsId, $personId, $kind, $title, $body = null, $link = null, $urgent = 0) {
    if ($personId === null || $personId === '') return null;
    $uid = scalar($conn, "SELECT id FROM dbo.users WHERE person_id = ? AND workspace_id = ? AND active = 1", [$personId, $wsId]);
    return notify($conn, $wsId, $uid, $kind, $title, $body, $link, $urgent);
}
/** Active user ids in the workspace holding $minRole or better (ADM-02 ranking). */
function users_with_role($conn, $wsId, $minRole) {
    $min = DP_ROLE_RANK[$minRole] ?? 99;
    $roles = array_keys(array_filter(DP_ROLE_RANK, fn($rank) => $rank >= $min));
    if (!$roles) return [];
    $in = "'" . implode("','", $roles) . "'";   // from a constant, never from input
    return array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.users WHERE workspace_id = ? AND active = 1 AND role IN ($in)", [$wsId]));
}
function add_trigger($conn, $wsId, $type, $class, $label, $entity = null, $entityId = null, $personIds = null) {
    return insert($conn, 'replan_triggers', ['workspace_id' => $wsId, 'type' => $type, 'class' => $class,
        'label' => $label, 'source_entity' => $entity, 'source_id' => $entityId,
        'person_ids' => $personIds ? implode(',', (array)$personIds) : null]);
}

/**
 * STAB-05: an urgent trigger starts an immediate cycle limited to the affected people.
 *
 * Called by the endpoints that raise an urgent trigger, AFTER they have committed their own
 * change, so the engine plans against the new facts. It is synchronous and cheap (the
 * heuristic runs in tens of milliseconds on demo-sized data) and it is best-effort in the
 * strongest sense: nothing it does may fail the request that triggered it. `dp_soft_fail`
 * turns lib.php's fail() into an exception for the duration so a database or model problem
 * inside the engine cannot print an error envelope over the caller's own response.
 *
 * A dry run decides whether to persist. A scoped cycle that finds nothing to change would
 * otherwise supersede the standing proposal (CHG-08) and replace it with an empty one, which
 * is a worse outcome than not running at all.
 *
 * @param array $personIds scope; empty lets run_propose() derive it from the unprocessed urgent triggers.
 * @return array|null {proposal_id, changes, held} — or null/skipped when nothing was raised.
 */
function start_urgent_cycle($conn, $wsId, array $personIds = []) {
    static $ran = [];
    if (isset($ran[$wsId])) return null;      // at most one scoped cycle per request
    $ran[$wsId] = true;
    $scope = array_values(array_unique(array_map('intval', $personIds)));
    $prev = $GLOBALS['dp_soft_fail'] ?? false;
    $GLOBALS['dp_soft_fail'] = true;
    try {
        require_once __DIR__ . '/engine/proposals.php';
        if (!function_exists('run_propose')) return null;
        $opts = ['kind' => 'urgent', 'scope_person_ids' => $scope, 'engine' => 'heuristic'];
        $dry = run_propose($conn, $wsId, $opts + ['persist' => false]);
        if (empty($dry['changes']) && empty($dry['held'])) return ['proposal_id' => null, 'changes' => 0, 'held' => 0, 'skipped' => 'nothing to replan'];
        $r = run_propose($conn, $wsId, $opts);
        return ['proposal_id' => $r['proposal_id'] ?? null, 'changes' => count($r['changes'] ?? []), 'held' => count($r['held'] ?? []),
                'scope_person_ids' => $r['scope_person_ids'] ?? $scope];
    } catch (Throwable $e) {
        error_log('Urgent replan cycle failed (the originating request is unaffected): ' . $e->getMessage());
        return ['proposal_id' => null, 'changes' => 0, 'held' => 0, 'error' => $e->getMessage()];
    } finally {
        $GLOBALS['dp_soft_fail'] = $prev;
    }
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
