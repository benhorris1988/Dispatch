<?php
// Scheduling engine tests: the constraint model, the diff, the guardrails and the
// stability arithmetic — plus the acceptance scenarios of specification 13.1.
//   php tests/engine_test.php [base=http://localhost:8090]
//
// Runs the engine libraries directly against the seeded demo database (no HTTP), which
// is what lets it assert on candidate plans rather than only on stored proposals.
// Re-seed afterwards: proposing writes plan versions and proposals.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

require __DIR__ . '/../migration_connect.php';   // $conn (db_owner), CLI-only
require_once __DIR__ . '/../api/lib.php';
require_once __DIR__ . '/../api/engine/capacity.php';
require_once __DIR__ . '/../api/engine/model.php';
require_once __DIR__ . '/../api/engine/planner.php';
require_once __DIR__ . '/../api/engine/diff.php';
require_once __DIR__ . '/../api/engine/guardrails.php';
require_once __DIR__ . '/../api/engine/summary.php';
require_once __DIR__ . '/../api/engine/explain.php';
require_once __DIR__ . '/../api/engine/cpsat_client.php';
require_once __DIR__ . '/../api/engine/watchlist.php';

$pass = 0; $fail = 0;
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function near($a, $b, $tol, $label) { check(abs((float)$a - (float)$b) <= $tol, "$label (got " . var_export($a, true) . ", want ~$b +/-$tol)"); }
function section($t) { echo "\n== $t\n"; }

$wsId = (int)scalar($conn, "SELECT TOP 1 id FROM dbo.workspaces ORDER BY id");
check($wsId > 0, "workspace found (id $wsId)");
$policy = current_policy($conn, $wsId);
$today = today();

// ---------------------------------------------------------------------------------
section('Model builds from the seeded database');
$t0 = microtime(true);
$model = build_model($conn, $wsId);
$buildSeconds = microtime(true) - $t0;
check(count($model['people']) === 8, 'model has the 8 team members (' . count($model['people']) . ')');
check(count($model['items']) > 20, 'model has the open pipeline (' . count($model['items']) . ' items)');
check(!empty($model['committed']), 'model carries the committed plan as its baseline (' . count($model['committed']) . ')');
check($model['today'] === $today, "model today is $today");
check($model['windows']['freeze_end'] > $today, 'freeze horizon ends after today (' . $model['windows']['freeze_end'] . ')');
check($model['windows']['planned_end'] > $model['windows']['freeze_end'], 'planned window extends past the freeze horizon');
check($model['windows']['indicative_end'] > $model['windows']['planned_end'], 'indicative window extends past the planned window');

// Every person must have capacity for every modelled day, or the planner silently
// treats the gap as unavailable.
$missing = 0;
foreach ($model['people'] as $p) foreach ($model['days'] as $d) if (!isset($p['capacity'][$d])) $missing++;
check($missing === 0, "capacity is derived for every person-day ($missing gaps)");

// ---------------------------------------------------------------------------------
section('Heuristic planner (8.9) and the hard constraints (8.5)');
$t0 = microtime(true);
$result = heuristic_plan($model);
$planSeconds = microtime(true) - $t0;
check(!empty($result['assignments']), 'planner returns a plan (' . count($result['assignments']) . ' assignments)');
printf("  ..   built in %.2fs, planned in %.2fs\n", $buildSeconds, $planSeconds);
check($planSeconds < 2.0, sprintf('heuristic completes inside the 2s preview budget (%.2fs)', $planSeconds));

// The property that matters: no plan the engine produces may break a hard constraint.
$violations = plan_check_constraints($result['assignments'], $model);
check(empty($violations), 'candidate plan breaks no hard constraint' . (empty($violations) ? '' : ': ' . json_encode(array_slice($violations, 0, 3))));

// Skills, checked independently of the engine's own checker.
$skillBreaches = [];
foreach ($result['assignments'] as $a) {
    $item = $model['items'][$a['work_item_id']] ?? null;
    if (!$item || empty($item['skills']) || !empty($item['skill_effort'])) continue;
    $person = null;
    foreach ($model['people'] as $p) if ($p['id'] === $a['person_id']) { $person = $p; break; }
    if (!$person) continue;
    foreach ($item['skills'] as $s) {
        $level = (int)($person['skills'][$s['skill_id']] ?? 0);
        if ($level < (int)$s['min_proficiency']) $skillBreaches[] = "{$item['ref']} -> {$person['name']} ({$s['name']} $level < {$s['min_proficiency']})";
    }
}
check(empty($skillBreaches), 'nobody is assigned work they are not qualified for' . (empty($skillBreaches) ? '' : ': ' . implode('; ', array_slice($skillBreaches, 0, 3))));

