<?php
// Shared work-item helpers used by work_items.php, estimates.php and benefits.php:
// WorkItemRow builder, estimate maths (PERT / class tolerance / implied stamp), size bands,
// readiness, dependency cycle check. Pure functions over $conn - no HTTP.
require_once __DIR__ . '/lib.php';

const DP_CLASS_TOLERANCE = [5 => 50, 4 => 40, 3 => 30, 2 => 15, 1 => 5];
const DP_CLASS_DESCRIPTIONS = [
    5 => 'Idea only; order-of-magnitude',
    4 => 'Scope outlined; approach not chosen',
    3 => 'Scope defined, design not complete. Re-estimate before entering the committed window.',
    2 => 'Design complete; tasks broken down',
    1 => 'Work under way; remaining effort known',
];
const DP_OPEN_STATUSES = ['draft','needs_estimate','needs_benefit','ready','scheduled','in_progress','blocked'];
const DP_BENEFIT_TYPES = [
    'cost_avoidance' => ['label' => 'Cost avoidance', 'colour' => '#1F9D6B'],
    'revenue'        => ['label' => 'Revenue',        'colour' => '#6D5BD0'],
    'productivity'   => ['label' => 'Productivity',   'colour' => '#3B6BD6'],
    'risk_reduction' => ['label' => 'Risk reduction', 'colour' => '#D99A00'],
    'compliance'     => ['label' => 'Compliance',     'colour' => '#8A94A6'],
    'other'          => ['label' => 'Other',          'colour' => '#5B6B84'],
];

/** null for null/'' (ids may be 0, so never use ?: on them). */
function nz($v) { return ($v === null || $v === '') ? null : $v; }
function idp($key) { $v = param($key); return ($v === null || $v === '') ? null : (int)$v; }
function class_tolerance($class) { return DP_CLASS_TOLERANCE[(int)$class] ?? 30; }
function class_list() {
    $out = [];
    foreach (DP_CLASS_TOLERANCE as $c => $t) $out[] = ['class' => $c, 'label' => "±{$t}%", 'description' => DP_CLASS_DESCRIPTIONS[$c]];
    return $out;
}

