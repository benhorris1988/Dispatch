<?php
// Explainer (8.11, CHG-01). explain_change($change, $model, $triggers, $ctx) → $change + headline, reason, impact_chips.
// Chips: [{label, tone: ok|warn|info|bad}] in plain British English.
// $ctx (optional): ['displacements' => [...from planner], 'load_before' => [pid => pct], 'unscheduled_before' => [item ids], 'finish_shifts' => [iid => days]]

function explain_change(array $c, array $model, array $triggers = [], array $ctx = []) {
    $item = $model['items'][$c['work_item_id']] ?? ['ref' => $c['ref'] ?? '?', 'title' => $c['title'] ?? '', 'needed_by' => null, 'skills' => []];
    $before = $c['before']; $after = $c['after'];
    $pFrom = $before ? ($model['people'][$before['person_id']] ?? null) : null;
    $pTo = $after ? ($model['people'][$after['person_id']] ?? null) : null;
    $ref = $item['ref'];
    $shift = $c['start_shift_days'] ?? null; $fin = $c['finish_shift_days'] ?? null;

    // ---- headline
    switch ($c['kind']) {
        case 'move':
            if ($shift !== null && $shift > 0) $headline = "Start $ref " . ex_days($shift) . " later";
            elseif ($shift !== null && $shift < 0) $headline = "Pull $ref forward " . ex_days(-$shift);
            elseif ($fin !== null && $fin > 0) $headline = "Extend $ref by " . ex_days($fin);
            elseif (($after['allocation_pct'] ?? 0) !== ($before['allocation_pct'] ?? 0)) $headline = "Change " . ($pTo['name'] ?? 'the') . "'s allocation on $ref to {$after['allocation_pct']}%";
            else $headline = "Reshape $ref for " . ($pTo['name'] ?? '');
            break;
        case 'extend':
            $headline = $fin > 0 ? "Extend $ref by " . ex_days($fin) : "Finish $ref " . ex_days(-$fin) . " earlier";
            break;
        case 'reassign':
            $headline = "Move $ref to " . ($pTo['name'] ?? 'someone else');
            break;
        case 'add':
            $headline = "Schedule $ref for " . ($pTo['name'] ?? '') . " from " . ex_date($after['from']);
            break;
        case 'remove':
            $headline = "Take $ref off " . ($pFrom['name'] ?? '') . "'s plan";
            break;
        case 'pair':
            $skill = ex_pair_skill($after['role_label'] ?? '', $item);
            $headline = "Pair " . ($pTo['name'] ?? '') . " on $ref" . ($skill ? " for $skill" : '');
            break;
        default:
            $headline = "Change $ref";
    }

    // ---- reason: trigger + terms improved
    $reasonBits = [];
    $disp = null;
    foreach ($ctx['displacements'] ?? [] as $d) if ($d['work_item_id'] === $c['work_item_id']) $disp = $d;
    if ($disp) $reasonBits[] = "Displaced by {$disp['incident_ref']}, which used " . ($pFrom['name'] ?? 'the') . "'s reserve first and still needed planned time";
    $trig = ex_trigger_for($c, $item, $triggers, $model);
    if ($trig && !$disp) $reasonBits[] = $trig;
    $delta = $c['objective_delta'] ?? null;
    $improved = [];
    if ($delta) {
        $names = ['lateness' => 'lateness', 'valueCompletion' => 'value-weighted completion', 'unscheduledValue' => 'unscheduled value', 'loadImbalance' => 'load balance', 'contextSwitching' => 'context switching', 'preferences' => 'preferences'];
        foreach ($names as $k => $label) if (($delta[$k] ?? 0) < -0.005) $improved[] = $label;
    }
    if ($c['kind'] === 'pair') {
        $reasonBits[] = "Reduces single-person dependency" . ($item['skills'] ? " on " . ex_qualified_names($model, $item) : '') . "; " . ($pTo['name'] ?? '') . " is flagged for development";
    } elseif ($c['kind'] === 'add' && !$trig) {
        $reasonBits[] = "Fills free capacity for " . ($pTo['name'] ?? '') . " with the next item by priority (score " . round($item['priority'] ?? 0) . ")";
    } elseif ($c['kind'] === 'move' && $shift < 0 && !$trig) {
        $reasonBits[] = "Capacity freed earlier for " . ($pTo['name'] ?? '');
    } elseif ($c['kind'] === 'reassign' && !$trig) {
        $lb = $ctx['load_before'][$before['person_id']] ?? null;
        $reasonBits[] = ($pFrom['name'] ?? 'Previous owner') . ($lb !== null && $lb > 100 ? " is at " . round($lb) . "%" : " no longer has room") . "; " . ($pTo['name'] ?? '') . " qualifies and has capacity";
    } elseif ($c['kind'] === 'remove') {
        $reasonBits[] = in_array($c['work_item_id'], $ctx['unscheduled_after'] ?? [], true) ? "No feasible slot remains for $ref; see the watch list" : "Effort released";
    }
    if ($improved) $reasonBits[] = "Improves " . ex_join($improved);
    $reason = $reasonBits ? implode('. ', $reasonBits) . '.' : "Re-planned to keep the plan feasible.";

    // ---- chips
    $chips = [];
    $cost = (float)$c['stability_cost_days'];
    if ($c['kind'] === 'move' && !empty($c['earlier_same_person'])) $chips[] = ex_chip('Stability cost 0 · same person, earlier', 'info');
    elseif ($cost == 0) $chips[] = ex_chip('Stability cost 0', 'info');
    else $chips[] = ex_chip('Stability cost ' . ex_num($cost) . ' assignment-day' . ($cost == 1 ? '' : 's'), 'info');
    if (($c['protected_multiplier'] ?? 1) > 1) $chips[] = ex_chip('Protected · stability cost doubled', 'warn');
    if ($item['needed_by'] ?? null) {
        $bLate = $before && $before['to'] > $item['needed_by']; $aLate = $after && $after['to'] > $item['needed_by'];
        if ($after && !$aLate && !$bLate && $before && $before['to'] === $after['to']) $chips[] = ex_chip('Due date unchanged', 'ok');
        elseif ($after && !$aLate && $bLate) $chips[] = ex_chip('Now meets its needed-by date', 'ok');
        elseif ($after && $aLate) $chips[] = ex_chip("Finishes after needed-by " . ex_date($item['needed_by']), 'bad');
        elseif ($after && $fin !== null && $fin > 0) $chips[] = ex_chip("$ref finishes " . ex_days($fin) . " later", 'warn');
        elseif ($after && $fin !== null && $fin < 0) $chips[] = ex_chip("$ref finishes " . ex_days(-$fin) . " earlier", 'ok');
    } elseif ($fin !== null && $fin > 0) $chips[] = ex_chip("$ref finishes " . ex_days($fin) . " later", 'warn');
    elseif ($fin !== null && $fin < 0) $chips[] = ex_chip("$ref finishes " . ex_days(-$fin) . " earlier", 'ok');
    if ($c['kind'] === 'pair') $chips[] = ex_chip('Skills risk reduced', 'ok');
    if ($c['kind'] === 'move' && $shift < 0 && ($item['benefit_value'] ?? 0) > 0) $chips[] = ex_chip('Benefit realised ' . ex_days(-$shift) . ' earlier', 'ok');
    if ($disp) $chips[] = ex_chip("Displaced by {$disp['incident_ref']}", 'warn');
    if (!empty($c['inside_freeze'])) $chips[] = ex_chip('Inside freeze horizon · needs your approval', 'warn');
    if (($c['guardrail_status'] ?? 'ok') === 'held_budget') $chips[] = ex_chip('Over change budget · held', 'bad');
    if (($c['guardrail_status'] ?? 'ok') === 'held_threshold') { $chips[] = ex_chip('Improvement below ' . ex_num($model['policy']['min_improvement_pct']) . '% threshold', 'bad'); $chips[] = ex_chip('Not applied automatically', 'info'); }
    if (($after['allocation_pct'] ?? 100) < 100 && $c['kind'] !== 'pair') $chips[] = ex_chip("At {$after['allocation_pct']}% allocation", 'info');

    $c['headline'] = $headline; $c['reason'] = $reason; $c['impact_chips'] = $chips;
    return $c;
}

