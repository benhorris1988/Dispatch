<?php
// Inbound intake (INT-02, and the shape INT-01 and INT-03 would follow).
//
// The half of an incident integration that needs no ServiceNow instance: an endpoint a
// ticket system posts to, which turns an assigned incident above a severity threshold into
// interrupt-driven work with its priority taken from severity. ServiceNow is one caller;
// anything that can POST JSON is another.
//
//   POST /api/intake.php?source=<id>   with X-Dispatch-Intake-Secret  -> no session, receives an incident
//   POST {"action": "..."} with a bearer token (admin)                -> manage sources and read the log
//
// Idempotent on external_ref: a ticket system that retries — and they all retry — must not
// raise the same incident twice. A repost is answered 200 with the item it already made,
// because a retry that looks like a failure only makes the caller retry harder.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/items_lib.php';
require_once __DIR__ . '/engine/priority.php';

const DP_SEVERITY_RANK = ['P1' => 1, 'P2' => 2, 'P3' => 3, 'P4' => 4];

/** Pull a value out of the payload by a mapped path, e.g. 'incident.short_description'. */
function intake_pluck(array $payload, $path, $default = null) {
    if (!$path) return $default;
    $cur = $payload;
    foreach (explode('.', $path) as $seg) {
        if (!is_array($cur) || !array_key_exists($seg, $cur)) return $default;
        $cur = $cur[$seg];
    }
    return $cur;
}

/** Normalise whatever the caller calls severity into P1..P4. */
function intake_severity($raw, array $map) {
    if ($raw === null || $raw === '') return null;
    $key = trim((string)$raw);
    if (isset($map[$key])) return strtoupper($map[$key]);
    $upper = strtoupper($key);
    if (isset(DP_SEVERITY_RANK[$upper])) return $upper;
    // ServiceNow sends 1..4; so do most others.
    if (ctype_digit($key) && (int)$key >= 1 && (int)$key <= 4) return 'P' . (int)$key;
    if (preg_match('/\b(critical|high|moderate|medium|low)\b/i', $key, $m)) {
        return ['critical' => 'P1', 'high' => 'P2', 'moderate' => 'P3', 'medium' => 'P3', 'low' => 'P4'][strtolower($m[1])];
    }
    return null;
}

function intake_log($conn, $wsId, $sourceId, $ref, $outcome, $itemId, $detail, $payload) {
    insert($conn, 'intake_log', ['workspace_id' => $wsId, 'source_id' => $sourceId, 'external_ref' => $ref,
        'outcome' => $outcome, 'work_item_id' => $itemId, 'detail' => mb_substr((string)$detail, 0, 300),
        'payload' => json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)]);
}

