<?php
// Resource requests: "I want this person for this many hours on this item", and the approval that books them.
// Actions: preview | create | list | get | approve | decline | withdraw
//
// The demand side of the plan. A project owner asks; the person's team lead — or any lead above
// them, or a delivery lead — says yes, and the booking lands in the committed plan as a fixed
// assignment. See api/engine/requests_lib.php for the span arithmetic and the approval itself.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/requests_lib.php';
$action = param('action', 'list');
$today = today();

/** Load one request with everything the shape needs, or 404. */
function load_request($conn, $wsId, $id) {
    $r = row($conn, REQUEST_SELECT . " WHERE r.id = ? AND r.workspace_id = ?", [(int)$id, $wsId]);
    if (!$r) fail('Request not found', 404);
    return $r;
}

/**
 * Who may ask for somebody on this item. A team lead may ask for anyone on anything; below that
 * you may only ask for people on work you raised or own, which is the same rule work_items.php
 * applies to editing an item.
 */
function require_request_authority($conn, $wsId, array $item) {
    global $userId, $personId;
    require_role('requester');
    if (has_role('team_lead')) return;
    $mine = ($item['created_by'] !== null && (int)$item['created_by'] === (int)$userId)
        || ($item['owner_person_id'] !== null && $personId !== null && (int)$item['owner_person_id'] === (int)$personId);
    if (!$mine) fail('Forbidden: you can only request people for work you raised or own', 403);
}