// Capacity is checked by plan_check_constraints above: per-day effort cannot be
// reconstructed from a date range here, because a range spans days the person does not
// work and the planner spreads the remainder unevenly across the rest.

// Committed work is locked (STAB-01): the freeze horizon is not the planner's to move.
$frozenMoved = [];
foreach ($model['committed'] as $c) {
    if ($c['from_date'] > $model['windows']['freeze_end']) continue;
    $found = null;
    foreach ($result['assignments'] as $a) {
        if ($a['work_item_id'] === $c['work_item_id'] && $a['person_id'] === $c['person_id']) { $found = $a; break; }
    }
    if (!$found) { $frozenMoved[] = "{$c['work_item_id']} dropped"; continue; }
    if ($found['from_date'] !== $c['from_date']) $frozenMoved[] = "{$c['work_item_id']} {$c['from_date']} -> {$found['from_date']}";
}
check(empty($frozenMoved), 'assignments inside the freeze horizon are untouched' . (empty($frozenMoved) ? '' : ': ' . implode('; ', array_slice($frozenMoved, 0, 3))));

// Completeness (8.5): scheduled to the end, or reported unscheduled with a reason.
$reasoned = true;
foreach ($result['unscheduled'] ?? [] as $u) if (empty($u['reason'])) $reasoned = false;
check($reasoned, 'every unscheduled item carries a reason');

// ---------------------------------------------------------------------------------
section('Diff and stability costing (8.7, STAB-02/06)');
$changes = diff_plans($model['committed'], $result['assignments'], $model);
check(is_array($changes), 'diff returns a change list (' . count($changes) . ')');
$badCost = 0; $indicativeCharged = 0;
foreach ($changes as $c) {
    if (($c['stability_cost_days'] ?? 0) < 0) $badCost++;
    // STAB-06 charges nothing for a change that lives entirely beyond the planning horizon.
    // A change whose *after* is out there but whose *before* was inside the planned window has
    // still vacated planned days, and those days are real churn — so both ends are tested.
    $before = $c['before'] ?? null; $after = $c['after'] ?? null;
    $beforeOut = !$before || empty($before['from']) || $before['from'] > $model['windows']['planned_end'];
    $afterOut = !$after || empty($after['from']) || $after['from'] > $model['windows']['planned_end'];
    if ($beforeOut && $afterOut && ($c['stability_cost_days'] ?? 0) > 0) $indicativeCharged++;
}
check($badCost === 0, 'no change has a negative stability cost');
check($indicativeCharged === 0, 'moves beyond the planning horizon cost nothing (STAB-06)');

// A hand-built pair of plans, so the arithmetic is checked against a known answer.
$miniModel = [
    'today' => $today,
    'hours_per_day' => 7.5,
    'working_days' => ['Mon','Tue','Wed','Thu','Fri'],
    'windows' => ['today' => $today, 'freeze_end' => add_working_days($today, 10), 'planned_end' => add_working_days($today, 30), 'indicative_end' => add_working_days($today, 120)],
    'days' => $model['days'],
    'day_index' => $model['day_index'],
    'policy' => $model['policy'],
    'people' => [['id' => 1, 'name' => 'A', 'skills' => [], 'capacity' => []]],
    'items' => [99 => ['id' => 99, 'ref' => 'WI-TEST', 'title' => 'Test', 'priority' => 50, 'policy' => 'planned', 'skills' => [], 'protected' => false, 'type_name' => 'Project', 'size_stamp' => 'M']],
    'committed' => [], 'scope_person_ids' => [],
];
$start = add_working_days($today, 12);           // just outside the freeze horizon
$before = [['id' => 900, 'work_item_id' => 99, 'person_id' => 1, 'from_date' => $start, 'to_date' => add_working_days($start, 4), 'allocation_pct' => 100, 'state' => 'planned', 'locked' => false, 'is_reserve' => false, 'role_label' => null, 'fixed_person' => false, 'fixed_dates' => false, 'note' => null]];
$shifted = add_working_days($start, 2);
$after = [['work_item_id' => 99, 'person_id' => 1, 'from_date' => $shifted, 'to_date' => add_working_days($shifted, 4), 'allocation_pct' => 100]];
$miniChanges = diff_plans($before, $after, $miniModel);
check(count($miniChanges) === 1, 'a two-day shift is one change (' . count($miniChanges) . ')');
if ($miniChanges) {
    check(($miniChanges[0]['inside_freeze'] ?? true) === false, 'a change outside the freeze horizon is not flagged as inside it');
    check(($miniChanges[0]['stability_cost_days'] ?? 0) > 0, 'a moved assignment costs stability (' . ($miniChanges[0]['stability_cost_days'] ?? 0) . ' days)');
}
$identical = diff_plans($before, [['work_item_id' => 99, 'person_id' => 1, 'from_date' => $start, 'to_date' => add_working_days($start, 4), 'allocation_pct' => 100]], $miniModel);
check(count($identical) === 0, 'an unchanged plan produces no changes (' . count($identical) . ')');

