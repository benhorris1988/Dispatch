<?php
// Audit log (ADM-04): searchable, pageable, exportable. Admin only.
// Actions: list {entity?, action?, actor?, q?, from?, to?, limit?, offset?} | export_csv {same filters}
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
$action = param('action', 'list');
require_role('admin');

function audit_filters($wsId) {
    $where = ["workspace_id = ?"]; $params = [$wsId];
    if (param('entity')) { $where[] = "entity = ?"; $params[] = param('entity'); }
    if (param('action_type')) { $where[] = "action = ?"; $params[] = param('action_type'); }
    if (param('actor')) { $where[] = "(actor_name LIKE ? OR actor_user_id = ?)"; $params[] = '%' . param('actor') . '%'; $params[] = (int)param('actor'); }
    if (param('entity_id')) { $where[] = "entity_id = ?"; $params[] = (int)param('entity_id'); }
    if (param('q')) { $like = '%' . param('q') . '%'; $where[] = "(actor_name LIKE ? OR entity_label LIKE ? OR entity LIKE ? OR action LIKE ? OR reason LIKE ? OR before_json LIKE ? OR after_json LIKE ?)"; array_push($params, $like, $like, $like, $like, $like, $like, $like); }
    if (param('from')) { $where[] = "occurred_at >= ?"; $params[] = param('from') . ' 00:00:00'; }
    if (param('to')) { $where[] = "occurred_at < DATEADD(day, 1, CAST(? AS DATE))"; $params[] = param('to'); }
    return [implode(' AND ', $where), $params];
}
function event_shape(array $e) {
    return ['id' => (int)$e['id'], 'occurred_at' => $e['occurred_at'], 'actor_user_id' => $e['actor_user_id'] !== null ? (int)$e['actor_user_id'] : null, 'actor_name' => $e['actor_name'],
        'action' => $e['action'], 'entity' => $e['entity'], 'entity_id' => $e['entity_id'] !== null ? (int)$e['entity_id'] : null, 'entity_label' => $e['entity_label'],
        'before' => $e['before_json'] !== null ? json_decode($e['before_json'], true) : null, 'after' => $e['after_json'] !== null ? json_decode($e['after_json'], true) : null,
        'reason' => $e['reason'], 'changed_fields' => changed_fields($e['before_json'], $e['after_json'])];
}
/** Top-level keys whose value differs between before and after (handy for the log's "what changed" column). */
function changed_fields($beforeJson, $afterJson) {
    $b = $beforeJson !== null ? json_decode($beforeJson, true) : null; $a = $afterJson !== null ? json_decode($afterJson, true) : null;
    if (!is_array($b) || !is_array($a)) return [];
    $keys = array_unique(array_merge(array_keys($b), array_keys($a))); $out = [];
    foreach ($keys as $k) if (($b[$k] ?? null) != ($a[$k] ?? null)) $out[] = $k;
    return array_values($out);
}

if ($action === 'list') {
    [$where, $params] = audit_filters($wsId);
    $limit = max(1, min(500, (int)param('limit', 50))); $offset = max(0, (int)param('offset', 0));
    $total = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE $where", $params);
    $events = rows($conn, "SELECT * FROM dbo.audit_events WHERE $where ORDER BY occurred_at DESC, id DESC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY", array_merge($params, [$offset, $limit]));
    $entities = array_map(fn($r) => $r['entity'], rows($conn, "SELECT DISTINCT entity FROM dbo.audit_events WHERE workspace_id = ? ORDER BY entity", [$wsId]));
    $actions = array_map(fn($r) => $r['action'], rows($conn, "SELECT DISTINCT action FROM dbo.audit_events WHERE workspace_id = ? ORDER BY action", [$wsId]));
    ok(['events' => array_map('event_shape', $events), 'total' => $total, 'limit' => $limit, 'offset' => $offset, 'entities' => $entities, 'actions' => $actions]);
}

if ($action === 'export_csv') {
    [$where, $params] = audit_filters($wsId);
    $events = rows($conn, "SELECT TOP 10000 * FROM dbo.audit_events WHERE $where ORDER BY occurred_at DESC, id DESC", $params);
    $fh = fopen('php://temp', 'w+');
    fputcsv($fh, ['id', 'occurred_at', 'actor', 'action', 'entity', 'entity_id', 'entity_label', 'reason', 'before', 'after']);
    foreach ($events as $e) fputcsv($fh, [$e['id'], $e['occurred_at'], $e['actor_name'], $e['action'], $e['entity'], $e['entity_id'], $e['entity_label'], $e['reason'], $e['before_json'], $e['after_json']]);
    rewind($fh); $csv = stream_get_contents($fh); fclose($fh);
    audit($conn, $wsId, 'export', 'audit_events', null, null, ['rows' => count($events), 'filters' => array_intersect_key(body(), array_flip(['entity','action_type','actor','q','from','to']))], 'Audit log export');
    ok(['csv' => $csv, 'rows' => count($events), 'filename' => 'audit-' . today() . '.csv']);
}

fail('Unknown action', 400);
