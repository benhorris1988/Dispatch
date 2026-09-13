<?php
// Heuristic list-scheduling planner (section 8.9) over the model from model.php.
// heuristic_plan($model, $opts) → ['assignments'=>[...], 'unscheduled'=>[...], 'objective'=>float, 'terms'=>[...],
//                                  'weighted_terms'=>[...], 'solve_seconds'=>float, 'displacements'=>[...], 'stats'=>[...]]
// Hard constraints (8.5): skills, capacity − reserve (incidents may use reserve), zero-capacity days,
// finish-to-start dependencies, earliest start, locks (fixed / freeze window kept exactly when feasible),
// max concurrent (counted sizes), focus blocks (contiguous runs at constant allocation), completeness.
// Stability (8.7): committed slots are tried first and only abandoned when infeasible or when the
// objective gain beats the stability charge; small work fills gaps (STAB-10); upward re-estimates
// extend in place (STAB-09); incidents use reserve first then displace the person's lowest-priority
// planned item (SCH-10); urgent cycles are scoped to scope_person_ids (STAB-05).
require_once __DIR__ . '/model.php';

function heuristic_plan(array $model, array $opts = []) {
    $t0 = microtime(true);
    $st = pl_init_state($model);
    $scope = $model['scope_person_ids'] ?? [];
    $scopeSet = $scope ? array_flip($scope) : null;
    $out = []; $unscheduled = []; $displacements = [];
    $committedByItem = [];
    foreach ($model['committed'] as $a) $committedByItem[$a['work_item_id']][] = $a;

    // Pass 1: pre-load locked assignments, and (urgent cycles) everything belonging to people outside scope.
    // An item is only "preloaded" (taken out of the queue) when EVERY committed row of it was fixed
    // here. A partly fixed item — one person's row locked or out of scope, another's still free to
    // move — stays in the queue with the effort already covered by the fixed rows subtracted, so its
    // remaining rows are re-planned instead of being silently dropped with the item.
    $preloaded = [];             // item id => true when every committed row was pre-loaded
    $fixedShare = [];            // item id => share of the item's effort already covered by pre-loaded rows
    $fixedFinish = [];           // item id => last day index covered by pre-loaded rows
    $fixedCount = []; $committedCount = []; $fixedWeight = []; $totalWeight = [];
    foreach ($model['committed'] as $a) {
        if (!isset($model['items'][$a['work_item_id']]) || !isset($model['people'][$a['person_id']])) continue;
        $committedCount[$a['work_item_id']] = ($committedCount[$a['work_item_id']] ?? 0) + 1;
        $totalWeight[$a['work_item_id']] = ($totalWeight[$a['work_item_id']] ?? 0) + pl_row_weight($model, $a);
    }
    foreach ($model['committed'] as $a) {
        $item = $model['items'][$a['work_item_id']] ?? null;
        if (!$item) continue; // delivered / cancelled: released
        $outOfScope = $scopeSet !== null && !isset($scopeSet[$a['person_id']]);
        if (!$a['locked'] && !$outOfScope) continue;
        if (!isset($model['people'][$a['person_id']])) continue;
        $iid = $item['id']; $pid = $a['person_id']; $isInc = $item['policy'] === 'interrupt';
        $fixedCount[$iid] = ($fixedCount[$iid] ?? 0) + 1;
        $fixedWeight[$iid] = ($fixedWeight[$iid] ?? 0) + pl_row_weight($model, $a);
        $dis = model_days_in($model, $a['from_date'], $a['to_date']);
        if (!$dis) continue; // entirely in the past: nothing to occupy, nothing to emit
        $last = -1;
        foreach ($dis as $di) {
            // Same reading as pl_try_run(): the allocation is a share of that day's schedulable
            // time, and a day the person does not work carries no effort at all.
            $room = $isInc ? $st['cap'][$pid][$di] : max(0.0, $st['cap'][$pid][$di] - $st['res'][$pid][$di]);
            if ($room <= 1e-6) continue;
            $h = $a['allocation_pct'] / 100 * $room;
            pl_consume($st, $pid, $di, $iid, $h, $isInc);
            $last = $di;
        }
        $out[] = pl_out_row($model, $item, $pid, $a['from_date'], $a['to_date'], $a['allocation_pct'], $a['role_label'], true, true, $a['id'], $a['is_reserve']);
        $fixedFinish[$iid] = max($fixedFinish[$iid] ?? -1, $last);
    }
    foreach ($fixedCount as $iid => $n) {
        if ($n >= ($committedCount[$iid] ?? 0)) { $preloaded[$iid] = true; continue; }
        // Effort is shared across an item's committed rows in proportion to their weight (the same
        // split pl_try_keep() uses), so the rows left to plan carry only what the fixed rows do not.
        $tw = $totalWeight[$iid] ?? 0;
        if ($tw > 0) $fixedShare[$iid] = min(1.0, ($fixedWeight[$iid] ?? 0) / $tw);
    }

    // Order: interrupt items first (by priority), then everything already on the committed plan, then
    // incoming work. STAB-10: within the incoming work, items the policy counts as *small* go first.
    //
    // `small` is model.php's reading of the policy value `small_fill_threshold_days` — an item whose
    // remaining effort is at or below it. Taking the small ones first is what makes them fill the gaps
    // that the kept committed work leaves behind: a short run fits between two booked blocks, where a
    // large item would have to push something to find a contiguous window. Before this, every new item
    // was ordered by priority alone, so the threshold was computed and never read and a Large new item
    // was treated exactly like a Small one.
    $items = array_values(array_filter($model['items'], fn($i) => $i['schedulable'] && !isset($preloaded[$i['id']])));
    usort($items, function ($a, $b) use ($committedByItem) {
        if (($a['policy'] === 'interrupt') !== ($b['policy'] === 'interrupt')) return $a['policy'] === 'interrupt' ? -1 : 1;
        $ka = isset($committedByItem[$a['id']]) ? 0 : 1; $kb = isset($committedByItem[$b['id']]) ? 0 : 1;
        if ($ka !== $kb) return $ka - $kb;
        if ($ka === 1 && !empty($a['small']) !== !empty($b['small'])) return !empty($a['small']) ? -1 : 1;
        if ($a['priority'] != $b['priority']) return $b['priority'] <=> $a['priority'];
        return $a['id'] <=> $b['id'];
    });
    if ($scopeSet !== null) {
        // Urgent cycle: only items touching the scoped people (or new interrupts) are (re)planned.
        $items = array_values(array_filter($items, function ($i) use ($committedByItem, $scopeSet) {
            if ($i['policy'] === 'interrupt') return true;
            foreach ($committedByItem[$i['id']] ?? [] as $a) if (isset($scopeSet[$a['person_id']])) return true;
            return false;
        }));
    }

    $ctx = ['model' => $model, 'committedByItem' => $committedByItem, 'scopeSet' => $scopeSet, 'placed' => [], 'visiting' => [],
            'out' => &$out, 'unscheduled' => &$unscheduled, 'displacements' => &$displacements, 'queue' => $items, 'finish' => [],
            'fixedShare' => $fixedShare, 'fixedFinish' => $fixedFinish];
    foreach ($preloaded as $iid => $_) { $ctx['placed'][$iid] = true; $ctx['finish'][$iid] = pl_item_finish_di($model, $out, $iid); }

    $i = 0;
    while ($i < count($ctx['queue'])) {
        $item = $ctx['queue'][$i++];
        pl_place_item($st, $ctx, $item);
    }

    // Unscheduled: schedulable items never placed, plus non-schedulable ones reported for the watch list.
    foreach ($model['items'] as $it) {
        if (isset($ctx['placed'][$it['id']])) continue;
        if ($scopeSet !== null && !$it['schedulable']) continue;
        if (!$it['schedulable']) {
            if ($scopeSet !== null) continue;
            $reason = $it['status'] === 'blocked' ? 'blocked' : (!$it['has_estimate'] || $it['status'] === 'needs_estimate' ? 'no_estimate' : 'not_ready');
            $unscheduled[] = ['work_item_id' => $it['id'], 'ref' => $it['ref'], 'title' => $it['title'], 'reason' => $reason,
                'detail' => $reason === 'blocked' ? "{$it['ref']} is blocked" : ($reason === 'no_estimate' ? "{$it['ref']} has no estimate yet" : "{$it['ref']} is {$it['status']}"),
                'suggestion' => $reason === 'no_estimate' ? 'Add a size or estimate so it can be planned' : ($reason === 'blocked' ? 'Clear the blocker to release it into the queue' : 'Complete readiness to make it Ready'),
                'priority' => $it['priority']];
        } elseif (!pl_has_unscheduled($unscheduled, $it['id']) && $scopeSet === null) {
            $unscheduled[] = ['work_item_id' => $it['id'], 'ref' => $it['ref'], 'title' => $it['title'], 'reason' => 'capacity', 'detail' => "No capacity for {$it['ref']} inside the modelled horizon", 'suggestion' => 'Add capacity or move the needed-by date', 'priority' => $it['priority']];
        }
    }
    usort($unscheduled, fn($a, $b) => $b['priority'] <=> $a['priority']);

    $obj = plan_objective($out, $model, $unscheduled);
    $solve = round(microtime(true) - $t0, 4);
    return ['assignments' => $out, 'unscheduled' => $unscheduled, 'objective' => $obj['score'], 'terms' => $obj['terms'],
        'weighted_terms' => $obj['weighted'], 'solve_seconds' => $solve, 'displacements' => $displacements,
        'stats' => ['items_considered' => count($items), 'assignments' => count($out), 'unscheduled' => count($unscheduled), 'engine' => 'heuristic']];
}