// ---------------------------------------------------------------------------------
section('Guardrails (STAB-01/03/04, CHG-03)');
$budget = (int)$policy['change_budget_days'];
$minImp = (float)$policy['min_improvement_pct'];

// Inside the freeze horizon -> needs a named approver, never automatic.
$insideChange = [['id' => 1, 'person_id' => 1, 'work_item_id' => 99, 'kind' => 'move', 'inside_freeze' => true, 'stability_cost_days' => 2,
    'before' => ['from' => $today, 'to' => add_working_days($today, 3)], 'after' => ['from' => add_working_days($today, 2), 'to' => add_working_days($today, 5)]]];
$g = apply_guardrails($insideChange, 20.0, $policy);
$statuses = array_map(fn($c) => $c['guardrail_status'] ?? '?', $g['changes'] ?? $g);
check(in_array('needs_approval', $statuses, true), 'a change inside the freeze horizon needs approval (got ' . implode(',', $statuses) . ')');

// Over the per-person weekly change budget -> held.
$overBudget = [];
for ($i = 0; $i < 4; $i++) {
    $overBudget[] = ['id' => 10 + $i, 'person_id' => 1, 'work_item_id' => 100 + $i, 'kind' => 'move', 'inside_freeze' => false,
        'stability_cost_days' => $budget, 'before' => ['from' => add_working_days($today, 12), 'to' => add_working_days($today, 14)],
        'after' => ['from' => add_working_days($today, 15), 'to' => add_working_days($today, 17)]];
}
$g2 = apply_guardrails($overBudget, 20.0, $policy);
$statuses2 = array_map(fn($c) => $c['guardrail_status'] ?? '?', $g2['changes'] ?? $g2);
check(in_array('held_budget', $statuses2, true), "moving more than the $budget-day budget for one person is held (got " . implode(',', $statuses2) . ')');

// Below the minimum improvement threshold -> shown, never applied.
$g3 = apply_guardrails($insideChange, $minImp - 3, $policy);
$statuses3 = array_map(fn($c) => $c['guardrail_status'] ?? '?', $g3['changes'] ?? $g3);
check(in_array('held_threshold', $statuses3, true), "an improvement below $minImp% is held as information (got " . implode(',', $statuses3) . ')');
$g4 = apply_guardrails($overBudget, $minImp + 20, $policy);
$statuses4 = array_map(fn($c) => $c['guardrail_status'] ?? '?', $g4['changes'] ?? $g4);
check(!in_array('held_threshold', $statuses4, true), 'a worthwhile improvement is not held by the threshold');

// ---------------------------------------------------------------------------------
section('Plan summary and the stability index (CHG-04, STAB-08)');
$summary = plan_summary($result['assignments'], $model, ['committed' => $model['committed']]);
foreach (['late_items', 'people_over_100', 'assignment_days_changed', 'total_assignment_days'] as $k) {
    check(array_key_exists($k, $summary), "summary reports $k");
}
check(($summary['people_over_100'] ?? -1) >= 0, 'people over 100% is a count');
check(($summary['assignment_days_changed'] ?? -1) >= 0, 'assignment-days changed is a count');
check(($summary['total_assignment_days'] ?? 0) > 0, 'total assignment-days is positive');
// STAB-08 is a rolling four-week figure over stored history, so it is not simply
// 1 - changed/total for this one diff; assert only that it is a sane percentage.
$idx = (float)($summary['stability_index'] ?? -1);
check($idx >= 0 && $idx <= 100, "stability index is a percentage (got $idx)");

