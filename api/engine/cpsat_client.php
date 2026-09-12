<?php
// CP-SAT client (8.8, 10.4). cpsat_solve($model, $cfg, $budgetSeconds) POSTs {model, budget_seconds} to engine_url/solve.
// Expects {assignments:[{work_item_id, person_id, from_date, to_date, allocation_pct}], objective, terms, solve_seconds, proved_optimal, status}.
// Returns ['ok'=>true, 'result'=>[...normalised like heuristic_plan]] or ['ok'=>false, 'reason'=>string] so the caller can fall back.
require_once __DIR__ . '/planner.php';

function cpsat_model_payload(array $model) {
    // Strip PHP-only conveniences; the wire shape is documented in docs/ENGINE_MODEL.md.
    $people = [];
    foreach ($model['people'] as $p) {
        $cap = [];
        foreach ($model['days'] as $d) { $c = $p['capacity'][$d] ?? ['available' => 0, 'reserve' => 0]; $cap[] = [$c['available'], $c['reserve']]; }
        $people[] = ['id' => $p['id'], 'name' => $p['name'], 'max_concurrent' => $p['max_concurrent'], 'min_focus_days' => $p['min_focus_days'],
            'skills' => (object)$p['skills'], 'development' => (object)$p['development'], 'prefers' => $p['prefers'], 'avoid' => $p['avoid'],
            'protected' => $p['protected'], 'rota_weeks' => $p['rota_weeks'], 'capacity' => $cap];
    }
    $items = [];
    foreach ($model['items'] as $i) {
        if (!$i['schedulable'] || $i['remaining_days'] <= 0) continue;
        $items[] = ['id' => $i['id'], 'ref' => $i['ref'], 'policy' => $i['policy'], 'granularity' => $i['granularity'], 'counts_for_wip' => $i['counts_for_wip'],
            'remaining_days' => $i['remaining_days'], 'skill_effort' => $i['skill_effort'] ? (object)$i['skill_effort'] : null,
            'skills' => array_map(fn($s) => ['skill_id' => $s['skill_id'], 'min_proficiency' => $s['min_proficiency']], $i['skills']),
            'deps' => $i['deps'], 'soft_deps' => $i['soft_deps'], 'earliest_start' => $i['earliest_start'], 'needed_by' => $i['needed_by'],
            'priority' => $i['priority'], 'protected' => $i['protected'], 'small' => $i['small'], 'type_name' => $i['type_name'], 'tags' => $i['tags']];
    }
    $committed = [];
    foreach ($model['committed'] as $a) if (isset($model['items'][$a['work_item_id']])) $committed[] = ['id' => $a['id'], 'work_item_id' => $a['work_item_id'], 'person_id' => $a['person_id'], 'from_date' => $a['from_date'], 'to_date' => $a['to_date'], 'allocation_pct' => $a['allocation_pct'], 'locked' => $a['locked'], 'is_reserve' => $a['is_reserve']];
    return [
        'schema_version' => 1,
        'workspace_id' => $model['workspace_id'], 'today' => $model['today'], 'hours_per_day' => $model['hours_per_day'],
        'working_days' => $model['working_days'], 'days' => $model['days'], 'windows' => $model['windows'],
        'policy' => [
            'objective_weights' => $model['policy']['objective_weights'], 'change_budget_days' => $model['policy']['change_budget_days'],
            'min_improvement_pct' => $model['policy']['min_improvement_pct'], 'target_load_min' => $model['policy']['target_load_min'], 'target_load_max' => $model['policy']['target_load_max'],
            'small_fill_threshold_days' => $model['policy']['small_fill_threshold_days'], 'pairing_cost_threshold_days' => $model['policy']['pairing_cost_threshold_days'],
            'max_concurrent_items' => $model['policy']['max_concurrent_items'], 'min_focus_days' => $model['policy']['min_focus_days'],
        ],
        'people' => $people, 'items' => $items, 'committed' => $committed,
        'scope_person_ids' => $model['scope_person_ids'] ?? [],
    ];
}