// ---- state ------------------------------------------------------------------------------------
function pl_init_state(array $model) {
    $st = ['grid' => [], 'cap' => [], 'res' => [], 'model' => $model];
    foreach ($model['people'] as $pid => $p) {
        foreach ($model['days'] as $di => $day) {
            $c = $p['capacity'][$day] ?? ['available' => 0, 'reserve' => 0];
            $st['cap'][$pid][$di] = (float)$c['available'];
            $st['res'][$pid][$di] = min((float)$c['reserve'], (float)$c['available']);
            $st['grid'][$pid][$di] = ['used' => 0.0, 'res_used' => 0.0, 'items' => []];
        }
    }
    return $st;
}
function pl_free(array $st, $pid, $di) { return $st['cap'][$pid][$di] - $st['res'][$pid][$di] - $st['grid'][$pid][$di]['used']; }
function pl_reserve_free(array $st, $pid, $di) { return $st['res'][$pid][$di] - $st['grid'][$pid][$di]['res_used']; }
function pl_consume(array &$st, $pid, $di, $iid, $hours, $allowReserve) {
    $g = &$st['grid'][$pid][$di];
    $fromPlanned = min($hours, max(0.0, pl_free($st, $pid, $di)));
    $rest = $hours - $fromPlanned;
    if ($allowReserve && $rest > 1e-9) {
        // incidents take reserve first, then planned capacity
        $r = min($hours, max(0.0, pl_reserve_free($st, $pid, $di)));
        $g['res_used'] += $r;
        $g['used'] += $hours - $r;
    } else {
        $g['used'] += $hours;
    }
    $g['items'][$iid] = ($g['items'][$iid] ?? 0) + $hours;
}
function pl_release(array &$st, $pid, $di, $iid) {
    $g = &$st['grid'][$pid][$di];
    if (!isset($g['items'][$iid])) return;
    $h = $g['items'][$iid]; unset($g['items'][$iid]);
    $fromRes = min($h, $g['res_used']); // release reserve first (only incidents ever hold it)
    $g['res_used'] -= $fromRes; $g['used'] -= ($h - $fromRes);
    if ($g['used'] < 1e-9) $g['used'] = 0.0; if ($g['res_used'] < 1e-9) $g['res_used'] = 0.0;
}
function pl_counted(array $st, array $model, $pid, $di, $exceptIid = null) {
    $n = 0;
    foreach ($st['grid'][$pid][$di]['items'] as $iid => $h) {
        if ($iid === $exceptIid) continue;
        if (($model['items'][$iid]['counts_for_wip'] ?? true)) $n++;
    }
    return $n;
}
function pl_has_unscheduled(array $list, $iid) { foreach ($list as $u) if ($u['work_item_id'] === $iid) return true; return false; }

