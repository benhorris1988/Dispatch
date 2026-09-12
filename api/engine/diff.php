<?php
// Plan diff (8.7 / 8.11 / CHG-01). diff_plans($committed, $candidate, $model) → list of changes keyed per (item, person):
//   kind move|extend|reassign|add|remove|pair, before/after {label, person_id, from, to, allocation_pct},
//   stability_cost_days (assignment-days moved inside committed+planned windows; indicative = 0; protected ×2),
//   inside_freeze, affected_person_ids, objective_delta (filled by the caller from plan_objective before/after).
require_once __DIR__ . '/planner.php';

function diff_plans(array $committed, array $candidate, array $model) {
    $before = []; $after = [];
    foreach ($committed as $a) { if (!isset($model['items'][$a['work_item_id']])) continue; if ($a['to_date'] < $model['today']) continue; $before[$a['work_item_id']][$a['person_id']][] = $a; }
    foreach ($candidate as $a) { if (!isset($model['items'][$a['work_item_id']])) continue; $after[$a['work_item_id']][$a['person_id']][] = $a; }
    $changes = [];
    $itemIds = array_unique(array_merge(array_keys($before), array_keys($after)));
    foreach ($itemIds as $iid) {
        $item = $model['items'][$iid];
        $bp = $before[$iid] ?? []; $ap = $after[$iid] ?? [];
        $bPeople = array_keys($bp); $aPeople = array_keys($ap);
        $removed = array_values(array_diff($bPeople, $aPeople)); $added = array_values(array_diff($aPeople, $bPeople));
        // same person: compare envelopes
        foreach (array_intersect($bPeople, $aPeople) as $pid) {
            $b = diff_envelope($bp[$pid], $model); $a = diff_envelope($ap[$pid], $model);
            if ($b['from'] === $a['from'] && $b['to'] === $a['to'] && $b['allocation_pct'] === $a['allocation_pct']) continue;
            $kind = ($b['from'] === $a['from'] && $b['allocation_pct'] === $a['allocation_pct']) ? 'extend' : 'move';
            $changes[] = diff_change($model, $item, $kind, $pid, $pid, $bp[$pid], $ap[$pid], $b, $a);
        }
        // reassignments: pair removed with added (by order) → reassign; leftovers → add/remove/pair
        while ($removed && $added) {
            $from = array_shift($removed); $to = array_shift($added);
            $changes[] = diff_change($model, $item, 'reassign', $from, $to, $bp[$from], $ap[$to], diff_envelope($bp[$from], $model), diff_envelope($ap[$to], $model));
        }
        foreach ($removed as $pid) $changes[] = diff_change($model, $item, 'remove', $pid, null, $bp[$pid], [], diff_envelope($bp[$pid], $model), null);
        foreach ($added as $pid) {
            $isPair = false; foreach ($ap[$pid] as $r) if (str_starts_with((string)($r['role_label'] ?? ''), 'pair')) $isPair = true;
            $changes[] = diff_change($model, $item, $isPair ? 'pair' : 'add', null, $pid, [], $ap[$pid], null, diff_envelope($ap[$pid], $model));
        }
    }
    // affected people: everyone on the same item in either plan
    foreach ($changes as &$c) {
        $set = [];
        foreach (array_keys($before[$c['work_item_id']] ?? []) as $p) $set[$p] = true;
        foreach (array_keys($after[$c['work_item_id']] ?? []) as $p) $set[$p] = true;
        if ($c['before']['person_id'] ?? null) $set[$c['before']['person_id']] = true;
        if ($c['after']['person_id'] ?? null) $set[$c['after']['person_id']] = true;
        $c['affected_person_ids'] = array_values(array_map('intval', array_keys($set)));
    }
    unset($c);
    usort($changes, fn($x, $y) => $y['stability_cost_days'] <=> $x['stability_cost_days'] ?: $y['priority'] <=> $x['priority']);
    return $changes;
}

/** Collapse one person's rows on an item into a single envelope {from, to, allocation_pct, label}. */
function diff_envelope(array $rows, array $model) {
    $from = null; $to = null; $alloc = 0; $n = 0; $labels = [];
    foreach ($rows as $r) {
        if ($from === null || $r['from_date'] < $from) $from = $r['from_date'];
        if ($to === null || $r['to_date'] > $to) $to = $r['to_date'];
        $alloc += (int)$r['allocation_pct']; $n++;
        if (!empty($r['role_label'])) $labels[] = $r['role_label'];
    }
    return ['from' => $from, 'to' => $to, 'allocation_pct' => $n ? (int)round($alloc / $n) : 0, 'role_label' => $labels ? implode(', ', array_unique($labels)) : null];
}

