<?php
// Proposals and review (CHG-*). Actions:
//   current  list{status?}  get{id}  decide{change_id, decision, reason?}  commit{proposal_id}  accept_all_passing{proposal_id}
//   reject_all{proposal_id}  edit{change_id, after, reason}  acknowledge{change_id}  comment{change_id, body}  mine
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/proposals.php';
require_once __DIR__ . '/engine/commit.php';
$action = param('action', 'current');

if ($action === 'current') {
    $p = row($conn, "SELECT TOP 1 * FROM dbo.proposals WHERE workspace_id = ? AND status = 'open' ORDER BY generated_at DESC", [$wsId])
      ?: row($conn, "SELECT TOP 1 * FROM dbo.proposals WHERE workspace_id = ? AND kind <> 'preview' ORDER BY generated_at DESC", [$wsId]);
    if (!$p) ok(['proposal' => null, 'changes' => [], 'held' => [], 'awaiting_ack' => [], 'guardrails' => guardrail_descriptions(current_policy_arr($conn, $wsId)), 'counts' => ['proposed' => 0, 'held' => 0, 'pending' => 0, 'awaiting_ack' => 0]]);
    ok(proposal_payload($conn, $wsId, $p));
}
if ($action === 'list') {
    $status = param('status');
    $sql = "SELECT * FROM dbo.proposals WHERE workspace_id = ? AND kind <> 'preview'" . ($status ? " AND status = ?" : '') . " ORDER BY generated_at DESC";
    $ps = rows($conn, $sql, $status ? [$wsId, $status] : [$wsId]);
    ok(['proposals' => array_map(fn($p) => proposal_shape($conn, $p, $wsId), array_slice($ps, 0, (int)param('limit', 50)))]);
}
if ($action === 'get') {
    $p = row($conn, "SELECT * FROM dbo.proposals WHERE id = ? AND workspace_id = ?", [(int)require_param('id'), $wsId]);
    if (!$p) fail('Proposal not found', 404);
    ok(proposal_payload($conn, $wsId, $p));
}

if ($action === 'decide') {
    require_role('delivery_lead');
    $c = load_change($conn, $wsId, (int)require_param('change_id'));
    $decision = require_param('decision');
    if (!in_array($decision, ['accepted', 'rejected'], true)) fail('decision must be accepted or rejected', 400);
    $reason = trim((string)param('reason', ''));
    decide_change($conn, $wsId, $c, $decision, $reason);
    ok(['change' => change_x($conn, load_change_row($conn, $c['id']), $wsId), 'proposal_counts' => proposal_shape($conn, row($conn, "SELECT * FROM dbo.proposals WHERE id = ?", [$c['proposal_id']]), $wsId)['counts']]);
}