/** Weight of a committed row when effort is shared across an item's rows (mirrors pl_try_keep). */
function pl_row_weight(array $model, array $a) {
    return max(0.25, count(model_days_in($model, $a['from_date'], $a['to_date']))) * $a['allocation_pct'];
}

function pl_out_row(array $model, array $item, $pid, $from, $to, $alloc, $role, $kept, $locked, $committedId = null, $isReserve = false) {
    return ['work_item_id' => $item['id'], 'ref' => $item['ref'], 'person_id' => $pid, 'from_date' => $from, 'to_date' => $to,
        'allocation_pct' => (int)$alloc, 'state' => model_state_for(max($from, $model['today']), $model['windows']),
        'role_label' => $role, 'kept' => $kept, 'locked' => $locked, 'committed_id' => $committedId, 'is_reserve' => (bool)$isReserve];
}
function pl_item_finish_di(array $model, array $out, $iid) {
    $f = null;
    foreach ($out as $a) if ($a['work_item_id'] === $iid) { $di = $model['day_index'][$a['to_date']] ?? null; if ($di === null) { $di = pl_di_at_or_before($model, $a['to_date']); } if ($di !== null && ($f === null || $di > $f)) $f = $di; }
    return $f ?? -1;
}
function pl_di_at_or_before(array $model, $date) {
    if ($date < $model['today']) return -1;
    $best = null; foreach ($model['days'] as $i => $d) { if ($d > $date) break; $best = $i; } return $best;
}
function pl_di_at_or_after(array $model, $date) {
    foreach ($model['days'] as $i => $d) if ($d >= $date) return $i;
    return null;
}

// ---- eligibility ------------------------------------------------------------------------------
function pl_meets(array $person, array $skillReqs) {
    foreach ($skillReqs as $s) if (($person['skills'][$s['skill_id']] ?? 0) < $s['min_proficiency']) return false;
    return true;
}
function pl_eligible(array $model, array $item, $scopeSet) {
    $out = [];
    foreach ($model['people'] as $pid => $p) {
        if ($scopeSet !== null && !isset($scopeSet[$pid])) continue;
        if (pl_meets($p, $item['skills'])) $out[] = $pid;
    }
    return $out;
}
function pl_allocs($granularity) {
    return $granularity === 'halfDay' ? [100, 50] : ($granularity === 'week' ? [100, 50] : [100, 75, 50, 25]);
}
function pl_is_bucket_start(array $model, $di) {
    if ($di === 0) return true;
    return week_start($model['days'][$di]) !== week_start($model['days'][$di - 1]);
}

// ---- runs -------------------------------------------------------------------------------------
/** Try a contiguous run for $item on $pid at constant $alloc from $startDi. Returns run or null. */
function pl_try_run(array $st, array $model, array $item, $pid, $startDi, $alloc, $needHours, $allowReserve) {
    $n = count($model['days']);
    if ($startDi >= $n) return null;
    if ($item['granularity'] === 'week' && !pl_is_bucket_start($model, $startDi)) return null;
    // Allocation is a share of the person's own schedulable time that day, not of a
    // nominal 7.5-hour day. With an incident reserve held back, a 100% allocation could
    // otherwise never fit anyone — yet full-time is the normal case, and the reserve
    // exists precisely so that planned work stops short of it.
    $remaining = $needHours; $days = []; $di = $startDi; $last = $startDi;
    $maxConc = $model['people'][$pid]['max_concurrent'];
    $counts = $item['counts_for_wip'];
    while ($remaining > 1e-6 && $di < $n) {
        $cap = $st['cap'][$pid][$di];
        if ($cap <= 1e-6) { if ($di === $startDi) return null; $di++; continue; }
        $schedulable = $allowReserve ? $cap : max(0.0, $cap - $st['res'][$pid][$di]);
        $perDay = $alloc / 100 * $schedulable;
        if ($perDay <= 1e-6) { if ($di === $startDi) return null; $di++; continue; }
        $free = pl_free($st, $pid, $di) + ($allowReserve ? pl_reserve_free($st, $pid, $di) : 0);
        // The output is a date RANGE at one allocation, so every day in it claims the whole
        // nominal share — including the last, where less effort may actually remain. Booking
        // only the remainder on that day would let the next item start there while the emitted
        // range still says otherwise: the grid and the plan must say the same thing.
        if ($free + 1e-6 < $perDay) return null;
        if ($counts && !isset($st['grid'][$pid][$di]['items'][$item['id']]) && pl_counted($st, $model, $pid, $di, $item['id']) >= $maxConc) return null;
        $days[$di] = $perDay; $remaining -= min($perDay, $remaining); $last = $di; $di++;
    }
    if ($remaining > 1e-6) return null;
    return ['pid' => $pid, 'from_di' => $startDi, 'to_di' => $last, 'days' => $days, 'alloc' => $alloc];
}

/** Earliest-finishing run for $item on $pid starting at or after $minDi (scans allocations). */
function pl_find_run(array $st, array $model, array $item, $pid, $minDi, $needHours, $allowReserve, $allocs = null) {
    $allocs = $allocs ?? pl_allocs($item['granularity']);
    $n = count($model['days']); $best = null;
    foreach ($allocs as $alloc) {
        for ($s = $minDi; $s < $n; $s++) {
            if ($best !== null && $s > $best['to_di']) break;
            if ($st['cap'][$pid][$s] <= 1e-6) continue;
            // Cheap pre-filter, in the same currency as pl_try_run(): a share of that day's
            // schedulable time, claimed in full for every day of the run.
            $sched = $allowReserve ? $st['cap'][$pid][$s] : max(0.0, $st['cap'][$pid][$s] - $st['res'][$pid][$s]);
            $need = $alloc / 100 * $sched;
            if ($need <= 1e-6) continue;
            $free = pl_free($st, $pid, $s) + ($allowReserve ? pl_reserve_free($st, $pid, $s) : 0);
            if ($free + 1e-6 < $need) continue;
            $run = pl_try_run($st, $model, $item, $pid, $s, $alloc, $needHours, $allowReserve);
            if ($run) { if ($best === null || $run['to_di'] < $best['to_di']) $best = $run; break; }
        }
    }
    return $best;
}

