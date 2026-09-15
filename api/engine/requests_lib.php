<?php
// Resource requests (demand side): asking for a named person, and the approval that books them.
//
// A request is "I want Priya for 7.5 hours on WI-1042 from Monday". Hours are what a person asks
// for; a SPAN is what that converts to against that person's own capacity — which is why the
// conversion lives here and not in the client: a 3.75-hour Friday and a full Monday are not the
// same day, and only capacity_days knows that.
//
// Approving is the one thing in the system besides plan.php move_assignment that writes the
// committed plan directly. It does it the same way: a new committed version (CHG-05) carrying a
// FIXED assignment (SCH-06), recorded as an already-decided manual proposal so it appears in
// history like every other change. The engine still never edits the committed plan — a person does.
//
// Pure PHP over $conn. No HTTP; the endpoint does the role gating and the response shaping.
require_once __DIR__ . '/capacity.php';
require_once __DIR__ . '/proposals.php';

// ---- spans and fit ---------------------------------------------------------------------------

/** End of the modelled horizon — how far forward a request may reach. */
function request_horizon_end($conn, $wsId) {
    return date('Y-m-d', strtotime(week_start(today()) . ' +' . (int)current_policy($conn, $wsId)['model_horizon_weeks'] . ' weeks -1 day'));
}

/** 7.5 rather than 7.50, for a message a person reads. */
function req_hours($h) { return rtrim(rtrim(number_format((float)$h, 2, '.', ''), '0'), '.'); }

/**
 * Turn hours into a dated span against one person's real capacity.
 *
 * With $to given the span is fixed and the allocation is derived; without it the span grows at
 * $alloc (default 100%) until the hours are covered. Days with no schedulable time — weekends,
 * leave, a non-working weekday of a part-time pattern — are skipped, never counted as zero-hour
 * working days, so "7.5 hours from Friday" lands on Friday and Monday rather than pretending
 * Saturday exists.
 *
 * The allocation is always derived from the day set the span settles on, never left at whatever
 * was asked for: 7.5 hours over two 6.6-hour days is 57% of both, not 100% of both. A request for
 * hours books those hours and no more, so approving one never quietly steals a day from the plan.
 *
 * `committed_pct` and `free_pct` are shares of the person's whole day, which is what
 * `assignments.allocation_pct` means everywhere else — comparing hours against a reserve-adjusted
 * day would make every request look impossible.
 *
 * @return array {from, to, allocation_pct, schedulable_hours, booked_hours, days:[{day, schedulable, committed_pct, free_pct, free}]}
 *               or ['error' => message, 'detail' => [...]]
 */
function request_span($conn, $wsId, $personId, $hours, $from, $to = null, $alloc = null) {
    $hours = round((float)$hours, 2);
    if ($hours <= 0) return ['error' => 'Ask for more than zero hours'];
    $horizon = request_horizon_end($conn, $wsId);
    $scanTo = $to !== null ? $to : $horizon;
    if ($scanTo < $from) return ['error' => 'The end of the window is before its start'];

    // capacity_days is derived nightly; a window nobody has looked at yet is derived on demand.
    if ((int)scalar($conn, "SELECT COUNT(*) FROM dbo.capacity_days WHERE workspace_id = ? AND person_id = ? AND day BETWEEN ? AND ?", [$wsId, $personId, $from, $scanTo]) === 0) {
        derive_capacity($conn, $wsId, $from, $scanTo, [$personId]);
    }
    $capMap = capacity_map($conn, $wsId, $from, $scanTo, [$personId]);
    $bookedPct = request_committed_pct($conn, $wsId, $personId, $from, $scanTo);
    $cap = $capMap[$personId] ?? [];
    ksort($cap);

    $usable = [];
    foreach ($cap as $day => $c) {
        $schedulable = round($c['available'] - $c['reserve'], 2);
        if ($schedulable <= 0) continue;                        // weekend, leave, or a day off the pattern
        $committed = (int)($bookedPct[$day] ?? 0);
        $freePct = max(0, 100 - $committed);
        $usable[] = ['day' => $day, 'schedulable' => $schedulable, 'committed_pct' => $committed,
            'free_pct' => $freePct, 'free' => round($schedulable * $freePct / 100, 2)];
    }
    if (!$usable) return ['error' => 'That person has no schedulable time in this window'];

    if ($to !== null) {
        $days = $usable;
        $end = $to;
    } else {
        $walk = $alloc !== null ? max(1, min(100, (int)$alloc)) : 100;
        $days = [];
        $covered = 0;
        foreach ($usable as $u) {
            $days[] = $u;
            $covered += $u['schedulable'] * $walk / 100;
            if ($covered + 0.001 >= $hours) break;
        }
        if ($covered + 0.001 < $hours) {
            return ['error' => 'That person does not have that many hours before the end of the planning horizon (' . fmt_day($horizon) . ')',
                'detail' => ['schedulable_hours' => round($covered, 2), 'hours' => $hours]];
        }
        $end = $days[count($days) - 1]['day'];
    }

    $schedulable = 0;
    foreach ($days as $d) $schedulable += $d['schedulable'];
    $pct = (int)ceil($hours / $schedulable * 100);
    if ($pct > 100) {
        return ['error' => req_hours($hours) . ' hours needs more than that person has between those dates (' . req_hours($schedulable) . ' schedulable). Extend the window or ask for fewer hours.',
            'detail' => ['schedulable_hours' => round($schedulable, 2), 'hours' => $hours]];
    }
    $allocation = max(1, $pct);
    return [
        'from' => $days[0]['day'], 'to' => $end, 'allocation_pct' => $allocation,
        'schedulable_hours' => round($schedulable, 2),
        'booked_hours' => round($schedulable * $allocation / 100, 2),
        'days' => $days,
    ];
}