if ($action === 'commit') {
    require_role('delivery_lead');
    $p = open_proposal($conn, $wsId, (int)require_param('proposal_id'));
    ok(commit_proposal($conn, $wsId, $p));
}
if ($action === 'accept_all_passing') {
    require_role('delivery_lead');
    $p = open_proposal($conn, $wsId, (int)require_param('proposal_id'));
    $n = 0;
    foreach (rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND decision = 'pending' AND guardrail_status = 'ok'", [(int)$p['id']]) as $c) { decide_change($conn, $wsId, $c, 'accepted', 'Accepted with all passing changes'); $n++; }
    ok(array_merge(['accepted' => $n], commit_proposal($conn, $wsId, $p)));
}
if ($action === 'reject_all') {
    require_role('delivery_lead');
    $p = open_proposal($conn, $wsId, (int)require_param('proposal_id'));
    $reason = trim((string)param('reason', 'Rejected all'));
    $n = 0;
    foreach (rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND decision = 'pending'", [(int)$p['id']]) as $c) { update($conn, 'change_proposals', ['decision' => 'rejected', 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason], 'id = ?', [(int)$c['id']]); $n++; }
    update($conn, 'proposals', ['status' => 'decided', 'decided_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$p['id']]);
    if ($p['candidate_plan_version_id']) update($conn, 'plan_versions', ['status' => 'discarded'], 'id = ? AND status = ?', [(int)$p['candidate_plan_version_id'], 'proposed']);
    audit($conn, $wsId, 'reject', 'proposal', (int)$p['id'], ['status' => 'open'], ['status' => 'decided', 'rejected' => $n], "Proposal #{$p['id']}", $reason);
    ok(['rejected' => $n, 'proposal' => proposal_shape($conn, row($conn, "SELECT * FROM dbo.proposals WHERE id = ?", [(int)$p['id']]), $wsId)]);
}

if ($action === 'edit') {
    require_role('delivery_lead');
    $c = load_change($conn, $wsId, (int)require_param('change_id'));
    $after = (array)require_param('after');
    $reason = trim((string)require_param('reason'));
    if (empty($after['from']) || empty($after['to'])) fail('after.from and after.to are required', 422);
    if ($after['from'] > $after['to']) fail('after.from must not be after after.to', 400);
    $prev = json_col($c['after_json'], []) ?: [];
    $before = json_col($c['before_json'], null);
    $newAfter = ['person_id' => (int)($after['person_id'] ?? ($prev['person_id'] ?? ($before['person_id'] ?? 0))), 'from' => $after['from'], 'to' => $after['to'], 'allocation_pct' => (int)($after['allocation_pct'] ?? ($prev['allocation_pct'] ?? 100)), 'role_label' => $prev['role_label'] ?? null];
    if (!$newAfter['person_id']) fail('after.person_id is required', 422);
    // Recost with the engine: candidate for this item = committed minus the before rows plus the edited row.
    $model = build_model($conn, $wsId);
    $iid = (int)$c['work_item_id'];
    $item = $model['items'][$iid] ?? null;
    if (!$item) fail('Work item is no longer open', 409);
    $cand = array_values(array_filter($model['committed'], fn($a) => $a['work_item_id'] !== $iid || ($before && $a['person_id'] !== (int)$before['person_id'])));
    $cand[] = ['work_item_id' => $iid, 'person_id' => $newAfter['person_id'], 'from_date' => $newAfter['from'], 'to_date' => $newAfter['to'], 'allocation_pct' => $newAfter['allocation_pct'], 'role_label' => $newAfter['role_label'], 'state' => model_state_for(max($newAfter['from'], $model['today']), $model['windows'])];
    $diff = diff_plans($model['committed'], $cand, $model);
    $mine = array_values(array_filter($diff, fn($d) => $d['work_item_id'] === $iid && ($d['after']['person_id'] ?? null) === $newAfter['person_id']));
    $re = $mine[0] ?? ['kind' => $c['kind'], 'stability_cost_days' => 0, 'inside_freeze' => false, 'affected_person_ids' => [$newAfter['person_id']], 'before' => $before, 'after' => $newAfter, 'work_item_id' => $iid, 'ref' => $item['ref'], 'title' => $item['title'], 'priority' => $item['priority'], 'person_id' => $newAfter['person_id'], 'start_shift_days' => null, 'finish_shift_days' => null, 'protected_multiplier' => 1, 'objective_delta' => null, 'person_name' => $model['people'][$newAfter['person_id']]['name'] ?? null];
    $re['objective_delta'] = attribute_change_delta($re, $model['committed'], $cand, $model, plan_objective($model['committed'], $model));
    $re['guardrail_status'] = $re['inside_freeze'] ? 'needs_approval' : 'ok';
    $re = explain_change($re, $model, [], []);
    $warnings = plan_check_constraints(array_values(array_filter($cand, fn($a) => $a['work_item_id'] === $iid)), $model);
    $newAfter['label'] = $re['after']['label'] ?? null;
    $old = load_change_row($conn, $c['id']);
    update($conn, 'change_proposals', [
        'after_json' => json_encode($newAfter, JSON_UNESCAPED_UNICODE), 'person_id' => $newAfter['person_id'], 'kind' => $re['kind'], 'headline' => mb_substr($re['headline'], 0, 200),
        'stability_cost_days' => $re['stability_cost_days'], 'inside_freeze' => $re['inside_freeze'] ? 1 : 0, 'impact_chips' => json_encode(array_merge($re['impact_chips'], [['label' => 'Edited by ' . $userName, 'tone' => 'info']]), JSON_UNESCAPED_UNICODE),
        'affected_person_ids' => implode(',', array_unique(array_merge($re['affected_person_ids'], csv_ids($c['affected_person_ids'])))), 'objective_delta' => json_encode($re['objective_delta']),
        'guardrail_status' => $re['inside_freeze'] ? 'needs_approval' : 'ok', 'guardrail_reason' => $re['inside_freeze'] ? 'Edited into the freeze horizon: approved by ' . $userName : null,
        'decision' => 'edited', 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => mb_substr($reason, 0, 300),
    ], 'id = ?', [(int)$c['id']]);
    audit($conn, $wsId, 'update', 'change_proposal', (int)$c['id'], ['after' => json_col($old['after_json'], null)], ['after' => $newAfter], $re['headline'], $reason);
    ok(['change' => change_x($conn, load_change_row($conn, $c['id']), $wsId), 'warnings' => $warnings]);
}

if ($action === 'acknowledge') {
    $c = load_change($conn, $wsId, (int)require_param('change_id'));
    $affected = csv_ids($c['affected_person_ids']);
    if (!$personId || (!in_array($personId, $affected, true) && (int)$c['person_id'] !== $personId)) { if (!has_role('team_lead')) fail('Only an affected person can acknowledge this change', 403); }
    update($conn, 'change_proposals', ['acknowledged_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$c['id']]);
    audit($conn, $wsId, 'update', 'change_proposal', (int)$c['id'], null, ['acknowledged' => true, 'ack_required' => (bool)$c['ack_required']], $c['headline']);
    ok(['change' => change_x($conn, load_change_row($conn, $c['id']), $wsId)]);
}
if ($action === 'comment') {
    $c = load_change($conn, $wsId, (int)require_param('change_id'));
    $body = trim((string)require_param('body'));
    $id = insert($conn, 'item_comments', ['workspace_id' => $wsId, 'work_item_id' => $c['work_item_id'], 'change_proposal_id' => (int)$c['id'], 'author_user_id' => $userId, 'author_name' => $userName, 'body' => $body]);
    foreach (csv_ids($c['affected_person_ids']) as $pid) if ($pid !== $personId) notify_person($conn, $wsId, $pid, 'change_proposed', "$userName commented on \"{$c['headline']}\"", mb_substr($body, 0, 300), "/changes/{$c['proposal_id']}");
    foreach (delivery_lead_user_ids($conn, $wsId) as $uid) if ($uid !== $userId) notify($conn, $wsId, $uid, 'change_proposed', "$userName commented on \"{$c['headline']}\"", mb_substr($body, 0, 300), "/changes/{$c['proposal_id']}");
    audit($conn, $wsId, 'create', 'comment', $id, null, ['change_id' => (int)$c['id'], 'body' => $body], $c['headline']);
    ok(['comment' => ['id' => $id, 'author_name' => $userName, 'body' => $body, 'created_at' => date('Y-m-d H:i:s')]]);
}
if ($action === 'mine') {
    if ($personId === null) ok(['changes' => [], 'pending_ack' => []]);
    $since = date('Y-m-d', strtotime(today() . ' -8 weeks'));
    $rowsMine = rows($conn, "SELECT c.*, p.status AS proposal_status, p.kind AS proposal_kind, p.generated_at FROM dbo.change_proposals c JOIN dbo.proposals p ON p.id = c.proposal_id
                              WHERE c.workspace_id = ? AND p.generated_at >= ? AND (c.person_id = ? OR ',' + ISNULL(c.affected_person_ids,'') + ',' LIKE ?) ORDER BY p.generated_at DESC, c.sort_order", [$wsId, $since, $personId, "%,$personId,%"]);
    $changes = []; $pending = [];
    foreach ($rowsMine as $r) {
        $s = change_x($conn, $r, $wsId); $s['proposal_status'] = $r['proposal_status']; $s['proposal_kind'] = $r['proposal_kind']; $s['generated_at'] = $r['generated_at'];
        $changes[] = $s;
        // CHG-06: an acknowledgement is pending only when the commit actually asked for one.
        // `require_ack_inside_horizon` is read at commit time and recorded on the row, so turning
        // the switch off stops asking instead of merely hiding the request.
        if (awaiting_ack($r)) $pending[] = $s;
    }
    ok(['changes' => $changes, 'pending_ack' => $pending]);
}
fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------------------------
function current_policy_arr($conn, $wsId) { return model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []); }

/**
 * CHG-06. A committed change is awaiting acknowledgement when the commit recorded that one was
 * required (`ack_required`, written from `require_ack_inside_horizon`) and nobody has given it.
 */
function awaiting_ack(array $r) {
    return (int)($r['ack_required'] ?? 0) === 1 && $r['acknowledged_at'] === null
        && in_array($r['decision'], ['accepted', 'edited'], true);
}
/** Change shape + the acknowledgement state, which engine/proposals.php's change_shape() does not carry. */
function change_x($conn, array $r, $wsId) {
    $s = change_shape($conn, $r, $wsId);
    $s['ack_required'] = (int)($r['ack_required'] ?? 0) === 1;
    $s['awaiting_ack'] = awaiting_ack($r);
    return $s;
}
function load_changes_x($conn, $wsId, $proposalId) {
    return array_map(fn($r) => change_x($conn, $r, $wsId), rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND workspace_id = ? ORDER BY sort_order, id", [$proposalId, $wsId]));
}
function proposal_payload($conn, $wsId, array $p) {
    $all = load_changes_x($conn, $wsId, (int)$p['id']);
    $shape = proposal_shape($conn, $p, $wsId);
    $awaiting = array_values(array_filter($all, fn($c) => $c['awaiting_ack']));
    $shape['counts']['awaiting_ack'] = count($awaiting);
    return ['proposal' => $shape,
        'changes' => array_values(array_filter($all, fn($c) => in_array($c['guardrail_status'], ['ok', 'needs_approval']))),
        'held' => array_values(array_filter($all, fn($c) => !in_array($c['guardrail_status'], ['ok', 'needs_approval']))),
        'awaiting_ack' => $awaiting,
        'guardrails' => guardrail_descriptions(current_policy_arr($conn, $wsId)),
        'counts' => $shape['counts'],
        'comments' => rows($conn, "SELECT id, change_proposal_id, author_name, body, created_at FROM dbo.item_comments WHERE change_proposal_id IN (SELECT id FROM dbo.change_proposals WHERE proposal_id = ?) ORDER BY created_at", [(int)$p['id']])];
}
function load_change_row($conn, $id) { return row($conn, "SELECT * FROM dbo.change_proposals WHERE id = ?", [(int)$id]); }
function load_change($conn, $wsId, $id) {
    $c = row($conn, "SELECT * FROM dbo.change_proposals WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$c) fail('Change not found', 404);
    return $c;
}
function open_proposal($conn, $wsId, $id) {
    $p = row($conn, "SELECT * FROM dbo.proposals WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$p) fail('Proposal not found', 404);
    if ($p['status'] !== 'open') fail('This proposal is ' . $p['status'] . ' and can no longer be changed', 409);
    return $p;
}
function decide_change($conn, $wsId, array $c, $decision, $reason) {
    global $userId, $userName;
    $p = row($conn, "SELECT status FROM dbo.proposals WHERE id = ?", [(int)$c['proposal_id']]);
    if (!$p || $p['status'] !== 'open') fail('This proposal is no longer open', 409);
    if ($decision === 'accepted') {
        if ($c['guardrail_status'] === 'needs_approval' && $reason === '') fail('This change is inside the freeze horizon: a reason is required to approve it', 409, ['guardrail_status' => 'needs_approval', 'guardrail_reason' => $c['guardrail_reason']]);
        if (in_array($c['guardrail_status'], ['held_budget', 'held_threshold'], true)) {
            if (!has_role('admin')) fail($c['guardrail_reason'] ?: 'Held by a guardrail: an administrator override with a reason is required', 409, ['guardrail_status' => $c['guardrail_status'], 'guardrail_reason' => $c['guardrail_reason']]);
            if ($reason === '') fail('Overriding a guardrail requires a reason', 409, ['guardrail_status' => $c['guardrail_status'], 'guardrail_reason' => $c['guardrail_reason']]);
        }
    }
    update($conn, 'change_proposals', ['decision' => $decision, 'decided_by' => $userId, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason !== '' ? mb_substr($reason, 0, 300) : null], 'id = ?', [(int)$c['id']]);
    audit($conn, $wsId, $decision === 'accepted' ? 'approve' : 'reject', 'change_proposal', (int)$c['id'], ['decision' => $c['decision']], ['decision' => $decision, 'guardrail_status' => $c['guardrail_status']], $c['headline'], $reason ?: null);
}

// commit_proposal() lives in engine/commit.php: replan.php's nightly auto-apply (CHG-07) needs
// the same materialisation, and duplicating it would be two things to keep in step.