// ---- placement --------------------------------------------------------------------------------
function pl_place_item(array &$st, array &$ctx, array $item) {
    $model = $ctx['model']; $iid = $item['id'];
    if (isset($ctx['placed'][$iid]) || isset($ctx['visiting'][$iid])) return;
    $ctx['visiting'][$iid] = true;
    if ($item['remaining_days'] <= 0) { $ctx['placed'][$iid] = true; $ctx['finish'][$iid] = -1; unset($ctx['visiting'][$iid]); return; }

    // Dependencies: predecessors first (finish-to-start).
    $minDi = 0;
    if ($item['earliest_start'] && $item['earliest_start'] > $model['today']) { $d = pl_di_at_or_after($model, $item['earliest_start']); if ($d === null) { pl_unsched($ctx, $item, 'horizon', "{$item['ref']} cannot start before {$item['earliest_start']}, beyond the modelled horizon", 'Extend the model horizon or bring the earliest-start date forward'); unset($ctx['visiting'][$iid]); return; } $minDi = $d; }
    foreach ($item['deps'] as $pred) {
        if (!isset($model['items'][$pred])) continue; // delivered → cleared
        if (!isset($ctx['placed'][$pred])) {
            $pi = $model['items'][$pred];
            if ($pi['schedulable']) pl_place_item($st, $ctx, $pi);
        }
        if (!isset($ctx['placed'][$pred])) {
            $pr = $model['items'][$pred]['ref'];
            pl_unsched($ctx, $item, 'dependency', "{$item['ref']} waits on $pr, which is not scheduled", "Schedule $pr first (or clear the dependency)");
            unset($ctx['visiting'][$iid]); return;
        }
        $minDi = max($minDi, ($ctx['finish'][$pred] ?? -1) + 1);
    }

    $isInc = $item['policy'] === 'interrupt';
    $eligible = pl_eligible($model, $item, $ctx['scopeSet']);
    $committedRows = array_values(array_filter($ctx['committedByItem'][$iid] ?? [], fn($a) => isset($model['people'][$a['person_id']]) && !$a['locked'] && ($ctx['scopeSet'] === null || isset($ctx['scopeSet'][$a['person_id']]))));
    // Effort already covered by rows pre-loaded in pass 1 (locked, or out of scope on an urgent
    // cycle) is not planned again — otherwise the same work is booked twice on the same grid.
    $needHours = $item['remaining_days'] * $model['hours_per_day'] * (1 - ($ctx['fixedShare'][$iid] ?? 0));
    if ($needHours <= 1e-6) {
        $ctx['placed'][$iid] = true; $ctx['finish'][$iid] = $ctx['fixedFinish'][$iid] ?? -1;
        unset($ctx['visiting'][$iid]); return;
    }

    // 1) Keep the committed slot if it is still feasible (extend in place for upward re-estimates).
    $kept = null;
    if ($committedRows) $kept = pl_try_keep($st, $model, $item, $committedRows, $minDi, $needHours, $isInc);
    $insideFreeze = false;
    foreach ($committedRows as $a) if ($a['from_date'] <= $model['windows']['freeze_end']) $insideFreeze = true;
    if ($kept && ($insideFreeze || !pl_breaks_needed_by($model, $item, $kept))) {
        pl_commit_runs($st, $ctx, $item, $kept, true);
        unset($ctx['visiting'][$iid]); return;
    }

    // 2) Fresh placement: candidates are the committed person(s) and the best-fit eligible person.
    if (!$eligible && !$item['skill_effort']) {
        pl_skills_gap($ctx, $item, $committedRows);
        unset($ctx['visiting'][$iid]); return;
    }
    $best = null;
    if ($eligible) {
        $cands = [];
        foreach ($eligible as $pid) {
            $run = pl_find_run($st, $model, $item, $pid, $minDi, $needHours, $isInc);
            if ($run) $cands[] = ['runs' => [$run], 'cost' => pl_item_cost($model, $item, [$run], $committedRows, $pid, $st)];
        }
        if ($kept) $cands[] = ['runs' => $kept, 'cost' => pl_item_cost($model, $item, $kept, $committedRows, null, $st)];
        foreach ($cands as $c) if ($best === null || $c['cost'] < $best['cost']) $best = $c;
    }
    if ($best === null && $item['skill_effort']) {
        $best = pl_split_placement($st, $model, $item, $ctx['scopeSet'], $minDi, $isInc);
        if ($best === null) { pl_skills_gap($ctx, $item, $committedRows); unset($ctx['visiting'][$iid]); return; }
    }

    // 3) Incidents: if the run finishes after the needed-by / response window, displace the person's lowest-priority planned item.
    if ($isInc) {
        $limitDi = pl_incident_limit_di($model, $item);
        $tries = 0;
        while (($best === null || $best['runs'][0]['to_di'] > $limitDi) && $tries < 3) {
            $target = pl_incident_target($model, $item, $eligible, $ctx);
            if ($target === null) break;
            $victim = pl_lowest_priority_on($st, $ctx, $target, $item, $limitDi);
            if ($victim === null) break;
            pl_displace($st, $ctx, $victim, $item);
            $run = pl_find_run($st, $model, $item, $target, $minDi, $needHours, true);
            if ($run) $best = ['runs' => [$run], 'cost' => 0];
            $tries++;
        }
    }
    if ($best === null) {
        $needDays = $item['remaining_days'];
        pl_unsched($ctx, $item, 'capacity', "No one with the right skills has {$needDays} free days for {$item['ref']} inside the horizon",
            $item['needed_by'] ? "Add {$needDays} days capacity for " . pl_skill_list($item) . " or move the needed-by date" : "Add {$needDays} days capacity for " . pl_skill_list($item));
        unset($ctx['visiting'][$iid]); return;
    }
    pl_commit_runs($st, $ctx, $item, $best['runs'], false);
    pl_try_pairing($st, $ctx, $item, $best['runs']);
    unset($ctx['visiting'][$iid]);
}