// ---------------------------------------------------------------------------------
section('Explainer (8.11)');
if ($changes) {
    $explained = explain_change($changes[0], $model, []);
    check(!empty($explained['headline']), 'a change gets a plain-language headline: ' . substr($explained['headline'] ?? '', 0, 60));
    check(!empty($explained['reason']), 'a change gets a reason');
    check(is_array($explained['impact_chips'] ?? null), 'a change gets impact chips');
    $tones = array_map(fn($c) => $c['tone'] ?? '', $explained['impact_chips'] ?? []);
    $validTones = array_diff($tones, ['ok', 'warn', 'bad', 'info', '']);
    check(empty($validTones), 'every chip tone is one the client renders (' . implode(',', array_unique($tones)) . ')');
}

// ---------------------------------------------------------------------------------
section('Incidents consume the reserve before displacing work (SCH-10)');
$rota = row($conn, "SELECT TOP 1 person_id, week_start FROM dbo.incident_rota WHERE workspace_id = ? AND week_start <= ? ORDER BY week_start DESC", [$wsId, $today]);
check($rota !== null, 'someone is on the incident rota this week');
if ($rota) {
    $pid = (int)$rota['person_id'];
    $person = null; foreach ($model['people'] as $p) if ($p['id'] === $pid) { $person = $p; break; }
    check($person !== null, 'the rota person is in the model');
    if ($person) {
        $cap = $person['capacity'][$today] ?? null;
        if ($cap && $cap['available'] > 0) {
            $pct = round($cap['reserve'] / $cap['available'] * 100);
            near($pct, (float)$policy['rota_reserve_pct'], 2, "the rota person's reserve is {$policy['rota_reserve_pct']}% this week");
        }
        $others = 0; $normal = 0;
        foreach ($model['people'] as $p) {
            if ($p['id'] === $pid) continue;
            $c = $p['capacity'][$today] ?? null;
            if (!$c || $c['available'] <= 0) continue;
            $others++;
            if (abs($c['reserve'] / $c['available'] * 100 - (float)$policy['incident_reserve_pct']) < 2) $normal++;
        }
        check($others === 0 || $normal === $others, "everyone else holds {$policy['incident_reserve_pct']}% back ($normal of $others)");
    }
}
$incident = row($conn, "SELECT wi.id, wi.ref FROM dbo.work_items wi JOIN dbo.work_types wt ON wt.id = wi.work_type_id
    WHERE wi.workspace_id = ? AND wt.policy = 'interrupt' AND wi.status NOT IN ('delivered','cancelled')", [$wsId]);
check($incident !== null, 'the demo has an open incident (' . ($incident['ref'] ?? 'none') . ')');
if ($incident) {
    $item = $model['items'][(int)$incident['id']] ?? null;
    check($item !== null && $item['policy'] === 'interrupt', "{$incident['ref']} is modelled as interrupt-driven");
}

// ---------------------------------------------------------------------------------
section('Urgent cycles are scoped to the affected people (STAB-05)');
$scopePid = (int)array_key_first($model['people']);   // keyed by person id, not positional
$scoped = build_model($conn, $wsId, ['scope_person_ids' => [$scopePid]]);
$scopedPlan = heuristic_plan($scoped);
// Rows are matched by committed_id, not by (item, person): one person legitimately holds several
// committed rows for the same item (a continuation split across windows), and matching on the pair
// compared row A against row B's dates and called an untouched plan "moved".
$planByCommitted = [];
foreach ($scopedPlan['assignments'] as $a) if (!empty($a['committed_id'])) $planByCommitted[(int)$a['committed_id']] = $a;
$outOfScopeMoved = [];
foreach ($scoped['committed'] as $c) {
    if ($c['person_id'] === $scopePid) continue;
    if ($c['to_date'] < $scoped['today']) continue;                       // wholly in the past: not replanned
    if (!isset($scoped['items'][$c['work_item_id']])) continue;           // delivered / cancelled: released
    if (!isset($scoped['people'][$c['person_id']])) continue;
    $a = $planByCommitted[(int)$c['id']] ?? null;
    if ($a === null) { $outOfScopeMoved[] = "{$c['id']} dropped"; continue; }
    if ($a['person_id'] !== $c['person_id'] || $a['from_date'] !== $c['from_date'] || $a['to_date'] !== $c['to_date'] || (int)$a['allocation_pct'] !== (int)$c['allocation_pct']) {
        $outOfScopeMoved[] = "{$c['id']} {$c['from_date']}..{$c['to_date']}@{$c['allocation_pct']} -> {$a['from_date']}..{$a['to_date']}@{$a['allocation_pct']}";
    }
}
check(empty($outOfScopeMoved), 'an urgent cycle leaves everyone else\'s plan alone (' . count($outOfScopeMoved) . ' moved' . ($outOfScopeMoved ? ': ' . implode('; ', array_slice($outOfScopeMoved, 0, 3)) : '') . ')');

// Regression (scope leak): an item held by BOTH a scoped and an unscoped person used to be marked
// "preloaded" by the out-of-scope rows alone, which dropped the scoped person's rows from the plan
// entirely — the urgent cycle silently deleted the very work it was called to re-plan.
$scopedItems = [];
foreach ($scoped['committed'] as $c) if ($c['person_id'] === $scopePid && $c['to_date'] >= $scoped['today'] && isset($scoped['items'][$c['work_item_id']])) $scopedItems[$c['work_item_id']] = true;
$lostInScope = [];
foreach (array_keys($scopedItems) as $iid) {
    $found = false;
    foreach ($scopedPlan['assignments'] as $a) if ($a['work_item_id'] === $iid && $a['person_id'] === $scopePid) { $found = true; break; }
    foreach ($scopedPlan['unscheduled'] as $u) if ($u['work_item_id'] === $iid) { $found = true; break; }
    if (!$found) $lostInScope[] = $scoped['items'][$iid]['ref'];
}
check(empty($lostInScope), 'the scoped person keeps (or is told about) every item they were committed to' . ($lostInScope ? ': ' . implode(', ', $lostInScope) : ''));

// Regression (double booking): the candidate plan is a list of date RANGES, so the planner's own
// occupancy grid and the rows it emits must agree. Re-derive per-day load here, independently of
// plan_check_constraints(), at the documented reading: allocation_pct is a share of that day's
// schedulable time (available − reserve; interrupts may eat the reserve).
$overbooked = [];
$dayLoad = [];
foreach ($result['assignments'] as $a) {
    $p = $model['people'][$a['person_id']] ?? null; $it = $model['items'][$a['work_item_id']] ?? null;
    if (!$p || !$it) continue;
    foreach (model_days_in($model, $a['from_date'], $a['to_date']) as $di) {
        $day = $model['days'][$di];
        $cap = $p['capacity'][$day] ?? ['available' => 0, 'reserve' => 0];
        $room = $cap['available'] - ($it['policy'] === 'interrupt' ? 0 : $cap['reserve']);
        if ($room <= 1e-6) continue;                       // not a day this person works
        $dayLoad[$a['person_id']][$day] = ($dayLoad[$a['person_id']][$day] ?? 0) + $a['allocation_pct'] / 100 * $room;
    }
}
foreach ($dayLoad as $pid => $days) {
    $p = $model['people'][$pid];
    foreach ($days as $day => $h) {
        if ($h > $p['capacity'][$day]['available'] + 1e-6) $overbooked[] = "{$p['name']} " . round($h, 2) . "h on $day";
    }
}
check(empty($overbooked), 'no one is booked past their day once the ranges are expanded' . ($overbooked ? ': ' . implode('; ', array_slice($overbooked, 0, 3)) : ''));

// ---------------------------------------------------------------------------------
section('Watch list carries what the scheduler cannot fix (SCH-05, 8.13)');
$watch = build_watch_list($conn, $wsId);
check(is_array($watch), 'watch list builds (' . count($watch) . ' entries)');
$kinds = array_values(array_unique(array_map(fn($w) => $w['kind'] ?? '?', $watch)));
$knownKinds = ['skills_gap', 'no_estimate', 'over_capacity', 'late', 'single_point'];
check(empty(array_diff($kinds, $knownKinds)), 'every entry has a known kind (' . implode(',', $kinds) . ')');
$withSuggestion = 0;
foreach ($watch as $w) if (!empty($w['suggestion'])) $withSuggestion++;
check(count($watch) === 0 || $withSuggestion === count($watch), "every entry suggests a way through ($withSuggestion of " . count($watch) . ')');
$singlePoint = array_values(array_filter($watch, fn($w) => ($w['kind'] ?? '') === 'single_point'));
check(!empty($singlePoint), 'the single-point-of-failure skill is flagged (spec 13.1 skills gap)');

// ---------------------------------------------------------------------------------
section('Small incoming work fills gaps first, at the configured threshold (STAB-10)');
$threshold = (float)$policy['small_fill_threshold_days'];
$flagWrong = 0;
foreach ($model['items'] as $it) if ((bool)$it['small'] !== ((float)$it['remaining_days'] <= $threshold)) $flagWrong++;
check($flagWrong === 0, "every item's small flag is remaining effort <= small_fill_threshold_days ($threshold): $flagWrong disagree");

/**
 * Refs of the items NOT already on the committed plan, in the order the planner first placed
 * them. Interrupts are excluded: they are ordered ahead of everything by policy, not by size.
 */
$incomingOrder = function (array $assignments, array $model, array $committedIds) {
    $seen = []; $order = [];
    foreach ($assignments as $a) {
        $iid = $a['work_item_id'];
        if (isset($committedIds[$iid]) || isset($seen[$iid])) continue;
        $seen[$iid] = true;
        $it = $model['items'][$iid] ?? null;
        if (!$it || $it['policy'] === 'interrupt') continue;
        $order[] = $it['ref'];
    }
    return $order;
};
/** True when every small item in the placement order comes before every large one. */
$smallFirst = function (array $order, array $model) {
    $bySmall = []; foreach ($model['items'] as $it) $bySmall[$it['ref']] = !empty($it['small']);
    $seenLarge = false;
    foreach ($order as $ref) { if (!$bySmall[$ref]) $seenLarge = true; elseif ($seenLarge) return false; }
    return true;
};
$committedIds = []; foreach ($model['committed'] as $c) $committedIds[$c['work_item_id']] = true;
$incomingSmall = []; $incomingLarge = [];
foreach ($model['items'] as $it) {
    if (isset($committedIds[$it['id']]) || !$it['schedulable'] || $it['policy'] === 'interrupt') continue;
    if ($it['small']) $incomingSmall[] = $it['ref']; else $incomingLarge[] = $it['ref'];
}
check($incomingSmall && $incomingLarge, 'the demo has both small and large incoming work (' . count($incomingSmall) . ' small, ' . count($incomingLarge) . ' large)');
$orderReal = $incomingOrder($result['assignments'], $model, $committedIds);
check($smallFirst($orderReal, $model), 'small incoming work is placed before large incoming work (' . implode(', ', $orderReal) . ')');

// On this demo the small item also happens to outrank the large ones, so the order above alone
// cannot tell the rule apart from plain priority ordering. Invert the flags — nothing else — and
// the order must invert with them: that is what proves the planner reads `small`, and `small` is
// model.php's reading of small_fill_threshold_days (asserted above).
$flipped = $model;
foreach ($flipped['items'] as $k => $it) if (!isset($committedIds[$it['id']]) && $it['policy'] !== 'interrupt') $flipped['items'][$k]['small'] = !$it['small'];
$flippedRes = heuristic_plan($flipped);
$orderFlipped = $incomingOrder($flippedRes['assignments'], $flipped, $committedIds);
check($orderReal !== $orderFlipped, 'inverting the threshold inverts the order (' . implode(', ', $orderReal) . '  ->  ' . implode(', ', $orderFlipped) . ')');
check($smallFirst($orderFlipped, $flipped), 'and the inverted model is still placed small-first');
// Filling gaps must not cost completeness: no more work goes unplanned than without the rule.
check(count($result['unscheduled']) <= count($flippedRes['unscheduled']), 'gap-filling leaves no more work unscheduled (' . count($result['unscheduled']) . ' vs ' . count($flippedRes['unscheduled']) . ')');

// ---------------------------------------------------------------------------------
section('CP-SAT client degrades to the heuristic rather than failing (10.4)');
$bad = cpsat_solve($model, ['engine_url' => 'http://127.0.0.1:9'], 2);
check(($bad['ok'] ?? true) === false, 'an unreachable solver reports failure rather than throwing');
check(!empty($bad['reason']), 'and says why: ' . substr((string)($bad['reason'] ?? ''), 0, 60));
$noUrl = cpsat_solve($model, ['engine_url' => ''], 2);
check(($noUrl['ok'] ?? true) === false, 'an unconfigured solver reports failure');

$payload = cpsat_model_payload($model);
foreach (['schema_version', 'today', 'days', 'windows', 'policy', 'people', 'items', 'committed'] as $k) {
    check(array_key_exists($k, $payload), "solver payload carries $k");
}
$capLen = true;
foreach ($payload['people'] as $p) if (count($p['capacity']) !== count($payload['days'])) $capLen = false;
check($capLen, 'each person sends one capacity pair per modelled day (docs/ENGINE_MODEL.md)');

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
