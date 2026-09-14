<?php
// Public REST API, version 1 (INT-07).
//
// The internal API is one PHP file per resource called with POST {"action": …}, which suits
// the client but is not a contract anyone else should have to code against. This is the
// public surface: resource paths under /v1, GET for reads, cursor pagination, RFC 9457
// problem details for errors, and an OpenAPI 3.1 document at /v1/openapi.yaml.
//
// It is read-only by design. Writing a plan is a deliberate act with guardrails and an
// approver behind it; a public integration that could move someone's week without going
// through a proposal would defeat the point of the product.
//
// Routed by router.php: /v1/<resource> arrives here with $_GET['_path'] set.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/items_lib.php';

$path = trim((string)($_GET['_path'] ?? ''), '/');
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$segments = $path === '' ? [] : explode('/', $path);

/** Event names the outbound webhooks use; advertised on the index for discoverability. */
const DP_V1_WEBHOOK_EVENTS = ['plan.committed' => 1, 'proposal.created' => 1, 'change.decided' => 1, 'workitem.statusChanged' => 1];


/** RFC 9457 problem details, as the contract promises. */
function problem($status, $title, $detail = null, $code = null) {
    http_response_code($status);
    header('Content-Type: application/problem+json; charset=utf-8');
    echo json_encode(array_filter([
        'type' => 'https://github.com/benhorris1988/Dispatch/blob/main/docs/openapi.yaml',
        'title' => $title, 'status' => $status, 'detail' => $detail, 'code' => $code,
    ], fn($v) => $v !== null), JSON_UNESCAPED_SLASHES);
    exit;
}