function pl_skill_list(array $item) {
    if (!$item['skills']) return 'this work';
    return implode(', ', array_map(fn($s) => $s['name'] . ' L' . $s['min_proficiency'], $item['skills']));
}

/** Reproduce the committed slot(s): same person, same start (or today if already started), same allocation; extend to cover remaining effort. */
function pl_try_keep(array $st, array $model, array $item, array $committedRows, $minDi, $needHours, $allowReserve) {
    // Share remaining effort across the committed rows in proportion to their remaining scheduled hours.
    $weights = []; $tot = 0;
    foreach ($committedRows as $k => $a) {
        $dis = model_days_in($model, $a['from_date'], $a['to_date']);
        $w = max(0.25, count($dis)) * $a['allocation_pct'];
        $weights[$k] = $w; $tot += $w;
    }
    $runs = [];
    $tmp = $st; // simulate on a copy so partial keeps do not pollute state
    foreach ($committedRows as $k => $a) {
        $share = $needHours * $weights[$k] / $tot;
        $startDate = max($a['from_date'], $model['today']);
        $startDi = pl_di_at_or_after($model, $startDate);
        if ($startDi === null) return null;
        if ($startDi < $minDi) return null; // dependency now finishes later than the committed start
        if (!pl_meets($model['people'][$a['person_id']], $item['skills']) && !$item['skill_effort']) return null;
        $run = pl_try_run($tmp, $model, $item, $a['person_id'], $startDi, $a['allocation_pct'], $share, $allowReserve);
        if (!$run) {
            // try a later bucket start for week-granular items whose committed start was mid-week (already started)
            return null;
        }
        $run['committed_id'] = $a['id']; $run['orig_from'] = $a['from_date']; $run['role_label'] = $a['role_label'];
        foreach ($run['days'] as $di => $h) pl_consume($tmp, $a['person_id'], $di, $item['id'], $h, $allowReserve);
        $runs[] = $run;
    }
    return $runs;
}
function pl_breaks_needed_by(array $model, array $item, array $runs) {
    if (!$item['needed_by']) return false;
    $finish = max(array_map(fn($r) => $r['to_di'], $runs));
    return $model['days'][$finish] > $item['needed_by'];
}

function pl_commit_runs(array &$st, array &$ctx, array $item, array $runs, $kept) {
    $model = $ctx['model']; $isInc = $item['policy'] === 'interrupt';
    $finish = -1; $usedReserve = false;
    foreach ($runs as $run) {
        foreach ($run['days'] as $di => $h) {
            if ($isInc && pl_reserve_free($st, $run['pid'], $di) > 1e-6) $usedReserve = true;
            pl_consume($st, $run['pid'], $di, $item['id'], $h, $isInc);
        }
        $from = $model['days'][$run['from_di']]; $to = $model['days'][$run['to_di']];
        if (!empty($run['orig_from']) && $run['orig_from'] < $model['today']) $from = $run['orig_from']; // already started: keep the original start
        $ctx['out'][] = pl_out_row($model, $item, $run['pid'], $from, $to, $run['alloc'], $run['role_label'] ?? null, $kept, false, $run['committed_id'] ?? null, $usedReserve);
        $finish = max($finish, $run['to_di']);
    }
    $ctx['placed'][$item['id']] = true;
    $ctx['finish'][$item['id']] = max($finish, $ctx['fixedFinish'][$item['id']] ?? -1);
}

/** Local cost used to choose between candidate placements (mirrors the objective terms in 8.6). */
function pl_item_cost(array $model, array $item, array $runs, array $committedRows, $pid, array $st) {
    $w = $model['policy']['objective_weights']; $pr = $item['priority'] / 100;
    $finishDi = max(array_map(fn($r) => $r['to_di'], $runs));
    $finish = $model['days'][$finishDi];
    $cost = $w['valueCompletion'] * $pr * (intdiv($finishDi, 5) + 1);
    if ($item['needed_by'] && $finish > $item['needed_by']) $cost += $w['lateness'] * $pr * working_days_between(add_working_days($item['needed_by'], 1, $model['working_days']), $finish, $model['working_days']);
    // stability: days that differ from the committed rows inside committed+planned windows
    $moved = 0;
    if ($committedRows) {
        $before = []; foreach ($committedRows as $a) foreach (model_days_in($model, $a['from_date'], $a['to_date']) as $di) $before["{$a['person_id']}:$di"] = $a['allocation_pct'];
        $after = []; foreach ($runs as $r) foreach ($r['days'] as $di => $h) $after["{$r['pid']}:$di"] = $r['alloc'];
        $plannedEndDi = pl_di_at_or_before($model, $model['windows']['planned_end']);
        $rem = 0; $add = 0;
        foreach ($before as $k => $v) { $di = (int)explode(':', $k)[1]; if ($di > $plannedEndDi) continue; if (!isset($after[$k])) $rem += $v / 100; elseif ($after[$k] != $v) $rem += abs($after[$k] - $v) / 100; }
        foreach ($after as $k => $v) { $di = (int)explode(':', $k)[1]; if ($di > $plannedEndDi) continue; if (!isset($before[$k])) $add += $v / 100; }
        $moved = max($rem, $add) * ($item['protected'] ? 2 : 1);
        foreach ($runs as $r) if ($model['people'][$r['pid']]['protected'] ?? false) { $moved *= 2; break; }
    }
    $cost += $w['stabilityPlanned'] * $moved;
    // preferences & fit
    foreach ($runs as $r) {
        $p = $model['people'][$r['pid']];
        $cost += $w['preferences'] * pl_pref_penalty($p, $item);
        $prof = 0; foreach ($item['skills'] as $s) $prof += ($p['skills'][$s['skill_id']] ?? 0);
        $cost -= 0.01 * $prof;
        $cost += 0.001 * pl_person_load($st, $r['pid'], $r['from_di'], $r['to_di']);
        if ($item['owner_person_id'] === $r['pid']) $cost -= 0.05;
    }
    return $cost;
}
function pl_pref_penalty(array $person, array $item) {
    $hay = array_map('mb_strtolower', array_merge([$item['type_name'] ?? '', $item['size_name'] ?? ''], $item['tags'], array_map(fn($s) => $s['name'], $item['skills'])));
    $pen = 0;
    foreach ($person['avoid'] as $a) if (in_array(mb_strtolower($a), $hay, true)) $pen += 1;
    foreach ($person['prefers'] as $a) if (in_array(mb_strtolower($a), $hay, true)) $pen -= 0.5;
    return $pen;
}
function pl_person_load(array $st, $pid, $fromDi, $toDi) {
    $cap = 0; $used = 0;
    for ($d = $fromDi; $d <= $toDi; $d++) { $cap += $st['cap'][$pid][$d]; $used += $st['grid'][$pid][$d]['used']; }
    return $cap > 0 ? $used / $cap * 100 : 100;
}

