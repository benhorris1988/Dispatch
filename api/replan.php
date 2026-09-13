<?php
// Engine entry points (SCH-*, STAB-*). Actions:
//   propose{kind, scope_person_ids?, engine?} (delivery_lead)      preview{changes:[...]}       scenario_save{name, changes}
//   scenarios   scenario_adopt{id} (delivery_lead)                 watch_list                   run_nightly (CLI or cron_key)
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/engine/proposals.php';
foreach (['capacity', 'priority', 'watchlist'] as $peer) { $f = __DIR__ . "/engine/$peer.php"; if (file_exists($f)) require_once $f; }

$action = param('action', 'propose');
$cfg = dp_config();

// ---- run_nightly: CLI (cron.php) or shared cron_key; runs for every workspace ------------------------------
if ($action === 'run_nightly' && (PHP_SAPI === 'cli' || (param('cron_key') && hash_equals((string)($cfg['cron_key'] ?? ''), (string)param('cron_key'))))) {
    $userId = null; $userName = 'Nightly replan';
    $results = [];
    $wsIds = param('workspace_id') ? [(int)param('workspace_id')] : array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.workspaces"));
    foreach ($wsIds as $wsId) $results[] = run_nightly($conn, $wsId);
    ok(['results' => $results]);
}

require_once __DIR__ . '/auth_middleware.php';

if ($action === 'propose') {
    require_role('delivery_lead');
    $kind = param('kind', 'manual');
    if (!in_array($kind, ['manual', 'nightly', 'urgent'], true)) fail('kind must be manual, nightly or urgent', 400);
    $engine = param('engine', 'heuristic');
    if (!in_array($engine, ['heuristic', 'cpsat'], true)) fail('engine must be heuristic or cpsat', 400);
    if ($kind === 'urgent' && !param('scope_person_ids')) {
        $hasUrgent = scalar($conn, "SELECT COUNT(*) FROM dbo.replan_triggers WHERE workspace_id = ? AND processed_at IS NULL AND class = 'urgent'", [$wsId]);
        if (!$hasUrgent) fail('An urgent cycle needs scope_person_ids or an unprocessed urgent trigger', 400);
    }
    $r = run_propose($conn, $wsId, ['kind' => $kind, 'scope_person_ids' => (array)param('scope_person_ids', []), 'engine' => $engine]);
    ok($r);
}

if ($action === 'preview') {
    // What-if within 2 s: hypothetical edits applied in memory, nothing persisted (SCH-08, SCH-11 lite).
    $edits = (array)param('changes', []);
    $r = preview_with_edits($conn, $wsId, $edits);
    ok(['summary_before' => $r['summary_before'], 'summary_after' => $r['summary_after'], 'changes' => array_map('change_lite', $r['changes']), 'held' => array_map('change_lite', $r['held']),
        'improvement_pct' => $r['improvement_pct'], 'below_threshold' => $r['below_threshold'], 'unscheduled' => $r['unscheduled'], 'solver_stats' => $r['solver_stats'], 'edits_applied' => $r['edits_applied']]);
}

