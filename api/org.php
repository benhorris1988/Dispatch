<?php
// The organisation chart (ORG-01..05). Actions:
//   tree (everyone)
//   save_team | move_team | move_person | set_manager | set_visibility | delete_team
//
// Authority (ORG-05) is hierarchical, not a flat role check: a delivery lead or administrator may
// change anything, a team lead may change the team they lead and everything beneath it. Moving a team
// or a person touches two places in the tree, so both ends are checked — you cannot push your own
// sub-team into somebody else's branch, and you cannot pull one out of it.
//
// Visibility (ORG-04): everything is visible to everyone unless a team has been restricted with a
// stated reason, in which case outsiders see the team's name and where it sits but not its people or
// its sub-tree. The name stays visible on purpose — a hole in the chart is worse than a closed door.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
$action = param('action', 'tree');
$today = today();

/** Every active person, keyed by id, with the joins the chart needs. */
function org_people($conn, $wsId) {
    static $cache = null;
    if ($cache !== null) return $cache;
    $cache = [];
    foreach (rows($conn, "SELECT p.id, p.name, p.initials, p.colour, p.role_title, p.team_id, p.manager_person_id, p.role_family_id, p.active,
                                 m.name AS manager_name, rf.name AS role_family_name
                          FROM dbo.people p LEFT JOIN dbo.people m ON m.id = p.manager_person_id
                          LEFT JOIN dbo.role_families rf ON rf.id = p.role_family_id
                          WHERE p.workspace_id = ? AND p.active = 1 ORDER BY p.name", [$wsId]) as $p) {
        $cache[(int)$p['id']] = $p;
    }
    return $cache;
}

function org_person_shape(array $p, array $loadByPerson, array $loansToday, array $leadIds) {
    $id = (int)$p['id'];
    return ['id' => $id, 'name' => $p['name'], 'initials' => $p['initials'] !== null ? trim((string)$p['initials']) : null,
        'colour' => $p['colour'], 'role_title' => $p['role_title'],
        'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null,
        'manager_person_id' => $p['manager_person_id'] !== null ? (int)$p['manager_person_id'] : null,
        'manager_name' => $p['manager_name'],
        'role_family_id' => $p['role_family_id'] !== null ? (int)$p['role_family_id'] : null,
        'role_family_name' => $p['role_family_name'],
        'load_pct' => $loadByPerson[$id]['load_pct'] ?? 0,
        'is_lead' => in_array($id, $leadIds, true),
        'active' => true,
        'on_loan_to' => $loansToday[$id] ?? null];
}

// ---------------------------------------------------------------------------------------------------
if ($action === 'tree') {
    $from = $today; $to = date('Y-m-d', strtotime("$today +27 days"));
    $c = team_closure($conn, $wsId);
    $people = org_people($conn, $wsId);
    $load = team_load($conn, $wsId, null, $from, $to);           // whole workspace: share 1 for everyone
    $loadByPerson = $load['people'];
    $editable = editable_team_ids($conn, $wsId);
    $canEditAll = $editable === '*';

    $loansToday = [];
    foreach (loans_in_window($conn, $wsId, $today, $today) as $l) {
        $loansToday[$l['person_id']] = ['to_team_id' => $l['to_team_id'], 'to_team_name' => $l['to_team_name'], 'to_date' => $l['to_date'], 'allocation_pct' => $l['allocation_pct']];
    }
    $byTeam = [];
    foreach ($people as $p) if ($p['team_id'] !== null) $byTeam[(int)$p['team_id']][] = $p;
    $leadIds = array_values(array_filter(array_map(fn($t) => $t['lead_person_id'], $c['teams'])));

    $node = function ($id) use (&$node, $conn, $wsId, $c, $byTeam, $loadByPerson, $loansToday, $leadIds, $canEditAll, $editable, $role, $personId, $from, $to) {
        $t = $c['teams'][$id];
        if (!team_visible_to($conn, $wsId, $id, $role, $personId)) {
            // A restricted branch: enough to draw the box and its place in the tree, nothing more.
            return ['id' => $id, 'name' => $t['name'], 'parent_team_id' => $t['parent_team_id'], 'sort_order' => $t['sort_order'],
                'restricted' => true, 'visibility' => 'restricted', 'can_edit' => false, 'children' => [], 'people' => []];
        }
        $mine = $byTeam[$id] ?? [];
        $subtree = team_descendants($conn, $wsId, $id);
        $headcountAll = 0;
        foreach ($subtree as $sid) $headcountAll += count($byTeam[$sid] ?? []);
        $sub = team_load($conn, $wsId, $subtree, $from, $to);
        $children = [];
        foreach ($c['children'][(string)$id] ?? [] as $kid) $children[] = $node($kid);
        return [
            'id' => $id, 'name' => $t['name'], 'parent_team_id' => $t['parent_team_id'], 'sort_order' => $t['sort_order'],
            'description' => $t['description'], 'visibility' => $t['visibility'], 'visibility_reason' => $t['visibility_reason'],
            'directory_object_id' => $t['directory_object_id'], 'restricted' => false,
            'lead_person_id' => $t['lead_person_id'],
            'lead' => org_lead_shape($conn, $wsId, $t['lead_person_id']),
            'headcount' => count($mine), 'headcount_all' => $headcountAll,
            'load_pct' => $sub['load_pct'], 'available_hours' => $sub['available_hours'], 'assigned_hours' => $sub['assigned_hours'],
            'can_edit' => $canEditAll || in_array($id, (array)$editable, true),
            'people' => array_map(fn($p) => org_person_shape($p, $loadByPerson, $loansToday, $leadIds), $mine),
            'children' => $children,
        ];
    };
    $teams = [];
    foreach ($c['roots'] as $rootId) $teams[] = $node($rootId);

    $unassigned = [];
    foreach ($people as $p) if ($p['team_id'] === null) $unassigned[] = org_person_shape($p, $loadByPerson, $loansToday, $leadIds);
    $families = [];
    foreach (rows($conn, "SELECT id, name, description FROM dbo.role_families WHERE workspace_id = ? ORDER BY name", [$wsId]) as $f)
        $families[] = ['id' => (int)$f['id'], 'name' => $f['name'], 'description' => $f['description']];

    ok(['teams' => $teams, 'unassigned_people' => $unassigned, 'role_families' => $families,
        'can_edit_team_ids' => $canEditAll ? '*' : array_values((array)$editable),
        'window' => ['from' => $from, 'to' => $to],
        'definitions' => ['headcount' => 'People whose home team is this one.',
            'headcount_all' => 'People in this team and every team beneath it.',
            'load_pct' => 'Committed assignment hours ÷ available hours over the next four weeks for the whole sub-tree, each person weighted by the share of their time that belongs to it (loans).',
            'restricted' => 'A team an administrator or its lead has restricted for a stated reason. Everyone still sees that it exists and where it sits; only the lead chain and the people inside it see its members.']]);
}

function org_lead_shape($conn, $wsId, $leadId) {
    if ($leadId === null) return null;
    $p = row($conn, "SELECT id, name, initials, colour, role_title FROM dbo.people WHERE id = ? AND workspace_id = ?", [(int)$leadId, $wsId]);
    if (!$p) return null;
    return ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => $p['initials'] !== null ? trim((string)$p['initials']) : null,
        'colour' => $p['colour'], 'role_title' => $p['role_title']];
}