/** Split by skill: each skill portion to a person meeting that skill (parallel runs). */
function pl_split_placement(array $st, array $model, array $item, $scopeSet, $minDi, $allowReserve) {
    $runs = []; $tmp = $st; $cost = 0;
    foreach ($item['skill_effort'] as $skillId => $days) {
        if ($days <= 0) continue;
        $req = null; foreach ($item['skills'] as $s) if ($s['skill_id'] === (int)$skillId) $req = $s;
        $portion = ['skills' => $req ? [$req] : []];
        $sub = array_merge($item, $portion);
        $bestRun = null; $bestC = null;
        foreach ($model['people'] as $pid => $p) {
            if ($scopeSet !== null && !isset($scopeSet[$pid])) continue;
            if (!pl_meets($p, $sub['skills'])) continue;
            $run = pl_find_run($tmp, $model, $sub, $pid, $minDi, $days * $model['hours_per_day'], $allowReserve);
            if (!$run) continue;
            $c = $run['to_di'] - 0.01 * ($p['skills'][(int)$skillId] ?? 0);
            if ($bestC === null || $c < $bestC) { $bestC = $c; $bestRun = $run; }
        }
        if (!$bestRun) return null;
        $bestRun['role_label'] = $req ? $req['name'] : null;
        foreach ($bestRun['days'] as $di => $h) pl_consume($tmp, $bestRun['pid'], $di, $item['id'], $h, $allowReserve);
        $runs[] = $bestRun; $cost += $bestC;
    }
    return $runs ? ['runs' => $runs, 'cost' => $cost] : null;
}

/** Development pairing (SCH-12): a person with pairing enabled on a required skill joins at 25% when the extra effort stays under the threshold. */
function pl_try_pairing(array &$st, array &$ctx, array $item, array $runs) {
    $model = $ctx['model'];
    if (!$item['skills'] || $item['policy'] === 'interrupt') return;
    $primary = $runs[0]; $days = array_keys($primary['days']);
    if (count($days) * 0.25 > $model['policy']['pairing_cost_threshold_days']) return;
    $assigned = array_map(fn($r) => $r['pid'], $runs);
    foreach ($model['people'] as $pid => $p) {
        if (in_array($pid, $assigned, true)) continue;
        if ($ctx['scopeSet'] !== null && !isset($ctx['scopeSet'][$pid])) continue;
        foreach ($item['skills'] as $s) {
            $dev = $p['development'][$s['skill_id']] ?? null;
            if (!$dev || !$dev['pairing_enabled']) continue;
            if (($p['skills'][$s['skill_id']] ?? 0) >= $s['min_proficiency']) continue; // already qualified: not development
            if (($p['skills'][$s['skill_id']] ?? 0) < $s['min_proficiency'] - 1) continue; // one level below only
            // 25% of the pair's own schedulable time on each day, matching how the emitted range reads.
            $ok = true; $need = [];
            foreach ($days as $di) {
                $need[$di] = 0.25 * max(0.0, $st['cap'][$pid][$di] - $st['res'][$pid][$di]);
                if ($need[$di] <= 1e-6 || pl_free($st, $pid, $di) + 1e-6 < $need[$di] || ($item['counts_for_wip'] && pl_counted($st, $model, $pid, $di) >= $p['max_concurrent'])) { $ok = false; break; }
            }
            if (!$ok) continue;
            foreach ($days as $di) pl_consume($st, $pid, $di, $item['id'], $need[$di], false);
            $ctx['out'][] = pl_out_row($model, $item, $pid, $model['days'][$primary['from_di']], $model['days'][$primary['to_di']], 25, 'pair · ' . $s['name'], false, false, null, false);
            return;
        }
    }
}

