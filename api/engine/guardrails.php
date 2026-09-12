<?php
// Guardrails (STAB-01/03/04, CHG-03). apply_guardrails($changes, $improvementPct, $policy, $priorUsage = [])
//   → ['changes' => [... + guardrail_status, guardrail_reason], 'budget' => {used, limit, per_person:[{person_id, week_start, used}]}, 'below_threshold' => bool]
// Statuses: ok | needs_approval (inside freeze horizon) | held_budget (person's moved days in a week exceed change_budget_days)
//           | held_threshold (whole proposal improves less than min_improvement_pct: shown as information, never applied automatically).
// $priorUsage: [ "person_id:week_start" => days already used this week by committed changes ] so the budget spans the week, not just this proposal.

function apply_guardrails(array $changes, $improvementPct, array $policy, array $priorUsage = []) {
    $limit = (int)($policy['change_budget_days'] ?? 5);
    $minImp = (float)($policy['min_improvement_pct'] ?? 5);
    $belowThreshold = $improvementPct !== null && $improvementPct < $minImp;
    $usage = $priorUsage;
    // Cheapest changes first within a person-week so the budget is spent on the least disruptive ones.
    $order = array_keys($changes);
    usort($order, fn($a, $b) => $changes[$a]['stability_cost_days'] <=> $changes[$b]['stability_cost_days']);
    foreach ($order as $k) {
        $c = &$changes[$k];
        $c['guardrail_status'] = 'ok'; $c['guardrail_reason'] = null;
        if (!empty($c['inside_freeze'])) {
            $c['guardrail_status'] = 'needs_approval';
            $c['guardrail_reason'] = 'Inside the freeze horizon (' . ($policy['freeze_horizon_days'] ?? 10) . ' working days): needs a named approver and a reason.';
        }
        $pid = $c['person_id'] ?? null; $cost = (float)($c['stability_cost_days'] ?? 0);
        $week = week_start(($c['after']['from'] ?? null) ?: ($c['before']['from'] ?? date('Y-m-d')));
        if ($pid && $cost > 0) {
            $key = "$pid:$week";
            $used = $usage[$key] ?? 0;
            if ($used + $cost > $limit + 1e-9) {
                $c['guardrail_status'] = 'held_budget';
                $c['guardrail_reason'] = sprintf('Change budget exceeded: %s would have %.1f of %d assignment-days moved in w/c %s. Held until a delivery lead overrides with a reason.', $c['person_name'] ?? 'this person', $used + $cost, $limit, date('j M', strtotime($week)));
            } else {
                $usage[$key] = $used + $cost;
            }
        }
        if ($belowThreshold) {
            $c['guardrail_status'] = 'held_threshold';
            $c['guardrail_reason'] = sprintf('Improvement %.1f%% is below the %.0f%% minimum: shown as information, never applied automatically.', $improvementPct, $minImp);
        }
        unset($c);
    }
    $perPerson = [];
    foreach ($usage as $key => $v) { [$pid, $wk] = explode(':', $key); $perPerson[] = ['person_id' => (int)$pid, 'week_start' => $wk, 'used' => round($v, 2)]; }
    $thisWeek = week_start($policy['today'] ?? date('Y-m-d'));
    $usedThisWeek = 0; foreach ($perPerson as $pp) if ($pp['week_start'] === $thisWeek) $usedThisWeek = max($usedThisWeek, $pp['used']);
    return ['changes' => $changes, 'budget' => ['used' => round($usedThisWeek, 2), 'limit' => $limit, 'per_person' => $perPerson, 'week_start' => $thisWeek], 'below_threshold' => $belowThreshold];
}

/** Human-readable guardrail descriptions for the Changes screen side panel. */
function guardrail_descriptions(array $policy) {
    return [
        ['key' => 'freeze', 'label' => 'Freeze horizon ' . $policy['freeze_horizon_days'] . ' working days', 'detail' => 'Changes inside need a named approver', 'enabled' => true],
        ['key' => 'budget', 'label' => 'Change budget ' . $policy['change_budget_days'] . ' per person per week', 'detail' => 'Counts any moved assignment-day', 'enabled' => true],
        ['key' => 'threshold', 'label' => 'Minimum improvement ' . rtrim(rtrim(number_format($policy['min_improvement_pct'], 1), '0'), '.') . '%', 'detail' => 'Smaller gains are shown but never applied', 'enabled' => true],
        ['key' => 'reserve', 'label' => 'Incident reserve ' . rtrim(rtrim(number_format($policy['incident_reserve_pct'], 1), '0'), '.') . '% per person', 'detail' => 'Planned work never fills the reserve', 'enabled' => true],
    ];
}
