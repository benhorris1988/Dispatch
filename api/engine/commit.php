<?php
// Materialising a proposal into a new committed plan version (CHG-05/06/07, EST-09, NOT-01).
//
// This lives beside the engine rather than inside changes.php because two callers need it:
// changes.php (`commit`, `accept_all_passing`) and replan.php (the nightly auto-apply of
// changes that fall wholly outside the freeze horizon). Pure PHP over $conn; every write is
// audited here rather than by the caller, because the caller may be the nightly cron.
require_once __DIR__ . '/proposals.php';

/**
 * EST-09. When the workspace policy sets `reestimate_class_threshold`, an item whose latest
 * estimate class is WORSE than the threshold may not enter the committed window.
 *
 * Estimate classes run 5 (±50%, the roughest) down to 1 (±5%), so "worse than 3" means a
 * stored class of 4 or 5. Only a change that puts work inside the freeze horizon which was
 * not already committed there is blocked: work already in the window is not entering it, and
 * a change that lives wholly outside it never enters it either.
 *
 * @return array [ ['work_item_id','ref','estimate_class','threshold','change_id'], ... ] — empty when nothing is blocked.
 */
function reestimate_blocked_changes($conn, $wsId, array $model, array $changeRows) {
    $policy = current_policy($conn, $wsId);
    $threshold = $policy['reestimate_class_threshold'] ?? null;
    if ($threshold === null || $threshold === '') return [];
    $threshold = (int)$threshold;
    $freezeEnd = $model['windows']['freeze_end'];
    $items = load_item_map($conn, $wsId);
    $blocked = []; $classes = [];
    foreach ($changeRows as $r) {
        if ($r['work_item_id'] === null) continue;
        $iid = (int)$r['work_item_id'];
        $after = json_col($r['after_json'], null);
        $before = json_col($r['before_json'], null);
        if (!$after || empty($after['from'])) continue;                 // a removal never enters the window
        if ($after['from'] > $freezeEnd) continue;                      // stays outside the committed window
        if ($before && !empty($before['from']) && $before['from'] <= $freezeEnd) continue;  // already in it
        if (!array_key_exists($iid, $classes)) {
            $classes[$iid] = scalar($conn, "SELECT TOP 1 estimate_class FROM dbo.estimates WHERE work_item_id = ? ORDER BY version DESC", [$iid]);
        }
        if ($classes[$iid] === null) continue;                          // no estimate: readiness catches that, not this
        if ((int)$classes[$iid] <= $threshold) continue;
        $blocked[] = ['change_id' => (int)$r['id'], 'work_item_id' => $iid, 'ref' => $items[$iid]['ref'] ?? "#$iid",
            'estimate_class' => (int)$classes[$iid], 'threshold' => $threshold];
    }
    return $blocked;
}

/** The sentence shown when EST-09 stops a commit. */
function reestimate_block_message(array $blocked) {
    $refs = [];
    foreach ($blocked as $b) $refs[$b['ref']] = "{$b['ref']} (class {$b['estimate_class']})";
    $t = (int)$blocked[0]['threshold'];
    return 'Re-estimate required before entering the committed window: ' . implode(', ', $refs)
        . '. The policy allows class ' . $t . ' or better inside the horizon.';
}

/**
 * Materialise accepted changes into a new committed version (CHG-05/06), notify, log, roll up stability.
 *
 * $opts:
 *   'auto_applied' => true  — the nightly applied these without review (CHG-07); recorded on the audit row.
 */
