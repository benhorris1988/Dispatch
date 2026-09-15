<?php
// =====================================================================================
// seed_demo_plan.php — plan versions and assignments, the open nightly proposal and its
// changes, replan triggers, stability reporting, change log, notifications, audit trail,
// comments, progress logs and integration rows.
// Included from seed_demo_items.php (which supplies $I, $WI and $N on top of everything
// seed_demo.php defines).
// =====================================================================================
if (!isset($conn) || !isset($I)) { fwrite(STDERR, "seed_demo_plan.php must be included from seed_demo_items.php\n"); exit(1); }

// -------------------------------------------------------------------------------------
// 1. PLAN VERSIONS — v1..v5 superseded weekly commits, v6 the committed plan,
//    v7 the candidate behind the open proposal.
// -------------------------------------------------------------------------------------
$objTerms = fn($late, $unsched, $imbalance, $stab) => j([
    'valueCompletion' => 1, 'lateness' => $late, 'unscheduledValue' => $unsched,
    'loadImbalance' => $imbalance, 'contextSwitching' => 2, 'stabilityPlanned' => $stab, 'preferences' => 1,
]);

$PV = [];   // version_no => id
$pvRows = [
    // no, status,       committed_at,          committed_through, generated_at,          objective, stability, notes
    [1, 'superseded', '2026-08-10 09:00:00', '2026-08-21', '2026-08-10 02:00:00', 1284.50, 11.0, 'Weekly commit. First plan after the freeze horizon was introduced.'],
    [2, 'superseded', '2026-08-17 09:00:00', '2026-08-28', '2026-08-17 02:00:00', 1246.75,  9.5, 'Weekly commit. WI-1040 pulled forward after the design review.'],
    [3, 'superseded', '2026-08-24 09:00:00', '2026-09-04', '2026-08-24 02:00:00', 1198.25,  8.0, 'Weekly commit. Sam on leave, WI-1042 discovery deferred.'],
    [4, 'superseded', '2026-08-31 09:00:00', '2026-09-11', '2026-08-31 02:00:00', 1163.00,  7.5, 'Weekly commit. WI-1055 added ahead of the WI-1042 workspace build.'],
    [5, 'superseded', '2026-09-02 16:30:00', '2026-09-15', '2026-09-02 02:00:00', 1151.40,  6.5, 'Out-of-cycle commit after two accepted changes.'],
    [6, 'committed',  '2026-09-07 09:00:00', '2026-09-18', '2026-09-07 02:00:00', 1128.60,  6.0, 'Weekly commit. Committed through Fri 18 Sep.'],
];
foreach ($pvRows as $r) {
    $PV[$r[0]] = xid($conn, 'plan_versions', [
        'workspace_id' => $W, 'version_no' => $r[0], 'status' => $r[1], 'engine' => 'heuristic',
        'generated_at' => $r[4], 'generated_by' => $U['ben'],
        'committed_at' => $r[2], 'committed_by' => $U['ben'], 'committed_through' => $r[3],
        'policy_version' => 1, 'inputs_hash' => substr(hash('sha256', 'dispatch-plan-v' . $r[0]), 0, 40),
        'objective_score' => $r[5], 'objective_terms' => $objTerms(3, 5, 0.5, 2),
        'stability_cost_days' => $r[6],
        'solver_stats' => j(['engine' => 'heuristic', 'solveSeconds' => 1.8, 'provedOptimal' => false, 'assignments' => 36]),
        'notes' => $r[7],
    ]);
}
$PV[7] = xid($conn, 'plan_versions', [
    'workspace_id' => $W, 'version_no' => 7, 'status' => 'proposed', 'engine' => 'heuristic',
    'generated_at' => '2026-09-08 02:00:00', 'generated_by' => $U['ben'],
    'committed_at' => null, 'committed_by' => null, 'committed_through' => null,
    'policy_version' => 1, 'inputs_hash' => substr(hash('sha256', 'dispatch-plan-v7'), 0, 40),
    'objective_score' => 1094.20, 'objective_terms' => $objTerms(1, 4, 0.4, 2),
    'stability_cost_days' => 9.0,
    'solver_stats' => j(['engine' => 'heuristic', 'solveSeconds' => 2.1, 'provedOptimal' => false, 'assignments' => 38]),
    'notes' => 'Nightly candidate behind the open proposal. Six changes proposed, three held by guardrails.',
]);
$N['plan_versions'] = count($PV);
$COMMITTED = $PV[6];