/** Current committed plan version id (or null). */
function committed_plan_id($conn, $wsId) {
    static $cache = [];
    if (!array_key_exists($wsId, $cache)) {
        $v = scalar($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY committed_at DESC, version_no DESC", [$wsId]);
        $cache[$wsId] = $v !== null ? (int)$v : null;   // ids may legitimately be 0
    }
    return $cache[$wsId];
}
// current_policy() is canonical in lib.php.
// workspace_working_days() is canonical in lib.php.
/** Blended (or latest) day rate in force today. */
function blended_day_rate($conn, $wsId) {
    $r = scalar($conn, "SELECT TOP 1 rate FROM dbo.day_rates WHERE workspace_id = ? AND effective_from <= ? ORDER BY is_blended DESC, effective_from DESC", [$wsId, today()]);
    return $r !== null ? (float)$r : 700.0;
}

/** Size classes for a type: type-specific override scope when it exists, else the workspace default scope. */
function size_bands($conn, $wsId, $workTypeId = null) {
    $bands = [];
    if ($workTypeId !== null) $bands = rows($conn, "SELECT * FROM dbo.size_classes WHERE workspace_id = ? AND work_type_id = ? ORDER BY is_custom, sort_order, min_days", [$wsId, $workTypeId]);
    if (!$bands) $bands = rows($conn, "SELECT * FROM dbo.size_classes WHERE workspace_id = ? AND work_type_id IS NULL ORDER BY is_custom, sort_order, min_days", [$wsId]);
    return $bands;
}
function size_band_for_stamp($conn, $wsId, $workTypeId, $stamp) {
    foreach (size_bands($conn, $wsId, $workTypeId) as $b) if (strcasecmp($b['stamp'], $stamp) === 0) return $b;
    return null;
}
/** Stamp of the (non-custom) band containing $days; larger than every band -> 'C'. */
function implied_stamp($conn, $wsId, $workTypeId, $days) {
    if ($days === null) return null;
    $largest = null;
    foreach (size_bands($conn, $wsId, $workTypeId) as $b) {
        if ((int)$b['is_custom']) continue;
        $min = $b['min_days'] !== null ? (float)$b['min_days'] : 0;
        $max = $b['max_days'] !== null ? (float)$b['max_days'] : INF;
        if ($days >= $min && $days <= $max) return $b['stamp'];
        if ($largest === null || $max >= (float)($largest['max_days'] ?? INF)) $largest = $b;
    }
    return 'C';
}

/** Derived maths for one estimate row (decoded). */
function estimate_derive($conn, $wsId, array $e, $workTypeId = null, $dayRateDefault = null) {
    $o = $e['optimistic'] !== null ? (float)$e['optimistic'] : null;
    $m = $e['likely'] !== null ? (float)$e['likely'] : null;
    $p = $e['pessimistic'] !== null ? (float)$e['pessimistic'] : null;
    $tol = class_tolerance($e['estimate_class'] ?? 3);
    if ($m !== null && ($o === null || $p === null)) { $o = $o ?? round($m * (1 - $tol / 100), 2); $p = $p ?? round($m * (1 + $tol / 100), 2); }
    $expected = $m !== null ? round(($o + 4 * $m + $p) / 6, 1) : null;
    $sd = $m !== null ? round(($p - $o) / 6, 1) : null;
    $p80 = $expected !== null ? round($expected + 0.8416 * (($p - $o) / 6), 1) : null;
    $rate = $e['day_rate'] !== null ? (float)$e['day_rate'] : ($dayRateDefault ?? blended_day_rate($conn, $wsId));
    $cost = $m !== null ? (int)round($m * $rate) : null;
    $e['optimistic'] = $o; $e['likely'] = $m; $e['pessimistic'] = $p;
    $e['estimate_class'] = (int)($e['estimate_class'] ?? 3);
    $e['class_label'] = "±{$tol}%";
    $e['class_description'] = DP_CLASS_DESCRIPTIONS[$e['estimate_class']] ?? '';
    $e['tolerance_pct'] = $tol;
    $e['expected'] = $expected; $e['sd'] = $sd; $e['p80'] = $p80;
    $e['implied_stamp'] = $expected !== null ? implied_stamp($conn, $wsId, $workTypeId, $expected) : null;
    $e['day_rate'] = $rate;
    $e['cost_likely'] = $cost;
    $e['cost_low'] = $cost !== null ? (int)round($cost * (1 - $tol / 100)) : null;
    $e['cost_high'] = $cost !== null ? (int)round($cost * (1 + $tol / 100)) : null;
    if (isset($e['skill_split']) && is_string($e['skill_split'])) $e['skill_split'] = json_col($e['skill_split']);
    if (isset($e['created_at'])) $e['created_at'] = substr($e['created_at'], 0, 19);
    return $e;
}
function latest_estimate($conn, $workItemId) {
    return row($conn, "SELECT TOP 1 * FROM dbo.estimates WHERE work_item_id = ? ORDER BY version DESC", [$workItemId]);
}

/** ROM range for a row (needs est_* / size band / custom columns from work_item_rows SQL). */
function rom_range(array $r) {
    $unit = ($r['size_unit'] ?? 'days') === 'hours' ? 'hours' : 'days';
    $tol = class_tolerance($r['estimate_class'] ?? 3) / 100;
    if ($r['est_id'] !== null && $r['likely'] !== null) {
        $m = (float)$r['likely'];
        if ($r['est_method'] === 'three_point' && $r['optimistic'] !== null && $r['pessimistic'] !== null) return [(float)$r['optimistic'], (float)$r['pessimistic'], $unit];
        if ($r['est_method'] === 'size' && $r['min_days'] !== null) return [(float)$r['min_days'], $r['max_days'] !== null ? (float)$r['max_days'] : round($m * (1 + $tol), 1), $unit];
        return [round($m * (1 - $tol), 1), round($m * (1 + $tol), 1), $unit];
    }
    if ($r['custom_effort_days'] !== null && ($r['size_class_id'] === null || (int)$r['is_custom'])) {
        $m = (float)$r['custom_effort_days'];
        return [round($m * (1 - $tol), 1), round($m * (1 + $tol), 1), $unit];
    }
    if ($r['size_class_id'] !== null) return [$r['min_days'] !== null ? (float)$r['min_days'] : null, $r['max_days'] !== null ? (float)$r['max_days'] : null, $unit];
    return [null, null, $unit];
}

const DP_ITEM_SELECT = "SELECT wi.*, wt.name AS type_name, wt.plural AS type_plural, wt.colour AS type_colour, wt.policy AS type_policy, wt.prefix AS type_prefix,
    wt.requires_estimate, wt.requires_benefit, wt.size_unit,
    sc.stamp AS sc_stamp, sc.name AS size_name, sc.is_custom, sc.min_days, sc.max_days, sc.planning_days, sc.default_estimate_class,
    e.id AS est_id, e.method AS est_method, e.optimistic, e.likely, e.pessimistic, e.estimate_class, e.version AS est_version, e.author_name AS est_author, e.created_at AS est_created_at,
    b.benefit_value, b.benefit_count,
    pl.planned_from, pl.planned_to
  FROM dbo.work_items wi
  JOIN dbo.work_types wt ON wt.id = wi.work_type_id
  LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
  OUTER APPLY (SELECT TOP 1 * FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
  OUTER APPLY (SELECT SUM(bb.annual_value) AS benefit_value, COUNT(*) AS benefit_count FROM dbo.benefits bb WHERE bb.work_item_id = wi.id) b
  OUTER APPLY (SELECT MIN(a.from_date) AS planned_from, MAX(a.to_date) AS planned_to FROM dbo.assignments a WHERE a.work_item_id = wi.id AND a.plan_version_id = ?) pl";

/**
 * Fetch WorkItemRows. $where is SQL over the aliases above (wi, wt, sc, e, b, pl) — always ANDed with wi.workspace_id.
 * Returns [rows, total].
 */
function work_item_rows($conn, $wsId, $where = '1=1', array $params = [], $orderBy = 'wi.priority_score DESC, wi.id', $limit = null, $offset = 0) {
    $pv = committed_plan_id($conn, $wsId) ?? -1;
    $sql = DP_ITEM_SELECT . " WHERE wi.workspace_id = ? AND ($where) ORDER BY $orderBy";
    $p = array_merge([$pv, $wsId], $params);
    if ($limit !== null) { $sql .= " OFFSET ? ROWS FETCH NEXT ? ROWS ONLY"; $p[] = (int)$offset; $p[] = (int)$limit; }
    $raw = rows($conn, $sql, $p);
    $total = count($raw);
    if ($limit !== null) $total = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
        OUTER APPLY (SELECT TOP 1 * FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
        OUTER APPLY (SELECT SUM(bb.annual_value) AS benefit_value, COUNT(*) AS benefit_count FROM dbo.benefits bb WHERE bb.work_item_id = wi.id) b
        OUTER APPLY (SELECT MIN(a.from_date) AS planned_from, MAX(a.to_date) AS planned_to FROM dbo.assignments a WHERE a.work_item_id = wi.id AND a.plan_version_id = ?) pl
        WHERE wi.workspace_id = ? AND ($where)", array_merge([$pv, $wsId], $params));
    if (!$raw) return [[], $total];
    $ids = array_map(fn($r) => (int)$r['id'], $raw);
    $in = implode(',', $ids);
    $skills = [];
    foreach (rows($conn, "SELECT sr.work_item_id, sr.skill_id, s.name, sr.min_proficiency FROM dbo.skill_requirements sr JOIN dbo.skills s ON s.id = sr.skill_id WHERE sr.work_item_id IN ($in) ORDER BY sr.min_proficiency DESC, s.name") as $s)
        $skills[(int)$s['work_item_id']][] = ['skill_id' => (int)$s['skill_id'], 'name' => $s['name'], 'min_proficiency' => (int)$s['min_proficiency']];
    $assignees = [];
    if ($pv >= 0) foreach (rows($conn, "SELECT DISTINCT a.work_item_id, p.id AS person_id, p.initials, p.colour, p.name FROM dbo.assignments a JOIN dbo.people p ON p.id = a.person_id WHERE a.plan_version_id = ? AND a.work_item_id IN ($in) ORDER BY a.work_item_id, p.name", [$pv]) as $a)
        $assignees[(int)$a['work_item_id']][] = ['person_id' => (int)$a['person_id'], 'initials' => $a['initials'], 'colour' => $a['colour'], 'name' => $a['name']];
    $out = [];
    foreach ($raw as $r) { $out[] = shape_item_row($r, $skills[(int)$r['id']] ?? [], $assignees[(int)$r['id']] ?? []); }
    return [$out, $total];
}

function shape_item_row(array $r, array $skills, array $assignees) {
    $isCustom = ($r['size_class_id'] === null && $r['custom_effort_days'] !== null) || (int)($r['is_custom'] ?? 0) === 1;
    [$lo, $hi, $unit] = rom_range($r);
    return [
        'id' => (int)$r['id'], 'ref' => $r['ref'], 'title' => $r['title'],
        'work_type_id' => (int)$r['work_type_id'], 'type_name' => $r['type_name'], 'type_colour' => $r['type_colour'], 'type_policy' => $r['type_policy'],
        'size_stamp' => $isCustom ? 'C' : $r['sc_stamp'], 'size_name' => $isCustom ? 'Custom' : $r['size_name'], 'is_custom' => $isCustom,
        'size_class_id' => $r['size_class_id'] !== null ? (int)$r['size_class_id'] : null,
        'custom_effort_days' => $r['custom_effort_days'] !== null ? (float)$r['custom_effort_days'] : null,
        'status' => $r['status'], 'health' => $r['health'],
        'priority_score' => $r['priority_score'] !== null ? (float)$r['priority_score'] : null,
        'benefit_value' => (int)round((float)($r['benefit_value'] ?? 0)), 'benefit_count' => (int)($r['benefit_count'] ?? 0),
        'rom_low' => $lo, 'rom_high' => $hi, 'rom_unit' => $unit,
        'estimate_likely' => $r['likely'] !== null ? (float)$r['likely'] : null,
        'estimate_class' => $r['est_id'] !== null ? (int)$r['estimate_class'] : null,
        'has_estimate' => $r['est_id'] !== null,
        'skills' => $skills,
        'needed_by' => $r['needed_by'], 'earliest_start' => $r['earliest_start'],
        'planned_from' => $r['planned_from'], 'planned_to' => $r['planned_to'],
        'assignees' => $assignees,
        'requested_by' => $r['requested_by'], 'sponsor' => $r['sponsor'], 'owner_person_id' => $r['owner_person_id'] !== null ? (int)$r['owner_person_id'] : null,
        'progress_pct' => (int)$r['progress_pct'], 'severity' => $r['severity'],
        'tags' => $r['tags'] ? array_values(array_filter(array_map('trim', explode(',', $r['tags'])))) : [],
        'created_at' => substr($r['created_at'], 0, 19), 'updated_at' => substr($r['updated_at'], 0, 19),
    ];
}

/** Readiness checklist per type policy (REQ-04). */
function readiness_for($conn, $wsId, array $item, array $type) {
    if (($type['policy'] ?? 'planned') === 'interrupt') return ['items' => [], 'ready' => true];
    $items = [];
    if ((int)$type['requires_estimate']) $items[] = ['key' => 'estimate', 'label' => 'Estimate present', 'done' => scalar($conn, "SELECT COUNT(*) FROM dbo.estimates WHERE work_item_id = ?", [$item['id']]) > 0];
    if ((int)$type['requires_benefit']) $items[] = ['key' => 'benefit', 'label' => 'Benefit case present', 'done' => scalar($conn, "SELECT COUNT(*) FROM dbo.benefits WHERE work_item_id = ?", [$item['id']]) > 0];
    $items[] = ['key' => 'skills', 'label' => 'Skills declared', 'done' => scalar($conn, "SELECT COUNT(*) FROM dbo.skill_requirements WHERE work_item_id = ?", [$item['id']]) > 0];
    $items[] = ['key' => 'sponsor', 'label' => 'Sponsor named', 'done' => trim((string)$item['sponsor']) !== ''];
    $items[] = ['key' => 'needed_by', 'label' => 'Needed-by date set', 'done' => !empty($item['needed_by'])];
    $ready = true; foreach ($items as $i) if (!$i['done']) $ready = false;
    return ['items' => $items, 'ready' => $ready];
}

/** Status an item should sit in given its policy, once intake requirements are met. */
function policy_status_after_intake($conn, array $type, $workItemId) {
    if (($type['policy'] ?? 'planned') === 'interrupt') return 'ready';
    if ((int)$type['requires_estimate'] && !scalar($conn, "SELECT COUNT(*) FROM dbo.estimates WHERE work_item_id = ?", [$workItemId])) return 'needs_estimate';
    if ((int)$type['requires_benefit'] && !scalar($conn, "SELECT COUNT(*) FROM dbo.benefits WHERE work_item_id = ?", [$workItemId])) return 'needs_benefit';
    return 'ready';
}

/** Would adding from->to create a cycle? DFS from $to following successors looking for $from. */
function dependency_creates_cycle($conn, $wsId, $fromId, $toId) {
    if ($fromId === $toId) return true;
    $edges = [];
    foreach (rows($conn, "SELECT from_work_item_id f, to_work_item_id t FROM dbo.dependencies WHERE workspace_id = ?", [$wsId]) as $e) $edges[(int)$e['f']][] = (int)$e['t'];
    $stack = [$toId]; $seen = [];
    while ($stack) {
        $n = array_pop($stack);
        if ($n === $fromId) return true;
        if (isset($seen[$n])) continue; $seen[$n] = true;
        foreach ($edges[$n] ?? [] as $next) $stack[] = $next;
    }
    return false;
}

/** Person-lite list of active people with proficiency >= min for a skill. */
function qualified_people($conn, $wsId, $skillId, $min) {
    return rows($conn, "SELECT p.id, p.name, p.initials, p.colour, ps.proficiency FROM dbo.person_skills ps JOIN dbo.people p ON p.id = ps.person_id
        WHERE ps.skill_id = ? AND ps.proficiency >= ? AND p.active = 1 AND p.workspace_id = ? ORDER BY ps.proficiency DESC, p.name", [$skillId, $min, $wsId]);
}
function coverage_label(array $qualified, $min) {
    $n = count($qualified);
    if ($n === 0) return "No one at L$min or above";
    if ($n === 1) return 'Only ' . explode(' ', $qualified[0]['name'])[0] . " is L$min";
    return "$n people at L$min or above";
}

/** Human slack label: "2 weeks slack" / "3 days slack" / "1 week late" / "on time". */
function slack_label($days) {
    if ($days === null) return null;
    $abs = abs($days); $suffix = $days < 0 ? 'late' : 'slack';
    if ($abs === 0) return 'due on the planned finish';
    if ($abs >= 5 && $abs % 5 === 0) { $w = $abs / 5; return "$w week" . ($w === 1 ? '' : 's') . " $suffix"; }
    if ($abs >= 10) { $w = round($abs / 5); return "$w weeks $suffix"; }
    return "$abs day" . ($abs === 1 ? '' : 's') . " $suffix";
}
function quarter_label($date) { $t = strtotime($date); return 'Q' . (int)ceil((int)date('n', $t) / 3) . ' ' . date('Y', $t); }
function quarter_sort_key($label) { if (preg_match('/Q([1-4])\s+(\d{4})/', $label, $m)) return $m[2] * 10 + $m[1]; return 0; }

/** After an estimate is saved, move needs_estimate -> needs_benefit|ready per policy (audited). */
function progress_status_after_estimate($conn, $wsId, array $wi) {
    if ($wi['status'] !== 'needs_estimate') return null;
    $type = row($conn, "SELECT * FROM dbo.work_types WHERE id = ?", [$wi['work_type_id']]);
    $next = policy_status_after_intake($conn, $type, $wi['id']);
    if ($next === $wi['status']) return null;
    update($conn, 'work_items', ['status' => $next, 'ready_at' => $next === 'ready' ? ($wi['ready_at'] ?: date('Y-m-d H:i:s')) : $wi['ready_at'], 'updated_at' => date('Y-m-d H:i:s')], 'id = ?', [$wi['id']]);
    audit($conn, $wsId, 'status', 'work_item', $wi['id'], ['field' => 'status', 'value' => $wi['status']], ['field' => 'status', 'value' => $next], $wi['ref'], 'estimate saved');
    return $next;
}

/** Benefit row shape shared by work_items.get and benefits.list. */
function benefit_shape(array $b) {
    $meta = DP_BENEFIT_TYPES[$b['type']] ?? DP_BENEFIT_TYPES['other'];
    return ['id' => (int)$b['id'], 'work_item_id' => (int)$b['work_item_id'], 'type' => $b['type'], 'type_label' => $meta['label'], 'type_colour' => $meta['colour'],
        'annual_value' => (int)round((float)$b['annual_value']), 'currency' => $b['currency'], 'confidence' => strtolower($b['confidence']), 'qualitative_scale' => $b['qualitative_scale'] !== null ? (int)$b['qualitative_scale'] : null,
        'realisation_from' => $b['realisation_from'], 'realisation_quarter' => $b['realisation_from'] ? quarter_label($b['realisation_from']) : null,
        'owner_person_id' => $b['owner_person_id'] !== null ? (int)$b['owner_person_id'] : null, 'owner_name' => $b['owner_name'] ?: ($b['owner_person_name'] ?? null),
        'narrative' => $b['narrative'], 'status' => $b['status'], 'realised_value' => $b['realised_value'] !== null ? (int)round((float)$b['realised_value']) : null,
        'created_at' => substr($b['created_at'], 0, 19)];
}

/** Next ref for a prefix (PIP-02): WI-1072 / INC-4472 / SR-0216. Atomic on ref_sequences. */
function allocate_ref($conn, $wsId, $prefix) {
    $stmt = q($conn, "UPDATE dbo.ref_sequences SET next_value = next_value + 1 OUTPUT DELETED.next_value WHERE workspace_id = ? AND prefix = ?", [$wsId, $prefix]);
    $n = null; if (sqlsrv_fetch($stmt)) $n = (int)sqlsrv_get_field($stmt, 0); sqlsrv_free_stmt($stmt);
    if ($n === null) {
        $max = (int)scalar($conn, "SELECT MAX(TRY_CAST(SUBSTRING(ref, LEN(?) + 2, 10) AS INT)) FROM dbo.work_items WHERE workspace_id = ? AND ref LIKE ?", [$prefix, $wsId, "$prefix-%"]);
        $n = $max ? $max + 1 : 1000;
        q($conn, "INSERT INTO dbo.ref_sequences (workspace_id, prefix, next_value) VALUES (?, ?, ?)", [$wsId, $prefix, $n + 1]);
    }
    return sprintf('%s-%04d', $prefix, $n);
}
