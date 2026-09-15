<?php
// Campaigns: sandbox workspaces alongside the live one (ADM-07).
// Actions: list | create | switch | update | reset | delete
//
// A campaign is a place to try things — a reorganisation, a new intake of work, the app itself —
// without touching the plan people are working to. It is a real workspace, isolated by the same
// row-level scoping every query already applies, so nothing in a campaign can reach Live and
// nothing in Live can see it.
//
// Identity is the lower-cased email address. A person has one `users` row PER workspace, which is
// what keeps a role, a linked person, notification preferences and devices per workspace; switching
// re-issues a token for the target workspace rather than widening the one they hold.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/jwt_lib.php';
require_once __DIR__ . '/engine/workspace_clone.php';
$action = param('action', 'list');

/** The signed-in person's email, lower-cased: their identity across workspaces. */
function my_email($conn, $userId) {
    return strtolower((string)scalar($conn, "SELECT email FROM dbo.users WHERE id = ?", [$userId]));
}

/** The users row for this email in that workspace, or null. */
function member_row($conn, $wsId, $email) {
    return row($conn, "SELECT * FROM dbo.users WHERE workspace_id = ? AND LOWER(email) = ?", [$wsId, strtolower($email)]);
}

/**
 * May this person go into that workspace?
 *
 * A row there is the obvious yes. Beyond that, a campaign that is open to all lets any member of
 * its source workspace in — the point of a sandbox is that people can try it — and the creator can
 * always return to their own. Live is never joined this way: an account in Live exists because
 * somebody signed in with an identity the deployment accepts (ADM-01).
 */
function may_enter($conn, array $ws, $email, $homeWsId) {
    if (member_row($conn, (int)$ws['id'], $email)) return true;
    if (($ws['kind'] ?? 'live') !== 'campaign') return false;
    if (strcasecmp((string)($ws['created_by_email'] ?? ''), $email) === 0) return true;
    return (int)$ws['open_to_all'] === 1 && (int)($ws['source_workspace_id'] ?? 0) === (int)$homeWsId;
}

function campaign_shape($conn, array $ws, $email, $homeWsId, $myRole) {
    $member = member_row($conn, (int)$ws['id'], $email);
    $isCreator = strcasecmp((string)($ws['created_by_email'] ?? ''), $email) === 0;
    return [
        'id' => (int)$ws['id'], 'name' => $ws['name'], 'kind' => $ws['kind'] ?? 'live',
        'description' => $ws['description'] ?? null,
        'source_workspace_id' => isset($ws['source_workspace_id']) && $ws['source_workspace_id'] !== null ? (int)$ws['source_workspace_id'] : null,
        'source_name' => isset($ws['source_workspace_id']) && $ws['source_workspace_id'] !== null
            ? scalar($conn, "SELECT name FROM dbo.workspaces WHERE id = ?", [(int)$ws['source_workspace_id']]) : null,
        'seeded_from' => $ws['seeded_from'] ?? null,
        'open_to_all' => (int)($ws['open_to_all'] ?? 1) === 1,
        'created_by_email' => $ws['created_by_email'] ?? null,
        'created_at' => $ws['created_at'],
        'member' => $member !== null,
        'my_role' => $member ? $member['role'] : null,
        'people_count' => (int)scalar($conn, "SELECT COUNT(*) FROM dbo.people WHERE workspace_id = ? AND active = 1", [(int)$ws['id']]),
        'items_count' => (int)scalar($conn, "SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id = ?", [(int)$ws['id']]),
        // Only a campaign can be reset or deleted, and only by whoever made it or an administrator of Live.
        'can_reset' => ($ws['kind'] ?? 'live') === 'campaign' && ($isCreator || $myRole === 'admin'),
        'can_delete' => ($ws['kind'] ?? 'live') === 'campaign' && ($isCreator || $myRole === 'admin'),
        'is_current' => (int)$ws['id'] === (int)$GLOBALS['wsId'],
    ];
}