// -------------------------------------------------------------------------------------
// 2. ASSIGNMENTS for v6 — this is web-04-schedule.png, lane by lane.
//    state: committed on or before Fri 18 Sep, planned to Fri 9 Oct, indicative after
//    (or wherever the lane itself is labelled "indicative").
// -------------------------------------------------------------------------------------
// person, ref, from, to, allocation, state, role_label
$v6 = [
    // Priya Kaur — 92% load
    ['Priya', 'WI-1038', '2026-09-07', '2026-09-11',  60, 'committed',  'phase 2'],
    ['Priya', 'WI-1055', '2026-09-14', '2026-09-18', 100, 'committed',  null],
    ['Priya', 'WI-1042', '2026-09-21', '2026-10-09', 100, 'planned',    'with Sam, Hana'],
    ['Priya', 'WI-1042', '2026-10-12', '2026-11-13', 100, 'indicative', 'with Sam, Hana'],
    // Jon Okafor — 86% load (training 17-18 Sep shows as an availability block)
    ['Jon',   'WI-1038', '2026-09-07', '2026-09-11', 100, 'committed',  'phase 2'],
    ['Jon',   'SR-0212', '2026-09-14', '2026-09-16', 100, 'committed',  null],
    ['Jon',   'WI-1044', '2026-09-21', '2026-10-02', 100, 'planned',    null],
    ['Jon',   'WI-1070', '2026-10-05', '2026-10-16', 100, 'indicative', null],
    ['Jon',   'WI-1039', '2026-10-19', '2026-11-13', 100, 'indicative', null],
    // Amira Mansour — 88% load
    ['Amira', 'WI-1057', '2026-09-07', '2026-09-08', 100, 'committed',  null],
    ['Amira', 'WI-1033', '2026-09-09', '2026-09-18', 100, 'committed',  'with Lena'],
    ['Amira', 'WI-1063', '2026-09-21', '2026-09-25', 100, 'planned',    null],
    ['Amira', 'WI-1066', '2026-09-28', '2026-10-16', 100, 'indicative', null],
    ['Amira', 'WI-1041', '2026-10-19', '2026-10-30', 100, 'indicative', null],
    // Ravi Shah — 104% load, on the incident rota
    ['Ravi',  'INC-4471', '2026-09-07', '2026-09-10', 100, 'committed',  'M · P2'],
    ['Ravi',  'WI-1052',  '2026-09-11', '2026-09-18', 100, 'committed',  null],
    ['Ravi',  'WI-1058',  '2026-09-21', '2026-10-02', 100, 'planned',    null],
    ['Ravi',  'WI-1058',  '2026-10-05', '2026-10-16', 100, 'indicative', 'cont.'],
    ['Ravi',  'WI-1045',  '2026-10-19', '2026-10-30', 100, 'indicative', null],
    // Lena Torres — 80% load, no Fridays
    ['Lena',  'WI-1059', '2026-09-07', '2026-09-08', 100, 'committed',  null],
    ['Lena',  'WI-1061', '2026-09-09', '2026-09-14', 100, 'committed',  null],
    ['Lena',  'WI-1033', '2026-09-15', '2026-09-18',  50, 'committed',  null],
    ['Lena',  'WI-1071', '2026-09-21', '2026-10-16', 100, 'indicative', null],
    ['Lena',  'WI-1048', '2026-10-19', '2026-10-23', 100, 'indicative', null],
    // Sam Doyle — 90% load
    ['Sam',   'WI-1040', '2026-09-07', '2026-09-18', 100, 'committed',  'final sprint'],
    ['Sam',   'WI-1042', '2026-09-21', '2026-10-09', 100, 'planned',    'lead'],
    ['Sam',   'WI-1042', '2026-10-12', '2026-11-13', 100, 'indicative', 'lead'],
    // Hana Novak — 72% load, on leave until Fri 11 Sep
    ['Hana',  'WI-1040', '2026-09-14', '2026-09-18', 100, 'committed',  null],
    ['Hana',  'WI-1042', '2026-09-21', '2026-10-09', 100, 'planned',    null],
    ['Hana',  'WI-1042', '2026-10-12', '2026-11-13', 100, 'indicative', null],
    // Ewan Wright — 78% load
    ['Ewan',  'WI-1047', '2026-09-07', '2026-09-11', 100, 'committed',  null],
    ['Ewan',  'WI-1049', '2026-09-14', '2026-09-15', 100, 'committed',  null],
    ['Ewan',  'SR-0215', '2026-09-16', '2026-09-18', 100, 'committed',  null],
    ['Ewan',  'WI-1050', '2026-09-21', '2026-10-02', 100, 'planned',    null],
    ['Ewan',  'WI-1068', '2026-10-05', '2026-10-16', 100, 'indicative', 'needs estimate'],
    ['Ewan',  'WI-1043', '2026-10-19', '2026-11-13', 100, 'indicative', null],
];

$N['assignments'] = 0;
$addAssign = function ($planId, $a, $extra = []) use ($conn, $PN, $I, &$N) {
    xid($conn, 'assignments', array_merge([
        'plan_version_id' => $planId, 'work_item_id' => $I[$a[1]], 'person_id' => $PN[$a[0]],
        'from_date' => $a[2], 'to_date' => $a[3], 'allocation_pct' => $a[4], 'state' => $a[5],
        'role_label' => $a[6], 'locked_until' => $a[5] === 'committed' ? '2026-09-18' : null,
        'fixed_person' => 0, 'fixed_dates' => 0, 'is_reserve' => 0, 'note' => null,
    ], $extra));
    $N['assignments']++;
};
foreach ($v6 as $a) $addAssign($COMMITTED, $a);

// --- v7: the same plan with the four applicable changes applied.
$v7 = [];
foreach ($v6 as $a) {
    // 1. Amira starts WI-1033 two days later; Lena covers the Wednesday and Thursday.
    if ($a[0] === 'Amira' && $a[1] === 'WI-1033') { $a[2] = '2026-09-11'; }
    // 2. Lena pulls WI-1061 forward one week.
    if ($a[0] === 'Lena' && $a[1] === 'WI-1061') { $a[2] = '2026-09-07'; $a[3] = '2026-09-10'; }
    if ($a[0] === 'Lena' && $a[1] === 'WI-1059') { $a[2] = '2026-09-11'; $a[3] = '2026-09-14'; }
    // 3. Jon pairs on WI-1042 for Terraform, so WI-1044 drops to 60% and finishes 3 days later.
    if ($a[0] === 'Jon' && $a[1] === 'WI-1044') { $a[4] = 60; $a[3] = '2026-10-07'; }
    // 4. SR-0215 moves from Ewan to Ravi.
    if ($a[0] === 'Ewan' && $a[1] === 'SR-0215') continue;
    $v7[] = $a;
}
$v7[] = ['Jon',  'WI-1042', '2026-09-21', '2026-10-09',  40, 'planned', 'Terraform pairing'];
$v7[] = ['Ravi', 'SR-0215', '2026-09-21', '2026-09-23', 100, 'planned', null];
$v7[] = ['Lena', 'WI-1033', '2026-09-09', '2026-09-10',  50, 'committed', 'covers Wed-Thu'];
foreach ($v7 as $a) $addAssign($PV[7], $a);

