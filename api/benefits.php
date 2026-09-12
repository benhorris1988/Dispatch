<?php
// Benefits register (BEN-*): benefits per item, totals, realisation by quarter, CSV export.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/items_lib.php';
require_once __DIR__ . '/engine/priority.php';
$action = param('action', 'list');

if ($action === 'list') {
    $where = ['b.workspace_id = ?']; $params = [$wsId];
    if ($t = param('type')) { $where[] = 'b.type = ?'; $params[] = $t; }
    if ($s = param('status')) { $where[] = 'b.status = ?'; $params[] = $s; }
    if (($o = param('owner')) !== null && $o !== '') {
        if (is_numeric($o)) { $where[] = 'b.owner_person_id = ?'; $params[] = (int)$o; }
        else { $where[] = '(b.owner_name LIKE ? OR p.name LIKE ?)'; $params[] = "%$o%"; $params[] = "%$o%"; }
    }
    if ($qtr = param('quarter')) {
        if (preg_match('/Q([1-4])\s*(\d{4})/i', $qtr, $m)) { $from = sprintf('%04d-%02d-01', $m[2], ($m[1] - 1) * 3 + 1); $to = date('Y-m-d', strtotime("$from +3 months")); $where[] = 'b.realisation_from >= ? AND b.realisation_from < ?'; $params[] = $from; $params[] = $to; }
    }
    if (($wid = idp('work_item_id')) !== null) { $where[] = 'b.work_item_id = ?'; $params[] = (int)$wid; }
    $rows = rows($conn, "SELECT b.*, p.name AS owner_person_name, wi.ref, wi.title, wi.status AS item_status, wt.colour AS item_type_colour, wt.name AS item_type_name
        FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.people p ON p.id = b.owner_person_id
        WHERE " . implode(' AND ', $where) . " ORDER BY b.annual_value DESC, b.id", $params);
    $benefits = array_map(fn($r) => benefit_shape($r) + ['ref' => $r['ref'], 'title' => $r['title'], 'item_status' => $r['item_status'], 'item_type_colour' => $r['item_type_colour'], 'item_type_name' => $r['item_type_name']], $rows);

    $today = today(); $year = substr($today, 0, 4);
    $qStart = sprintf('%s-%02d-01', $year, (int)((ceil((int)substr($today, 5, 2) / 3) - 1) * 3 + 1));
    $t = row($conn, "SELECT
        -- Value in the plan = value riding on work that is actually IN the plan, i.e.
        -- scheduled or under way, not everything sitting in the pipeline. Counting the
        -- whole backlog overstates what the team is on course to deliver: an unscheduled
        -- item's benefit is precisely the value that is NOT yet in the plan. in_pipeline
        -- carries the wider figure for anyone who wants it.
        SUM(CASE WHEN wi.status IN ('scheduled','in_progress') THEN b.annual_value ELSE 0 END) AS in_plan,
        SUM(CASE WHEN wi.status NOT IN ('delivered','cancelled') THEN b.annual_value ELSE 0 END) AS in_pipeline,
        SUM(CASE WHEN b.status = 'at_risk' THEN b.annual_value ELSE 0 END) AS at_risk,
        SUM(CASE WHEN b.status = 'at_risk' THEN 1 ELSE 0 END) AS at_risk_count,
        SUM(CASE WHEN b.created_at >= ? AND wi.status IN ('scheduled','in_progress') THEN b.annual_value ELSE 0 END) AS added_this_quarter,
        COUNT(*) AS benefit_count, COUNT(DISTINCT b.work_item_id) AS items_with_benefits
        FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id WHERE b.workspace_id = ?", [$qStart, $wsId]);
    $realisedYtd = (float)scalar($conn, "SELECT ISNULL(SUM(r.realised_value),0) FROM dbo.benefit_realisations r JOIN dbo.benefits b ON b.id = r.benefit_id
        WHERE b.workspace_id = ? AND r.realised_value IS NOT NULL AND r.confirmed_at IS NOT NULL AND r.quarter LIKE ?", [$wsId, "% $year"]);
    $plannedYear = (float)scalar($conn, "SELECT ISNULL(SUM(r.planned_value),0) FROM dbo.benefit_realisations r JOIN dbo.benefits b ON b.id = r.benefit_id WHERE b.workspace_id = ? AND r.quarter LIKE ?", [$wsId, "% $year"]);
    $openItems = rows($conn, "SELECT wi.id, sc.stamp, wt.name AS type_name, wt.requires_benefit, (SELECT COUNT(*) FROM dbo.benefits b WHERE b.work_item_id = wi.id) AS n
        FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        WHERE wi.workspace_id = ? AND wi.status NOT IN ('delivered','cancelled') AND wt.policy = 'planned'", [$wsId]);
    $without = array_values(array_filter($openItems, fn($i) => (int)$i['requires_benefit'] === 1 && (int)$i['n'] === 0));
    $note = null;
    if ($without) {
        $types = array_unique(array_column($without, 'type_name')); $stamps = array_unique(array_column($without, 'stamp'));
        if (count($types) === 1 && count($stamps) === 1 && $stamps[0] === 'S') $note = 'All are Small ' . strtolower($types[0]) . 's';
        elseif (count($types) === 1) $note = 'All are ' . $types[0] . 's';
        elseif (count($stamps) === 1 && $stamps[0]) $note = 'All are size ' . $stamps[0];
    }
    $totals = ['in_plan' => (int)round((float)$t['in_plan']), 'in_pipeline' => (int)round((float)$t['in_pipeline']), 'realised_ytd' => (int)round($realisedYtd), 'at_risk' => (int)round((float)$t['at_risk']), 'at_risk_count' => (int)$t['at_risk_count'],
        'items_without_case' => count($without), 'items_without_case_note' => $note, 'items_total' => count($openItems), 'items_with_benefits' => (int)$t['items_with_benefits'], 'benefit_count' => (int)$t['benefit_count'],
        'added_this_quarter' => (int)round((float)$t['added_this_quarter']), 'target_annual' => (int)round($plannedYear), 'target_pct' => $plannedYear > 0 ? (int)round($realisedYtd / $plannedYear * 100) : null, 'year' => (int)$year];

    $byType = [];
    foreach (rows($conn, "SELECT b.type, SUM(b.annual_value) AS v, COUNT(*) AS n FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id WHERE b.workspace_id = ? AND wi.status <> 'cancelled' GROUP BY b.type ORDER BY SUM(b.annual_value) DESC", [$wsId]) as $r) {
        $meta = DP_BENEFIT_TYPES[$r['type']] ?? DP_BENEFIT_TYPES['other'];
        $byType[] = ['type' => $r['type'], 'label' => $meta['label'], 'colour' => $meta['colour'], 'value' => (int)round((float)$r['v']), 'count' => (int)$r['n']];
    }
    $byQ = rows($conn, "SELECT r.quarter, SUM(r.planned_value) AS planned, SUM(CASE WHEN r.confirmed_at IS NOT NULL THEN r.realised_value ELSE 0 END) AS realised, SUM(CASE WHEN r.confirmed_at IS NOT NULL THEN 1 ELSE 0 END) AS confirmed
        FROM dbo.benefit_realisations r JOIN dbo.benefits b ON b.id = r.benefit_id WHERE b.workspace_id = ? GROUP BY r.quarter", [$wsId]);
    usort($byQ, fn($a, $b) => quarter_sort_key($a['quarter']) <=> quarter_sort_key($b['quarter']));
    $cp = 0; $cr = 0; $byQuarter = [];
    foreach ($byQ as $r) { $cp += (float)$r['planned']; $cr += (float)$r['realised']; $byQuarter[] = ['quarter' => $r['quarter'], 'label' => preg_replace('/(Q\d)\s+\d\d(\d\d)/', '$1 $2', $r['quarter']), 'planned' => (int)round($cp), 'realised' => (int)round($cr), 'planned_in_quarter' => (int)round((float)$r['planned']), 'realised_in_quarter' => (int)round((float)$r['realised']), 'confirmed' => (int)$r['confirmed'] > 0]; }
    $byOwner = array_map(fn($r) => ['owner_name' => $r['owner'], 'owner_person_id' => $r['owner_person_id'] !== null ? (int)$r['owner_person_id'] : null, 'count' => (int)$r['n'], 'value' => (int)round((float)$r['v']), 'realised' => (int)round((float)$r['realised'])],
        rows($conn, "SELECT COALESCE(b.owner_name, p.name, 'Unassigned') AS owner, MIN(b.owner_person_id) AS owner_person_id, COUNT(*) AS n, SUM(b.annual_value) AS v, SUM(ISNULL(b.realised_value,0)) AS realised
            FROM dbo.benefits b LEFT JOIN dbo.people p ON p.id = b.owner_person_id JOIN dbo.work_items wi ON wi.id = b.work_item_id WHERE b.workspace_id = ? AND wi.status <> 'cancelled' GROUP BY COALESCE(b.owner_name, p.name, 'Unassigned') ORDER BY SUM(b.annual_value) DESC", [$wsId]));
    $pw = current_policy($conn, $wsId)['priority_weights'] ?: [];
    $cs = $pw['confidenceScale'] ?? ['high' => 1, 'medium' => 0.7, 'low' => 0.4];
    ok(['benefits' => $benefits, 'totals' => $totals, 'by_type' => $byType, 'by_quarter' => $byQuarter, 'by_owner' => $byOwner,
        'priority_note' => sprintf('Benefit value contributes %d%% of the priority score. Confidence scales it: High ×%s, Medium ×%s, Low ×%s.', (int)($pw['value'] ?? 40), $cs['high'] ?? 1, $cs['medium'] ?? 0.7, $cs['low'] ?? 0.4),
        'types' => array_map(fn($k, $v) => ['type' => $k] + $v, array_keys(DP_BENEFIT_TYPES), DP_BENEFIT_TYPES)]);
}

if ($action === 'get') {
    $id = (int)require_param('id');
    $b = row($conn, "SELECT b.*, p.name AS owner_person_name, wi.ref, wi.title FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id LEFT JOIN dbo.people p ON p.id = b.owner_person_id WHERE b.id = ? AND b.workspace_id = ?", [$id, $wsId]);
    if (!$b) fail('Benefit not found', 404);
    ok(['benefit' => benefit_shape($b) + ['ref' => $b['ref'], 'title' => $b['title']], 'realisations' => realisations_for($conn, $id)]);
}

if ($action === 'save') {
    require_role('benefit_owner');
    $id = idp('id');
    $ex = $id !== null ? row($conn, "SELECT * FROM dbo.benefits WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$ex) fail('Benefit not found', 404);
    $wid = (int)($ex['work_item_id'] ?? require_param('work_item_id'));
    $wi = row($conn, "SELECT id, ref, status, work_type_id FROM dbo.work_items WHERE id = ? AND workspace_id = ?", [$wid, $wsId]);
    if (!$wi) fail('Work item not found', 404);
    $type = param('type', $ex['type'] ?? null); if (!isset(DP_BENEFIT_TYPES[$type])) fail('type must be one of ' . implode(', ', array_keys(DP_BENEFIT_TYPES)), 400);
    $conf = strtolower(param('confidence', $ex['confidence'] ?? 'medium')); if (!in_array($conf, ['low','medium','high'], true)) fail('confidence must be low, medium or high', 400);
    $status = param('status', $ex['status'] ?? 'planned'); if (!in_array($status, ['planned','in_flight','realising','realised','at_risk'], true)) fail('Invalid status', 400);
    $val = param('annual_value', $ex['annual_value'] ?? null);
    if ($val === null || $val === '' || (float)$val < 0) fail('annual_value is required (whole currency units; 0 allowed for qualitative benefits)', 422);
    $data = ['work_item_id' => $wid, 'type' => $type, 'annual_value' => round((float)$val, 2), 'currency' => param('currency', $ex['currency'] ?? 'GBP'), 'confidence' => $conf,
        'qualitative_scale' => param('qualitative_scale', $ex['qualitative_scale'] ?? null) !== null ? (int)param('qualitative_scale', $ex['qualitative_scale'] ?? null) : null,
        'realisation_from' => nz(param('realisation_from', $ex['realisation_from'] ?? null)),
        'owner_person_id' => nz(param('owner_person_id', $ex['owner_person_id'] ?? null)), 'owner_name' => param('owner_name', $ex['owner_name'] ?? null),
        'narrative' => param('narrative', $ex['narrative'] ?? null), 'status' => $status];
    if ($data['owner_person_id'] !== null && !$data['owner_name']) $data['owner_name'] = scalar($conn, "SELECT name FROM dbo.people WHERE id = ?", [$data['owner_person_id']]);
    if ($ex) {
        $before = []; $after = [];
        foreach ($data as $k => $v) if ((string)$ex[$k] !== (string)$v && !($ex[$k] === null && $v === null)) { $before[$k] = is_numeric($ex[$k]) ? $ex[$k] + 0 : $ex[$k]; $after[$k] = $v; }
        update($conn, 'benefits', $data, 'id = ?', [$id]);
        if ($after) audit($conn, $wsId, 'update', 'benefit', $id, ['field' => 'benefit', 'value' => $before], ['field' => 'benefit', 'value' => $after], $wi['ref']);
    } else {
        $id = insert($conn, 'benefits', $data + ['workspace_id' => $wsId]);
        audit($conn, $wsId, 'create', 'benefit', $id, null, ['field' => 'benefit', 'value' => $data], $wi['ref']);
        // Seed a planned realisation for the first four quarters from realisation_from so the by-quarter view has something to compare.
        if ($data['realisation_from'] && $data['annual_value'] > 0) {
            $d = new DateTime($data['realisation_from']);
            for ($i = 0; $i < 4; $i++) { insert($conn, 'benefit_realisations', ['benefit_id' => $id, 'quarter' => quarter_label($d->format('Y-m-d')), 'planned_value' => round($data['annual_value'] / 4, 2)]); $d->modify('+3 months'); }
        }
        if ($wi['status'] === 'needs_benefit') {
            $wtype = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$wi['work_type_id']]);
            $next = policy_status_after_intake($conn, $wtype, $wid);
            if ($next !== 'needs_benefit') { update($conn, 'work_items', ['status' => $next, 'ready_at' => $next === 'ready' ? date('Y-m-d H:i:s') : null, 'updated_at' => date('Y-m-d H:i:s')], 'id = ?', [$wid]);
                audit($conn, $wsId, 'status', 'work_item', $wid, ['field' => 'status', 'value' => 'needs_benefit'], ['field' => 'status', 'value' => $next], $wi['ref'], 'benefit case added'); }
        }
    }
    q($conn, "UPDATE dbo.work_items SET updated_at = SYSDATETIME() WHERE id = ?", [$wid]);
    $terms = compute_priority_for_item($conn, $wsId, $wid);
    $b = row($conn, "SELECT b.*, p.name AS owner_person_name FROM dbo.benefits b LEFT JOIN dbo.people p ON p.id = b.owner_person_id WHERE b.id = ?", [$id]);
    ok(['benefit' => benefit_shape($b) + ['ref' => $wi['ref']], 'priority_score' => $terms['scaled'] ?? null, 'priority_terms' => $terms]);
}

if ($action === 'delete') {
    require_role('benefit_owner');
    $id = (int)require_param('id');
    $b = row($conn, "SELECT b.*, wi.ref FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id WHERE b.id = ? AND b.workspace_id = ?", [$id, $wsId]);
    if (!$b) fail('Benefit not found', 404);
    q($conn, "DELETE FROM dbo.benefit_realisations WHERE benefit_id = ?", [$id]);
    q($conn, "DELETE FROM dbo.benefits WHERE id = ?", [$id]);
    audit($conn, $wsId, 'delete', 'benefit', $id, ['field' => 'benefit', 'value' => ['type' => $b['type'], 'annual_value' => (float)$b['annual_value']]], null, $b['ref'], param('reason'));
    $terms = compute_priority_for_item($conn, $wsId, (int)$b['work_item_id']);
    ok(['deleted' => $id, 'priority_score' => $terms['scaled'] ?? null]);
}

if ($action === 'record_realisation') {
    require_role('benefit_owner');
    $bid = (int)require_param('benefit_id');
    $b = row($conn, "SELECT b.*, wi.ref FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id WHERE b.id = ? AND b.workspace_id = ?", [$bid, $wsId]);
    if (!$b) fail('Benefit not found', 404);
    $quarter = trim((string)require_param('quarter'));
    if (!preg_match('/^Q[1-4] \d{4}$/', $quarter)) fail("quarter must look like 'Q1 2027'", 400);
    $val = round((float)require_param('realised_value'), 2);
    $ex = row($conn, "SELECT * FROM dbo.benefit_realisations WHERE benefit_id = ? AND quarter = ?", [$bid, $quarter]);
    $now = date('Y-m-d H:i:s');
    if ($ex) update($conn, 'benefit_realisations', ['realised_value' => $val, 'confirmed_by' => $userId, 'confirmed_at' => $now, 'planned_value' => param('planned_value') !== null ? (float)param('planned_value') : $ex['planned_value']], 'id = ?', [$ex['id']]);
    else insert($conn, 'benefit_realisations', ['benefit_id' => $bid, 'quarter' => $quarter, 'planned_value' => param('planned_value') !== null ? (float)param('planned_value') : round((float)$b['annual_value'] / 4, 2), 'realised_value' => $val, 'confirmed_by' => $userId, 'confirmed_at' => $now]);
    $cum = (float)scalar($conn, "SELECT ISNULL(SUM(realised_value),0) FROM dbo.benefit_realisations WHERE benefit_id = ? AND confirmed_at IS NOT NULL", [$bid]);
    $status = ($b['annual_value'] > 0 && $cum >= (float)$b['annual_value']) ? 'realised' : 'realising';
    update($conn, 'benefits', ['realised_value' => $cum, 'status' => $status], 'id = ?', [$bid]);
    audit($conn, $wsId, 'realise', 'benefit_realisation', $bid, ['field' => 'realised', 'value' => ['status' => $b['status'], 'cumulative' => (float)($b['realised_value'] ?? 0)]], ['field' => 'realised', 'value' => ['quarter' => $quarter, 'realised_value' => $val, 'cumulative' => $cum, 'status' => $status]], $b['ref']);
    $bb = row($conn, "SELECT b.*, p.name AS owner_person_name FROM dbo.benefits b LEFT JOIN dbo.people p ON p.id = b.owner_person_id WHERE b.id = ?", [$bid]);
    ok(['benefit' => benefit_shape($bb) + ['ref' => $b['ref']], 'realisations' => realisations_for($conn, $bid)]);
}

if ($action === 'export_csv') {
    $rows = rows($conn, "SELECT wi.ref, wi.title, wt.name AS work_type, b.type, b.annual_value, b.currency, b.confidence, b.realisation_from, COALESCE(b.owner_name, p.name) AS owner, b.status, b.realised_value, b.narrative
        FROM dbo.benefits b JOIN dbo.work_items wi ON wi.id = b.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.people p ON p.id = b.owner_person_id
        WHERE b.workspace_id = ? ORDER BY wi.ref, b.annual_value DESC", [$wsId]);
    $fh = fopen('php://temp', 'w+');
    fputcsv($fh, ['Ref','Title','Work type','Benefit type','Annual value','Currency','Confidence','Realisation from','Realisation quarter','Owner','Status','Realised to date','Narrative']);
    foreach ($rows as $r) fputcsv($fh, [$r['ref'], $r['title'], $r['work_type'], DP_BENEFIT_TYPES[$r['type']]['label'] ?? $r['type'], (int)round((float)$r['annual_value']), $r['currency'], ucfirst($r['confidence']), $r['realisation_from'], $r['realisation_from'] ? quarter_label($r['realisation_from']) : '', $r['owner'], $r['status'], $r['realised_value'] !== null ? (int)round((float)$r['realised_value']) : '', $r['narrative']]);
    rewind($fh); $csv = stream_get_contents($fh); fclose($fh);
    audit($conn, $wsId, 'export', 'benefit', null, null, ['rows' => count($rows)], 'benefits register');
    ok(['csv' => $csv, 'rows' => count($rows), 'filename' => 'benefits-' . today() . '.csv']);
}

fail('Unknown action', 400);

function realisations_for($conn, $bid) {
    $r = rows($conn, "SELECT r.*, u.display_name AS confirmed_by_name FROM dbo.benefit_realisations r LEFT JOIN dbo.users u ON u.id = r.confirmed_by WHERE r.benefit_id = ?", [$bid]);
    usort($r, fn($a, $b) => quarter_sort_key($a['quarter']) <=> quarter_sort_key($b['quarter']));
    return array_map(fn($x) => ['id' => (int)$x['id'], 'quarter' => $x['quarter'], 'planned_value' => (int)round((float)$x['planned_value']), 'realised_value' => $x['realised_value'] !== null ? (int)round((float)$x['realised_value']) : null,
        'confirmed_by_name' => $x['confirmed_by_name'], 'confirmed_at' => $x['confirmed_at'] ? substr($x['confirmed_at'], 0, 19) : null], $r);
}
