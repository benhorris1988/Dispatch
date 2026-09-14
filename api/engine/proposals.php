<?php
// Persistence + API shapes shared by replan.php / changes.php / plan.php (plan versions, proposals, change rows).
// Pure PHP over $conn; every write here is accompanied by audit() in the calling endpoint.
require_once __DIR__ . '/model.php';
require_once __DIR__ . '/planner.php';
require_once __DIR__ . '/diff.php';
require_once __DIR__ . '/guardrails.php';
require_once __DIR__ . '/explain.php';
require_once __DIR__ . '/summary.php';
require_once __DIR__ . '/cpsat_client.php';

// ---- plan versions -------------------------------------------------------------------------------
function next_version_no($conn, $wsId) {
    return (int)(scalar($conn, "SELECT ISNULL(MAX(version_no), 0) + 1 FROM dbo.plan_versions WHERE workspace_id = ?", [$wsId]));
}

/** Insert a plan version + its assignment rows from planner output (rows: work_item_id, person_id, from_date, to_date, allocation_pct, state, role_label, is_reserve, committed_id). */
function store_plan_version($conn, $wsId, array $model, array $assignments, array $meta) {
    global $userId;
    $vid = insert($conn, 'plan_versions', [
        'workspace_id' => $wsId, 'version_no' => next_version_no($conn, $wsId), 'status' => $meta['status'] ?? 'proposed',
        'engine' => $meta['engine'] ?? 'heuristic', 'generated_by' => $userId ?? null,
        'committed_at' => ($meta['status'] ?? '') === 'committed' ? date('Y-m-d H:i:s') : null,
        'committed_by' => ($meta['status'] ?? '') === 'committed' ? ($userId ?? null) : null,
        'committed_through' => ($meta['status'] ?? '') === 'committed' ? $model['windows']['freeze_end'] : null,
        'policy_version' => $model['policy']['version'], 'inputs_hash' => $meta['inputs_hash'] ?? model_inputs_hash($model),
        'objective_score' => $meta['objective_score'] ?? null, 'objective_terms' => isset($meta['objective_terms']) ? json_encode($meta['objective_terms']) : null,
        'stability_cost_days' => $meta['stability_cost_days'] ?? null, 'solver_stats' => isset($meta['solver_stats']) ? json_encode($meta['solver_stats']) : null,
        'scenario_name' => $meta['scenario_name'] ?? null, 'notes' => $meta['notes'] ?? null,
    ]);
    $byId = []; foreach ($model['committed'] as $c) $byId[$c['id']] = $c;
    foreach ($assignments as $a) {
        $src = isset($a['committed_id']) && isset($byId[$a['committed_id']]) ? $byId[$a['committed_id']] : null;
        insert($conn, 'assignments', [
            'plan_version_id' => $vid, 'work_item_id' => $a['work_item_id'], 'person_id' => $a['person_id'],
            'from_date' => $a['from_date'], 'to_date' => $a['to_date'], 'allocation_pct' => (int)$a['allocation_pct'],
            'state' => $a['state'] ?? model_state_for(max($a['from_date'], $model['today']), $model['windows']),
            'role_label' => $a['role_label'] ?? ($src['role_label'] ?? null),
            'locked_until' => $a['locked_until'] ?? null,
            'fixed_by' => $a['fixed_by'] ?? null, 'fixed_person' => (int)($a['fixed_person'] ?? ($src['fixed_person'] ?? 0)), 'fixed_dates' => (int)($a['fixed_dates'] ?? ($src['fixed_dates'] ?? 0)),
            'is_reserve' => (int)($a['is_reserve'] ?? 0), 'note' => $a['note'] ?? ($src['note'] ?? null),
        ]);
    }
    return $vid;
}