function v1_ok(array $data, array $page = []) {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($page ? $data + ['page' => $page] : $data, JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    exit;
}

/** Cursor pagination: an opaque cursor is just the last id seen. */
function v1_page($limit = null) {
    $limit = (int)($limit ?? param('limit', 50));
    return max(1, min(200, $limit));
}
function v1_cursor() {
    $c = param('cursor');
    if ($c === null || $c === '') return 0;
    $decoded = base64_decode((string)$c, true);
    return $decoded !== false && ctype_digit($decoded) ? (int)$decoded : 0;
}
function v1_next($rows, $limit) {
    if (count($rows) < $limit) return null;
    $last = end($rows);
    return isset($last['id']) ? base64_encode((string)(int)$last['id']) : null;
}

if ($method !== 'GET') problem(405, 'Method not allowed', 'The v1 API is read-only. Plans change through a reviewed proposal, not through an integration.', 'method_not_allowed');

// ---------------------------------------------------------------------------------------
if ($segments === [] || $segments === ['']) {
    v1_ok(['api' => 'Dispatch', 'version' => 'v1', 'workspace_id' => $wsId, 'read_only' => true,
        'openapi' => '/v1/openapi.yaml',
        'resources' => ['/v1/work-items', '/v1/work-items/{ref}', '/v1/people', '/v1/skills', '/v1/plan', '/v1/assignments', '/v1/proposals', '/v1/benefits', '/v1/estimates', '/v1/reports/stability'],
        'auth' => 'Authorization: Bearer <token>, the same token the app uses.',
        'webhooks' => array_keys(DP_V1_WEBHOOK_EVENTS)]);
}

if ($segments[0] === 'openapi.yaml') {
    $doc = __DIR__ . '/../docs/openapi.yaml';
    if (!file_exists($doc)) problem(404, 'Not found', 'The OpenAPI document is missing from this deployment.');
    header('Content-Type: application/yaml; charset=utf-8');
    readfile($doc);
    exit;
}

// ---------------------------------------------------------------------------------------
if ($segments[0] === 'work-items') {
    if (count($segments) === 1) {
        $limit = v1_page(); $after = v1_cursor();
        $where = ['wi.id > ?']; $params = [$after];
        if ($s = param('status')) { $where[] = 'wi.status = ?'; $params[] = $s; }
        if (($t = param('type')) !== null && $t !== '') { $where[] = 'wt.name = ?'; $params[] = $t; }
        if (($u = param('updated_since')) !== null && $u !== '') { $where[] = 'wi.updated_at >= ?'; $params[] = $u; }
        [$items] = work_item_rows($conn, $wsId, implode(' AND ', $where), $params, 'wi.id', $limit, 0);
        v1_ok(['work_items' => $items], ['limit' => $limit, 'next_cursor' => v1_next($items, $limit)]);
    }
    $ref = $segments[1];
    $wi = row($conn, "SELECT id FROM dbo.work_items WHERE workspace_id = ? AND ref = ?", [$wsId, $ref]);
    if (!$wi) problem(404, 'Not found', "No work item with reference $ref in this workspace.", 'work_item_not_found');
    [$rowsOut] = work_item_rows($conn, $wsId, 'wi.id = ?', [(int)$wi['id']], 'wi.id', 1, 0);
    v1_ok(['work_item' => $rowsOut[0] ?? null]);
}

if ($segments[0] === 'people') {
    $limit = v1_page(); $after = v1_cursor();
    $people = rows($conn, "SELECT TOP ($limit) p.id, p.name, p.initials, p.email, p.role_title, p.days_per_week, p.active, t.name AS team
        FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id
        WHERE p.workspace_id = ? AND p.id > ? ORDER BY p.id", [$wsId, $after]);
    v1_ok(['people' => $people], ['limit' => $limit, 'next_cursor' => v1_next($people, $limit)]);
}

if ($segments[0] === 'skills') {
    $skills = rows($conn, "SELECT id, name, category, description, retired FROM dbo.skills WHERE workspace_id = ? ORDER BY sort_order, name", [$wsId]);
    v1_ok(['skills' => $skills]);
}

if ($segments[0] === 'plan') {
    $pv = row($conn, "SELECT TOP 1 * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    if (!$pv) problem(404, 'Not found', 'No plan has been committed in this workspace yet.', 'no_committed_plan');
    v1_ok(['plan' => ['id' => (int)$pv['id'], 'version' => (int)$pv['version_no'], 'status' => $pv['status'],
        'committed_at' => $pv['committed_at'], 'committed_through' => $pv['committed_through'],
        'objective_score' => $pv['objective_score'], 'stability_cost_days' => $pv['stability_cost_days'],
        'assignments' => (int)scalar($conn, "SELECT COUNT(*) FROM dbo.assignments WHERE plan_version_id = ?", [(int)$pv['id']])]]);
}

if ($segments[0] === 'assignments') {
    $limit = v1_page(); $after = v1_cursor();
    // plan_version_id arrives from the caller, so it must be checked before it is used.
    // Filtering on it alone crossed the tenancy boundary — any id from any workspace would
    // have returned that workspace's assignments — and served drafts, because a proposed
    // version is not a plan anyone is working to. Only committed history is public here.
    if (param('plan_version_id') !== null && param('plan_version_id') !== '') {
        $pvId = (int)param('plan_version_id');
        $pv = row($conn, "SELECT id, status FROM dbo.plan_versions WHERE id = ? AND workspace_id = ?", [$pvId, $wsId]);
        if (!$pv) problem(404, 'Not found', "No plan version $pvId in this workspace.", 'plan_version_not_found');
        if (!in_array($pv['status'], ['committed', 'superseded'], true)) {
            problem(404, 'Not found', 'That plan version is a proposal or a scenario, not a plan anyone is working to. Only committed and superseded versions are readable here.', 'plan_version_not_public');
        }
    } else {
        $pvId = (int)(scalar($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]) ?? -1);
    }
    $where = ['a.plan_version_id = ?', 'a.id > ?']; $params = [$pvId, $after];
    if (($p = param('person_id')) !== null && $p !== '') { $where[] = 'a.person_id = ?'; $params[] = (int)$p; }
    if (($f = param('from')) !== null && $f !== '') { $where[] = 'a.to_date >= ?'; $params[] = $f; }
    if (($t = param('to')) !== null && $t !== '') { $where[] = 'a.from_date <= ?'; $params[] = $t; }
    // Belt and braces: scope the rows themselves to the workspace as well, so this query
    // cannot leak even if the guard above is ever refactored away.
    $where[] = 'wi.workspace_id = ?'; $params[] = $wsId;
    $out = rows($conn, "SELECT TOP ($limit) a.id, a.work_item_id, wi.ref, wi.title, a.person_id, pe.name AS person,
            a.from_date, a.to_date, a.allocation_pct, a.state, a.role_label
        FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.people pe ON pe.id = a.person_id
        WHERE " . implode(' AND ', $where) . " ORDER BY a.id", $params);
    v1_ok(['assignments' => $out, 'plan_version_id' => $pvId], ['limit' => $limit, 'next_cursor' => v1_next($out, $limit)]);
}

if ($segments[0] === 'proposals') {
    $limit = v1_page();
    $out = rows($conn, "SELECT TOP ($limit) id, kind, status, generated_at, improvement_pct, below_threshold, decided_at
        FROM dbo.proposals WHERE workspace_id = ? ORDER BY id DESC", [$wsId]);
    foreach ($out as &$p) $p['changes'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.change_proposals WHERE proposal_id = ?", [(int)$p['id']]);
    unset($p);
    v1_ok(['proposals' => $out]);
}

if ($segments[0] === 'benefits') {
    $limit = v1_page(); $after = v1_cursor();
    $out = rows($conn, "SELECT TOP ($limit) b.id, wi.ref, wi.title, b.type, b.annual_value, b.currency, b.confidence,
            b.realisation_from, b.status, b.realised_value, b.owner_name, b.is_financial, b.qualitative_scale, b.proxy_value
        FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id
        WHERE b.workspace_id = ? AND b.id > ? ORDER BY b.id", [$wsId, $after]);
    foreach ($out as &$b) { $b['is_financial'] = (bool)$b['is_financial']; $b['qualitative_scale'] = $b['qualitative_scale'] === null ? null : (int)$b['qualitative_scale']; }
    unset($b);
    v1_ok(['benefits' => $out], ['limit' => $limit, 'next_cursor' => v1_next($out, $limit)]);
}

if ($segments[0] === 'estimates') {
    $limit = v1_page();
    $out = rows($conn, "SELECT TOP ($limit) e.id, wi.ref, e.version, e.method, e.optimistic, e.likely, e.pessimistic,
            e.estimate_class, e.day_rate, e.author_name, e.created_at
        FROM dbo.estimates e JOIN dbo.work_items wi ON wi.id = e.work_item_id
        WHERE wi.workspace_id = ? ORDER BY e.id DESC", [$wsId]);
    v1_ok(['estimates' => $out]);
}

if ($segments[0] === 'reports' && ($segments[1] ?? '') === 'stability') {
    $out = rows($conn, "SELECT week_start, total_assignment_days, moved_assignment_days, changes_inside_freeze,
            planned_load_pct, actual_load_pct, note
        FROM dbo.stability_weeks WHERE workspace_id = ? ORDER BY week_start", [$wsId]);
    foreach ($out as &$w) {
        $tot = (float)$w['total_assignment_days'];
        $w['stability_index_pct'] = $tot > 0 ? round(100 * (1 - (float)$w['moved_assignment_days'] / $tot), 1) : null;
    }
    unset($w);
    v1_ok(['weeks' => $out, 'definition' => 'Plan stability index = 1 - (assignment-days changed inside the committed and planned windows / total assignment-days in those windows).']);
}

problem(404, 'Not found', "No resource at /v1/$path.", 'unknown_resource');