/** The item and person a request is about, validated against the workspace and each other. */
function request_subjects($conn, $wsId) {
    $itemId = (int)require_param('work_item_id');
    $pid = (int)require_param('person_id');
    $item = row($conn, "SELECT wi.*, wt.name AS type_name FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id WHERE wi.id = ? AND wi.workspace_id = ?", [$itemId, $wsId]);
    if (!$item) fail('Work item not found', 404);
    $person = row($conn, "SELECT id, name, active, team_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$pid, $wsId]);
    if (!$person) fail('Person not found', 404);
    return [$item, $person];
}

// ---------------------------------------------------------------------------------------------
if ($action === 'preview' || $action === 'create') {
    [$item, $person] = request_subjects($conn, $wsId);
    require_request_authority($conn, $wsId, $item);
    $hours = round((float)require_param('hours'), 2);
    $from = substr((string)require_param('from_date'), 0, 10);
    $to = param('to_date') ? substr((string)param('to_date'), 0, 10) : null;
    $alloc = param('allocation_pct') !== null && param('allocation_pct') !== '' ? (int)param('allocation_pct') : null;

    if ($hours <= 0) fail('Ask for more than zero hours', 400);
    if ($from < $today) fail('A request starts today or later', 400, ['today' => $today]);
    if ($to !== null && $to < $from) fail('The end date is before the start date', 400);
    if (!(int)$person['active']) fail($person['name'] . ' is not active, so they cannot be booked', 409);
    if (in_array($item['status'], ['delivered', 'cancelled'], true)) fail('That work item is ' . $item['status'] . ', so nobody can be booked on to it', 409);

    $span = request_span($conn, $wsId, (int)$person['id'], $hours, $from, $to, $alloc);
    if (isset($span['error'])) fail($span['error'], 409, $span['detail'] ?? []);
    $fit = request_fit($conn, $wsId, (int)$person['id'], $span);
    $freezeEnd = freeze_horizon_end($conn, $wsId);
    $insideFreeze = $span['from'] <= $freezeEnd;

    // TEAM-09: a person lent wholly to another team for the whole span is not this team's to ask for.
    $loans = loans_in_window($conn, $wsId, $span['from'], $span['to'], [(int)$person['id']]);
    $lentAway = null;
    foreach ($loans as $l) {
        if ((int)$l['allocation_pct'] >= 100 && substr($l['from_date'], 0, 10) <= $span['from'] && substr($l['to_date'], 0, 10) >= $span['to']) $lentAway = $l;
    }
    if ($lentAway && $action === 'create') {
        fail($person['name'] . ' is on loan to ' . $lentAway['to_team_name'] . ' for the whole of that window. Ask that team, or pick different dates.', 409,
            ['loan' => ['to_team_name' => $lentAway['to_team_name'], 'from_date' => substr($lentAway['from_date'], 0, 10), 'to_date' => substr($lentAway['to_date'], 0, 10)]]);
    }

    $payload = [
        'span' => ['from' => $span['from'], 'to' => $span['to'], 'allocation_pct' => $span['allocation_pct'],
            'schedulable_hours' => $span['schedulable_hours'], 'booked_hours' => $span['booked_hours'], 'days' => $span['days']],
        'fit' => $fit, 'inside_freeze' => $insideFreeze, 'freeze_end' => $freezeEnd,
        'approver_label' => request_approver_label($conn, $wsId, (int)$person['id']),
        'on_loan' => $lentAway ? ['to_team_name' => $lentAway['to_team_name'], 'to_date' => substr($lentAway['to_date'], 0, 10)] : null,
    ];
    if ($action === 'preview') ok($payload);

    // One pending request per person per item per overlapping window: asking twice is a mistake, not a queue.
    $dupe = row($conn, "SELECT TOP 1 id FROM dbo.resource_requests WHERE workspace_id = ? AND work_item_id = ? AND person_id = ? AND status = 'pending' AND from_date <= ? AND to_date >= ?",
        [$wsId, (int)$item['id'], (int)$person['id'], $span['to'], $span['from']]);
    if ($dupe) fail('There is already a pending request for ' . $person['name'] . ' on ' . $item['ref'] . ' over those dates', 409, ['request_id' => (int)$dupe['id']]);

    $id = insert($conn, 'resource_requests', ['workspace_id' => $wsId, 'work_item_id' => (int)$item['id'], 'person_id' => (int)$person['id'],
        'requested_by' => $userId, 'hours' => $hours, 'from_date' => $span['from'], 'to_date' => $span['to'],
        'allocation_pct' => (int)$span['allocation_pct'], 'note' => param('note') ? mb_substr(trim((string)param('note')), 0, 300) : null, 'status' => 'pending']);

    $title = $person['name'] . ' requested for ' . $item['ref'];
    $body = req_hours($hours) . ' hours, ' . fmt_range($span['from'], $span['to']) . ' at ' . (int)$span['allocation_pct'] . '%, asked by ' . $userName
        . (param('note') ? '. ' . mb_substr(trim((string)param('note')), 0, 200) : '');
    $notified = 0;
    foreach (request_approver_user_ids($conn, $wsId, (int)$person['id']) as $uid) {
        if (notify($conn, $wsId, $uid, 'approval_requested', $title, $body, '/requests/' . $id, $insideFreeze ? 1 : 0) !== null) $notified++;
    }
    audit($conn, $wsId, 'create', 'resource_request', $id, null,
        ['work_item' => $item['ref'], 'person' => $person['name'], 'hours' => $hours, 'from' => $span['from'], 'to' => $span['to'], 'allocation_pct' => (int)$span['allocation_pct']],
        $item['ref'] . ' to ' . $person['name'], param('note') ? mb_substr(trim((string)param('note')), 0, 300) : null);

    ok(['request' => request_shape($conn, $wsId, load_request($conn, $wsId, $id)), 'notified' => $notified] + $payload);
}

// ---------------------------------------------------------------------------------------------
if ($action === 'list') {
    $view = param('view', 'mine');
    $where = ['r.workspace_id = ?'];
    $params = [$wsId];
    if (param('status')) { $where[] = 'r.status = ?'; $params[] = (string)param('status'); }
    if (param('work_item_id')) { $where[] = 'r.work_item_id = ?'; $params[] = (int)param('work_item_id'); }
    if (param('person_id')) { $where[] = 'r.person_id = ?'; $params[] = (int)param('person_id'); }

    if ($view === 'mine') {
        $where[] = 'r.requested_by = ?';
        $params[] = $userId;
    } elseif ($view === 'for_me') {
        // Only rows this caller could actually decide. A delivery lead sees every one; a team lead
        // sees the people of the teams they lead and everything beneath them (ORG-05).
        if (!has_role('team_lead')) ok(['requests' => [], 'counts' => request_counts($conn, $wsId)]);
        $teamIds = editable_team_ids($conn, $wsId);
        if ($teamIds !== '*') {
            if (!$teamIds) ok(['requests' => [], 'counts' => request_counts($conn, $wsId)]);
            $in = implode(',', array_fill(0, count($teamIds), '?'));
            $where[] = "p.team_id IN ($in)";
            $params = array_merge($params, $teamIds);
        }
    } elseif ($view === 'all') {
        require_role('team_lead');
    } else {
        fail('Unknown view: use mine, for_me or all', 400);
    }
    $limit = max(1, min(200, (int)param('limit', 100)));
    $sql = REQUEST_SELECT . ' WHERE ' . implode(' AND ', $where) . " ORDER BY CASE r.status WHEN 'pending' THEN 0 ELSE 1 END, r.from_date, r.id DESC";
    $out = [];
    foreach (array_slice(rows($conn, $sql, $params), 0, $limit) as $r) $out[] = request_shape($conn, $wsId, $r);
    ok(['requests' => $out, 'counts' => request_counts($conn, $wsId)]);
}

if ($action === 'get') {
    ok(['request' => request_shape($conn, $wsId, load_request($conn, $wsId, require_param('id')))]);
}

// ---------------------------------------------------------------------------------------------
if ($action === 'approve' || $action === 'decline') {
    $r = load_request($conn, $wsId, require_param('id'));
    if ($r['status'] !== 'pending') fail('That request has already been ' . $r['status'], 409, ['status' => $r['status']]);
    if (!can_approve_request($conn, $wsId, (int)$r['person_id'])) {
        fail('Forbidden: only ' . request_approver_label($conn, $wsId, (int)$r['person_id']) . ' can decide this', 403);
    }
    $reason = trim((string)param('reason', ''));

    if ($action === 'decline') {
        if ($reason === '') fail('Declining a request needs a reason: the person who asked has to know why', 422);
        update($conn, 'resource_requests', ['status' => 'declined', 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'),
            'decision_reason' => mb_substr($reason, 0, 300)], 'id = ? AND workspace_id = ?', [(int)$r['id'], $wsId]);
        notify($conn, $wsId, (int)$r['requested_by'], 'request_decided', 'Declined: ' . $r['person_name'] . ' on ' . $r['ref'], $userName . ' declined your request. ' . $reason, '/requests/' . (int)$r['id']);
        audit($conn, $wsId, 'reject', 'resource_request', (int)$r['id'], ['status' => 'pending'], ['status' => 'declined'], $r['ref'] . ' to ' . $r['person_name'], $reason);
        ok(['request' => request_shape($conn, $wsId, load_request($conn, $wsId, (int)$r['id']))]);
    }

    $res = approve_request($conn, $wsId, $r, $reason, (bool)param('force', false));
    audit($conn, $wsId, 'approve', 'resource_request', (int)$r['id'], ['status' => 'pending'],
        ['status' => 'approved', 'plan_version_id' => $res['plan_version_id'], 'assignment_id' => $res['assignment_id'],
            'from' => $res['from'], 'to' => $res['to'], 'allocation_pct' => $res['allocation_pct'], 'inside_freeze' => $res['inside_freeze']],
        $r['ref'] . ' to ' . $r['person_name'], $reason !== '' ? $reason : null);
    ok(['request' => request_shape($conn, $wsId, load_request($conn, $wsId, (int)$r['id'])),
        'plan_version' => ['id' => $res['plan_version_id'], 'assignment_id' => $res['assignment_id']],
        'headline' => $res['headline'], 'stability_cost_days' => $res['stability_cost_days'],
        'inside_freeze' => $res['inside_freeze'], 'over_booked' => $res['over_booked'], 'fit' => $res['fit']]);
}

if ($action === 'withdraw') {
    $r = load_request($conn, $wsId, require_param('id'));
    if ($r['status'] !== 'pending') fail('That request has already been ' . $r['status'], 409, ['status' => $r['status']]);
    if ((int)$r['requested_by'] !== (int)$userId && !has_role('delivery_lead')) fail('Forbidden: only the person who asked, or a delivery lead, can withdraw a request', 403);
    $reason = param('reason') ? mb_substr(trim((string)param('reason')), 0, 300) : null;
    update($conn, 'resource_requests', ['status' => 'withdrawn', 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason],
        'id = ? AND workspace_id = ?', [(int)$r['id'], $wsId]);
    audit($conn, $wsId, 'update', 'resource_request', (int)$r['id'], ['status' => 'pending'], ['status' => 'withdrawn'], $r['ref'] . ' to ' . $r['person_name'], $reason);
    ok(['request' => request_shape($conn, $wsId, load_request($conn, $wsId, (int)$r['id']))]);
}

fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------
/** Badge counts for the shell: what is waiting on me, and what I am waiting for. */
function request_counts($conn, $wsId) {
    global $userId;
    $mine = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.resource_requests WHERE workspace_id = ? AND requested_by = ? AND status = 'pending'", [$wsId, $userId]);
    $forMe = 0;
    if (has_role('team_lead')) {
        $teamIds = editable_team_ids($conn, $wsId);
        if ($teamIds === '*') {
            $forMe = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.resource_requests WHERE workspace_id = ? AND status = 'pending'", [$wsId]);
        } elseif ($teamIds) {
            $in = implode(',', array_fill(0, count($teamIds), '?'));
            $forMe = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.resource_requests r JOIN dbo.people p ON p.id = r.person_id
                                         WHERE r.workspace_id = ? AND r.status = 'pending' AND p.team_id IN ($in)", array_merge([$wsId], $teamIds));
        }
    }
    return ['pending_for_me' => $forMe, 'mine_pending' => $mine];
}