/** One team as a mutation returns it: no children, no people. */
function team_shape($conn, $wsId, $id) {
    $t = team_node($conn, $wsId, $id);
    if (!$t) fail('Team not found', 404);
    return ['id' => (int)$t['id'], 'name' => $t['name'], 'parent_team_id' => $t['parent_team_id'], 'sort_order' => $t['sort_order'],
        'description' => $t['description'], 'visibility' => $t['visibility'], 'visibility_reason' => $t['visibility_reason'],
        'directory_object_id' => $t['directory_object_id'], 'lead_person_id' => $t['lead_person_id'],
        'lead' => org_lead_shape($conn, $wsId, $t['lead_person_id']), 'path' => team_path($conn, $wsId, $id)];
}

/**
 * Siblings renumbered 0..n with $teamId sitting at $position (null position = last). Pass $teamId null
 * to close the gap left behind when a team moves away or is deleted. Returns the new order.
 */
function resort_siblings($conn, $wsId, $parentId, $teamId = null, $position = null) {
    $ids = array_values(array_filter(team_children($conn, $wsId, $parentId), fn($i) => $teamId === null || $i !== (int)$teamId));
    if ($teamId !== null) {
        $position = $position === null ? count($ids) : max(0, min(count($ids), (int)$position));
        array_splice($ids, $position, 0, [(int)$teamId]);
    }
    $out = [];
    foreach ($ids as $i => $id) {
        update($conn, 'teams', ['sort_order' => $i], 'id = ? AND workspace_id = ?', [$id, $wsId]);
        $out[] = ['id' => $id, 'sort_order' => $i];
    }
    team_closure($conn, $wsId, true);
    return $out;
}