// -------------------------------------------------------------------------------------
// 3. PROPOSAL — the open nightly replan generated at 02:00 today (web-05-changes.png).
// -------------------------------------------------------------------------------------
$triggers = [
    ['type' => 'incident',   'label' => "INC-4471 raised Sun 6 Sep, consuming Ravi's reserve and 4 hours of planned work", 'occurredAt' => '2026-09-06 21:40:00'],
    ['type' => 'dependency', 'label' => 'Identity export delivered early; WI-1061 dependency cleared',                      'occurredAt' => '2026-09-04 16:20:00'],
    ['type' => 'estimate',   'label' => 'WI-1047 re-estimated from 4 to 6 days after design review',                        'occurredAt' => '2026-09-07 11:05:00'],
];
$PROPOSAL = xid($conn, 'proposals', [
    'workspace_id' => $W, 'candidate_plan_version_id' => $PV[7], 'base_plan_version_id' => $COMMITTED,
    'kind' => 'nightly', 'status' => 'open', 'generated_at' => '2026-09-08 02:00:00', 'generated_by' => $U['ben'],
    'improvement_pct' => 6.4, 'below_threshold' => 0,
    'summary_before' => j(['late_items' => 2, 'value_quarter' => 612000, 'people_over_100' => 2, 'single_skill_deps' => 3,
                           'assignment_days_changed' => 0, 'total_assignment_days' => 365, 'stability_index' => 92]),
    'summary_after'  => j(['late_items' => 1, 'value_quarter' => 657000, 'people_over_100' => 0, 'single_skill_deps' => 2,
                           'assignment_days_changed' => 9, 'total_assignment_days' => 365, 'stability_index' => 90]),
    'triggers' => j($triggers),
    'carried_over_note' => null, 'scope_person_ids' => null, 'engine' => 'heuristic', 'decided_at' => null,
]);
$N['proposals'] = 1;

// --- replan_triggers rows behind those three triggers
$trigRows = [
    ['incident',   'urgent',  $triggers[0]['label'], '2026-09-06 21:40:00', 'work_item', $I['INC-4471'], [$PN['Ravi']]],
    ['dependency', 'batched', $triggers[1]['label'], '2026-09-04 16:20:00', 'work_item', $I['WI-1036'],  [$PN['Lena']]],
    ['estimate',   'batched', $triggers[2]['label'], '2026-09-07 11:05:00', 'work_item', $I['WI-1047'],  [$PN['Ewan']]],
];
$N['replan_triggers'] = 0;
foreach ($trigRows as $t) {
    xid($conn, 'replan_triggers', ['workspace_id' => $W, 'type' => $t[0], 'class' => $t[1], 'label' => $t[2],
        'occurred_at' => $t[3], 'source_entity' => $t[4], 'source_id' => $t[5],
        'person_ids' => implode(',', $t[6]), 'processed_at' => '2026-09-08 02:00:00', 'proposal_id' => $PROPOSAL]);
    $N['replan_triggers']++;
}
$trigList = '1,2,3';

