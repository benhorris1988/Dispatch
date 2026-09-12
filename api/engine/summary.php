<?php
// Before/after summary (CHG-04, STAB-08). plan_summary($assignments, $model, $opts)
//   → {late_items, value_quarter, people_over_100, single_skill_deps, assignment_days_changed, total_assignment_days, stability_index, late_refs, over_100_names}
// $opts: baseline (assignments to compare against; default model committed), stability_weeks (rows from dbo.stability_weeks for rolling 4 weeks)
require_once __DIR__ . '/planner.php';

function plan_summary(array $assignments, array $model, array $opts = []) {
    $baseline = $opts['baseline'] ?? $model['committed'];
    $finish = [];
    foreach ($assignments as $a) { $iid = $a['work_item_id']; if (!isset($model['items'][$iid])) continue; if (!isset($finish[$iid]) || $a['to_date'] > $finish[$iid]) $finish[$iid] = $a['to_date']; }
    // Late items
    $late = [];
    foreach ($finish as $iid => $f) { $it = $model['items'][$iid]; if ($it['needed_by'] && $f > $it['needed_by']) $late[] = $it['ref']; }
    // Value landing this quarter: annual benefit value of items finishing inside the current quarter
    [$qStart, $qEnd] = summary_quarter_bounds($model['today']);
    $value = 0.0;
    foreach ($finish as $iid => $f) if ($f >= $qStart && $f <= $qEnd) $value += (float)$model['items'][$iid]['benefit_value'];
    // People over 100% in any week of the committed+planned windows
    $over = summary_people_over($assignments, $model);
    // Single-skill dependencies: required skills (on scheduled items in the windows) with exactly one qualified person on the team
    $single = summary_single_skill_deps($assignments, $model);
    // Assignment-days changed vs baseline, total assignment-days in the windows
    $changed = plan_moved_days($model, $baseline, $assignments);
    $total = summary_total_days($model, $assignments);
    $baseTotal = summary_total_days($model, $baseline);
    $index = stability_index($opts['stability_weeks'] ?? [], $changed, max($total, $baseTotal), week_start($model['today']));
    return [
        'late_items' => count($late), 'late_refs' => $late,
        'value_quarter' => round($value, 2), 'quarter_label' => summary_quarter_label($model['today']),
        'people_over_100' => count($over), 'over_100_names' => array_values($over),
        'single_skill_deps' => count($single), 'single_skill_names' => $single,
        'assignment_days_changed' => $changed, 'total_assignment_days' => $total,
        'stability_index' => $index,
    ];
}

/** Assignment-days (allocation-weighted) inside committed+planned windows. */
function summary_total_days(array $model, array $assignments) {
    $end = $model['windows']['planned_end']; $t = 0;
    foreach ($assignments as $a) { if (!isset($model['items'][$a['work_item_id']])) continue; foreach (model_days_in($model, $a['from_date'], min($a['to_date'], $end)) as $di) $t += $a['allocation_pct'] / 100; }
    return round($t, 2);
}
function summary_people_over(array $assignments, array $model) {
    $hours = [];
    foreach ($assignments as $a) foreach (model_days_in($model, $a['from_date'], min($a['to_date'], $model['windows']['planned_end'])) as $di) { $wk = week_start($model['days'][$di]); $hours[$a['person_id']][$wk] = ($hours[$a['person_id']][$wk] ?? 0) + $a['allocation_pct'] / 100 * $model['hours_per_day']; }
    $over = [];
    foreach ($hours as $pid => $weeks) {
        $p = $model['people'][$pid] ?? null; if (!$p) continue;
        foreach ($weeks as $wk => $h) {
            $cap = 0; $wkEnd = date('Y-m-d', strtotime("$wk +6 days"));
            foreach ($p['capacity'] as $day => $c) if ($day >= $wk && $day <= $wkEnd) $cap += $c['available'];
            if ($cap > 0 && $h / $cap > 1.0001) { $over[$pid] = $p['name']; break; }
        }
    }
    return $over;
}
function summary_single_skill_deps(array $assignments, array $model) {
    $itemsInWindow = [];
    foreach ($assignments as $a) if ($a['from_date'] <= $model['windows']['planned_end'] && isset($model['items'][$a['work_item_id']])) $itemsInWindow[$a['work_item_id']] = true;
    $single = [];
    foreach (array_keys($itemsInWindow) as $iid) {
        foreach ($model['items'][$iid]['skills'] as $s) {
            $n = 0; foreach ($model['people'] as $p) if (($p['skills'][$s['skill_id']] ?? 0) >= $s['min_proficiency']) $n++;
            if ($n === 1) $single[$s['name'] . ' L' . $s['min_proficiency']] = true;
        }
    }
    return array_keys($single);
}
function summary_quarter_bounds($today) {
    $m = (int)date('n', strtotime($today)); $y = date('Y', strtotime($today));
    $qm = intdiv($m - 1, 3) * 3 + 1;
    $start = sprintf('%s-%02d-01', $y, $qm);
    $end = date('Y-m-t', strtotime(sprintf('%s-%02d-01', $y, $qm + 2)));
    return [$start, $end];
}
function summary_quarter_label($today) { $m = (int)date('n', strtotime($today)); return 'Q' . (intdiv($m - 1, 3) + 1) . ' ' . date('Y', strtotime($today)); }

/**
 * STAB-08: 1 − (moved assignment-days ÷ total assignment-days in the committed+planned windows), rolling four weeks.
 * $weeks: rows {week_start, total_assignment_days, moved_assignment_days} (any range; only the 4 weeks up to $thisWeek count).
 * $extraMoved/$extraTotal: this proposal's contribution to the current week. Returns a percentage 0..100.
 */
function stability_index(array $weeks, $extraMoved = 0, $extraTotal = 0, $thisWeek = null) {
    $thisWeek = $thisWeek ?? week_start(date('Y-m-d'));
    $from = date('Y-m-d', strtotime("$thisWeek -3 weeks"));
    $moved = 0; $total = 0; $seenThis = false;
    foreach ($weeks as $w) {
        $ws = substr($w['week_start'], 0, 10);
        if ($ws < $from || $ws > $thisWeek) continue;
        $moved += (float)$w['moved_assignment_days'];
        $total += (float)$w['total_assignment_days'];
        if ($ws === $thisWeek) $seenThis = true;
    }
    $moved += $extraMoved;
    if (!$seenThis) $total += $extraTotal; else $total = max($total, $extraTotal);
    if ($total <= 0) return 100.0;
    return round(max(0, 1 - $moved / $total) * 100, 1);
}