function commit_proposal($conn, $wsId, array $p, array $opts = []) {
    global $userId, $userName;
    $accepted = rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND decision IN ('accepted','edited') ORDER BY sort_order", [(int)$p['id']]);
    $model = build_model($conn, $wsId);
    $policy = current_policy($conn, $wsId);
    $requireAck = !empty($policy['require_ack_inside_horizon']);
    // EST-09 is a gate on the committed window, so it is checked before anything is written.
    $blocked = reestimate_blocked_changes($conn, $wsId, $model, $accepted);
    if ($blocked) fail(reestimate_block_message($blocked), 409, ['reestimate_blocked' => $blocked]);

    $vid = null; $movedDays = 0; $insideCount = 0; $ackRequired = 0; $assigned = 0;
    if ($accepted) {
        $changes = array_map(fn($r) => ['work_item_id' => (int)$r['work_item_id'], 'kind' => $r['kind'], 'before' => json_col($r['before_json'], null), 'after' => json_col($r['after_json'], null)], $accepted);
        $vid = new_committed_version($conn, $wsId, $model, function (&$rows) use ($changes) { foreach ($changes as $c) apply_change_to_rows($rows, $c); },
            ['engine' => $p['engine'] ?: 'heuristic', 'notes' => 'Committed from proposal #' . $p['id'] . ' (' . count($accepted) . ' change' . (count($accepted) === 1 ? '' : 's') . ')' . (!empty($opts['auto_applied']) ? ', auto-applied outside the freeze horizon' : '')]);
        $items = load_item_map($conn, $wsId);
        foreach ($accepted as $r) {
            $before = json_col($r['before_json'], null); $after = json_col($r['after_json'], null);
            $week = week_start(($after['from'] ?? null) ?: ($before['from'] ?? $model['today']));
            $pids = array_unique(array_filter([(int)($before['person_id'] ?? 0), (int)($after['person_id'] ?? 0)]));
            $days = (float)$r['stability_cost_days']; $movedDays += $days; if ((int)$r['inside_freeze']) $insideCount++;
            foreach ($pids as $pid) {
                insert($conn, 'person_change_log', ['workspace_id' => $wsId, 'person_id' => $pid, 'work_item_id' => $r['work_item_id'], 'week_start' => $week, 'inside_freeze' => (int)$r['inside_freeze'], 'assignment_days' => $days / count($pids), 'reason' => mb_substr((string)$r['reason'], 0, 300), 'change_proposal_id' => (int)$r['id']]);
            }
            // CHG-06: the policy switch decides whether the affected person must acknowledge a
            // committed change inside the freeze horizon. Recorded on the row so `current` and
            // `mine` can say which changes are still awaiting one, and so that turning the switch
            // off stops asking rather than merely hiding the ask.
            if ($requireAck && (int)$r['inside_freeze']) { update($conn, 'change_proposals', ['ack_required' => 1], 'id = ?', [(int)$r['id']]); $ackRequired++; }
            $ref = $items[(int)$r['work_item_id']]['ref'] ?? '';
            $title = $items[(int)$r['work_item_id']]['title'] ?? '';
            foreach (csv_ids($r['affected_person_ids']) as $pid) notify_person($conn, $wsId, $pid, 'change_committed', $r['headline'], $r['reason'], "/changes/{$p['id']}", (int)$r['inside_freeze']);
            // NOT-01 item_assigned: a commit that gives someone work they did not already hold.
            $toPid = (int)($after['person_id'] ?? 0);
            $fromPid = (int)($before['person_id'] ?? 0);
            if ($after && $toPid && (!$before || $fromPid !== $toPid)) {
                $when = 'Starts ' . date('D j M', strtotime($after['from'])) . ' at ' . (int)($after['allocation_pct'] ?? 100) . '%';
                notify_person($conn, $wsId, $toPid, 'item_assigned', "$ref $title is assigned to you", $when . ($r['reason'] ? ' · ' . $r['reason'] : ''), "/items/$ref", 0);
                $assigned++;
            }
            // requester of a displaced / delayed item (13.1 incident handling)
            if (in_array($r['kind'], ['move', 'remove', 'reassign'], true) && $r['work_item_id']) {
                $creator = scalar($conn, "SELECT created_by FROM dbo.work_items WHERE id = ?", [(int)$r['work_item_id']]);
                if ($creator) notify($conn, $wsId, (int)$creator, 'change_committed', "$ref: {$r['headline']}", $r['reason'], "/items/$ref", 0);
            }
        }
    }
    update($conn, 'proposals', ['status' => 'decided', 'decided_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$p['id']]);
    if ($p['candidate_plan_version_id']) update($conn, 'plan_versions', ['status' => 'discarded'], 'id = ? AND status = ?', [(int)$p['candidate_plan_version_id'], 'proposed']);
    $model2 = build_model($conn, $wsId);
    $stab = rollup_stability_week($conn, $wsId, $model2);
    audit($conn, $wsId, 'commit', 'proposal', (int)$p['id'], ['status' => 'open'],
        ['status' => 'decided', 'accepted' => count($accepted), 'plan_version_id' => $vid, 'moved_days' => $movedDays,
         'inside_freeze' => $insideCount, 'ack_required' => $ackRequired, 'assigned' => $assigned,
         'auto_applied' => !empty($opts['auto_applied'])], "Proposal #{$p['id']}");
    $newVersion = $vid ? row($conn, "SELECT id, version_no, status, committed_at, committed_through FROM dbo.plan_versions WHERE id = ?", [$vid]) : null;
    return ['proposal' => proposal_shape($conn, row($conn, "SELECT * FROM dbo.proposals WHERE id = ?", [(int)$p['id']]), $wsId),
        'plan_version' => $newVersion, 'committed' => count($accepted), 'stability_week' => $stab,
        'ack_required' => $ackRequired, 'items_assigned' => $assigned];
}

/**
 * CHG-07. When `auto_apply_outside_horizon` is on, changes that pass every guardrail and fall
 * wholly outside the freeze horizon are applied by the nightly cycle without review.
 *
 * Changes that still need a person — anything inside the horizon, held by a guardrail, or
 * stopped by EST-09 — are not auto-applied. Because committing closes the proposal (CHG-08),
 * the caller is told how many were left over so it can re-propose them for review against the
 * new committed baseline; leaving them inside a decided proposal would hide them for a night.
 *
 * @return array {enabled, applied:int, leftover:int, plan_version_id, blocked:[EST-09 rows]}
 */
function auto_apply_outside_horizon($conn, $wsId, $proposalId) {
    $policy = current_policy($conn, $wsId);
    if (empty($policy['auto_apply_outside_horizon'])) return ['enabled' => false, 'applied' => 0, 'leftover' => 0];
    $p = row($conn, "SELECT * FROM dbo.proposals WHERE id = ? AND workspace_id = ?", [(int)$proposalId, $wsId]);
    if (!$p || $p['status'] !== 'open') return ['enabled' => true, 'applied' => 0, 'leftover' => 0, 'skipped' => 'no open proposal'];
    if ((int)$p['below_threshold']) return ['enabled' => true, 'applied' => 0, 'leftover' => 0, 'skipped' => 'improvement below the minimum threshold (STAB-04)'];

    $model = build_model($conn, $wsId);
    $freezeEnd = $model['windows']['freeze_end'];
    $pending = rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND decision = 'pending'", [(int)$p['id']]);
    $eligible = [];
    foreach ($pending as $r) {
        if ($r['guardrail_status'] !== 'ok' || (int)$r['inside_freeze']) continue;
        $before = json_col($r['before_json'], null); $after = json_col($r['after_json'], null);
        // "Wholly outside" is asserted on the dates as well as on the diff's inside_freeze flag.
        if ($before && !empty($before['from']) && $before['from'] <= $freezeEnd) continue;
        if ($after && !empty($after['from']) && $after['from'] <= $freezeEnd) continue;
        $eligible[] = $r;
    }
    $blocked = reestimate_blocked_changes($conn, $wsId, $model, $eligible);
    if ($blocked) {
        $stop = array_flip(array_column($blocked, 'change_id'));
        $eligible = array_values(array_filter($eligible, fn($r) => !isset($stop[(int)$r['id']])));
    }
    if (!$eligible) return ['enabled' => true, 'applied' => 0, 'leftover' => count($pending), 'blocked' => $blocked];

    $reason = 'Auto-applied outside the freeze horizon (CHG-07)';
    foreach ($eligible as $r) {
        update($conn, 'change_proposals', ['decision' => 'accepted', 'decided_by' => null, 'decided_at' => date('Y-m-d H:i:s'), 'decision_reason' => $reason], 'id = ?', [(int)$r['id']]);
        audit($conn, $wsId, 'auto_apply', 'change_proposal', (int)$r['id'], ['decision' => 'pending'],
            ['decision' => 'accepted', 'auto_applied' => true, 'inside_freeze' => false, 'guardrail_status' => $r['guardrail_status']], $r['headline'], $reason);
    }
    $leftover = count($pending) - count($eligible);
    $res = commit_proposal($conn, $wsId, $p, ['auto_applied' => true]);
    audit($conn, $wsId, 'auto_apply', 'proposal', (int)$p['id'], null, ['applied' => count($eligible), 'leftover' => $leftover, 'plan_version_id' => $res['plan_version']['id'] ?? null], "Proposal #{$p['id']}", $reason);
    return ['enabled' => true, 'applied' => count($eligible), 'leftover' => $leftover,
        'plan_version_id' => $res['plan_version']['id'] ?? null, 'blocked' => $blocked];
}