function cpsat_solve(array $model, array $cfg, $budgetSeconds = null) {
    $url = rtrim((string)($cfg['engine_url'] ?? ''), '/');
    if ($url === '') return ['ok' => false, 'reason' => 'engine_url not configured'];
    $budget = (int)($budgetSeconds ?? $model['policy']['solver_budget_seconds'] ?? 60);
    $timeout = (int)($cfg['engine_timeout_seconds'] ?? ($budget + 10));
    $payload = json_encode(['model' => cpsat_model_payload($model), 'budget_seconds' => $budget], JSON_UNESCAPED_UNICODE);
    $t0 = microtime(true);
    if (function_exists('curl_init')) {
        $ch = curl_init("$url/solve");
        curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $payload, CURLOPT_HTTPHEADER => ['Content-Type: application/json'], CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => $timeout, CURLOPT_CONNECTTIMEOUT => 3]);
        $body = curl_exec($ch); $err = curl_error($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
        if ($body === false) return ['ok' => false, 'reason' => "engine unreachable: $err"];
    } else {
        $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => "Content-Type: application/json\r\n", 'content' => $payload, 'timeout' => $timeout, 'ignore_errors' => true]]);
        $body = @file_get_contents("$url/solve", false, $ctx);
        $code = 0; foreach ($http_response_header ?? [] as $h) if (preg_match('#HTTP/\S+ (\d+)#', $h, $m)) $code = (int)$m[1];
        if ($body === false) return ['ok' => false, 'reason' => 'engine unreachable'];
    }
    if ($code < 200 || $code >= 300) return ['ok' => false, 'reason' => "engine HTTP $code"];
    $j = json_decode($body, true);
    if (!is_array($j) || !isset($j['assignments']) || !is_array($j['assignments'])) return ['ok' => false, 'reason' => 'engine returned no assignments'];
    if (in_array($j['status'] ?? 'ok', ['infeasible', 'error', 'unknown'], true)) return ['ok' => false, 'reason' => 'engine status ' . $j['status']];
    // Normalise to the heuristic's shape and validate hard constraints (never trust an external plan blindly).
    $out = [];
    foreach ($j['assignments'] as $a) {
        if (!isset($model['items'][(int)$a['work_item_id']]) || !isset($model['people'][(int)$a['person_id']])) continue;
        $item = $model['items'][(int)$a['work_item_id']];
        $out[] = ['work_item_id' => (int)$a['work_item_id'], 'ref' => $item['ref'], 'person_id' => (int)$a['person_id'], 'from_date' => substr($a['from_date'], 0, 10), 'to_date' => substr($a['to_date'], 0, 10),
            'allocation_pct' => (int)$a['allocation_pct'], 'state' => model_state_for(max(substr($a['from_date'], 0, 10), $model['today']), $model['windows']),
            'role_label' => $a['role_label'] ?? null, 'kept' => false, 'locked' => false, 'committed_id' => null, 'is_reserve' => (bool)($a['is_reserve'] ?? false)];
    }
    $violations = plan_check_constraints($out, $model);
    if ($violations) return ['ok' => false, 'reason' => 'engine plan violates hard constraints: ' . implode('; ', array_slice($violations, 0, 3))];
    $placed = []; foreach ($out as $a) $placed[$a['work_item_id']] = true;
    $unsched = [];
    foreach ($model['items'] as $it) if ($it['schedulable'] && $it['remaining_days'] > 0 && !isset($placed[$it['id']])) $unsched[] = ['work_item_id' => $it['id'], 'ref' => $it['ref'], 'title' => $it['title'], 'reason' => 'capacity', 'detail' => "The solver left {$it['ref']} unscheduled", 'suggestion' => 'Add capacity or move the needed-by date', 'priority' => $it['priority']];
    $obj = plan_objective($out, $model, $unsched);
    return ['ok' => true, 'result' => ['assignments' => $out, 'unscheduled' => $unsched, 'objective' => $obj['score'], 'terms' => $obj['terms'], 'weighted_terms' => $obj['weighted'],
        'solve_seconds' => (float)($j['solve_seconds'] ?? round(microtime(true) - $t0, 3)), 'displacements' => [],
        'stats' => ['engine' => 'cpsat', 'proved_optimal' => (bool)($j['proved_optimal'] ?? false), 'status' => $j['status'] ?? 'ok', 'engine_objective' => $j['objective'] ?? null, 'engine_terms' => $j['terms'] ?? null, 'assignments' => count($out), 'unscheduled' => count($unsched)]]];
}