/** Raw assignment rows of a version as arrays suitable for re-insertion (without id/plan_version_id). */
function version_rows($conn, $versionId) {
    $out = [];
    foreach (rows($conn, "SELECT * FROM dbo.assignments WHERE plan_version_id = ?", [$versionId]) as $a) {
        $out[] = ['work_item_id' => (int)$a['work_item_id'], 'person_id' => (int)$a['person_id'], 'from_date' => substr($a['from_date'], 0, 10), 'to_date' => substr($a['to_date'], 0, 10),
            'allocation_pct' => (int)$a['allocation_pct'], 'state' => $a['state'], 'role_label' => $a['role_label'],
            'locked_until' => $a['locked_until'] ? substr($a['locked_until'], 0, 10) : null, 'fixed_by' => $a['fixed_by'], 'fixed_person' => (int)$a['fixed_person'], 'fixed_dates' => (int)$a['fixed_dates'],
            'is_reserve' => (int)$a['is_reserve'], 'note' => $a['note'], 'src_id' => (int)$a['id']];
    }
    return $out;
}

/**
 * Create a new committed version = copy of the current committed one with $mutator(array &$rows) applied (CHG-05).
 * Previous committed → superseded. Returns the new version id.
 */
function new_committed_version($conn, $wsId, array $model, callable $mutator, array $meta = []) {
    global $userId;
    $cur = row($conn, "SELECT TOP 1 * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]);
    $rows = $cur ? version_rows($conn, (int)$cur['id']) : [];
    // release delivered / cancelled items' future work
    $rows = array_values(array_filter($rows, fn($r) => isset($model['items'][$r['work_item_id']]) || $r['to_date'] < $model['today']));
    $mutator($rows);
    foreach ($rows as &$r) { $r['state'] = model_state_for(max($r['from_date'], $model['today']), $model['windows']); unset($r['src_id']); }
    unset($r);
    $vid = insert($conn, 'plan_versions', [
        'workspace_id' => $wsId, 'version_no' => next_version_no($conn, $wsId), 'status' => 'committed', 'engine' => $meta['engine'] ?? 'manual',
        'generated_by' => $userId ?? null, 'committed_at' => date('Y-m-d H:i:s'), 'committed_by' => $userId ?? null,
        'committed_through' => $model['windows']['freeze_end'], 'policy_version' => $model['policy']['version'],
        'inputs_hash' => model_inputs_hash($model), 'objective_score' => $meta['objective_score'] ?? null,
        'objective_terms' => isset($meta['objective_terms']) ? json_encode($meta['objective_terms']) : null,
        'stability_cost_days' => $meta['stability_cost_days'] ?? null, 'solver_stats' => isset($meta['solver_stats']) ? json_encode($meta['solver_stats']) : null,
        'notes' => $meta['notes'] ?? null,
    ]);
    foreach ($rows as $r) insert($conn, 'assignments', array_merge(['plan_version_id' => $vid], array_intersect_key($r, array_flip(['work_item_id', 'person_id', 'from_date', 'to_date', 'allocation_pct', 'state', 'role_label', 'locked_until', 'fixed_by', 'fixed_person', 'fixed_dates', 'is_reserve', 'note']))));
    if ($cur) update($conn, 'plan_versions', ['status' => 'superseded'], 'id = ?', [(int)$cur['id']]);
    // items now scheduled
    $sched = []; foreach ($rows as $r) if ($r['to_date'] >= $model['today']) $sched[$r['work_item_id']] = true;
    foreach (array_keys($sched) as $iid) q($conn, "UPDATE dbo.work_items SET status = 'scheduled', updated_at = SYSDATETIME() WHERE id = ? AND workspace_id = ? AND status = 'ready'", [$iid, $wsId]);
    return $vid;
}

/** Apply one change's after_json onto a row list (used by commit and move_assignment). */
function apply_change_to_rows(array &$rows, array $change) {
    $iid = (int)$change['work_item_id'];
    $before = $change['before'] ?? null; $after = $change['after'] ?? null;
    $kind = $change['kind'];
    $template = null;
    if ($before && $before['person_id']) {
        foreach ($rows as $k => $r) if ($r['work_item_id'] === $iid && $r['person_id'] === (int)$before['person_id']) { $template = $template ?? $r; unset($rows[$k]); }
    }
    $rows = array_values($rows);
    if ($kind === 'remove' || !$after) return;
    $new = $template ?? ['work_item_id' => $iid, 'role_label' => null, 'locked_until' => null, 'fixed_by' => null, 'fixed_person' => 0, 'fixed_dates' => 0, 'is_reserve' => 0, 'note' => null];
    $new['work_item_id'] = $iid; $new['person_id'] = (int)$after['person_id']; $new['from_date'] = $after['from']; $new['to_date'] = $after['to'];
    $new['allocation_pct'] = (int)($after['allocation_pct'] ?? 100);
    if (!empty($after['role_label'])) $new['role_label'] = $after['role_label'];
    if ($kind === 'reassign') { $new['fixed_person'] = 0; }
    $rows[] = $new;
}

// ---- proposals & changes -------------------------------------------------------------------------
function load_people_map($conn, $wsId) {
    static $cache = [];
    if (!isset($cache[$wsId])) { $cache[$wsId] = []; foreach (rows($conn, "SELECT id, name, initials, colour, role_title FROM dbo.people WHERE workspace_id = ?", [$wsId]) as $p) $cache[$wsId][(int)$p['id']] = ['id' => (int)$p['id'], 'name' => $p['name'], 'initials' => trim((string)$p['initials']), 'colour' => $p['colour'], 'role_title' => $p['role_title']]; }
    return $cache[$wsId];
}
function load_item_map($conn, $wsId) {
    static $cache = [];
    if (!isset($cache[$wsId])) { $cache[$wsId] = []; foreach (rows($conn, "SELECT wi.id, wi.ref, wi.title, wt.colour AS type_colour, wt.name AS type_name FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id WHERE wi.workspace_id = ?", [$wsId]) as $i) $cache[$wsId][(int)$i['id']] = ['id' => (int)$i['id'], 'ref' => $i['ref'], 'title' => $i['title'], 'type_colour' => $i['type_colour'], 'type_name' => $i['type_name']]; }
    return $cache[$wsId];
}

/** DB row of change_proposals → API Change shape. */
function change_shape($conn, array $r, $wsId) {
    $people = load_people_map($conn, $wsId); $items = load_item_map($conn, $wsId);
    $affected = [];
    foreach (csv_ids($r['affected_person_ids'] ?? '') as $pid) if (isset($people[$pid])) $affected[] = model_person_lite($people[$pid]);
    $decidedBy = $r['decided_by'] ? scalar($conn, "SELECT display_name FROM dbo.users WHERE id = ?", [(int)$r['decided_by']]) : null;
    return [
        'id' => (int)$r['id'], 'proposal_id' => (int)$r['proposal_id'],
        'person' => $r['person_id'] ? model_person_lite($people[(int)$r['person_id']] ?? null) : null,
        'work_item' => $r['work_item_id'] ? ($items[(int)$r['work_item_id']] ?? ['id' => (int)$r['work_item_id']]) : null,
        'kind' => $r['kind'], 'headline' => $r['headline'],
        'before' => json_col($r['before_json'], null), 'after' => json_col($r['after_json'], null),
        'reason' => $r['reason'], 'stability_cost_days' => (float)$r['stability_cost_days'], 'inside_freeze' => (bool)$r['inside_freeze'],
        'impact_chips' => json_col($r['impact_chips'], []), 'affected_people' => $affected,
        'objective_delta' => json_col($r['objective_delta'], null),
        'guardrail_status' => $r['guardrail_status'], 'guardrail_reason' => $r['guardrail_reason'],
        'decision' => $r['decision'], 'decided_by_name' => $decidedBy, 'decided_at' => $r['decided_at'], 'decision_reason' => $r['decision_reason'],
        'acknowledged_at' => $r['acknowledged_at'], 'sort_order' => (int)$r['sort_order'],
    ];
}
function load_changes($conn, $wsId, $proposalId) {
    return array_map(fn($r) => change_shape($conn, $r, $wsId), rows($conn, "SELECT * FROM dbo.change_proposals WHERE proposal_id = ? AND workspace_id = ? ORDER BY sort_order, id", [$proposalId, $wsId]));
}
function proposal_shape($conn, array $p, $wsId) {
    $pol = model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []);
    $counts = row($conn, "SELECT SUM(CASE WHEN guardrail_status IN ('ok','needs_approval') THEN 1 ELSE 0 END) AS proposed,
                                 SUM(CASE WHEN guardrail_status IN ('held_budget','held_threshold') THEN 1 ELSE 0 END) AS held,
                                 SUM(CASE WHEN decision = 'pending' THEN 1 ELSE 0 END) AS pending,
                                 SUM(CASE WHEN decision IN ('accepted','edited') THEN 1 ELSE 0 END) AS accepted,
                                 SUM(CASE WHEN decision = 'rejected' THEN 1 ELSE 0 END) AS rejected, COUNT(*) AS total
                          FROM dbo.change_proposals WHERE proposal_id = ?", [(int)$p['id']]) ?: [];
    // budget usage this week: committed changes (person_change_log) + this proposal's pending/accepted moves
    $wk = week_start(today());
    $used = rows($conn, "SELECT person_id, SUM(assignment_days) AS d FROM dbo.person_change_log WHERE workspace_id = ? AND week_start = ? GROUP BY person_id", [$wsId, $wk]);
    $perPerson = []; foreach ($used as $u) $perPerson[(int)$u['person_id']] = (float)$u['d'];
    foreach (rows($conn, "SELECT person_id, stability_cost_days, after_json, before_json FROM dbo.change_proposals WHERE proposal_id = ? AND decision <> 'rejected' AND guardrail_status <> 'held_threshold'", [(int)$p['id']]) as $c) {
        $aft = json_col($c['after_json'], []); $bef = json_col($c['before_json'], []);
        $from = $aft['from'] ?? ($bef['from'] ?? null);
        if ($from && week_start($from) === $wk && $c['person_id']) $perPerson[(int)$c['person_id']] = ($perPerson[(int)$c['person_id']] ?? 0) + (float)$c['stability_cost_days'];
    }
    $people = load_people_map($conn, $wsId);
    $pp = []; $max = 0;
    foreach ($perPerson as $pid => $d) { $pp[] = ['person' => model_person_lite($people[$pid] ?? ['id' => $pid, 'name' => '?', 'initials' => '', 'colour' => null]), 'used' => round($d, 2)]; $max = max($max, $d); }
    $gen = $p['generated_by'] ? scalar($conn, "SELECT display_name FROM dbo.users WHERE id = ?", [(int)$p['generated_by']]) : null;
    return [
        'id' => (int)$p['id'], 'kind' => $p['kind'], 'status' => $p['status'], 'engine' => $p['engine'],
        'generated_at' => $p['generated_at'], 'generated_by_name' => $gen, 'decided_at' => $p['decided_at'],
        'candidate_plan_version_id' => $p['candidate_plan_version_id'] !== null ? (int)$p['candidate_plan_version_id'] : null,
        'base_plan_version_id' => $p['base_plan_version_id'] !== null ? (int)$p['base_plan_version_id'] : null,
        'triggers' => json_col($p['triggers'], []),
        'summary_before' => json_col($p['summary_before'], null), 'summary_after' => json_col($p['summary_after'], null),
        'improvement_pct' => $p['improvement_pct'] !== null ? (float)$p['improvement_pct'] : null, 'below_threshold' => (bool)$p['below_threshold'],
        'carried_over_note' => $p['carried_over_note'], 'scope_person_ids' => csv_ids($p['scope_person_ids'] ?? ''),
        'budget' => ['used' => round($max, 2), 'limit' => $pol['change_budget_days'], 'week_start' => $wk, 'per_person' => $pp],
        'counts' => ['proposed' => (int)($counts['proposed'] ?? 0), 'held' => (int)($counts['held'] ?? 0), 'pending' => (int)($counts['pending'] ?? 0), 'accepted' => (int)($counts['accepted'] ?? 0), 'rejected' => (int)($counts['rejected'] ?? 0), 'total' => (int)($counts['total'] ?? 0)],
    ];
}

function delivery_lead_user_ids($conn, $wsId) {
    return array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.users WHERE workspace_id = ? AND active = 1 AND role IN ('delivery_lead','admin')", [$wsId]));
}

/**
 * The full propose cycle (SCH-03, STAB-*, CHG-08). Returns the API payload for replan.php `propose`.
 * $opts: kind (manual|nightly|urgent), scope_person_ids, engine (heuristic|cpsat), persist (default true), model_overrides callable
 */
function run_propose($conn, $wsId, array $opts = []) {
    global $userId, $userName;
    $t0 = microtime(true);
    $kind = $opts['kind'] ?? 'manual';
    $cfg = dp_config();
    $triggers = rows($conn, "SELECT * FROM dbo.replan_triggers WHERE workspace_id = ? AND processed_at IS NULL ORDER BY occurred_at", [$wsId]);
    $scope = array_values(array_map('intval', (array)($opts['scope_person_ids'] ?? [])));
    if ($kind === 'urgent' && !$scope) { foreach ($triggers as $t) if (($t['class'] ?? '') === 'urgent') $scope = array_merge($scope, csv_ids($t['person_ids'])); $scope = array_values(array_unique($scope)); }
    if ($kind !== 'urgent') $scope = [];
    // SCH-13: a proposal may be scoped to one team or to a portfolio of teams. The keys pass
    // straight through to build_model(), which decides what pool of people and items that means.
    $modelOpts = ['scope_person_ids' => $scope];
    foreach (['team_id', 'portfolio_id'] as $k) if (isset($opts[$k]) && $opts[$k] !== null && $opts[$k] !== '') $modelOpts[$k] = (int)$opts[$k];
    $model = build_model($conn, $wsId, $modelOpts);
    if (!$model) fail('Workspace not found', 404);
    if (isset($opts['model_overrides'])) $model = $opts['model_overrides']($model);

    // Solve
    $engine = $opts['engine'] ?? 'heuristic'; $fallback = null;
    $result = null;
    if ($engine === 'cpsat') {
        $r = cpsat_solve($model, $cfg, $model['policy']['solver_budget_seconds']);
        if ($r['ok']) $result = $r['result']; else { $fallback = $r['reason']; $engine = 'heuristic'; }
    }
    if ($result === null) $result = heuristic_plan($model);
    $candidate = $result['assignments'];

    // Objective before / after, diff, guardrails, explain
    $baseObj = plan_objective($model['committed'], $model);
    $candObj = ['terms' => $result['terms'], 'weighted' => $result['weighted_terms'], 'score' => $result['objective']];
    $delta = objective_delta($baseObj, $candObj);
    $improvement = $delta['improvement_pct'];
    $changes = diff_plans($model['committed'], $candidate, $model);
    if (count($changes) <= 150) foreach ($changes as &$c) $c['objective_delta'] = attribute_change_delta($c, $model['committed'], $candidate, $model, $baseObj);
    unset($c);
    $priorUsage = [];
    foreach (rows($conn, "SELECT person_id, week_start, SUM(assignment_days) AS d FROM dbo.person_change_log WHERE workspace_id = ? AND week_start >= ? GROUP BY person_id, week_start", [$wsId, week_start($model['today'])]) as $u) $priorUsage[(int)$u['person_id'] . ':' . substr($u['week_start'], 0, 10)] = (float)$u['d'];
    $gr = apply_guardrails($changes, $changes ? $improvement : null, $model['policy'] + ['today' => $model['today']], $priorUsage);
    $changes = $gr['changes'];
    $loadBefore = [];
    foreach (summary_people_over($model['committed'], $model) as $pid => $n) $loadBefore[$pid] = 101;
    $unschedAfter = array_map(fn($u) => $u['work_item_id'], $result['unscheduled']);
    $ctx = ['displacements' => $result['displacements'] ?? [], 'load_before' => $loadBefore, 'unscheduled_after' => $unschedAfter];
    foreach ($changes as &$c) $c = explain_change($c, $model, $triggers, $ctx);
    unset($c);
    // Order: proposed (ok / needs_approval) before held; stability cost desc within each group
    usort($changes, function ($a, $b) {
        $ga = in_array($a['guardrail_status'], ['ok', 'needs_approval']) ? 0 : 1; $gb = in_array($b['guardrail_status'], ['ok', 'needs_approval']) ? 0 : 1;
        if ($ga !== $gb) return $ga - $gb;
        return $b['stability_cost_days'] <=> $a['stability_cost_days'] ?: $b['priority'] <=> $a['priority'];
    });
    $stabRows = rows($conn, "SELECT * FROM dbo.stability_weeks WHERE workspace_id = ? AND week_start >= ?", [$wsId, date('Y-m-d', strtotime(week_start($model['today']) . ' -4 weeks'))]);
    $summaryBefore = plan_summary($model['committed'], $model, ['stability_weeks' => $stabRows]);
    $summaryAfter = plan_summary($candidate, $model, ['stability_weeks' => $stabRows]);
    $stabilityCost = plan_moved_days($model, $model['committed'], $candidate);
    $solverStats = array_merge($result['stats'] ?? [], ['solve_seconds' => $result['solve_seconds'], 'total_seconds' => round(microtime(true) - $t0, 3), 'engine' => $engine, 'fallback' => $fallback, 'items' => count($model['items']), 'people' => count($model['people']), 'changes' => count($changes), 'displacements' => count($result['displacements'] ?? [])]);

    $payload = ['engine' => $engine, 'improvement_pct' => $improvement, 'below_threshold' => $gr['below_threshold'], 'objective_before' => $baseObj, 'objective_after' => $candObj, 'objective_delta' => $delta,
        'summary_before' => $summaryBefore, 'summary_after' => $summaryAfter, 'solver_stats' => $solverStats, 'unscheduled' => $result['unscheduled'], 'budget' => $gr['budget'],
        'triggers' => label_triggers($triggers), 'windows' => $model['windows'], 'scope_person_ids' => $scope];

    if (($opts['persist'] ?? true) === false) {
        $payload['changes'] = array_values(array_filter($changes, fn($c) => in_array($c['guardrail_status'], ['ok', 'needs_approval'])));
        $payload['held'] = array_values(array_filter($changes, fn($c) => !in_array($c['guardrail_status'], ['ok', 'needs_approval'])));
        $payload['candidate'] = $candidate; $payload['model'] = $model;
        return $payload;
    }

    // ---- persist
    $vid = store_plan_version($conn, $wsId, $model, $candidate, ['status' => 'proposed', 'engine' => $engine, 'objective_score' => $candObj['score'], 'objective_terms' => $candObj['terms'], 'stability_cost_days' => $stabilityCost, 'solver_stats' => $solverStats, 'notes' => ucfirst($kind) . ' proposal']);
    // supersede the previous open proposal(s), carrying over undecided headlines (CHG-08)
    $carried = [];
    foreach (rows($conn, "SELECT id FROM dbo.proposals WHERE workspace_id = ? AND status = 'open'", [$wsId]) as $old) {
        foreach (rows($conn, "SELECT headline FROM dbo.change_proposals WHERE proposal_id = ? AND decision = 'pending'", [(int)$old['id']]) as $h) $carried[] = $h['headline'];
        update($conn, 'proposals', ['status' => 'superseded', 'decided_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$old['id']]);
        $cv = scalar($conn, "SELECT candidate_plan_version_id FROM dbo.proposals WHERE id = ?", [(int)$old['id']]);
        if ($cv) update($conn, 'plan_versions', ['status' => 'discarded'], 'id = ? AND status = ?', [(int)$cv, 'proposed']);
    }
    $note = null;
    if ($carried) { $note = count($carried) . ' undecided change' . (count($carried) === 1 ? '' : 's') . ' carried over from the previous proposal: ' . implode('; ', array_slice($carried, 0, 3)) . (count($carried) > 3 ? '…' : ''); $note = mb_substr($note, 0, 300); }
    $pid = insert($conn, 'proposals', [
        'workspace_id' => $wsId, 'candidate_plan_version_id' => $vid, 'base_plan_version_id' => $model['committed_version_id'], 'kind' => $kind, 'status' => 'open',
        'generated_by' => $userId ?? null, 'improvement_pct' => $improvement, 'below_threshold' => $gr['below_threshold'] ? 1 : 0,
        'summary_before' => json_encode($summaryBefore), 'summary_after' => json_encode($summaryAfter),
        'triggers' => json_encode(label_triggers($triggers)), 'carried_over_note' => $note,
        'scope_person_ids' => $scope ? implode(',', $scope) : null, 'engine' => $engine,
    ]);
    $trigIds = implode(',', array_map(fn($t) => (int)$t['id'], $triggers));
    $sort = 0; $stored = [];
    foreach ($changes as $c) {
        $cid = insert($conn, 'change_proposals', [
            'proposal_id' => $pid, 'workspace_id' => $wsId, 'person_id' => $c['person_id'], 'work_item_id' => $c['work_item_id'], 'kind' => $c['kind'],
            'headline' => mb_substr($c['headline'], 0, 200), 'before_json' => $c['before'] ? json_encode($c['before'], JSON_UNESCAPED_UNICODE) : null, 'after_json' => $c['after'] ? json_encode($c['after'], JSON_UNESCAPED_UNICODE) : null,
            'reason' => mb_substr($c['reason'], 0, 400), 'trigger_ids' => mb_substr($trigIds, 0, 100) ?: null, 'objective_delta' => $c['objective_delta'] ? json_encode($c['objective_delta']) : null,
            'stability_cost_days' => $c['stability_cost_days'], 'inside_freeze' => $c['inside_freeze'] ? 1 : 0, 'impact_chips' => json_encode($c['impact_chips'], JSON_UNESCAPED_UNICODE),
            'affected_person_ids' => implode(',', $c['affected_person_ids']), 'guardrail_status' => $c['guardrail_status'], 'guardrail_reason' => $c['guardrail_reason'] ? mb_substr($c['guardrail_reason'], 0, 300) : null,
            'decision' => 'pending', 'sort_order' => $sort++,
        ]);
        $stored[] = $cid;
    }
    if ($triggers) q($conn, "UPDATE dbo.replan_triggers SET processed_at = SYSDATETIME(), proposal_id = ? WHERE workspace_id = ? AND processed_at IS NULL", [$pid, $wsId]);
    // notifications: affected people (change_proposed; urgent inside freeze), delivery leads (approval_requested)
    $notified = [];
    foreach ($changes as $c) {
        foreach ($c['affected_person_ids'] as $p) {
            $key = "$p:" . ($c['inside_freeze'] ? 'u' : 'n');
            if (isset($notified[$key])) continue; $notified[$key] = true;
            notify_person($conn, $wsId, $p, 'change_proposed', $c['headline'], $c['reason'], "/changes/$pid", $c['inside_freeze'] ? 1 : 0);
        }
    }
    $n = count($changes); $held = count(array_filter($changes, fn($c) => !in_array($c['guardrail_status'], ['ok', 'needs_approval'])));
    foreach (delivery_lead_user_ids($conn, $wsId) as $uid) notify($conn, $wsId, $uid, 'approval_requested', ucfirst($kind) . " replan: $n change" . ($n === 1 ? '' : 's') . " proposed" . ($held ? ", $held held by guardrails" : ''), $gr['below_threshold'] ? 'Improvement below threshold: shown as information only.' : null, "/changes/$pid", 0);
    audit($conn, $wsId, 'create', 'proposal', $pid, null, ['kind' => $kind, 'engine' => $engine, 'changes' => $n, 'held' => $held, 'improvement_pct' => $improvement, 'plan_version_id' => $vid], "Proposal #$pid");

    $all = load_changes($conn, $wsId, $pid);
    $payload['proposal_id'] = $pid; $payload['plan_version_id'] = $vid;
    $payload['changes'] = array_values(array_filter($all, fn($c) => in_array($c['guardrail_status'], ['ok', 'needs_approval'])));
    $payload['held'] = array_values(array_filter($all, fn($c) => !in_array($c['guardrail_status'], ['ok', 'needs_approval'])));
    $payload['carried_over_note'] = $note;
    $payload['proposal'] = proposal_shape($conn, row($conn, "SELECT * FROM dbo.proposals WHERE id = ?", [$pid]), $wsId);
    return $payload;
}

/** Roll the current week's stability_weeks row up from the committed plan + person_change_log (STAB-08). */
function rollup_stability_week($conn, $wsId, array $model, $extraMoved = 0, $extraInsideFreeze = 0) {
    $wk = week_start($model['today']);
    $total = summary_total_days($model, $model['committed']);
    $moved = (float)(scalar($conn, "SELECT ISNULL(SUM(assignment_days),0) FROM dbo.person_change_log WHERE workspace_id = ? AND week_start = ?", [$wsId, $wk]) ?? 0);
    $inside = (int)(scalar($conn, "SELECT COUNT(*) FROM dbo.person_change_log WHERE workspace_id = ? AND week_start = ? AND inside_freeze = 1", [$wsId, $wk]) ?? 0);
    // planned load % this week
    $cap = 0; $hrs = 0; $wkEnd = date('Y-m-d', strtotime("$wk +6 days"));
    foreach ($model['people'] as $p) foreach ($p['capacity'] as $day => $c) if ($day >= $wk && $day <= $wkEnd) $cap += $c['available'];
    foreach ($model['committed'] as $a) foreach (model_days_in($model, $a['from_date'], min($a['to_date'], $wkEnd)) as $di) if ($model['days'][$di] >= $wk) $hrs += $a['allocation_pct'] / 100 * $model['hours_per_day'];
    $load = $cap > 0 ? round($hrs / $cap * 100, 1) : null;
    $exists = scalar($conn, "SELECT COUNT(*) FROM dbo.stability_weeks WHERE workspace_id = ? AND week_start = ?", [$wsId, $wk]);
    $data = ['total_assignment_days' => $total, 'moved_assignment_days' => round($moved + $extraMoved, 2), 'changes_inside_freeze' => $inside + $extraInsideFreeze, 'planned_load_pct' => $load];
    if ($exists) update($conn, 'stability_weeks', $data, 'workspace_id = ? AND week_start = ?', [$wsId, $wk]);
    else insert_nokey($conn, 'stability_weeks', array_merge(['workspace_id' => $wsId, 'week_start' => $wk], $data));
    return $data;
}
/** INSERT for tables without an identity column. */
function insert_nokey($conn, $table, array $data) {
    $cols = array_keys($data);
    q($conn, "INSERT INTO dbo.$table (" . implode(',', $cols) . ") VALUES (" . implode(',', array_fill(0, count($cols), '?')) . ")", array_values($data));
}

/** Watch list derived from a planner run (fallback when engine/watchlist.php is absent). */
function derive_watch_list(array $model, array $result) {
    $items = [];
    foreach ($result['unscheduled'] as $u) {
        $kind = in_array($u['reason'], ['skills_gap', 'no_estimate', 'dependency', 'capacity', 'blocked'], true) ? $u['reason'] : 'late';
        if ($kind === 'dependency' || $kind === 'blocked') $kind = 'late';
        $items[] = ['kind' => $kind, 'title' => "{$u['ref']} {$u['title']}", 'body' => $u['detail'], 'suggestion' => $u['suggestion'], 'link' => "/items/{$u['ref']}", 'tone' => $kind === 'skills_gap' ? 'bad' : ($kind === 'no_estimate' ? 'info' : 'warn'), 'work_item_id' => $u['work_item_id']];
    }
    $finish = [];
    foreach ($result['assignments'] as $a) if (!isset($finish[$a['work_item_id']]) || $a['to_date'] > $finish[$a['work_item_id']]) $finish[$a['work_item_id']] = $a['to_date'];
    foreach ($finish as $iid => $f) {
        $it = $model['items'][$iid] ?? null;
        if ($it && $it['needed_by'] && $f > $it['needed_by']) $items[] = ['kind' => 'late', 'title' => "{$it['ref']} {$it['title']}", 'body' => "Earliest finish " . ex_date($f) . ", needed by " . ex_date($it['needed_by']), 'suggestion' => 'Add capacity, descope, or move the needed-by date', 'link' => "/items/{$it['ref']}", 'tone' => 'warn', 'work_item_id' => $iid];
    }
    foreach (summary_people_over($result['assignments'], $model) as $pid => $name) $items[] = ['kind' => 'over_capacity', 'title' => "$name over 100%", 'body' => "$name is over capacity in at least one week of the planned window", 'suggestion' => 'Displace planned work through an accepted proposal, never silently', 'link' => "/people/$pid", 'tone' => 'warn', 'person_id' => $pid];
    foreach (summary_single_skill_deps($result['assignments'], $model) as $s) $items[] = ['kind' => 'single_point', 'title' => "Single point: $s", 'body' => "Only one person on the team meets $s and scheduled work depends on it", 'suggestion' => 'Enable development pairing on this skill', 'link' => '/team', 'tone' => 'info'];
    return $items;
}