function ex_chip($label, $tone) { return ['label' => $label, 'tone' => $tone]; }
function ex_num($n) { return rtrim(rtrim(number_format((float)$n, 2, '.', ''), '0'), '.'); }
function ex_days($n) {
    $n = (int)round($n);
    if ($n % 5 === 0 && $n >= 5) { $w = intdiv($n, 5); return $w === 1 ? 'one week' : "$w weeks"; }
    $words = [1 => 'one', 2 => 'two', 3 => 'three', 4 => 'four', 6 => 'six', 7 => 'seven', 8 => 'eight', 9 => 'nine'];
    return ($words[$n] ?? $n) . ' day' . ($n === 1 ? '' : 's');
}
function ex_date($d) { return $d ? date('D j M', strtotime($d)) : ''; }
function ex_join(array $xs) { if (count($xs) <= 1) return implode('', $xs); $last = array_pop($xs); return implode(', ', $xs) . ' and ' . $last; }
function ex_pair_skill($roleLabel, array $item) {
    if (preg_match('/pair · (.+)$/u', (string)$roleLabel, $m)) return $m[1];
    return $item['skills'][0]['name'] ?? null;
}
function ex_qualified_names(array $model, array $item) {
    $names = [];
    foreach ($item['skills'] as $s) foreach ($model['people'] as $p) if (($p['skills'][$s['skill_id']] ?? 0) >= $s['min_proficiency']) $names[$p['name']] = true;
    $n = array_keys($names); return $n ? ex_join(array_slice($n, 0, 2)) . ' for ' . $item['skills'][0]['name'] . ' L' . $item['skills'][0]['min_proficiency'] : '';
}
/** Pick the trigger most relevant to the change: same item, else same person, else most recent incident/estimate/etc. */
function ex_trigger_for(array $c, array $item, array $triggers, array $model) {
    if (!$triggers) return null;
    foreach ($triggers as $t) if (($t['source_entity'] ?? '') === 'work_item' && (int)($t['source_id'] ?? 0) === $c['work_item_id']) return ex_trigger_sentence($t, $model);
    $pids = $c['affected_person_ids'] ?? [];
    foreach ($triggers as $t) { foreach (csv_ids($t['person_ids'] ?? '') as $pid) if (in_array($pid, $pids, true)) return ex_trigger_sentence($t, $model); }
    return null;
}
function ex_trigger_sentence(array $t, array $model) {
    $label = trim((string)($t['label'] ?? ''));
    if ($label === '') $label = ucfirst($t['type'] ?? 'trigger');
    return rtrim($label, '.');
}

/** Labels for the "Why the plan changed" panel. */
function label_triggers(array $triggers) {
    $out = [];
    foreach ($triggers as $t) $out[] = ['id' => (int)$t['id'], 'type' => $t['type'], 'class' => $t['class'] ?? 'batched', 'label' => $t['label'] ?: ucfirst($t['type']), 'occurred_at' => $t['occurred_at'] ?? null, 'source_entity' => $t['source_entity'] ?? null, 'source_id' => $t['source_id'] ?? null, 'person_ids' => csv_ids($t['person_ids'] ?? '')];
    return $out;
}