// ---------------------------------------------------------------- the receiving endpoint
$sourceParam = $_GET['source'] ?? null;
if ($sourceParam !== null && $sourceParam !== '') {
    $headers = function_exists('getallheaders') ? getallheaders() : [];
    $presented = $headers['X-Dispatch-Intake-Secret'] ?? $headers['x-dispatch-intake-secret'] ?? ($_SERVER['HTTP_X_DISPATCH_INTAKE_SECRET'] ?? '');
    $src = row($conn, "SELECT * FROM dbo.intake_sources WHERE id = ? AND active = 1", [(int)$sourceParam]);
    // Constant-time, and the same answer either way: a caller with the wrong secret learns
    // nothing about whether the source exists.
    if (!$src || !is_string($presented) || $presented === '' || !hash_equals($src['secret'], $presented)) {
        fail('Unknown source or bad secret', 401);
    }
    $wsId = (int)$src['workspace_id'];
    $payload = body();
    $map = json_col($src['field_map'], []);
    $sevMap = json_col($src['severity_map'], []);

    $ref = intake_pluck($payload, $map['external_ref'] ?? 'number')
        ?? intake_pluck($payload, 'number') ?? intake_pluck($payload, 'id');
    $title = intake_pluck($payload, $map['title'] ?? 'short_description')
        ?? intake_pluck($payload, 'short_description') ?? intake_pluck($payload, 'title');
    $severityRaw = intake_pluck($payload, $map['severity'] ?? 'priority')
        ?? intake_pluck($payload, 'priority') ?? intake_pluck($payload, 'severity');
    $summary = intake_pluck($payload, $map['summary'] ?? 'description') ?? intake_pluck($payload, 'description');
    $requestedBy = intake_pluck($payload, $map['requested_by'] ?? 'caller_id') ?? intake_pluck($payload, 'caller');

    $counters = ['received_count' => (int)$src['received_count'] + 1, 'last_seen_at' => date('Y-m-d H:i:s')];

    if (!$title) {
        update($conn, 'intake_sources', $counters + ['last_status' => 'rejected: no title'], 'id = ?', [(int)$src['id']]);
        intake_log($conn, $wsId, (int)$src['id'], $ref, 'rejected', null, 'No title in the payload', $payload);
        fail('The payload carries no title. Map one with field_map.title.', 422);
    }

    // A retry must not raise the incident twice.
    if ($ref) {
        $existing = row($conn, "SELECT id, ref FROM dbo.work_items WHERE workspace_id = ? AND external_ref = ?", [$wsId, (string)$ref]);
        if ($existing) {
            update($conn, 'intake_sources', $counters + ['last_status' => 'duplicate ' . $ref], 'id = ?', [(int)$src['id']]);
            intake_log($conn, $wsId, (int)$src['id'], $ref, 'duplicate', (int)$existing['id'], 'Already raised', $payload);
            ok(['outcome' => 'duplicate', 'ref' => $existing['ref'], 'work_item_id' => (int)$existing['id'],
                'note' => 'This incident was already raised; nothing was created.']);
        }
    }

    $severity = intake_severity($severityRaw, $sevMap);
    $threshold = $src['severity_threshold'];
    if ($threshold && $severity && (DP_SEVERITY_RANK[$severity] ?? 9) > (DP_SEVERITY_RANK[strtoupper($threshold)] ?? 9)) {
        update($conn, 'intake_sources', $counters + ['ignored_count' => (int)$src['ignored_count'] + 1, 'last_status' => "below $threshold"], 'id = ?', [(int)$src['id']]);
        intake_log($conn, $wsId, (int)$src['id'], $ref, 'below_threshold', null, "$severity is below the $threshold threshold", $payload);
        ok(['outcome' => 'below_threshold', 'severity' => $severity, 'threshold' => $threshold,
            'note' => 'Recorded and ignored: the team is only asked to carry incidents at or above the threshold.']);
    }

    // The work type: whatever the source names, else the workspace's interrupt-driven type.
    $type = $src['work_type_id']
        ? row($conn, "SELECT * FROM dbo.work_types WHERE id = ? AND workspace_id = ?", [(int)$src['work_type_id'], $wsId])
        : row($conn, "SELECT TOP 1 * FROM dbo.work_types WHERE workspace_id = ? AND policy = 'interrupt' AND retired = 0 ORDER BY sort_order", [$wsId]);
    if (!$type) {
        intake_log($conn, $wsId, (int)$src['id'], $ref, 'rejected', null, 'No interrupt-driven work type configured', $payload);
        fail('This workspace has no interrupt-driven work type to raise an incident as.', 409);
    }

    $itemRef = allocate_ref($conn, $wsId, $type['prefix']);
    $itemId = insert($conn, 'work_items', [
        'workspace_id' => $wsId, 'ref' => $itemRef, 'work_type_id' => (int)$type['id'],
        'title' => mb_substr((string)$title, 0, 200),
        'summary' => $summary !== null ? mb_substr((string)$summary, 0, 4000) : null,
        'status' => 'ready', 'severity' => $severity,
        'requested_by' => $requestedBy !== null ? mb_substr((string)$requestedBy, 0, 120) : $src['name'],
        'external_ref' => $ref !== null ? mb_substr((string)$ref, 0, 60) : null,
        'external_url' => intake_pluck($payload, $map['external_url'] ?? 'url'),
        'needed_by' => today(),
        'created_at' => date('Y-m-d H:i:s'), 'updated_at' => date('Y-m-d H:i:s'),
    ]);

    // Score it and let the planner know something urgent arrived. The urgent cycle is
    // started by the trigger path, exactly as it is for an incident typed in by hand.
    if (function_exists('compute_priority_for_item')) compute_priority_for_item($conn, $wsId, $itemId);
    $rota = scalar($conn, "SELECT TOP 1 person_id FROM dbo.incident_rota WHERE workspace_id = ? AND week_start <= ? ORDER BY week_start DESC", [$wsId, today()]);
    $scope = $src['default_person_id'] !== null ? [(int)$src['default_person_id']] : ($rota !== null ? [(int)$rota] : []);
    add_trigger($conn, $wsId, 'incident', 'urgent', "$itemRef raised from {$src['name']}" . ($severity ? " ($severity)" : ''), 'work_item', $itemId, $scope);

    $GLOBALS['userId'] = null; $GLOBALS['userName'] = $src['name'];
    audit($conn, $wsId, 'create', 'work_item', $itemId, null,
        ['ref' => $itemRef, 'title' => $title, 'severity' => $severity, 'source' => $src['system'], 'external_ref' => $ref],
        $itemRef, 'Raised by intake');
    update($conn, 'intake_sources', $counters + ['created_count' => (int)$src['created_count'] + 1, 'last_status' => "created $itemRef"], 'id = ?', [(int)$src['id']]);
    intake_log($conn, $wsId, (int)$src['id'], $ref, 'created', $itemId, "Raised as $itemRef", $payload);

    if (function_exists('start_urgent_cycle') && $scope) {
        try { start_urgent_cycle($conn, $wsId, $scope); } catch (Throwable $e) { /* intake must not fail on a replan */ }
    }
    ok(['outcome' => 'created', 'ref' => $itemRef, 'work_item_id' => $itemId, 'severity' => $severity]);
}