// ---- mutations ------------------------------------------------------------------------------------
if ($action === 'save_team') {
    $id = param('id') !== null && param('id') !== '' ? (int)param('id') : null;
    $before = $id !== null ? team_node($conn, $wsId, $id) : null;
    if ($id !== null && !$before) fail('Team not found', 404);
    $b = body();
    $parentGiven = array_key_exists('parent_team_id', $b);
    $parentId = $parentGiven && $b['parent_team_id'] !== null && $b['parent_team_id'] !== '' ? (int)$b['parent_team_id'] : null;
    if ($parentGiven && $parentId !== null && !team_node($conn, $wsId, $parentId)) fail('Parent team not found', 404);

    if ($id === null) require_team_authority($conn, $wsId, $parentId);
    else {
        require_team_authority($conn, $wsId, $id);
        if ($parentGiven && $parentId !== $before['parent_team_id']) {
            if (team_is_within($conn, $wsId, $parentId, $id)) fail('A team cannot sit inside itself or one of its own sub-teams', 409);
            require_team_authority($conn, $wsId, $parentId);
        }
    }

    $data = [];
    if (param('name') !== null) { $data['name'] = mb_substr(trim((string)param('name')), 0, 80); if ($data['name'] === '') fail('name is required', 422); }
    if (array_key_exists('description', $b)) $data['description'] = $b['description'] !== null ? mb_substr(trim((string)$b['description']), 0, 300) : null;
    if (array_key_exists('lead_person_id', $b)) {
        $lead = $b['lead_person_id'];
        if ($lead !== null && $lead !== '') {
            $lp = row($conn, "SELECT id, active, name FROM dbo.people WHERE id = ? AND workspace_id = ?", [(int)$lead, $wsId]);
            if (!$lp) fail('Lead person not found', 404);
            if (!(int)$lp['active']) fail("{$lp['name']} is no longer active and cannot lead a team", 409);
            $data['lead_person_id'] = (int)$lead;
        } else $data['lead_person_id'] = null;
    }
    if (array_key_exists('directory_object_id', $b)) $data['directory_object_id'] = $b['directory_object_id'] !== null && $b['directory_object_id'] !== '' ? mb_substr(trim((string)$b['directory_object_id']), 0, 64) : null;
    if ($parentGiven) $data['parent_team_id'] = $parentId;

    // Names must be unique among siblings: two 'Platform engineering' teams under one parent would be
    // indistinguishable on the chart. The same name in a different branch is fine and often right.
    $checkName = $data['name'] ?? ($before['name'] ?? null);
    $checkParent = $parentGiven ? $parentId : ($before['parent_team_id'] ?? null);
    if ($checkName !== null) {
        $dup = scalar($conn, "SELECT id FROM dbo.teams WHERE workspace_id = ? AND name = ? AND id <> ? AND " . ($checkParent === null ? "parent_team_id IS NULL" : "parent_team_id = ?"),
            $checkParent === null ? [$wsId, $checkName, $id ?? -1] : [$wsId, $checkName, $id ?? -1, $checkParent]);
        if ($dup !== null) fail("A team called $checkName already sits there", 409, ['existing_id' => (int)$dup]);
    }

    if ($id !== null) update($conn, 'teams', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    else {
        if (empty($data['name'])) fail('name is required', 422);
        $data['workspace_id'] = $wsId;
        $data['sort_order'] = count(team_children($conn, $wsId, $parentId));
        $id = insert($conn, 'teams', $data);
    }
    team_closure($conn, $wsId, true);
    $after = team_shape($conn, $wsId, $id);
    audit($conn, $wsId, $before ? 'update' : 'create', 'team', $id,
        $before ? ['id' => (int)$before['id'], 'name' => $before['name'], 'parent_team_id' => $before['parent_team_id'], 'lead_person_id' => $before['lead_person_id'], 'description' => $before['description']] : null,
        $after, $after['path']);
    ok(['team' => $after]);
}

if ($action === 'move_team') {
    $teamId = (int)require_param('team_id');
    $t = team_node($conn, $wsId, $teamId);
    if (!$t) fail('Team not found', 404);
    $b = body();
    $parentId = array_key_exists('parent_team_id', $b) && $b['parent_team_id'] !== null && $b['parent_team_id'] !== '' ? (int)$b['parent_team_id'] : null;
    if ($parentId !== null && !team_node($conn, $wsId, $parentId)) fail('Parent team not found', 404);
    if (team_is_within($conn, $wsId, $parentId, $teamId)) fail("{$t['name']} cannot be moved inside itself or one of its own sub-teams", 409);
    require_team_authority($conn, $wsId, $teamId);
    if ($parentId !== $t['parent_team_id']) require_team_authority($conn, $wsId, $parentId);

    $oldParent = $t['parent_team_id'];
    $oldPath = team_path($conn, $wsId, $teamId);
    update($conn, 'teams', ['parent_team_id' => $parentId], 'id = ? AND workspace_id = ?', [$teamId, $wsId]);
    team_closure($conn, $wsId, true);
    $siblings = resort_siblings($conn, $wsId, $parentId, $teamId, param('sort_order'));
    if ($oldParent !== $parentId) resort_siblings($conn, $wsId, $oldParent);
    $after = team_shape($conn, $wsId, $teamId);
    audit($conn, $wsId, 'update', 'team', $teamId,
        ['parent_team_id' => $oldParent, 'path' => $oldPath], ['parent_team_id' => $parentId, 'path' => $after['path']],
        "{$t['name']}: $oldPath to {$after['path']}", param('reason') ?: 'Moved on the organisation chart');
    ok(['team' => $after, 'siblings' => $siblings]);
}

if ($action === 'move_person') {
    $pid = (int)require_param('person_id');
    $p = row($conn, "SELECT * FROM dbo.people WHERE id = ? AND workspace_id = ?", [$pid, $wsId]);
    if (!$p) fail('Person not found', 404);
    $b = body();
    $teamId = array_key_exists('team_id', $b) && $b['team_id'] !== null && $b['team_id'] !== '' ? (int)$b['team_id'] : null;
    require_team_authority($conn, $wsId, $p['team_id'] !== null ? (int)$p['team_id'] : null);
    require_team_authority($conn, $wsId, $teamId);
    $r = move_person_home_team($conn, $wsId, $p, $teamId, param('reason'), (bool)param('force', false));
    if (array_key_exists('manager_person_id', $b)) {
        $mid = validate_manager($conn, $wsId, $pid, $b['manager_person_id']);
        update($conn, 'people', ['manager_person_id' => $mid], 'id = ? AND workspace_id = ?', [$pid, $wsId]);
        audit($conn, $wsId, 'update', 'person', $pid, ['manager_person_id' => $p['manager_person_id'] !== null ? (int)$p['manager_person_id'] : null],
            ['manager_person_id' => $mid], $p['name'], 'Reporting line changed with the team move');
    }
    $fresh = row($conn, "SELECT p.*, t.name AS team_name, m.name AS manager_name, rf.name AS role_family_name
                         FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id LEFT JOIN dbo.people m ON m.id = p.manager_person_id
                         LEFT JOIN dbo.role_families rf ON rf.id = p.role_family_id WHERE p.id = ?", [$pid]);
    ok(['person' => person_shape($fresh), 'loans_ended' => $r['loans_ended']]);
}

if ($action === 'set_manager') {
    $pid = (int)require_param('person_id');
    $p = row($conn, "SELECT p.*, m.name AS manager_name FROM dbo.people p LEFT JOIN dbo.people m ON m.id = p.manager_person_id WHERE p.id = ? AND p.workspace_id = ?", [$pid, $wsId]);
    if (!$p) fail('Person not found', 404);
    // Somebody with no team is not inside anyone's branch; a team lead may still set their manager.
    if ($p['team_id'] !== null) require_team_authority($conn, $wsId, (int)$p['team_id']);
    else require_role('team_lead');
    $mid = validate_manager($conn, $wsId, $pid, param('manager_person_id'));
    $before = ['manager_person_id' => $p['manager_person_id'] !== null ? (int)$p['manager_person_id'] : null, 'manager_name' => $p['manager_name']];
    update($conn, 'people', ['manager_person_id' => $mid], 'id = ? AND workspace_id = ?', [$pid, $wsId]);
    $newName = $mid !== null ? person_display_name($conn, $wsId, $mid) : null;
    audit($conn, $wsId, 'update', 'person', $pid, $before, ['manager_person_id' => $mid, 'manager_name' => $newName],
        "{$p['name']} reports to " . ($newName ?? 'nobody'), param('reason') ?: 'Reporting line changed on the organisation chart');
    $fresh = row($conn, "SELECT p.*, t.name AS team_name, m.name AS manager_name, rf.name AS role_family_name
                         FROM dbo.people p LEFT JOIN dbo.teams t ON t.id = p.team_id LEFT JOIN dbo.people m ON m.id = p.manager_person_id
                         LEFT JOIN dbo.role_families rf ON rf.id = p.role_family_id WHERE p.id = ?", [$pid]);
    ok(['person' => person_shape($fresh)]);
}

if ($action === 'set_visibility') {
    $teamId = (int)require_param('team_id');
    $t = team_node($conn, $wsId, $teamId);
    if (!$t) fail('Team not found', 404);
    require_team_authority($conn, $wsId, $teamId);
    $visibility = (string)require_param('visibility');
    if (!in_array($visibility, ['everyone', 'restricted'], true)) fail("visibility must be 'everyone' or 'restricted'", 400);
    $reason = param('reason') !== null ? trim((string)param('reason')) : '';
    // ORG-04/ADM-05: hiding part of the organisation from colleagues needs a reason on the record, and
    // it is a reason about the work — a reorganisation not yet announced — never about a person.
    if ($visibility === 'restricted' && $reason === '') fail('A reason is required to restrict a team', 422);
    $data = ['visibility' => $visibility, 'visibility_reason' => $visibility === 'restricted' ? mb_substr($reason, 0, 300) : null];
    update($conn, 'teams', $data, 'id = ? AND workspace_id = ?', [$teamId, $wsId]);
    team_closure($conn, $wsId, true);
    audit($conn, $wsId, 'update', 'team', $teamId,
        ['visibility' => $t['visibility'], 'visibility_reason' => $t['visibility_reason']], $data,
        $t['name'] . ($visibility === 'restricted' ? ' restricted' : ' visible to everyone'), $visibility === 'restricted' ? $data['visibility_reason'] : 'Restriction lifted');
    ok(['team' => team_shape($conn, $wsId, $teamId)]);
}

if ($action === 'delete_team') {
    $teamId = (int)require_param('team_id');
    $t = team_node($conn, $wsId, $teamId);
    if (!$t) fail('Team not found', 404);
    require_team_authority($conn, $wsId, $teamId);
    $children = team_children($conn, $wsId, $teamId);
    $people = rows($conn, "SELECT id, name, initials, colour, role_title, team_id FROM dbo.people WHERE workspace_id = ? AND team_id = ? ORDER BY name", [$wsId, $teamId]);
    $loans = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.person_loans WHERE workspace_id = ? AND (from_team_id = ? OR to_team_id = ?)", [$wsId, $teamId, $teamId]);
    if ($children || $people || $loans) {
        $why = [];
        if ($children) $why[] = count($children) . ' sub-team' . (count($children) === 1 ? '' : 's');
        if ($people) $why[] = count($people) . ' ' . (count($people) === 1 ? 'person' : 'people');
        if ($loans) $why[] = $loans . ' loan' . ($loans === 1 ? '' : 's') . ' in its history';
        fail("{$t['name']} still has " . implode(' and ', $why) . '; move them first', 409, [
            'children' => array_map(fn($id) => ['id' => $id, 'name' => team_node($conn, $wsId, $id)['name']], $children),
            'people' => array_map(fn($p) => ['id' => (int)$p['id'], 'name' => $p['name']], $people),
            'loans' => $loans]);
    }
    $before = team_shape($conn, $wsId, $teamId);
    q($conn, "DELETE FROM dbo.teams WHERE id = ? AND workspace_id = ?", [$teamId, $wsId]);
    team_closure($conn, $wsId, true);
    resort_siblings($conn, $wsId, $t['parent_team_id']);
    audit($conn, $wsId, 'delete', 'team', $teamId, $before, null, $before['path']);
    ok(['deleted' => $teamId]);
}

fail('Unknown action', 400);