/** Find or create this person's account in the target workspace, then issue a token for it. */
function enter_workspace($conn, array $ws, $email, array $me) {
    $target = (int)$ws['id'];
    $u = member_row($conn, $target, $email);
    if ($u && !(int)$u['active']) fail('Your account in ' . $ws['name'] . ' has been deactivated', 403);
    if (!$u) {
        // Joining an open campaign: carry the role held in the workspace being left, and link to a
        // person there with the same work address, exactly as first sign-in does (auth.php).
        $personId = scalar($conn, "SELECT id FROM dbo.people WHERE workspace_id = ? AND LOWER(email) = ? AND active = 1", [$target, $email]);
        $id = insert($conn, 'users', [
            'workspace_id' => $target, 'email' => $email,
            'display_name' => $me['display_name'], 'short_name' => $me['short_name'],
            'role' => $me['role'], 'person_id' => $personId !== null ? (int)$personId : null,
            'auth_provider' => $me['auth_provider'] ?? 'campaign', 'active' => 1,
        ]);
        $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$id]);
        audit($conn, $target, 'create', 'user', $id, null, ['email' => $email, 'role' => $u['role'], 'joined' => 'campaign'], $u['display_name'], 'Joined an open campaign');
    }
    return $u;
}

function user_payload($conn, array $u) {
    $p = $u['person_id'] ? row($conn, "SELECT id, name, initials, colour, role_title, team_id FROM dbo.people WHERE id = ?", [$u['person_id']]) : null;
    $ws = row($conn, "SELECT id, name, time_zone, working_days, hours_per_day, currency, kind, description, source_workspace_id, seeded_from FROM dbo.workspaces WHERE id = ?", [$u['workspace_id']]);
    return ['id' => (int)$u['id'], 'email' => $u['email'], 'display_name' => $u['display_name'], 'short_name' => $u['short_name'],
        'role' => $u['role'], 'auth_provider' => $u['auth_provider'] ?? null,
        'person_id' => $u['person_id'] !== null ? (int)$u['person_id'] : null, 'person' => $p, 'workspace' => $ws];
}

// ---------------------------------------------------------------------------------------------
$email = my_email($conn, $userId);
$me = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$userId]);

if ($action === 'list') {
    $out = [];
    foreach (rows($conn, "SELECT * FROM dbo.workspaces ORDER BY CASE WHEN kind = 'live' THEN 0 ELSE 1 END, name") as $ws) {
        if (!may_enter($conn, $ws, $email, $wsId)) continue;
        $out[] = campaign_shape($conn, $ws, $email, $wsId, $role);
    }
    $current = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]);
    ok([
        'current' => campaign_shape($conn, $current, $email, $wsId, $role),
        'workspaces' => $out,
        'can_create' => has_role('delivery_lead'),
        'note' => 'A campaign is a sandbox: a real workspace of its own, isolated from the live plan.',
    ]);
}