/** Committed share of each day already spoken for: [day => Σ allocation_pct] from the committed plan. */
function request_committed_pct($conn, $wsId, $personId, $from, $to) {
    $pv = committed_plan_version_id($conn, $wsId);
    if ($pv === null) return [];
    $out = [];
    foreach (rows($conn, "SELECT from_date, to_date, allocation_pct FROM dbo.assignments
                          WHERE plan_version_id = ? AND person_id = ? AND is_reserve = 0 AND from_date <= ? AND to_date >= ?",
        [$pv, $personId, $to, $from]) as $a) {
        $d = new DateTime(max($from, substr($a['from_date'], 0, 10)));
        $end = new DateTime(min($to, substr($a['to_date'], 0, 10)));
        while ($d <= $end) { $out[$d->format('Y-m-d')] = ($out[$d->format('Y-m-d')] ?? 0) + (int)$a['allocation_pct']; $d->modify('+1 day'); }
    }
    return $out;
}

/**
 * Does the span fit alongside what the person is already committed to?
 *
 * A request that does not fit is not refused outright: it is reported as short, with what it
 * collides with, so the approver decides. Over-booking somebody is a decision a lead is allowed
 * to make, with their name on it.
 */
function request_fit($conn, $wsId, $personId, array $span) {
    $free = 0; $short = 0;
    foreach ($span['days'] as $d) {
        $free += $d['free'];
        $shortPct = max(0, $span['allocation_pct'] - $d['free_pct']);
        if ($shortPct > 0) $short += round($d['schedulable'] * $shortPct / 100, 2);
    }
    $conflicts = [];
    $pv = committed_plan_version_id($conn, $wsId);
    if ($pv !== null) {
        foreach (rows($conn, "SELECT a.from_date, a.to_date, a.allocation_pct, wi.ref, wi.title
                              FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id
                              WHERE a.plan_version_id = ? AND a.person_id = ? AND a.is_reserve = 0 AND a.from_date <= ? AND a.to_date >= ?
                              ORDER BY a.from_date", [$pv, $personId, $span['to'], $span['from']]) as $a) {
            $conflicts[] = ['ref' => $a['ref'], 'title' => $a['title'], 'from' => substr($a['from_date'], 0, 10),
                'to' => substr($a['to_date'], 0, 10), 'allocation_pct' => (int)$a['allocation_pct']];
        }
    }
    return ['fits' => $short <= 0.01, 'free_hours' => round($free, 2), 'short_hours' => round($short, 2), 'conflicts' => $conflicts];
}

// ---- authority -------------------------------------------------------------------------------

/**
 * ORG-05 authority, applied to a PERSON rather than a team: a delivery lead or administrator may
 * approve anything; a team lead may approve for the team they lead and every team beneath it,
 * because they appear in the lead chain of each. One approval is enough — the chain is a list of
 * people who MAY say yes, not a queue who all must.
 *
 * A team-lead account with no linked person has nothing to scope the check to and passes on role
 * alone, exactly as can_edit_team() and require_loan_authority() already do. A person with no home
 * team has no lead, so only a delivery lead can approve for them.
 */
function can_approve_request($conn, $wsId, $subjectPersonId) {
    global $personId;
    if (has_role('delivery_lead')) return true;
    if (!has_role('team_lead')) return false;
    if ($personId === null) return true;
    $teamId = scalar($conn, "SELECT team_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$subjectPersonId, $wsId]);
    if ($teamId === null) return false;
    return in_array((int)$personId, team_lead_chain($conn, $wsId, (int)$teamId), true);
}

/** The people who may approve for $subjectPersonId, nearest lead first. */
function request_approver_people($conn, $wsId, $subjectPersonId) {
    $teamId = scalar($conn, "SELECT team_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$subjectPersonId, $wsId]);
    if ($teamId === null) return [];
    $out = [];
    foreach (team_lead_chain($conn, $wsId, (int)$teamId) as $pid) {
        if ((int)$pid === (int)$subjectPersonId) continue;      // nobody approves their own booking by leading their own team
        $p = row($conn, "SELECT id, name FROM dbo.people WHERE id = ? AND workspace_id = ? AND active = 1", [$pid, $wsId]);
        if ($p) $out[] = ['id' => (int)$p['id'], 'name' => $p['name']];
    }
    return $out;
}

/** User ids to tell that an approval is wanted: the lead chain, plus every delivery lead. */
function request_approver_user_ids($conn, $wsId, $subjectPersonId) {
    $ids = [];
    foreach (request_approver_people($conn, $wsId, $subjectPersonId) as $p) {
        $uid = scalar($conn, "SELECT id FROM dbo.users WHERE person_id = ? AND workspace_id = ? AND active = 1", [$p['id'], $wsId]);
        if ($uid !== null) $ids[] = (int)$uid;
    }
    foreach (users_with_role($conn, $wsId, 'delivery_lead') as $uid) $ids[] = (int)$uid;
    return array_values(array_unique($ids));
}

/** "Lena Torres, Priya Kaur or a delivery lead" — who the requester is waiting on. */
function request_approver_label($conn, $wsId, $subjectPersonId) {
    $names = array_map(fn($p) => $p['name'], request_approver_people($conn, $wsId, $subjectPersonId));
    $names[] = 'a delivery lead';
    $last = array_pop($names);
    return $names ? implode(', ', $names) . ' or ' . $last : $last;
}

// ---- approval --------------------------------------------------------------------------------

/**
 * Book the request: a new committed plan version carrying a fixed assignment, recorded as an
 * already-decided manual proposal (SCH-07, 8.13 "manual edits are changes like any other").
 *
 * The span is re-derived rather than trusted: between raising and approving, leave may have been
 * booked or the plan may have moved. A request that no longer fits is refused with what it would
 * cost, unless the approver forces it through.
 *
 * @return array {plan_version_id, assignment_id, proposal_id, change_id, inside_freeze, stability_cost_days, headline, from, to, allocation_pct}
 */
function approve_request($conn, $wsId, array $req, $reason = '', $force = false) {
    global $userId, $userName;
    $model = build_model($conn, $wsId);
    if (!$model) fail('Could not build the planning model', 500);
    $itemId = (int)$req['work_item_id'];
    $pid = (int)$req['person_id'];
    $item = $model['items'][$itemId] ?? null;
    if (!$item) fail('That work item is no longer open, so nobody can be booked on to it', 409);
    if (!isset($model['people'][$pid])) fail('That person is no longer active in the plan', 409);

    $span = request_span($conn, $wsId, $pid, (float)$req['hours'], max(substr($req['from_date'], 0, 10), $model['today']), substr($req['to_date'], 0, 10), (int)$req['allocation_pct']);
    if (isset($span['error'])) {
        // The span cannot be computed at all any more — leave was booked, the pattern changed, the
        // dates have run out. That is a genuine refusal, and forcing it would book nothing sensible.
        if (!$force) fail($span['error'], 409, ['refit_failed' => true]);
        $span = ['from' => max(substr($req['from_date'], 0, 10), $model['today']), 'to' => substr($req['to_date'], 0, 10),
            'allocation_pct' => (int)$req['allocation_pct'], 'days' => [], 'schedulable_hours' => 0, 'booked_hours' => (float)$req['hours']];
        $fit = ['fits' => false, 'free_hours' => 0, 'short_hours' => 0, 'conflicts' => []];
    } else {
        // Not fitting is NOT a refusal. A committed plan books people at or near 100%, so almost every
        // request lands on top of something; that is precisely what the approver is deciding about, and
        // the batched replan trigger below lets the next cycle move the lower-priority work out of the
        // way. Blocking here would mean no request could ever be approved against a healthy plan.
        $fit = request_fit($conn, $wsId, $pid, $span);
    }

    $insideFreeze = $span['from'] <= $model['windows']['freeze_end'];
    $reason = trim((string)$reason);
    if ($insideFreeze && $reason === '') {
        $nextMonday = date('Y-m-d', strtotime($model['windows']['freeze_end'] . ' next monday'));
        fail('Inside the freeze horizon. Approving this needs a reason, or move the start to Monday ' . fmt_day($nextMonday) . ' or later.', 409,
            ['inside_freeze' => true, 'freeze_end' => $model['windows']['freeze_end'], 'reason_required' => true]);
    }

    $newRow = [
        'work_item_id' => $itemId, 'person_id' => $pid, 'from_date' => $span['from'], 'to_date' => $span['to'],
        'allocation_pct' => (int)$span['allocation_pct'], 'role_label' => 'requested',
        'locked_until' => null, 'fixed_by' => $userId ?? null, 'fixed_person' => 1, 'fixed_dates' => 1,
        'is_reserve' => 0, 'note' => mb_substr('Requested by ' . ($req['requested_by_name'] ?? 'a project owner'), 0, 200),
    ];

    // Cost and explain it exactly as the engine would: the candidate plan is the committed one plus
    // this booking, so the diff names the same kinds, chips and stability cost every other change uses.
    $candidate = $model['committed'];
    $candidate[] = $newRow + ['id' => 0, 'state' => model_state_for(max($span['from'], $model['today']), $model['windows']), 'locked' => true];
    $diff = diff_plans($model['committed'], $candidate, $model);
    $change = null;
    foreach ($diff as $c) {
        if ((int)$c['work_item_id'] === $itemId && (int)($c['after']['person_id'] ?? 0) === $pid) { $change = explain_change($c, $model, []); break; }
    }
    if (!$change) {   // the person already holds exactly these dates: nothing to say beyond the booking itself
        $change = ['work_item_id' => $itemId, 'person_id' => $pid, 'kind' => 'add', 'before' => null,
            'after' => ['person_id' => $pid, 'from' => $span['from'], 'to' => $span['to'], 'allocation_pct' => (int)$span['allocation_pct']],
            'headline' => 'Book ' . $model['people'][$pid]['name'] . ' on ' . $item['ref'],
            'reason' => 'Approved resource request.', 'impact_chips' => [], 'affected_person_ids' => [$pid],
            'stability_cost_days' => 0, 'inside_freeze' => $insideFreeze];
    }
    $change['inside_freeze'] = !empty($change['inside_freeze']) || $insideFreeze;

    $vid = new_committed_version($conn, $wsId, $model, function (&$rows) use ($newRow) { $rows[] = $newRow; },
        ['engine' => 'manual', 'notes' => 'Approved resource request #' . $req['id'] . ' (' . $item['ref'] . ' to ' . $model['people'][$pid]['name'] . ')']);
    $aid = scalar($conn, "SELECT TOP 1 id FROM dbo.assignments WHERE plan_version_id = ? AND work_item_id = ? AND person_id = ? AND from_date = ? ORDER BY id DESC",
        [$vid, $itemId, $pid, $span['from']]);

    $proposalId = insert($conn, 'proposals', ['workspace_id' => $wsId, 'candidate_plan_version_id' => $vid,
        'base_plan_version_id' => $model['committed_version_id'], 'kind' => 'manual', 'status' => 'decided',
        'generated_by' => $userId ?? null, 'decided_at' => date('Y-m-d H:i:s'), 'engine' => 'manual',
        'triggers' => json_encode([['type' => 'manual', 'label' => ($req['requested_by_name'] ?? 'A project owner') . ' asked for ' . $model['people'][$pid]['name'] . ' on ' . $item['ref']]], JSON_UNESCAPED_UNICODE)]);
    $changeId = insert($conn, 'change_proposals', ['proposal_id' => $proposalId, 'workspace_id' => $wsId,
        'person_id' => $pid, 'work_item_id' => $itemId, 'kind' => $change['kind'], 'headline' => mb_substr($change['headline'], 0, 200),
        'before_json' => !empty($change['before']) ? json_encode($change['before'], JSON_UNESCAPED_UNICODE) : null,
        'after_json' => !empty($change['after']) ? json_encode($change['after'], JSON_UNESCAPED_UNICODE) : null,
        'reason' => mb_substr($reason !== '' ? $reason : 'Approved resource request from ' . ($req['requested_by_name'] ?? 'a project owner'), 0, 400),
        'stability_cost_days' => $change['stability_cost_days'], 'inside_freeze' => $change['inside_freeze'] ? 1 : 0,
        'impact_chips' => json_encode($change['impact_chips'] ?? [], JSON_UNESCAPED_UNICODE),
        'affected_person_ids' => implode(',', $change['affected_person_ids'] ?? [$pid]),
        'guardrail_status' => $change['inside_freeze'] ? 'needs_approval' : 'ok',
        'guardrail_reason' => $change['inside_freeze'] ? 'Approved by ' . $userName . ': ' . $reason : null,
        'decision' => 'accepted', 'decided_by' => $userId ?? null, 'decided_at' => date('Y-m-d H:i:s'),
        'decision_reason' => $reason !== '' ? mb_substr($reason, 0, 300) : null, 'sort_order' => 0]);
    insert($conn, 'person_change_log', ['workspace_id' => $wsId, 'person_id' => $pid, 'work_item_id' => $itemId,
        'week_start' => week_start($span['from']), 'inside_freeze' => $change['inside_freeze'] ? 1 : 0,
        'assignment_days' => $change['stability_cost_days'], 'reason' => 'Approved resource request', 'change_proposal_id' => $changeId]);

    update($conn, 'resource_requests', ['status' => 'approved', 'decided_by' => $userId ?? null,
        'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason !== '' ? mb_substr($reason, 0, 300) : null,
        'from_date' => $span['from'], 'to_date' => $span['to'], 'allocation_pct' => (int)$span['allocation_pct'],
        'plan_version_id' => $vid, 'assignment_id' => $aid !== null ? (int)$aid : null], 'id = ? AND workspace_id = ?', [(int)$req['id'], $wsId]);

    // NOT-01: the person learns they have work; the requester learns the answer.
    notify_person($conn, $wsId, $pid, 'item_assigned', $item['ref'] . ': ' . $item['title'],
        'Booked ' . fmt_range($span['from'], $span['to']) . ' at ' . (int)$span['allocation_pct'] . '%', '/items/' . $item['ref'], $change['inside_freeze'] ? 1 : 0);
    notify($conn, $wsId, (int)$req['requested_by'], 'request_decided', 'Approved: ' . $model['people'][$pid]['name'] . ' on ' . $item['ref'],
        ($userName ?? 'A lead') . ' approved your request. ' . fmt_range($span['from'], $span['to']) . ' at ' . (int)$span['allocation_pct'] . '%.' . ($reason !== '' ? ' ' . $reason : ''), '/requests/' . (int)$req['id']);

    // The plan now holds a fixed booking the engine has not seen; let the next cycle plan around it.
    add_trigger($conn, $wsId, 'manual', 'batched', 'Approved resource request: ' . $model['people'][$pid]['name'] . ' on ' . $item['ref'], 'resource_request', (int)$req['id'], [$pid]);
    rollup_stability_week($conn, $wsId, build_model($conn, $wsId));

    return ['plan_version_id' => $vid, 'assignment_id' => $aid !== null ? (int)$aid : null, 'proposal_id' => $proposalId,
        'change_id' => $changeId, 'inside_freeze' => (bool)$change['inside_freeze'],
        'stability_cost_days' => $change['stability_cost_days'], 'headline' => $change['headline'],
        'from' => $span['from'], 'to' => $span['to'], 'allocation_pct' => (int)$span['allocation_pct'],
        'over_booked' => !$fit['fits'], 'fit' => $fit];
}

/**
 * A pending request whose start date has passed is expired by the nightly cycle: nobody should be
 * asked on Friday to approve a Monday that has gone. The requester is told, so it is a closed loop
 * rather than a row that quietly rots.
 */
function expire_requests($conn, $wsId) {
    $today = today();
    $due = rows($conn, "SELECT r.*, p.name AS person_name, wi.ref FROM dbo.resource_requests r
                        JOIN dbo.people p ON p.id = r.person_id JOIN dbo.work_items wi ON wi.id = r.work_item_id
                        WHERE r.workspace_id = ? AND r.status = 'pending' AND r.from_date < ?", [$wsId, $today]);
    foreach ($due as $r) {
        update($conn, 'resource_requests', ['status' => 'expired', 'decided_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$r['id']]);
        notify($conn, $wsId, (int)$r['requested_by'], 'request_decided', 'Expired: ' . $r['person_name'] . ' on ' . $r['ref'],
            'Nobody approved this before ' . fmt_day(substr($r['from_date'], 0, 10)) . ', so it has expired. Raise it again with new dates if it is still needed.', '/requests/' . (int)$r['id']);
        audit($conn, $wsId, 'update', 'resource_request', (int)$r['id'], ['status' => 'pending'], ['status' => 'expired'], $r['ref'] . ' to ' . $r['person_name'], 'Start date passed with no decision');
    }
    return count($due);
}

// ---- shapes ----------------------------------------------------------------------------------

const REQUEST_SELECT = "SELECT r.*, wi.ref, wi.title, wi.status AS item_status, wt.colour AS type_colour, wt.name AS type_name,
        p.name AS person_name, p.initials, p.colour AS person_colour, p.team_id, t.name AS team_name,
        u.display_name AS requested_by_name, d.display_name AS decided_by_name
     FROM dbo.resource_requests r
     JOIN dbo.work_items wi ON wi.id = r.work_item_id
     JOIN dbo.work_types wt ON wt.id = wi.work_type_id
     JOIN dbo.people p ON p.id = r.person_id
     LEFT JOIN dbo.teams t ON t.id = p.team_id
     JOIN dbo.users u ON u.id = r.requested_by
     LEFT JOIN dbo.users d ON d.id = r.decided_by";

/** DB row → API Request shape. `can_approve` / `can_withdraw` are about the caller, so the client hides controls (ADM-02). */
function request_shape($conn, $wsId, array $r) {
    global $userId;
    return [
        'id' => (int)$r['id'],
        'work_item' => ['id' => (int)$r['work_item_id'], 'ref' => $r['ref'], 'title' => $r['title'], 'status' => $r['item_status'],
            'type_colour' => $r['type_colour'], 'type_name' => $r['type_name']],
        'person' => ['id' => (int)$r['person_id'], 'name' => $r['person_name'], 'initials' => $r['initials'] !== null ? trim($r['initials']) : null,
            'colour' => $r['person_colour'], 'team_id' => $r['team_id'] !== null ? (int)$r['team_id'] : null, 'team_name' => $r['team_name']],
        'requested_by' => ['id' => (int)$r['requested_by'], 'name' => $r['requested_by_name']],
        'hours' => (float)$r['hours'], 'from_date' => substr($r['from_date'], 0, 10), 'to_date' => substr($r['to_date'], 0, 10),
        'allocation_pct' => (int)$r['allocation_pct'], 'note' => $r['note'], 'status' => $r['status'],
        'decided_by_name' => $r['decided_by_name'], 'decided_at' => $r['decided_at'], 'decision_reason' => $r['decision_reason'],
        'plan_version_id' => $r['plan_version_id'] !== null ? (int)$r['plan_version_id'] : null,
        'assignment_id' => $r['assignment_id'] !== null ? (int)$r['assignment_id'] : null,
        'created_at' => $r['created_at'],
        'can_approve' => $r['status'] === 'pending' && can_approve_request($conn, $wsId, (int)$r['person_id']),
        'can_withdraw' => $r['status'] === 'pending' && ((int)$r['requested_by'] === (int)$userId || has_role('delivery_lead')),
        'approver_label' => request_approver_label($conn, $wsId, (int)$r['person_id']),
    ];
}