// ---- incidents --------------------------------------------------------------------------------
function pl_incident_limit_di(array $model, array $item) {
    if ($item['needed_by']) { $d = pl_di_at_or_before($model, $item['needed_by']); return $d === null || $d < 0 ? 0 : $d; }
    $resp = ['P1' => 1, 'P2' => 4, 'P3' => 9, 'P4' => 14];
    return min(count($model['days']) - 1, $resp[$item['severity'] ?? 'P3'] ?? 9);
}
function pl_incident_target(array $model, array $item, array $eligible, array $ctx) {
    if (!$eligible) return null;
    $ws = week_start($model['today']);
    foreach ($eligible as $pid) if (in_array($ws, $model['people'][$pid]['rota_weeks'], true)) return $pid;
    if ($item['owner_person_id'] && in_array($item['owner_person_id'], $eligible, true)) return $item['owner_person_id'];
    return $eligible[0];
}
/** Lowest-priority non-locked item the person holds on grid days up to $limitDi (planned or committed window, never fixed). */
function pl_lowest_priority_on(array $st, array $ctx, $pid, array $incident, $limitDi) {
    $model = $ctx['model']; $best = null;
    foreach ($ctx['out'] as $k => $a) {
        if ($a['person_id'] !== $pid || $a['locked'] || $a['work_item_id'] === $incident['id']) continue;
        $it = $model['items'][$a['work_item_id']] ?? null;
        if (!$it || $it['policy'] === 'interrupt') continue;
        $dis = model_days_in($model, $a['from_date'], $a['to_date']);
        if (!$dis || min($dis) > $limitDi) continue;
        if ($best === null || $it['priority'] < $model['items'][$ctx['out'][$best]['work_item_id']]['priority']) $best = $k;
    }
    return $best;
}
function pl_displace(array &$st, array &$ctx, $outIndex, array $incident) {
    $model = $ctx['model']; $a = $ctx['out'][$outIndex]; $iid = $a['work_item_id'];
    foreach ($ctx['out'] as $k => $row) if ($row['work_item_id'] === $iid) { foreach (model_days_in($model, $row['from_date'], $row['to_date']) as $di) pl_release($st, $row['person_id'], $di, $iid); unset($ctx['out'][$k]); }
    $ctx['out'] = array_values($ctx['out']);
    unset($ctx['placed'][$iid], $ctx['finish'][$iid]);
    $ctx['displacements'][] = ['incident_id' => $incident['id'], 'incident_ref' => $incident['ref'], 'work_item_id' => $iid, 'ref' => $model['items'][$iid]['ref'], 'person_id' => $a['person_id']];
    $ctx['queue'][] = array_merge($model['items'][$iid], ['displaced_by' => $incident['ref']]);
}

// ---- unscheduled reporting (SCH-05, 8.13) -------------------------------------------------------
function pl_unsched(array &$ctx, array $item, $reason, $detail, $suggestion, array $extra = []) {
    if (pl_has_unscheduled($ctx['unscheduled'], $item['id'])) return;
    $ctx['unscheduled'][] = array_merge(['work_item_id' => $item['id'], 'ref' => $item['ref'], 'title' => $item['title'], 'reason' => $reason, 'detail' => $detail, 'suggestion' => $suggestion, 'priority' => $item['priority']], $extra);
}
function pl_skills_gap(array &$ctx, array $item, array $committedRows) {
    $model = $ctx['model'];
    $gaps = [];
    foreach ($item['skills'] as $s) {
        $qualified = []; $closest = null;
        foreach ($model['people'] as $pid => $p) {
            $lvl = $p['skills'][$s['skill_id']] ?? 0;
            if ($lvl >= $s['min_proficiency']) $qualified[] = $p;
            elseif ($lvl > 0 && ($closest === null || $lvl > ($closest['skills'][$s['skill_id']] ?? 0))) $closest = $p;
        }
        if (count($qualified) === 0 || (count($qualified) === 1 && !pl_person_has_capacity($model, $qualified[0]))) {
            $gaps[] = ['skill' => $s['name'], 'level' => $s['min_proficiency'], 'qualified' => array_map(fn($p) => $p['name'], $qualified), 'closest' => $closest ? $closest['name'] . ' (L' . ($closest['skills'][$s['skill_id']] ?? 0) . ')' : null];
        }
    }
    if (!$gaps) {
        // people qualified but none free: capacity rather than skills
        pl_unsched($ctx, $item, 'capacity', "Everyone qualified for {$item['ref']} is fully booked in the horizon", "Add {$item['remaining_days']} days capacity for " . pl_skill_list($item) . ($item['needed_by'] ? " or move the needed-by date" : ''));
        return;
    }
    $g = $gaps[0];
    $detail = "{$item['ref']} needs {$g['skill']} at level {$g['level']}; " . (count($g['qualified']) === 0 ? 'no one qualifies' : "only {$g['qualified'][0]} qualifies and has no capacity in the window");
    if (count($g['qualified']) === 1 && $g['closest']) $sugg = "Pair {$g['closest']} with {$g['qualified'][0]} on {$g['skill']} as development, or wait for {$g['qualified'][0]}'s capacity";
    elseif (count($g['qualified']) === 1) $sugg = "Wait for {$g['qualified'][0]}'s capacity or bring in cover for {$g['skill']} L{$g['level']}";
    elseif ($g['closest']) $sugg = "Develop {$g['closest']} to level {$g['level']} in {$g['skill']} or bring in a contractor";
    else $sugg = "Bring in {$g['skill']} at level {$g['level']} (no one on the team has it)";
    pl_unsched($ctx, $item, 'skills_gap', $detail, $sugg, ['gaps' => $gaps]);
}
function pl_person_has_capacity(array $model, array $p) {
    $end = $model['windows']['planned_end']; $h = 0;
    foreach ($p['capacity'] as $day => $c) { if ($day > $end) continue; $h += $c['available'] - $c['reserve']; }
    return $h > $model['hours_per_day'];
}