if ($action === 'create') {
    // Making a copy of a workspace means reading all of it, so it takes the same rank as committing
    // the plan. Inside a campaign anybody who is an administrator there may make another.
    require_role('delivery_lead');
    $name = mb_substr(trim((string)require_param('name')), 0, 120);
    if ($name === '') fail('Give the campaign a name', 400);
    $mode = (string)param('mode', 'full');
    if (!in_array($mode, ['full', 'config', 'demo'], true)) fail("mode must be full, config or demo", 400);
    $srcId = param('source_workspace_id') ? (int)param('source_workspace_id') : $wsId;
    $src = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$srcId]);
    if (!$src) fail('Workspace to copy not found', 404);
    if (!may_enter($conn, $src, $email, $wsId)) fail('You cannot copy a workspace you are not in', 403);
    if (scalar($conn, "SELECT TOP 1 id FROM dbo.workspaces WHERE name = ?", [$name]) !== null) fail('A workspace called ' . $name . ' already exists', 409);

    $opts = ['name' => $name, 'description' => param('description') ? mb_substr(trim((string)param('description')), 0, 300) : null,
        'mode' => $mode, 'creator_email' => $email, 'creator_name' => $me['display_name'],
        'open_to_all' => param('open_to_all') === null ? true : (bool)param('open_to_all')];

    if ($mode === 'demo') {
        // A demo campaign copies nothing: it gets the same dataset the tests run against.
        $newId = insert($conn, 'workspaces', ['name' => $name, 'time_zone' => $src['time_zone'], 'working_days' => $src['working_days'],
            'hours_per_day' => $src['hours_per_day'], 'currency' => $src['currency'], 'kind' => 'campaign',
            'description' => $opts['description'], 'source_workspace_id' => null, 'seeded_from' => 'demo',
            'open_to_all' => $opts['open_to_all'] ? 1 : 0, 'created_by_email' => $email]);
        seed_demo_into($conn, $newId);
        // The seed builds its own accounts; make sure the person who asked for it can get in as an admin.
        $mine = member_row($conn, $newId, $email);
        if ($mine) update($conn, 'users', ['role' => 'admin'], 'id = ?', [(int)$mine['id']]);
        else insert($conn, 'users', ['workspace_id' => $newId, 'email' => $email, 'display_name' => $me['display_name'],
            'short_name' => $me['short_name'], 'role' => 'admin', 'active' => 1, 'auth_provider' => 'campaign']);
    } else {
        $newId = clone_workspace($conn, $srcId, $opts);
    }

    $ws = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$newId]);
    $u = member_row($conn, $newId, $email);
    audit($conn, $wsId, 'create', 'workspace', $newId, null, ['name' => $name, 'mode' => $mode, 'source_workspace_id' => $mode === 'demo' ? null : $srcId], $name);
    audit($conn, $newId, 'create', 'workspace', $newId, null, ['name' => $name, 'mode' => $mode, 'created_by' => $email], $name, 'Campaign created');
    ok(['workspace' => campaign_shape($conn, $ws, $email, $wsId, $role),
        'token' => $u ? issue_token($u) : null, 'user' => $u ? user_payload($conn, $u) : null]);
}

if ($action === 'switch') {
    $target = (int)require_param('workspace_id');
    $ws = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$target]);
    if (!$ws) fail('Workspace not found', 404);
    if ($target === $wsId) ok(['token' => null, 'user' => user_payload($conn, $me), 'workspace' => campaign_shape($conn, $ws, $email, $wsId, $role), 'already_here' => true]);
    if (!may_enter($conn, $ws, $email, $wsId)) fail('You are not a member of ' . $ws['name'] . ', and it is not open to join', 403);
    $u = enter_workspace($conn, $ws, $email, $me);
    audit($conn, $target, 'update', 'user', (int)$u['id'], null, ['switched_from_workspace' => $wsId], $u['display_name'], 'Switched workspace');
    ok(['token' => issue_token($u), 'user' => user_payload($conn, $u), 'workspace' => campaign_shape($conn, $ws, $email, $target, $u['role'])]);
}