function diff_change(array $model, array $item, $kind, $fromPid, $toPid, array $bRows, array $aRows, $bEnv, $aEnv) {
    $windows = $model['windows'];
    $pairB = plan_pair_days($model, $bRows); $pairA = plan_pair_days($model, $aRows);
    $bDays = $pairB ? reset($pairB) : []; $aDays = $pairA ? reset($pairA) : [];
    $plannedEndDi = pl_di_at_or_before($model, $windows['planned_end']);
    $freezeEndDi = pl_di_at_or_before($model, $windows['freeze_end']);
    $rem = 0; $add = 0; $insideFreeze = false;
    foreach ($bDays as $di => $v) { if ($di <= $freezeEndDi && ($aDays[$di] ?? 0) != $v) $insideFreeze = true; if ($di > $plannedEndDi) continue; $x = $aDays[$di] ?? 0; if ($x < $v) $rem += ($v - $x) / 100; }
    foreach ($aDays as $di => $v) { if ($di <= $freezeEndDi && ($bDays[$di] ?? 0) != $v) $insideFreeze = true; if ($di > $plannedEndDi) continue; $x = $bDays[$di] ?? 0; if ($v > $x) $add += ($v - $x) / 100; }
    $cost = max($rem, $add);
    // A pull-forward with the same person that finishes no later is not churn for anyone else (mockup: "Stability cost 0 · same person, earlier").
    $earlierSamePerson = $kind === 'move' && $bEnv && $aEnv && $aEnv['from'] < $bEnv['from'] && $aEnv['to'] <= $bEnv['to'] && $aEnv['allocation_pct'] === $bEnv['allocation_pct'];
    if ($earlierSamePerson) $cost = 0;
    if ($kind === 'reassign') $cost = max($rem, $add); // whole envelope moves person
    $mult = 1;
    if ($item['protected']) $mult *= 2;
    foreach ([$fromPid, $toPid] as $p) if ($p && ($model['people'][$p]['protected'] ?? false)) { $mult *= 2; break; }
    $cost = round($cost * $mult, 2);
    $shift = ($bEnv && $aEnv && $bEnv['from'] && $aEnv['from']) ? diff_wd_shift($bEnv['from'], $aEnv['from'], $model['working_days']) : null;
    $finishShift = ($bEnv && $aEnv && $bEnv['to'] && $aEnv['to']) ? diff_wd_shift($bEnv['to'], $aEnv['to'], $model['working_days']) : null;
    $person = $model['people'][$toPid ?? $fromPid] ?? null;
    return [
        'work_item_id' => $item['id'], 'ref' => $item['ref'], 'title' => $item['title'], 'priority' => $item['priority'],
        'person_id' => $toPid ?? $fromPid, 'kind' => $kind,
        'before' => $bEnv ? ['label' => diff_label($model, $item, $fromPid, $bEnv), 'person_id' => $fromPid, 'from' => $bEnv['from'], 'to' => $bEnv['to'], 'allocation_pct' => $bEnv['allocation_pct']] : null,
        'after' => $aEnv ? ['label' => diff_label($model, $item, $toPid, $aEnv), 'person_id' => $toPid, 'from' => $aEnv['from'], 'to' => $aEnv['to'], 'allocation_pct' => $aEnv['allocation_pct'], 'role_label' => $aEnv['role_label']] : null,
        'stability_cost_days' => $cost, 'inside_freeze' => $insideFreeze,
        'start_shift_days' => $shift, 'finish_shift_days' => $finishShift, 'earlier_same_person' => $earlierSamePerson,
        'protected_multiplier' => $mult,
        'affected_person_ids' => array_values(array_filter([$fromPid, $toPid])),
        'objective_delta' => null,
        'person_name' => $person['name'] ?? null,
    ];
}
function diff_wd_shift($from, $to, array $workingDays) {
    if ($from === $to) return 0;
    return $to > $from ? working_days_between($from, $to, $workingDays) - 1 : -(working_days_between($to, $from, $workingDays) - 1);
}
function diff_label(array $model, array $item, $pid, array $env) {
    $p = $model['people'][$pid] ?? null;
    return "{$item['ref']} {$item['title']} · " . ($p ? $p['name'] . ' · ' : '') . diff_range($env['from'], $env['to']) . ($env['allocation_pct'] && $env['allocation_pct'] < 100 ? " · {$env['allocation_pct']}%" : '');
}
function diff_range($from, $to) {
    if (!$from) return '';
    $f = date('D j M', strtotime($from)); $t = date('D j M', strtotime($to));
    if ($from === $to) return $f;
    if (date('n', strtotime($from)) === date('n', strtotime($to))) return date('j', strtotime($from)) . '–' . date('j M', strtotime($to));
    return "$f – $t";
}

/** Objective delta between two plan_objective results: negative = improvement (lower cost). */
function objective_delta(array $before, array $after) {
    $d = [];
    foreach ($after['weighted'] as $k => $v) $d[$k] = round($v - ($before['weighted'][$k] ?? 0), 3);
    $d['total'] = round($after['score'] - $before['score'], 3);
    $d['improvement_pct'] = $before['score'] > 0 ? round(($before['score'] - $after['score']) / $before['score'] * 100, 2) : ($after['score'] < $before['score'] ? 100.0 : 0.0);
    return $d;
}

/**
 * Per-change objective attribution: re-evaluate the baseline with only this change's item(s) swapped in.
 * Cheap enough for ≤ 100 changes on 8×80; callers may skip for previews.
 */
function attribute_change_delta(array $change, array $committed, array $candidate, array $model, array $baseObj) {
    $iid = $change['work_item_id'];
    $plan = array_values(array_filter($committed, fn($a) => $a['work_item_id'] !== $iid));
    foreach ($candidate as $a) if ($a['work_item_id'] === $iid) $plan[] = $a;
    return objective_delta($baseObj, plan_objective($plan, $model));
}