// ---- objective (8.6) ----------------------------------------------------------------------------
/** Per-(item,person) day→allocation map for a list of assignments (days before today ignored). */
function plan_pair_days(array $model, array $assignments) {
    $out = [];
    foreach ($assignments as $a) {
        $k = $a['work_item_id'] . ':' . $a['person_id'];
        foreach (model_days_in($model, $a['from_date'], $a['to_date']) as $di) $out[$k][$di] = ($out[$k][$di] ?? 0) + (int)$a['allocation_pct'];
    }
    return $out;
}
/** Moved assignment-days between two plans inside committed+planned windows (STAB-02/08). */
function plan_moved_days(array $model, array $baseline, array $candidate, $onlyItemIds = null) {
    $b = plan_pair_days($model, $baseline); $c = plan_pair_days($model, $candidate);
    $plannedEndDi = pl_di_at_or_before($model, $model['windows']['planned_end']);
    $moved = 0;
    foreach (array_unique(array_merge(array_keys($b), array_keys($c))) as $k) {
        [$iid] = explode(':', $k);
        if ($onlyItemIds !== null && !in_array((int)$iid, $onlyItemIds, true)) continue;
        if (!isset($model['items'][(int)$iid])) continue; // delivered/cancelled: released, not churn
        $rem = 0; $add = 0;
        foreach ($b[$k] ?? [] as $di => $v) { if ($di > $plannedEndDi) continue; $after = $c[$k][$di] ?? 0; if ($after < $v) $rem += ($v - $after) / 100; }
        foreach ($c[$k] ?? [] as $di => $v) { if ($di > $plannedEndDi) continue; $before = $b[$k][$di] ?? 0; if ($v > $before) $add += ($v - $before) / 100; }
        $moved += max($rem, $add);
    }
    return round($moved, 2);
}

function plan_objective(array $assignments, array $model, array $unscheduled = null) {
    $w = $model['policy']['objective_weights'];
    $finish = []; $perPersonWeek = []; $prefPen = 0;
    foreach ($assignments as $a) {
        $iid = $a['work_item_id']; $it = $model['items'][$iid] ?? null; if (!$it) continue;
        if (!isset($finish[$iid]) || $a['to_date'] > $finish[$iid]) $finish[$iid] = $a['to_date'];
        foreach (model_days_in($model, $a['from_date'], $a['to_date']) as $di) {
            $wk = week_start($model['days'][$di]);
            $perPersonWeek[$a['person_id']][$wk]['hours'] = ($perPersonWeek[$a['person_id']][$wk]['hours'] ?? 0) + $a['allocation_pct'] / 100 * $model['hours_per_day'];
            $perPersonWeek[$a['person_id']][$wk]['items'][$iid] = true;
        }
        $p = $model['people'][$a['person_id']] ?? null;
        if ($p) { $prefPen += pl_pref_penalty($p, $it); if (str_starts_with((string)($a['role_label'] ?? ''), 'pair')) $prefPen -= 0.5; }
    }
    $vc = 0; $late = 0;
    $todayWeek = new DateTime(week_start($model['today']));
    foreach ($finish as $iid => $f) {
        $it = $model['items'][$iid]; $pr = $it['priority'] / 100;
        $weeks = (int)floor(((new DateTime(week_start($f)))->getTimestamp() - $todayWeek->getTimestamp()) / 604800) + 1;
        $vc += $pr * max(1, $weeks);
        if ($it['needed_by'] && $f > $it['needed_by']) $late += $pr * working_days_between(add_working_days($it['needed_by'], 1, $model['working_days']), $f, $model['working_days']);
    }
    $unsch = 0;
    if ($unscheduled === null) {
        foreach ($model['items'] as $it) if ($it['schedulable'] && $it['remaining_days'] > 0 && !isset($finish[$it['id']]) && (!$it['earliest_start'] || $it['earliest_start'] <= $model['windows']['planned_end'])) $unsch += $it['priority'] / 100;
    } else {
        foreach ($unscheduled as $u) { $it = $model['items'][$u['work_item_id']] ?? null; if ($it && $it['schedulable'] && (!$it['earliest_start'] || $it['earliest_start'] <= $model['windows']['planned_end'])) $unsch += $it['priority'] / 100; }
    }
    // load imbalance & context switching over planned window weeks
    $imb = 0; $ctx = 0;
    $weeks = []; $d = new DateTime(week_start($model['today'])); $pe = $model['windows']['planned_end'];
    while ($d->format('Y-m-d') <= $pe) { $weeks[] = $d->format('Y-m-d'); $d->modify('+7 days'); }
    foreach ($model['people'] as $pid => $p) {
        foreach ($weeks as $wk) {
            $cap = 0; foreach ($p['capacity'] as $day => $c) if ($day >= $wk && $day < date('Y-m-d', strtotime("$wk +7 days"))) $cap += $c['available'] - $c['reserve'];
            if ($cap <= 0) continue;
            $h = $perPersonWeek[$pid][$wk]['hours'] ?? 0; $load = $h / $cap * 100;
            if ($load < $model['policy']['target_load_min']) $imb += ($model['policy']['target_load_min'] - $load) / 100;
            elseif ($load > $model['policy']['target_load_max']) $imb += ($load - $model['policy']['target_load_max']) / 100;
            $n = count($perPersonWeek[$pid][$wk]['items'] ?? []); if ($n > 1) $ctx += $n - 1;
        }
    }
    $stab = plan_moved_days($model, $model['committed'], $assignments);
    $terms = ['valueCompletion' => round($vc, 3), 'lateness' => round($late, 3), 'unscheduledValue' => round($unsch, 3), 'loadImbalance' => round($imb, 3), 'contextSwitching' => $ctx, 'stabilityPlanned' => $stab, 'preferences' => round($prefPen, 3)];
    $weighted = []; $score = 0;
    foreach ($terms as $k => $v) { $weighted[$k] = round(($w[$k] ?? 0) * $v, 3); $score += $weighted[$k]; }
    return ['terms' => $terms, 'weighted' => $weighted, 'score' => round($score, 3)];
}

/**
 * What-if for SCH-07: move one committed assignment (locked at its new place) and let the heuristic re-plan around it.
 * Returns the heuristic result plus 'moved' (the hypothetical row).
 */
function preview_move(array $model, $assignmentId, $from, $to, $personId = null, $allocationPct = null) {
    $moved = null;
    foreach ($model['committed'] as &$a) {
        if ($a['id'] !== (int)$assignmentId) continue;
        $a['from_date'] = $from; $a['to_date'] = $to;
        if ($personId) $a['person_id'] = (int)$personId;
        if ($allocationPct) $a['allocation_pct'] = (int)$allocationPct;
        $a['locked'] = true; $moved = $a;
    }
    unset($a);
    if (!$moved) return null;
    $res = heuristic_plan($model);
    $res['moved'] = $moved;
    return $res;
}