if ($action === 'update' || $action === 'reset' || $action === 'delete') {
    $target = (int)require_param('workspace_id');
    $ws = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$target]);
    if (!$ws) fail('Workspace not found', 404);
    if (($ws['kind'] ?? 'live') !== 'campaign') fail('The live workspace cannot be reset, renamed away or deleted here', 409, ['kind' => $ws['kind'] ?? 'live']);
    $isCreator = strcasecmp((string)($ws['created_by_email'] ?? ''), $email) === 0;
    $mine = member_row($conn, $target, $email);
    $adminThere = $mine && $mine['role'] === 'admin';
    if (!$isCreator && !$adminThere && !has_role('admin')) fail('Only whoever created this campaign, or an administrator, can change it', 403);

    if ($action === 'update') {
        $data = [];
        if (param('name') !== null) $data['name'] = mb_substr(trim((string)param('name')), 0, 120);
        if (param('description') !== null) $data['description'] = mb_substr(trim((string)param('description')), 0, 300) ?: null;
        if (param('open_to_all') !== null) $data['open_to_all'] = param('open_to_all') ? 1 : 0;
        if ($data) update($conn, 'workspaces', $data, 'id = ?', [$target]);
        $after = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$target]);
        audit($conn, $target, 'config', 'workspace', $target, $ws, $after, $after['name']);
        ok(['workspace' => campaign_shape($conn, $after, $email, $wsId, $role)]);
    }

    if ($action === 'reset') {
        // Emptying and refilling it in place keeps the id, so links and the token people hold stay good.
        $mode = $ws['seeded_from'] ?: 'full';
        $srcId = $ws['source_workspace_id'] !== null ? (int)$ws['source_workspace_id'] : null;
        if ($mode !== 'demo' && ($srcId === null || !row($conn, "SELECT id FROM dbo.workspaces WHERE id = ?", [$srcId]))) {
            fail('The workspace this campaign was copied from no longer exists, so it cannot be reset', 409);
        }
        $keep = ['name' => $ws['name'], 'description' => $ws['description'], 'open_to_all' => $ws['open_to_all'], 'created_by_email' => $ws['created_by_email']];
        delete_workspace_contents($conn, $target, true);
        if ($mode === 'demo') {
            seed_demo_into($conn, $target);
        } else {
            $freshId = clone_workspace($conn, $srcId, ['name' => $keep['name'] . ' (rebuilding)', 'mode' => $mode, 'creator_email' => $email, 'creator_name' => $me['display_name']]);
            move_workspace_contents($conn, $freshId, $target);
            q($conn, "DELETE FROM dbo.workspaces WHERE id = ?", [$freshId]);
        }
        update($conn, 'workspaces', $keep + ['kind' => 'campaign', 'seeded_from' => $mode, 'source_workspace_id' => $srcId], 'id = ?', [$target]);
        // Whoever asked for the reset must still be able to get back in.
        if (!member_row($conn, $target, $email)) {
            insert($conn, 'users', ['workspace_id' => $target, 'email' => $email, 'display_name' => $me['display_name'],
                'short_name' => $me['short_name'], 'role' => 'admin', 'active' => 1, 'auth_provider' => 'campaign']);
        } else {
            update($conn, 'users', ['role' => 'admin'], 'workspace_id = ? AND LOWER(email) = ?', [$target, $email]);
        }
        $after = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$target]);
        audit($conn, $target, 'update', 'workspace', $target, null, ['reset_from' => $mode, 'source_workspace_id' => $srcId], $after['name'], 'Campaign reset');
        $u = member_row($conn, $target, $email);
        ok(['workspace' => campaign_shape($conn, $after, $email, $wsId, $role), 'token' => $u ? issue_token($u) : null]);
    }

    // delete
    $name = $ws['name'];
    audit($conn, $wsId, 'delete', 'workspace', $target, ['name' => $name, 'kind' => 'campaign'], null, $name, param('reason'));
    delete_workspace_contents($conn, $target);
    ok(['deleted' => true, 'name' => $name,
        'switch_to' => $target === $wsId ? (int)scalar($conn, "SELECT TOP 1 id FROM dbo.workspaces WHERE kind = 'live' ORDER BY id") : null]);
}

fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------
/**
 * Re-point every row of one workspace at another, so a reset can rebuild in place.
 *
 * A campaign's id is in the token people hold and in every link they have shared, so a reset that
 * handed back a new id would break both. Building the replacement in a scratch workspace and then
 * moving its rows keeps the id stable; the scratch row is deleted after.
 */
function move_workspace_contents($conn, $fromWsId, $toWsId) {
    $tables = ['work_types', 'size_classes', 'scheduling_policies', 'teams', 'people', 'skills', 'availability', 'incident_rota',
        'capacity_days', 'work_items', 'ref_sequences', 'dependencies', 'day_rates', 'benefits', 'plan_versions',
        'proposals', 'change_proposals', 'replan_triggers', 'notifications', 'item_comments', 'stability_weeks',
        'person_change_log', 'integrations', 'person_loans', 'role_families', 'public_holidays', 'resource_requests', 'users'];
    foreach ($tables as $t) {
        if (scalar($conn, "SELECT OBJECT_ID('dbo.$t')") === null) continue;
        q($conn, "UPDATE dbo.$t SET workspace_id = ? WHERE workspace_id = ?", [$toWsId, $fromWsId]);
    }
}