if ($action === 'scenario_save') {
    require_role('team_lead');
    $name = trim((string)require_param('name'));
    $edits = (array)param('changes', []);
    $r = preview_with_edits($conn, $wsId, $edits);
    $vid = store_plan_version($conn, $wsId, $r['model'], $r['candidate'], ['status' => 'scenario', 'engine' => 'heuristic', 'objective_score' => $r['objective_after']['score'], 'objective_terms' => $r['objective_after']['terms'],
        'stability_cost_days' => $r['summary_after']['assignment_days_changed'], 'solver_stats' => array_merge($r['solver_stats'], ['edits' => $edits, 'summary_before' => $r['summary_before'], 'summary_after' => $r['summary_after'], 'improvement_pct' => $r['improvement_pct']]),
        'scenario_name' => mb_substr($name, 0, 120), 'notes' => mb_substr(scenario_note($edits), 0, 400)]);
    audit($conn, $wsId, 'create', 'scenario', $vid, null, ['name' => $name, 'edits' => $edits], $name);
    ok(['scenario' => scenario_shape(row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ?", [$vid]))]);
}
if ($action === 'scenarios') {
    ok(['scenarios' => array_map('scenario_shape', rows($conn, "SELECT * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'scenario' ORDER BY generated_at DESC", [$wsId]))]);
}
if ($action === 'scenario_adopt') {
    require_role('delivery_lead');
    $id = (int)require_param('id');
    $sc = row($conn, "SELECT * FROM dbo.plan_versions WHERE id = ? AND workspace_id = ? AND status = 'scenario'", [$id, $wsId]);
    if (!$sc) fail('Scenario not found', 404);
    $stats = json_col($sc['solver_stats'], []);
    $edits = $stats['edits'] ?? [];
    // Re-run with the scenario's edits so the proposal reflects today's data, then persist it as a manual proposal.
    $r = run_propose($conn, $wsId, ['kind' => 'manual', 'engine' => 'heuristic', 'model_overrides' => fn($m) => apply_edits_to_model($m, $edits)['model']]);
    update($conn, 'proposals', ['carried_over_note' => mb_substr('Adopted from scenario "' . $sc['scenario_name'] . '"', 0, 300)], 'id = ?', [$r['proposal_id']]);
    audit($conn, $wsId, 'update', 'scenario', $id, ['status' => 'scenario'], ['adopted_as_proposal' => $r['proposal_id']], $sc['scenario_name']);
    ok($r);
}

if ($action === 'watch_list') {
    if (function_exists('build_watch_list')) {
        $wl = build_watch_list($conn, $wsId);
        ok(['items' => is_array($wl) && isset($wl['items']) ? $wl['items'] : $wl, 'source' => 'watchlist.php']);
    }
    $model = build_model($conn, $wsId);
    $res = heuristic_plan($model);
    ok(['items' => derive_watch_list($model, $res), 'source' => 'planner']);
}

if ($action === 'run_nightly') { require_role('admin'); ok(['results' => [run_nightly($conn, $wsId)]]); }

fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------------------------
function run_nightly($conn, $wsId) {
    $t0 = microtime(true);
    $today = today();
    $pol = model_policy(row($conn, "SELECT TOP 1 * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC", [$wsId]) ?: []);
    $steps = [];
    $to = date('Y-m-d', strtotime(week_start($today) . ' +' . $pol['model_horizon_weeks'] . ' weeks'));
    if (function_exists('derive_capacity')) { $steps['capacity'] = derive_capacity($conn, $wsId, $today, $to); } else $steps['capacity'] = 'skipped (engine/capacity.php absent)';
    if (function_exists('compute_priority_scores')) { $steps['priority'] = compute_priority_scores($conn, $wsId); } else $steps['priority'] = 'skipped (engine/priority.php absent)';
    $r = run_propose($conn, $wsId, ['kind' => 'nightly', 'engine' => !empty(dp_config()['engine_url']) && param('engine') === 'cpsat' ? 'cpsat' : 'heuristic']);
    $model = build_model($conn, $wsId);
    $steps['stability_week'] = rollup_stability_week($conn, $wsId, $model);
    audit($conn, $wsId, 'create', 'nightly_run', $r['proposal_id'], null, ['changes' => count($r['changes']), 'held' => count($r['held']), 'seconds' => round(microtime(true) - $t0, 2)], 'Nightly replan');
    // The priority step returns a full term-by-term breakdown for every item, which is
    // useful in an API reply and 30KB of noise in a nightly log. Keep the counts.
    if (is_array($steps['priority'] ?? null)) {
        $steps['priority'] = ['updated' => $steps['priority']['updated'] ?? 0, 'max_raw' => $steps['priority']['max_raw'] ?? null, 'p90' => $steps['priority']['p90'] ?? null];
    }
    return ['workspace_id' => $wsId, 'proposal_id' => $r['proposal_id'], 'changes' => count($r['changes']), 'held' => count($r['held']), 'improvement_pct' => $r['improvement_pct'], 'below_threshold' => $r['below_threshold'], 'solver_stats' => $r['solver_stats'], 'steps' => $steps, 'seconds' => round(microtime(true) - $t0, 2)];
}

/** Apply hypothetical edits to a model in memory. Edits: add_item{work_item_id}, remove_item{work_item_id}, person_away{person_id, from, to}, add_person{name, skills:[{skill_id,proficiency}], hours_per_day?, from?, to?}, move{assignment_id, from, to, person_id?, allocation_pct?}, set_effort{work_item_id, remaining_days}. */
function apply_edits_to_model(array $model, array $edits) {
    $applied = [];
    foreach ($edits as $e) {
        $op = $e['op'] ?? $e['type'] ?? $e['kind'] ?? null;
        switch ($op) {
            case 'add_item':
                $iid = (int)($e['work_item_id'] ?? 0);
                if (isset($model['items'][$iid])) { $model['items'][$iid]['schedulable'] = true; if ($model['items'][$iid]['remaining_days'] <= 0) $model['items'][$iid]['remaining_days'] = (float)($e['remaining_days'] ?? 3); $applied[] = "Include {$model['items'][$iid]['ref']}"; }
                break;
            case 'remove_item':
                $iid = (int)($e['work_item_id'] ?? 0);
                if (isset($model['items'][$iid])) { $applied[] = "Drop {$model['items'][$iid]['ref']}"; unset($model['items'][$iid]); }
                break;
            case 'set_effort':
                $iid = (int)($e['work_item_id'] ?? 0);
                if (isset($model['items'][$iid])) { $model['items'][$iid]['remaining_days'] = (float)$e['remaining_days']; $applied[] = "{$model['items'][$iid]['ref']} at {$e['remaining_days']} days"; }
                break;
            case 'person_away':
                $pid = (int)($e['person_id'] ?? 0);
                if (isset($model['people'][$pid])) { foreach ($model['people'][$pid]['capacity'] as $day => &$c) if ($day >= $e['from'] && $day <= $e['to']) $c = ['available' => 0.0, 'reserve' => 0.0]; unset($c); $applied[] = "{$model['people'][$pid]['name']} away " . ex_date($e['from']) . ' – ' . ex_date($e['to']); }
                break;
            case 'add_person':
                $pid = -(count($applied) + 1) * 1000 - 1;
                $hpd = (float)($e['hours_per_day'] ?? $model['hours_per_day']);
                $cap = []; foreach ($model['days'] as $d) $cap[$d] = (!empty($e['from']) && $d < $e['from']) || (!empty($e['to']) && $d > $e['to']) ? ['available' => 0.0, 'reserve' => 0.0] : ['available' => $hpd, 'reserve' => round($hpd * $model['policy']['incident_reserve_pct'] / 100, 2)];
                $skills = []; foreach ((array)($e['skills'] ?? []) as $s) $skills[(int)$s['skill_id']] = (int)$s['proficiency'];
                $model['people'][$pid] = ['id' => $pid, 'name' => $e['name'] ?? 'Contractor', 'initials' => strtoupper(substr($e['name'] ?? 'C', 0, 2)), 'colour' => '#888888', 'role_title' => 'Contractor (what-if)', 'team_id' => null, 'team_name' => null, 'days_per_week' => 5,
                    'max_concurrent' => $model['policy']['max_concurrent_items'], 'min_focus_days' => $model['policy']['min_focus_days'], 'prefers' => [], 'avoid' => [], 'protected' => false, 'skills' => $skills, 'development' => [], 'capacity' => $cap, 'rota_weeks' => []];
                $applied[] = "Add " . ($e['name'] ?? 'a contractor');
                break;
            case 'move':
                foreach ($model['committed'] as &$a) if ($a['id'] === (int)$e['assignment_id']) { $a['from_date'] = $e['from']; $a['to_date'] = $e['to']; if (!empty($e['person_id'])) $a['person_id'] = (int)$e['person_id']; if (!empty($e['allocation_pct'])) $a['allocation_pct'] = (int)$e['allocation_pct']; $a['locked'] = true; $applied[] = "Move assignment #{$a['id']}"; }
                unset($a);
                break;
        }
    }
    return ['model' => $model, 'applied' => $applied];
}

function preview_with_edits($conn, $wsId, array $edits) {
    $applied = [];
    $r = run_propose($conn, $wsId, ['kind' => 'manual', 'engine' => 'heuristic', 'persist' => false, 'model_overrides' => function ($m) use ($edits, &$applied) { $x = apply_edits_to_model($m, $edits); $applied = $x['applied']; return $x['model']; }]);
    $r['edits_applied'] = $applied;
    return $r;
}
function change_lite(array $c) {
    return ['person_id' => $c['person_id'], 'person_name' => $c['person_name'] ?? null, 'work_item_id' => $c['work_item_id'], 'ref' => $c['ref'], 'kind' => $c['kind'], 'headline' => $c['headline'], 'reason' => $c['reason'],
        'before' => $c['before'], 'after' => $c['after'], 'stability_cost_days' => $c['stability_cost_days'], 'inside_freeze' => $c['inside_freeze'], 'impact_chips' => $c['impact_chips'], 'guardrail_status' => $c['guardrail_status']];
}
function scenario_note(array $edits) { $x = apply_edits_to_model(['items' => [], 'people' => [], 'committed' => [], 'days' => [], 'policy' => ['incident_reserve_pct' => 12, 'max_concurrent_items' => 2, 'min_focus_days' => 2], 'hours_per_day' => 7.5], $edits); return implode('; ', $x['applied']); }
function scenario_shape(array $v) {
    $stats = json_col($v['solver_stats'], []);
    return ['id' => (int)$v['id'], 'name' => $v['scenario_name'], 'version_no' => (int)$v['version_no'], 'generated_at' => $v['generated_at'], 'objective_score' => $v['objective_score'] !== null ? (float)$v['objective_score'] : null,
        'stability_cost_days' => $v['stability_cost_days'] !== null ? (float)$v['stability_cost_days'] : null, 'edits' => $stats['edits'] ?? [], 'summary_before' => $stats['summary_before'] ?? null, 'summary_after' => $stats['summary_after'] ?? null, 'improvement_pct' => $stats['improvement_pct'] ?? null, 'notes' => $v['notes']];
}
