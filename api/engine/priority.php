<?php
// Priority score (spec 8.4 + Appendix B). Pure PHP, no HTTP.
//   compute_priority_scores($conn, $wsId, $itemIds = null) -> ['updated' => n, 'max_raw' => x, 'p90' => v, 'items' => [id => terms]]
//   compute_priority_for_item($conn, $wsId, $itemId)      -> terms for that item (score stored)
// Terms are always computed for every open item (normalisation and rescaling need the workspace
// distribution); when $itemIds is given only those rows are written.
require_once __DIR__ . '/../items_lib.php';

function dp_percentile(array $values, $pct) {
    $values = array_values(array_filter($values, fn($v) => $v > 0));
    if (!$values) return 0.0;
    sort($values);
    $n = count($values);
    if ($n === 1) return (float)$values[0];
    $rank = ($pct / 100) * ($n - 1);
    $lo = (int)floor($rank); $hi = (int)ceil($rank);
    return (float)($values[$lo] + ($values[$hi] - $values[$lo]) * ($rank - $lo));
}

function compute_priority_scores($conn, $wsId, $itemIds = null) {
    $policy = current_policy($conn, $wsId);
    $w = $policy['priority_weights'] ?: [];
    $W = ['value' => (float)($w['value'] ?? 40), 'urgency' => (float)($w['urgency'] ?? 25), 'risk' => (float)($w['riskCompliance'] ?? 15),
          'leverage' => (float)($w['dependencyLeverage'] ?? 10), 'age' => (float)($w['age'] ?? 10)];
    $confScale = $w['confidenceScale'] ?? ['high' => 1, 'medium' => 0.7, 'low' => 0.4];
    $sevScores = $w['severityScores'] ?? ['P1' => 100, 'P2' => 90, 'P3' => 70, 'P4' => 50];
    $riskDefaults = ['compliance' => 0.8, 'risk_reduction' => 0.6];
    $today = today();
    $wd = workspace_working_days($conn, $wsId);
    $pv = committed_plan_id($conn, $wsId) ?? -1;

    $items = rows($conn, "SELECT wi.id, wi.ref, wi.status, wi.needed_by, wi.ready_at, wi.progress_pct, wi.risk_weight, wi.severity,
            wi.priority_override_points, wi.priority_pinned_score, wi.priority_override_reason, wi.priority_override_expires, wi.priority_override_by,
            wi.custom_effort_days, wt.policy, sc.planning_days, e.likely,
            pl.planned_to
        FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id
        LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        OUTER APPLY (SELECT TOP 1 likely FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
        OUTER APPLY (SELECT MAX(a.to_date) AS planned_to FROM dbo.assignments a WHERE a.work_item_id = wi.id AND a.plan_version_id = ?) pl
        WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled')", [$pv, $wsId]);
    if (!$items) return ['updated' => 0, 'max_raw' => 0, 'p90' => 0, 'items' => []];
    $byId = []; foreach ($items as $it) $byId[(int)$it['id']] = $it;
    $in = implode(',', array_keys($byId));

    // Confidence-scaled benefit value per item, plus dominant benefit type for the risk default.
    $value = []; $rawValue = []; $riskFromType = [];
    foreach (rows($conn, "SELECT work_item_id, type, annual_value, confidence FROM dbo.benefits WHERE work_item_id IN ($in)") as $b) {
        $id = (int)$b['work_item_id'];
        $scale = (float)($confScale[strtolower($b['confidence'])] ?? 0.7);
        $value[$id] = ($value[$id] ?? 0) + (float)$b['annual_value'] * $scale;
        $rawValue[$id] = ($rawValue[$id] ?? 0) + (float)$b['annual_value'];
        $riskFromType[$id] = max($riskFromType[$id] ?? 0, $riskDefaults[$b['type']] ?? 0);
    }
    $p90 = dp_percentile(array_values($value), 90);

    // Finish-start successors per item (what this item unblocks) - only open successors count.
    $unblocks = [];
    foreach (rows($conn, "SELECT d.from_work_item_id f, d.to_work_item_id t FROM dbo.dependencies d WHERE d.workspace_id = ? AND d.type = 'finish_start' AND d.cleared_at IS NULL", [$wsId]) as $d)
        if (isset($byId[(int)$d['t']])) $unblocks[(int)$d['f']][] = (int)$d['t'];

    $results = []; $maxRaw = 0;
    foreach ($byId as $id => $it) {
        $isInterrupt = $it['policy'] === 'interrupt';
        $terms = [];
        if ($isInterrupt) {
            $sev = $it['severity'] ?: 'P3';
            $raw = (float)($sevScores[$sev] ?? 70);
            $terms['severity'] = ['input' => $sev, 'normalised' => $raw / 100, 'weight' => 100, 'contribution' => $raw];
            foreach (['value','urgency','risk','leverage','age'] as $k) $terms[$k] = ['input' => null, 'normalised' => 0, 'weight' => $W[$k], 'contribution' => 0, 'skipped' => 'interrupt policy'];
        } else {
            // Value
            $v = $value[$id] ?? 0.0;
            $vn = $p90 > 0 ? min(1.0, $v / $p90) : 0.0;
            $terms['value'] = ['input' => (int)round($v), 'input_raw' => (int)round($rawValue[$id] ?? 0), 'p90' => (int)round($p90), 'normalised' => round($vn, 2), 'weight' => $W['value'], 'contribution' => round($vn * $W['value'], 1)];
            // Urgency: slack (working days) between the expected finish and needed_by.
            $effort = $it['likely'] !== null ? (float)$it['likely'] : ($it['planning_days'] !== null ? (float)$it['planning_days'] : ($it['custom_effort_days'] !== null ? (float)$it['custom_effort_days'] : 0));
            $remaining = $effort * (1 - min(100, max(0, (int)$it['progress_pct'])) / 100);
            $finish = $it['planned_to'] && $it['planned_to'] >= $today ? $it['planned_to'] : add_working_days($today, (int)ceil($remaining), $wd);
            $slack = null; $un = 0.0;
            if ($it['needed_by']) {
                $slack = $it['needed_by'] >= $finish ? working_days_between($finish, $it['needed_by'], $wd) - 1 : -working_days_between($it['needed_by'], $finish, $wd);
                $un = $slack <= 0 ? 1.0 : ($slack > 40 ? 0.0 : 1 - $slack / 40);
            }
            $terms['urgency'] = ['input' => $it['needed_by'] ? ['needed_by' => $it['needed_by'], 'remaining_days' => round($remaining, 1), 'finish' => $finish, 'slack_days' => $slack] : null,
                                 'normalised' => round($un, 2), 'weight' => $W['urgency'], 'contribution' => round($un * $W['urgency'], 1)];
            // Risk / compliance
            $stated = $it['risk_weight'] !== null;
            $rk = $stated ? min(1, max(0, (float)$it['risk_weight'])) : (float)($riskFromType[$id] ?? 0);
            $terms['risk'] = ['input' => $rk, 'source' => $stated ? 'stated' : 'benefit type default', 'normalised' => round($rk, 2), 'weight' => $W['risk'], 'contribution' => round($rk * $W['risk'], 1)];
            // Dependency leverage
            $lv = 0.0; $unb = [];
            foreach ($unblocks[$id] ?? [] as $succ) { $lv += $value[$succ] ?? 0; $unb[] = $byId[$succ]['ref']; }
            $ln = $p90 > 0 ? min(1.0, $lv / $p90) : 0.0;
            $terms['leverage'] = ['input' => (int)round($lv), 'unblocks' => $unb, 'normalised' => round($ln, 2), 'weight' => $W['leverage'], 'contribution' => round($ln * $W['leverage'], 1)];
            // Age since ready
            $weeks = $it['ready_at'] ? max(0, (strtotime($today) - strtotime(substr($it['ready_at'], 0, 10))) / 604800) : 0;
            $an = min(1.0, $weeks / 12);
            $terms['age'] = ['input' => round($weeks, 1), 'normalised' => round($an, 2), 'weight' => $W['age'], 'contribution' => round($an * $W['age'], 1)];
            $raw = 0; foreach (['value','urgency','risk','leverage','age'] as $k) $raw += $terms[$k]['contribution'];
        }
        $expired = $it['priority_override_expires'] && $it['priority_override_expires'] < $today;
        $pinned = (!$expired && $it['priority_pinned_score'] !== null) ? (float)$it['priority_pinned_score'] : null;
        $points = (!$expired && $it['priority_override_points'] !== null) ? max(-20, min(20, (int)$it['priority_override_points'])) : 0;
        $terms['override'] = ['points' => $points, 'pinned' => $pinned, 'reason' => $expired ? null : $it['priority_override_reason'], 'expires' => $it['priority_override_expires'], 'expired' => (bool)$expired, 'by' => $it['priority_override_by'] !== null ? (int)$it['priority_override_by'] : null];
        $terms['raw_total'] = round($raw, 1);
        $results[$id] = ['terms' => $terms, 'raw' => $raw, 'interrupt' => $isInterrupt];
        if (!$isInterrupt && $pinned === null) $maxRaw = max($maxRaw, $raw);
    }

    // Scale so the top planned item sits at ~100; interrupt scores are already on the 0..100 scale.
    $now = date('Y-m-d H:i:s');
    $updated = 0;
    foreach ($results as $id => $r) {
        $t = $r['terms'];
        $scaled = $r['interrupt'] ? $r['raw'] : ($maxRaw > 0 ? $r['raw'] * 100 / $maxRaw : 0);
        if ($t['override']['pinned'] !== null) $scaled = $t['override']['pinned'];
        else $scaled += $t['override']['points'];
        $scaled = round(max(0, min(100, $scaled)), 1);
        $t['scaled'] = $scaled; $t['scale_factor'] = $maxRaw > 0 ? round(100 / $maxRaw, 3) : null; $t['computed_at'] = $now;
        $results[$id]['terms'] = $t; $results[$id]['scaled'] = $scaled;
        if ($itemIds !== null && !in_array($id, array_map('intval', (array)$itemIds), true)) continue;
        q($conn, "UPDATE dbo.work_items SET priority_score = ?, priority_terms = ? WHERE id = ?", [$scaled, json_encode($t, JSON_UNESCAPED_UNICODE), $id]);
        $updated++;
    }
    return ['updated' => $updated, 'max_raw' => round($maxRaw, 1), 'p90' => round($p90), 'items' => array_map(fn($r) => $r['terms'], $results)];
}

function compute_priority_for_item($conn, $wsId, $itemId) {
    $r = compute_priority_scores($conn, $wsId, [(int)$itemId]);
    return $r['items'][(int)$itemId] ?? null;
}