/** Property check used by tests and by the CP-SAT client: returns a list of hard-constraint violations (empty = clean). */
function plan_check_constraints(array $assignments, array $model) {
    $v = [];
    $load = []; $items = []; $finish = []; $start = [];
    foreach ($assignments as $a) {
        $iid = $a['work_item_id']; $pid = $a['person_id'];
        $item = $model['items'][$iid] ?? null; $p = $model['people'][$pid] ?? null;
        if (!$item || !$p) { $v[] = "unknown item/person on {$a['ref']}"; continue; }
        if ($a['from_date'] > $a['to_date']) $v[] = "{$item['ref']}: from after to";
        if ($item['earliest_start'] && $a['from_date'] < $item['earliest_start'] && $a['from_date'] >= $model['today']) $v[] = "{$item['ref']} starts before earliest start";
        $isPair = str_starts_with((string)($a['role_label'] ?? ''), 'pair');
        if (!$isPair && !$item['skill_effort'] && !pl_meets($p, $item['skills']) && !$a['locked']) $v[] = "{$p['name']} lacks skills for {$item['ref']}";
        foreach (model_days_in($model, $a['from_date'], $a['to_date']) as $di) {
            $day = $model['days'][$di];
            $cap = $p['capacity'][$day] ?? ['available' => 0, 'reserve' => 0];
            if ($cap['available'] <= 1e-6) $v[] = "{$p['name']} on {$item['ref']} on zero-capacity day $day";
            $load[$pid][$di]['planned'] = ($load[$pid][$di]['planned'] ?? 0) + ($item['policy'] === 'interrupt' ? 0 : $a['allocation_pct'] / 100 * $model['hours_per_day']);
            $load[$pid][$di]['all'] = ($load[$pid][$di]['all'] ?? 0) + $a['allocation_pct'] / 100 * $model['hours_per_day'];
            if ($item['counts_for_wip']) $items[$pid][$di][$iid] = true;
        }
        if (!isset($finish[$iid]) || $a['to_date'] > $finish[$iid]) $finish[$iid] = $a['to_date'];
        if (!isset($start[$iid]) || $a['from_date'] < $start[$iid]) $start[$iid] = $a['from_date'];
    }
    foreach ($load as $pid => $days) {
        $p = $model['people'][$pid];
        foreach ($days as $di => $h) {
            $c = $p['capacity'][$model['days'][$di]];
            if ($h['planned'] > $c['available'] - $c['reserve'] + 1e-6) $v[] = "{$p['name']} planned load " . round($h['planned'], 2) . "h > " . round($c['available'] - $c['reserve'], 2) . "h on {$model['days'][$di]}";
            if ($h['all'] > $c['available'] + 1e-6) $v[] = "{$p['name']} total load " . round($h['all'], 2) . "h > capacity on {$model['days'][$di]}";
            if (count($items[$pid][$di] ?? []) > $p['max_concurrent']) $v[] = "{$p['name']} has " . count($items[$pid][$di]) . " concurrent items on {$model['days'][$di]}";
        }
    }
    foreach ($start as $iid => $s) {
        foreach ($model['items'][$iid]['deps'] as $pred) {
            if (!isset($model['items'][$pred])) continue;
            if (isset($finish[$pred]) && $s <= $finish[$pred] && $s >= $model['today']) $v[] = "{$model['items'][$iid]['ref']} starts before {$model['items'][$pred]['ref']} finishes";
        }
    }
    return $v;
}