// ------------------------------------------------------------------------ managing sources
require_once __DIR__ . '/auth_middleware.php';
$action = param('action', 'list');
require_role('admin');

function intake_public(array $s) {
    return ['id' => (int)$s['id'], 'system' => $s['system'], 'name' => $s['name'],
        'work_type_id' => $s['work_type_id'] !== null ? (int)$s['work_type_id'] : null,
        'severity_threshold' => $s['severity_threshold'],
        'field_map' => json_col($s['field_map'], []), 'severity_map' => json_col($s['severity_map'], []),
        'default_person_id' => $s['default_person_id'] !== null ? (int)$s['default_person_id'] : null,
        'active' => (bool)$s['active'], 'created_at' => $s['created_at'], 'last_seen_at' => $s['last_seen_at'],
        'last_status' => $s['last_status'], 'received' => (int)$s['received_count'],
        'created_items' => (int)$s['created_count'], 'ignored' => (int)$s['ignored_count'],
        'secret_hint' => substr($s['secret'], 0, 4) . '…' . substr($s['secret'], -4)];
}

if ($action === 'list') {
    ok(['sources' => array_map('intake_public', rows($conn, "SELECT * FROM dbo.intake_sources WHERE workspace_id = ? ORDER BY id", [$wsId])),
        'recent' => rows($conn, "SELECT TOP 50 id, source_id, external_ref, outcome, work_item_id, detail, received_at FROM dbo.intake_log WHERE workspace_id = ? ORDER BY id DESC", [$wsId]),
        'how' => 'POST the incident as JSON to /api/intake.php?source=<id> with header X-Dispatch-Intake-Secret. Reposting the same external reference is answered 200 and creates nothing.',
        'severities' => array_keys(DP_SEVERITY_RANK)]);
}

if ($action === 'save') {
    $name = trim((string)require_param('name'));
    $system = param('system', 'servicenow');
    $threshold = param('severity_threshold');
    if ($threshold !== null && $threshold !== '' && !isset(DP_SEVERITY_RANK[strtoupper($threshold)])) fail('The threshold must be P1, P2, P3 or P4.', 422);
    $data = ['system' => $system, 'name' => mb_substr($name, 0, 120),
        'severity_threshold' => $threshold ? strtoupper($threshold) : null,
        'work_type_id' => param('work_type_id') !== null ? (int)param('work_type_id') : null,
        'default_person_id' => param('default_person_id') !== null ? (int)param('default_person_id') : null,
        'field_map' => param('field_map') !== null ? json_encode(param('field_map')) : null,
        'severity_map' => param('severity_map') !== null ? json_encode(param('severity_map')) : null,
        'active' => param('active', true) ? 1 : 0];
    $id = param('id') !== null ? (int)param('id') : null;
    if ($id) {
        $before = row($conn, "SELECT * FROM dbo.intake_sources WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
        if (!$before) fail('Unknown source', 404);
        update($conn, 'intake_sources', $data, 'id = ?', [$id]);
        $after = row($conn, "SELECT * FROM dbo.intake_sources WHERE id = ?", [$id]);
        audit($conn, $wsId, 'update', 'intake_source', $id, intake_public($before), intake_public($after), $name);
        ok(['source' => intake_public($after)]);
    }
    $secret = bin2hex(random_bytes(24));
    $newId = insert($conn, 'intake_sources', $data + ['workspace_id' => $wsId, 'secret' => $secret, 'created_by' => $userId]);
    $row = row($conn, "SELECT * FROM dbo.intake_sources WHERE id = ?", [$newId]);
    audit($conn, $wsId, 'create', 'intake_source', $newId, null, intake_public($row), $name);
    $base = ((!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http') . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost');
    ok(['source' => intake_public($row), 'secret' => $secret,
        'endpoint' => "$base/api/intake.php?source=$newId",
        'note' => 'Copy the secret now; it is stored for verification and never shown again.']);
}

if ($action === 'delete') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.intake_sources WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Unknown source', 404);
    q($conn, "DELETE FROM dbo.intake_log WHERE source_id = ?", [$id]);
    q($conn, "DELETE FROM dbo.intake_sources WHERE id = ?", [$id]);
    audit($conn, $wsId, 'delete', 'intake_source', $id, intake_public($s), null, $s['name']);
    ok();
}

if ($action === 'log') {
    ok(['entries' => rows($conn, "SELECT TOP 200 * FROM dbo.intake_log WHERE workspace_id = ? ORDER BY id DESC", [$wsId])]);
}

fail('Unknown action', 400);