// --- the eight proposed changes
$changes = [
    [   // 1
        'person' => 'Amira', 'ref' => 'WI-1033', 'kind' => 'move',
        'headline' => 'Start WI-1033 two days later',
        'before' => ['label' => 'WI-1033 Contract DQ rules · Wed 9 Sep – Fri 18 Sep', 'person_id' => $PN['Amira'], 'from' => '2026-09-09', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1033 Contract DQ rules · Fri 11 Sep – Fri 18 Sep (Lena covers Wed–Thu)', 'person_id' => $PN['Amira'], 'from' => '2026-09-11', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'reason' => 'Frees Amira for INC-4471 triage handover while Ravi is at 104%.',
        'chips'  => [['label' => 'Stability cost 2 assignment-days', 'tone' => 'info'], ['label' => 'Due date unchanged', 'tone' => 'ok'], ['label' => 'Inside freeze horizon · needs your approval', 'tone' => 'warn']],
        'stability' => 2, 'inside' => 1, 'guardrail' => 'needs_approval', 'guardrail_reason' => 'Inside the 10 working day freeze horizon, so a named approver is required.',
        'delta' => ['lateness' => -1, 'loadImbalance' => -0.4], 'affected' => [$PN['Amira'], $PN['Lena'], $PN['Ravi']],
    ],
    [   // 2
        'person' => 'Lena', 'ref' => 'WI-1061', 'kind' => 'move',
        'headline' => 'Pull WI-1061 forward one week',
        'before' => ['label' => 'WI-1061 Access review Q3 · w/c 14 Sep', 'person_id' => $PN['Lena'], 'from' => '2026-09-09', 'to' => '2026-09-14', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1061 Access review Q3 · w/c 7 Sep',  'person_id' => $PN['Lena'], 'from' => '2026-09-07', 'to' => '2026-09-10', 'allocation_pct' => 100],
        'reason' => 'Dependency on identity export cleared 4 days early.',
        'chips'  => [['label' => 'Stability cost 0 · same person, earlier', 'tone' => 'ok'], ['label' => 'Benefit realised 1 week earlier', 'tone' => 'ok']],
        'stability' => 0, 'inside' => 1, 'guardrail' => 'ok', 'guardrail_reason' => null,
        'delta' => ['valueCompletion' => 1.5], 'affected' => [$PN['Lena']],
    ],
    [   // 3
        'person' => 'Jon', 'ref' => 'WI-1042', 'kind' => 'pair',
        'headline' => 'Pair Jon on WI-1042 for Terraform',
        'before' => ['label' => 'WI-1044 Asset hierarchy loader · full time from 21 Sep', 'person_id' => $PN['Jon'], 'from' => '2026-09-21', 'to' => '2026-10-02', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1044 at 60% + WI-1042 Terraform pairing at 40% from 21 Sep', 'person_id' => $PN['Jon'], 'from' => '2026-09-21', 'to' => '2026-10-07', 'allocation_pct' => 60],
        'reason' => 'Reduces single-person dependency on Priya for Terraform L3; Jon is L2 and flagged for development.',
        'chips'  => [['label' => 'Stability cost 4 assignment-days', 'tone' => 'info'], ['label' => 'Skills risk reduced', 'tone' => 'ok'], ['label' => 'WI-1044 finishes 3 days later', 'tone' => 'warn']],
        'stability' => 4, 'inside' => 0, 'guardrail' => 'ok', 'guardrail_reason' => null,
        'delta' => ['single_skill_deps' => -1, 'lateness' => 0.5], 'affected' => [$PN['Jon'], $PN['Priya']],
    ],
    [   // 4
        'person' => 'Ewan', 'ref' => 'SR-0215', 'kind' => 'reassign',
        'headline' => 'Move SR-0215 to Ravi',
        'before' => ['label' => 'SR-0215 Report access · Ewan · 16–18 Sep', 'person_id' => $PN['Ewan'], 'from' => '2026-09-16', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'after'  => ['label' => 'SR-0215 Report access · Ravi · 21–23 Sep', 'person_id' => $PN['Ravi'], 'from' => '2026-09-21', 'to' => '2026-09-23', 'allocation_pct' => 100],
        'reason' => 'Ewan over capacity by 0.5 day in w/c 14 Sep after WI-1047 grew.',
        'chips'  => [['label' => 'Stability cost 3 assignment-days', 'tone' => 'info'], ['label' => 'Requester agreed new date', 'tone' => 'ok']],
        'stability' => 3, 'inside' => 1, 'guardrail' => 'ok', 'guardrail_reason' => null,
        'delta' => ['loadImbalance' => -0.6], 'affected' => [$PN['Ewan'], $PN['Ravi']],
    ],
    [   // 5
        'person' => 'Sam', 'ref' => 'WI-1040', 'kind' => 'reassign',
        'headline' => 'Swap Sam and Hana on WI-1040 hand-over',
        'before' => ['label' => 'Sam leads WI-1040 to 18 Sep', 'person_id' => $PN['Sam'], 'from' => '2026-09-07', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'after'  => ['label' => 'Hana leads WI-1040 from 14 Sep; Sam starts WI-1042 discovery early', 'person_id' => $PN['Hana'], 'from' => '2026-09-14', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'reason' => 'Marginal improvement of 2% in value-weighted completion.',
        'chips'  => [['label' => 'Improvement below 5% threshold', 'tone' => 'bad'], ['label' => 'Not applied automatically', 'tone' => 'warn']],
        'stability' => 5, 'inside' => 1, 'guardrail' => 'held_threshold', 'guardrail_reason' => 'Improvement of 2% is below the 5% minimum improvement guardrail.',
        'delta' => ['valueCompletion' => 2.0], 'affected' => [$PN['Sam'], $PN['Hana']],
    ],
    [   // 6
        'person' => 'Ewan', 'ref' => 'WI-1047', 'kind' => 'extend',
        'headline' => 'Extend WI-1047 by two days after re-estimate',
        'before' => ['label' => 'WI-1047 Ops dashboard · Mon 7 – Thu 10 Sep (4 days)', 'person_id' => $PN['Ewan'], 'from' => '2026-09-07', 'to' => '2026-09-10', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1047 Ops dashboard · Mon 7 – Fri 11 Sep (6 days)', 'person_id' => $PN['Ewan'], 'from' => '2026-09-07', 'to' => '2026-09-11', 'allocation_pct' => 100],
        'reason' => 'Design review added two pages; the estimate moved from 4 to 6 days.',
        'chips'  => [['label' => 'Stability cost 2 assignment-days', 'tone' => 'info'], ['label' => 'Reflects the accepted re-estimate', 'tone' => 'ok']],
        'stability' => 2, 'inside' => 1, 'guardrail' => 'ok', 'guardrail_reason' => null,
        'delta' => ['lateness' => 0.3], 'affected' => [$PN['Ewan']],
    ],
    [   // 7 — held: exceeds the change budget
        'person' => 'Ravi', 'ref' => 'WI-1052', 'kind' => 'move',
        'headline' => 'Move WI-1052 back four days for INC-4471',
        'before' => ['label' => 'WI-1052 Monitoring alerts · Fri 11 – Fri 18 Sep', 'person_id' => $PN['Ravi'], 'from' => '2026-09-11', 'to' => '2026-09-18', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1052 Monitoring alerts · Thu 17 – Wed 23 Sep', 'person_id' => $PN['Ravi'], 'from' => '2026-09-17', 'to' => '2026-09-23', 'allocation_pct' => 100],
        'reason' => 'The incident reserve covers 1.25 days; the rest of INC-4471 has to come from planned work, and WI-1052 is the lowest-priority item in the window (score 41).',
        'chips'  => [['label' => 'Stability cost 4 assignment-days', 'tone' => 'info'], ['label' => 'Exceeds change budget', 'tone' => 'bad'], ['label' => '5 of 5 used this week', 'tone' => 'warn']],
        'stability' => 4, 'inside' => 1, 'guardrail' => 'held_budget', 'guardrail_reason' => 'Exceeds the change budget of 5 assignment-days per person per week.',
        'delta' => ['lateness' => 1.0], 'affected' => [$PN['Ravi']],
    ],
    [   // 8 — held: below the improvement threshold
        'person' => 'Amira', 'ref' => 'WI-1066', 'kind' => 'move',
        'headline' => 'Bring WI-1066 forward to w/c 21 Sep',
        'before' => ['label' => 'WI-1066 Cost allocation model · from 28 Sep (indicative)', 'person_id' => $PN['Amira'], 'from' => '2026-09-28', 'to' => '2026-10-16', 'allocation_pct' => 100],
        'after'  => ['label' => 'WI-1066 Cost allocation model · from 21 Sep (indicative)', 'person_id' => $PN['Amira'], 'from' => '2026-09-21', 'to' => '2026-10-09', 'allocation_pct' => 100],
        'reason' => 'Starts the largest unscheduled item a week earlier, but displaces WI-1063 which is already waiting on a re-estimate.',
        'chips'  => [['label' => 'Improvement below 5% threshold', 'tone' => 'bad'], ['label' => 'Stability cost 6 assignment-days', 'tone' => 'warn'], ['label' => 'WI-1063 slips a week', 'tone' => 'warn']],
        'stability' => 6, 'inside' => 0, 'guardrail' => 'held_threshold', 'guardrail_reason' => 'Improvement of 3% is below the 5% minimum improvement guardrail.',
        'delta' => ['unscheduledValue' => -2.5, 'lateness' => 1.5], 'affected' => [$PN['Amira']],
    ],
];
$CP = [];   // index (1-based) => change_proposal id
$N['change_proposals'] = 0;
foreach ($changes as $i => $c) {
    $CP[$i + 1] = xid($conn, 'change_proposals', [
        'proposal_id' => $PROPOSAL, 'workspace_id' => $W, 'person_id' => $PN[$c['person']], 'work_item_id' => $I[$c['ref']],
        'kind' => $c['kind'], 'headline' => $c['headline'],
        'before_json' => j($c['before']), 'after_json' => j($c['after']),
        'reason' => $c['reason'], 'trigger_ids' => $trigList, 'objective_delta' => j($c['delta']),
        'stability_cost_days' => $c['stability'], 'inside_freeze' => $c['inside'],
        'impact_chips' => j($c['chips']), 'affected_person_ids' => implode(',', $c['affected']),
        'guardrail_status' => $c['guardrail'], 'guardrail_reason' => $c['guardrail_reason'],
        'decision' => 'pending', 'sort_order' => $i + 1,
    ]);
    $N['change_proposals']++;
}

// -------------------------------------------------------------------------------------
// 4. STABILITY WEEKS — weeks 25 to 36 of 2026 (web-11 plan stability and utilisation).
// -------------------------------------------------------------------------------------
// week, stability index %, changes inside freeze, planned load %, actual load %
$weeks = [
    [25, 55, 14, 84, 86, null],
    [26, 62, 13, 86, 89, null],
    [27, 59, 12, 85, 93, 'Two incidents in the same week pushed actual load above the target band.'],
    [28, 70, 11, 85, 88, null],
    [29, 75,  9, 86, 87, null],
    [30, 68, 10, 84, 90, 'Freeze horizon of 10 working days introduced this week.'],
    [31, 82,  7, 86, 85, null],
    [32, 86,  6, 85, 89, null],
    [33, 84,  6, 86, 95, 'Incident reserve fully consumed; actual load above 90%.'],
    [34, 89,  5, 85, 87, null],
    [35, 86,  4, 85, 88, null],
    [36, 92,  3, 85, null, 'Current week at the time of the demo snapshot.'],
];
$N['stability_weeks'] = 0;
foreach ($weeks as $w) {
    $total = 365.0;
    $moved = round($total * (100 - $w[1]) / 100, 2);
    x($conn, "INSERT INTO dbo.stability_weeks (workspace_id, week_start, total_assignment_days, moved_assignment_days, changes_inside_freeze, planned_load_pct, actual_load_pct, note) VALUES (?,?,?,?,?,?,?,?)",
        [$W, isoMonday(2026, $w[0]), $total, $moved, $w[2], $w[3], $w[4], $w[5]]);
    $N['stability_weeks']++;
}

// -------------------------------------------------------------------------------------
// 5. PERSON CHANGE LOG — the last eight weeks (ISO weeks 29-36 of 2026).
//    Priya has exactly three changes (weeks 30, 33 and 35); the team median is five.
// -------------------------------------------------------------------------------------
$changeLog = [
    'Priya' => [30, 33, 35],
    'Jon'   => [29, 30, 32, 34, 36],
    'Amira' => [29, 30, 31, 33, 34, 36],
    'Ravi'  => [29, 30, 31, 32, 33, 35, 36],
    'Lena'  => [30, 32, 34, 36],
    'Sam'   => [29, 31, 33, 34, 36],
    'Hana'  => [30, 31, 33, 35, 36],
    'Ewan'  => [29, 30, 32, 33, 35, 36],
];
$logItems = ['WI-1033', 'WI-1038', 'WI-1040', 'WI-1042', 'WI-1047', 'WI-1052', 'WI-1055', 'WI-1061'];
$logReasons = ['Incident displaced planned work', 'Estimate revised after design review', 'Dependency cleared early',
               'Leave booked in the planning window', 'Priority re-scored overnight', 'Manual edit by the delivery lead'];
$N['person_change_log'] = 0; $li = 0;
foreach ($changeLog as $first => $wks) {
    foreach ($wks as $k => $wk) {
        $monday = isoMonday(2026, $wk);
        xid($conn, 'person_change_log', ['workspace_id' => $W, 'person_id' => $PN[$first],
            'work_item_id' => $I[$logItems[$li % count($logItems)]],
            'changed_at' => addDays($monday, 1) . ' 09:15:00', 'week_start' => $monday,
            'inside_freeze' => ($wk >= 30 && $k % 3 === 0) ? 1 : 0,
            'assignment_days' => [1, 2, 2, 3, 4][$k % 5],
            'reason' => $logReasons[$li % count($logReasons)], 'change_proposal_id' => null]);
        $N['person_change_log']++; $li++;
    }
}

// -------------------------------------------------------------------------------------
// 6. NOTIFICATIONS
// -------------------------------------------------------------------------------------
$notes = [
    ['ben',   'approval_requested', 'Approval needed: Amira starts WI-1033 two days later',
     'Inside the freeze horizon. Stability cost 2 assignment-days; due date unchanged.', '/changes/' . $CP[1], 1, '2026-09-08 02:05:00', null],
    ['ben',   'approval_requested', '6 changes proposed by the nightly replan',
     'Two held back by guardrails. Change budget 3 of 5 used this week.', '/changes', 0, '2026-09-08 02:05:00', null],
    ['Priya', 'change_proposed',    'Pair on WI-1042 Terraform from 21 Sep',
     'Jon pairs with you on the Terraform workspace build so Terraform L3 is no longer a single point of failure.', '/changes/' . $CP[3], 0, '2026-09-08 02:05:00', null],
    ['Jon',   'change_proposed',    'WI-1044 drops to 60% from 21 Sep',
     'You pair on WI-1042 for Terraform at 40%. WI-1044 finishes three days later.', '/changes/' . $CP[3], 0, '2026-09-08 02:05:00', null],
    ['Amira', 'change_proposed',    'Start WI-1033 on Fri 11 Sep instead of Wed 9 Sep',
     'Frees you for the INC-4471 triage handover. Lena covers Wednesday and Thursday.', '/changes/' . $CP[1], 0, '2026-09-08 02:05:00', null],
    ['Lena',  'change_proposed',    'WI-1061 pulled forward to w/c 7 Sep',
     'The identity export dependency cleared four days early.', '/changes/' . $CP[2], 0, '2026-09-08 02:05:00', '2026-09-08 07:40:00'],
    ['Ewan',  'change_proposed',    'SR-0215 moves to Ravi',
     'You are over capacity by half a day in w/c 14 Sep after WI-1047 grew.', '/changes/' . $CP[4], 0, '2026-09-08 02:05:00', null],
    ['Ravi',  'item_assigned',      'INC-4471 assigned to you',
     'P2 incident, Medium. Your incident reserve is 25% this week because you are on the rota.', '/items/INC-4471', 1, '2026-09-06 21:45:00', '2026-09-07 06:50:00'],
    ['ben',   'estimate_requested', '6 items are waiting for a rough order of magnitude',
     'Oldest has waited 28 days. They cannot be scheduled until estimated.', '/pipeline?filter=needs_estimate', 0, '2026-09-08 02:05:00', null],
    ['finance', 'realisation_due',  'Q3 2026 benefit realisation is due for confirmation',
     'Three benefits are waiting on owner confirmation before the quarter closes.', '/benefits', 0, '2026-09-07 08:00:00', null],
    ['Sam',   'change_proposed',    'Held: swap with Hana on the WI-1040 hand-over',
     'Improvement of 2% is below the 5% threshold, so it was not applied automatically.', '/changes/' . $CP[5], 0, '2026-09-08 02:05:00', null],
    ['ben',   'change_committed',   'Plan v6 committed through Fri 18 Sep',
     '36 assignments across 8 people. Stability cost 6 assignment-days.', '/schedule', 0, '2026-09-07 09:01:00', '2026-09-07 09:20:00'],
];
$N['notifications'] = 0;
foreach ($notes as $n) {
    xid($conn, 'notifications', ['workspace_id' => $W, 'user_id' => $U[$n[0]], 'kind' => $n[1], 'title' => $n[2],
        'body' => $n[3], 'link' => $n[4], 'urgent' => $n[5], 'channel' => 'in_app', 'created_at' => $n[6], 'read_at' => $n[7]]);
    $N['notifications']++;
}

// -------------------------------------------------------------------------------------
// 7. ITEM COMMENTS — the four-message discussion on WI-1042.
// -------------------------------------------------------------------------------------
$comments = [
    ['requester', 'Procurement', '2026-08-04 10:12:00', 'Survivorship rules are the part we care about most. Can we see the rule order before build starts? The finance team will challenge anything that changes a vendor name silently.'],
    ['Sam', 'Sam Doyle', '2026-08-21 14:20:00', 'Rolled the estimate up from the seven tasks: 25 / 32 / 45 days. That assumes we reuse the ERP extract from WI-0987 rather than building a new one.'],
    ['ben', 'Ben A.', '2026-09-04 17:05:00', 'Design review widened the Terraform scope - the workspace now needs its own private endpoints. Sam has re-estimated to 28 / 36 / 52 at class 3. Still fits inside the 27 Nov date with about two weeks of slack.'],
    ['Priya', 'Priya Kaur', '2026-09-07 08:55:00', 'Terraform is 6 days of this and I am the only L3. Worth pairing Jon in from 21 Sep - he is flagged for development on Terraform and it takes the single point of failure off the plan.'],
];
$N['item_comments'] = 0;
foreach ($comments as $c) {
    xid($conn, 'item_comments', ['workspace_id' => $W, 'work_item_id' => $I['WI-1042'], 'change_proposal_id' => null,
        'author_user_id' => $U[$c[0]], 'author_name' => $c[1], 'body' => $c[3], 'created_at' => $c[2]]);
    $N['item_comments']++;
}

// -------------------------------------------------------------------------------------
// 8. PROGRESS LOGS — WI-1038 is on day 14 of 20.
// -------------------------------------------------------------------------------------
$progress = [
    ['2026-08-21 16:30:00', 'Priya', 15,  4.0, 'Streaming ingest for the first 400 vehicles is live in the dev workspace.'],
    ['2026-08-28 16:30:00', 'Jon',   35,  5.0, 'Late-arriving event handling built; replay tested against a two-day outage.'],
    ['2026-09-02 16:30:00', 'Priya', 50,  3.0, 'Curated telemetry layer published; operations pack re-pointed at it.'],
    ['2026-09-04 16:30:00', 'Jon',   62,  2.5, 'Remaining 1,000 vehicles onboarded in batches of 200.'],
    ['2026-09-07 16:30:00', 'Priya', 70,  1.5, 'Day 14 of 20. On track for Fri 11 Sep; only the handover pack left.'],
];
$N['progress_logs'] = 0;
foreach ($progress as $p) {
    xid($conn, 'progress_logs', ['work_item_id' => $I['WI-1038'], 'person_id' => $PN[$p[1]], 'logged_at' => $p[0],
        'progress_pct' => $p[2], 'effort_days' => $p[3], 'note' => $p[4]]);
    $N['progress_logs']++;
}

// -------------------------------------------------------------------------------------
// 9. AUDIT EVENTS — a representative trail. Every mutation in the app writes one of these.
// -------------------------------------------------------------------------------------
$audit = [
    ['2026-08-03 09:15:00', 'requester', 'Procurement', 'create', 'work_item', $I['WI-1042'], 'WI-1042 Supplier master data pipeline', null, 'Raised from the intake form'],
    ['2026-08-03 09:40:00', 'ben',   'Ben A.',      'create', 'estimate',  $I['WI-1042'], 'WI-1042 estimate v1 (size class L)', 'Sized at intake'],
    ['2026-08-04 10:12:00', 'requester', 'Procurement', 'create', 'comment', $I['WI-1042'], 'Comment on WI-1042', null],
    ['2026-08-10 09:00:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[1], 'Plan v1 committed through 21 Aug', 'Weekly commit'],
    ['2026-08-12 11:20:00', 'finance', 'Finance',    'create', 'benefit',   $I['WI-1042'], 'Cost avoidance £140k on WI-1042', 'Benefit case agreed with Finance'],
    ['2026-08-17 09:00:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[2], 'Plan v2 committed through 28 Aug', 'Weekly commit'],
    ['2026-08-18 09:05:00', 'ben',   'Ben A.',      'update', 'work_item', $I['WI-1042'], 'WI-1042 marked ready', 'Requirements signed off'],
    ['2026-08-21 14:10:00', 'Sam',   'Sam Doyle',   'create', 'estimate',  $I['WI-1042'], 'WI-1042 estimate v2 (roll-up 25/32/45)', 'Task roll-up from 7 tasks'],
    ['2026-08-24 09:00:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[3], 'Plan v3 committed through 4 Sep', 'Weekly commit'],
    ['2026-08-26 08:40:00', 'ben',   'Ben A.',      'create', 'work_item', $I['WI-1057'], 'WI-1057 Payroll interface fix', 'Raised by HR Services'],
    ['2026-08-31 09:00:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[4], 'Plan v4 committed through 11 Sep', 'Weekly commit'],
    ['2026-09-01 08:30:00', 'requester', 'Procurement', 'create', 'work_item', $I['SR-0212'], 'SR-0212 New workspace for asset analytics team', null],
    ['2026-09-02 10:15:00', 'ben',   'Ben A.',      'approve', 'change_proposal', null, 'Accepted: WI-1040 final sprint moved to Sam', 'Frees Hana for the close dashboard'],
    ['2026-09-02 16:30:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[5], 'Plan v5 committed through 15 Sep', 'Out-of-cycle commit after two accepted changes'],
    ['2026-09-03 07:45:00', 'admin', 'Dispatch Admin', 'create', 'work_item', $I['INC-4469'], 'INC-4469 Databricks job cluster start failures', 'Raised by the service desk'],
    ['2026-09-04 16:20:00', 'Lena',  'Lena Torres', 'update', 'dependency', $I['WI-1061'], 'Identity export dependency cleared', 'WI-1036 delivered four days early'],
    ['2026-09-04 16:45:00', 'Sam',   'Sam Doyle',   'create', 'estimate',  $I['WI-1042'], 'WI-1042 estimate v3 (28/36/52, class 3)', 'After design review widened Terraform scope'],
    ['2026-09-04 17:05:00', 'ben',   'Ben A.',      'create', 'comment',   $I['WI-1042'], 'Comment on WI-1042', null],
    ['2026-09-05 06:20:00', 'admin', 'Dispatch Admin', 'create', 'work_item', $I['INC-4470'], 'INC-4470 Power BI gateway timeouts', 'Raised by the service desk'],
    ['2026-09-06 21:40:00', 'admin', 'Dispatch Admin', 'create', 'work_item', $I['INC-4471'], 'INC-4471 Nightly finance load failing since 06 Sep', 'P2 raised out of hours'],
    ['2026-09-06 21:45:00', 'admin', 'Dispatch Admin', 'update', 'work_item', $I['INC-4471'], 'INC-4471 assigned to Ravi Shah', 'On the incident rota this week'],
    ['2026-09-07 08:55:00', 'Priya', 'Priya Kaur',  'create', 'comment',   $I['WI-1042'], 'Comment on WI-1042', null],
    ['2026-09-07 09:00:00', 'ben',   'Ben A.',      'commit', 'plan_version', $PV[6], 'Plan v6 committed through 18 Sep', 'Weekly commit'],
    ['2026-09-07 11:05:00', 'Ewan',  'Ewan Wright', 'update', 'estimate',  $I['WI-1047'], 'WI-1047 re-estimated from 4 to 6 days', 'Design review added two pages'],
    ['2026-09-07 14:30:00', 'ben',   'Ben A.',      'update', 'work_item', $I['INC-4471'], 'INC-4471 health set to blocked', 'Waiting on a vendor case for the source connector'],
    ['2026-09-07 16:30:00', 'Priya', 'Priya Kaur',  'create', 'progress_log', $I['WI-1038'], 'WI-1038 progress 70%', 'Day 14 of 20'],
    ['2026-09-08 02:00:00', 'ben',   'Ben A.',      'create', 'proposal',  $PROPOSAL, 'Nightly replan proposal', '3 triggers, 6 changes proposed, 3 held by guardrails'],
    ['2026-09-08 02:00:00', 'ben',   'Ben A.',      'create', 'plan_version', $PV[7], 'Plan v7 generated as a candidate', 'Nightly replan'],
    ['2026-09-08 07:40:00', 'Lena',  'Lena Torres', 'update', 'notification', null, 'Notification read', null],
    ['2026-09-08 08:05:00', 'ben',   'Ben A.',      'config', 'scheduling_policy', $POLICY, 'Change budget confirmed at 5 per person per week', 'Reviewed at the Monday planning meeting'],
];
$N['audit_events'] = 0;
foreach ($audit as $a) {
    xid($conn, 'audit_events', ['workspace_id' => $W, 'occurred_at' => $a[0], 'actor_user_id' => $U[$a[1]] ?? null,
        'actor_name' => $a[2], 'action' => $a[3], 'entity' => $a[4], 'entity_id' => $a[5], 'entity_label' => $a[6],
        'before_json' => null, 'after_json' => null, 'reason' => $a[7] ?? null]);
    $N['audit_events']++;
}

// -------------------------------------------------------------------------------------
// 10. INTEGRATIONS — all present, all switched off in the demo.
// -------------------------------------------------------------------------------------
$integrations = [
    ['jira',        'Import work items and push status back', '{"project":"DP","syncStatus":true,"syncEstimates":false}'],
    ['servicenow',  'Incidents and service requests',          '{"assignmentGroup":"Data Platform","severityMap":{"1":"P1","2":"P2","3":"P3","4":"P4"}}'],
    ['hr_leave',    'Approved leave into availability',        '{"system":"Workday","typesOnly":true,"lookAheadDays":180}'],
    ['m365',        'Directory and calendar',                  '{"tenant":"example.org","syncCalendar":false}'],
    ['teams',       'Change notifications into a channel',     '{"channel":"Data Platform / Dispatch"}'],
    ['timesheets',  'Actual effort against work items',        '{"system":"Tempo","weeklyImport":true}'],
    ['powerbi',     'Read-only reporting views',               '{"workspace":"Delivery reporting","views":["vw_assignments_committed","vw_estimate_accuracy"]}'],
];
$N['integrations'] = 0;
foreach ($integrations as $g) {
    xid($conn, 'integrations', ['workspace_id' => $W, 'system' => $g[0], 'enabled' => 0,
        'config_json' => $g[2], 'last_sync_at' => null, 'last_status' => 'Not connected · ' . $g[1]]);
    $N['integrations']++;
}

// -------------------------------------------------------------------------------------
// 11. SUMMARY
// -------------------------------------------------------------------------------------
$tables = ['workspaces', 'users', 'work_types', 'size_classes', 'scheduling_policies', 'teams', 'role_families', 'people', 'person_loans', 'skills',
    'person_skills', 'availability', 'incident_rota', 'capacity_days', 'work_items', 'ref_sequences', 'tasks',
    'dependencies', 'skill_requirements', 'estimates', 'day_rates', 'benefits', 'benefit_realisations',
    'plan_versions', 'assignments', 'proposals', 'change_proposals', 'replan_triggers', 'audit_events',
    'notifications', 'item_comments', 'stability_weeks', 'person_change_log', 'progress_logs', 'integrations'];
echo "\n--- Dispatch demo seed ------------------------------------------\n";
foreach ($tables as $t) {
    $r = xrows($conn, "SELECT COUNT(*) AS n FROM dbo.$t");
    printf("  %-24s %6d\n", $t, $r[0]['n']);
}
// ---------------------------------------------------------------------------------------
// Priority scores — computed by the real engine, never hand-written.
//
// The demo database must hold what a nightly cycle would actually produce, so that
// "Recompute priorities" is a no-op rather than a screen-wide renumbering. Loading the
// API's own helpers here is safe: they need only $conn, and lib.php reads today() from
// api/config.php, which the demo pins with 'fake_today'.
// ---------------------------------------------------------------------------------------
require_once __DIR__ . '/api/lib.php';
require_once __DIR__ . '/api/items_lib.php';
require_once __DIR__ . '/api/engine/priority.php';
$scored = compute_priority_scores($conn, $W);
printf("  priority engine scored %d items
", is_array($scored) ? (int)($scored['updated'] ?? 0) : (int)$scored);

$chk = xrows($conn, "
  SELECT
    (SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id=? AND status NOT IN ('delivered','cancelled')) AS open_items,
    (SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id=? AND status IN ('draft','needs_estimate','needs_benefit','ready')) AS unscheduled,
    (SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id=? AND status='needs_estimate') AS needs_estimate,
    (SELECT COUNT(*) FROM dbo.work_items WHERE workspace_id=? AND status='delivered') AS delivered,
    (SELECT COUNT(DISTINCT person_id) FROM dbo.assignments WHERE plan_version_id=?) AS people_in_v6,
    (SELECT SUM(annual_value) FROM dbo.benefits b JOIN dbo.work_items w ON w.id=b.work_item_id WHERE w.status IN ('scheduled','in_progress')) AS value_in_plan,
    (SELECT SUM(realised_value) FROM dbo.benefit_realisations WHERE quarter LIKE '%2026') AS realised_2026,
    (SELECT SUM(annual_value) FROM dbo.benefits WHERE status='at_risk') AS at_risk
", [$W, $W, $W, $W, $COMMITTED]);
$c = $chk[0];
echo "-----------------------------------------------------------------\n";
printf("  open work items %d · unscheduled %d · needs estimate %d · delivered %d\n", $c['open_items'], $c['unscheduled'], $c['needs_estimate'], $c['delivered']);
printf("  committed plan version id %d (v6) · people with assignments %d\n", $COMMITTED, $c['people_in_v6']);
printf("  open proposal id %d · change proposals %d\n", $PROPOSAL, $N['change_proposals']);
printf("  benefits: in plan £%s · realised 2026 £%s · at risk £%s\n", number_format((float)$c['value_in_plan']), number_format((float)$c['realised_2026']), number_format((float)$c['at_risk']));
printf("  Ben A. user id %d · seeded in %.1fs\n", $U['ben'], microtime(true) - $t0);
echo "-----------------------------------------------------------------\n";
