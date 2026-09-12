<?php
// seed_demo.php — wipes and reseeds the whole DispatchDB demo dataset ("Data Platform" workspace).
// CLI only. Idempotent: run as often as you like.   php seed_demo.php
// Demo "today" is Tue 8 Sep 2026; the committed plan (v6) runs through Fri 18 Sep 2026.
require __DIR__ . '/migration_connect.php';
$t0 = microtime(true);

// ---------------------------------------------------------------- helpers
function j($v) { return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); }
function isWorkDay($d) { return (int)date('N', strtotime($d)) <= 5; }
function addDays($d, $n) { return date('Y-m-d', strtotime("$d +$n day")); }
/** working days from $from to $to inclusive */
function workDays($from, $to) { $out = []; for ($d = $from; $d <= $to; $d = addDays($d, 1)) if (isWorkDay($d)) $out[] = $d; return $out; }
/** Monday of ISO week $w in $y */
function isoMonday($y, $w) { $d = new DateTime(); $d->setISODate($y, $w); return $d->format('Y-m-d'); }
function weekMonday($d) { return date('Y-m-d', strtotime('monday this week', strtotime($d))); }
$TODAY = '2026-09-08';

// ---------------------------------------------------------------- wipe (FK-safe order)
$wipe = ['item_comments','notifications','notification_prefs','person_change_log','progress_logs','replan_triggers',
  'change_proposals','proposals','assignments','plan_versions','benefit_realisations','benefits','estimates',
  'skill_requirements','dependencies','tasks','work_items','ref_sequences','capacity_days','incident_rota','availability',
  'person_skills','skills','day_rates','stability_weeks','audit_events','integrations','scheduling_policies','size_classes','work_types'];
// users <-> people <-> teams are circular: null the links first
x($conn, "UPDATE dbo.users SET person_id = NULL"); x($conn, "UPDATE dbo.teams SET lead_person_id = NULL");
foreach ($wipe as $t) x($conn, "DELETE FROM dbo.$t");
foreach (['people','users','teams','workspaces'] as $t) x($conn, "DELETE FROM dbo.$t");
$identityTables = ['workspaces','users','work_types','size_classes','scheduling_policies','teams','people','skills','availability','incident_rota',
  'work_items','tasks','dependencies','skill_requirements','estimates','day_rates','benefits','benefit_realisations','plan_versions','assignments',
  'proposals','change_proposals','replan_triggers','audit_events','notifications','item_comments','person_change_log','progress_logs','integrations'];
foreach ($identityTables as $t) x($conn, "DBCC CHECKIDENT ('dbo.$t', RESEED, 0) WITH NO_INFOMSGS");
echo "Wiped.\n";

// ---------------------------------------------------------------- workspace, work types, sizes, policy
$W = xid($conn, 'workspaces', ['name' => 'Data Platform', 'time_zone' => 'Europe/London', 'working_days' => 'Mon,Tue,Wed,Thu,Fri', 'hours_per_day' => 7.5, 'currency' => 'GBP', 'created_at' => '2026-03-30 09:00:00']);

// Requirements templates (REQ-03): pre-populate the requirements tab of a new item of this type.
$reqTemplates = [
  'Project' => "## Problem
What is wrong today, who feels it and how often.

## Scope
In scope:
- 

Out of scope:
- 

## Data and interfaces
Source systems, target datasets, refresh frequency and owners.

## Acceptance criteria
- [ ] Agreed with the sponsor and the requesting team
- [ ] Measurable, with the check written down
- [ ] Non-functional needs stated (volume, refresh, retention, access)

## Assumptions and exclusions
- 

## Benefit
How the annual value is measured and who confirms it.",
  'Small change' => "## Change
What changes and where.

## Reason
Why now, and what happens if it is not done.

## Acceptance criteria
- [ ] Behaviour after the change, stated as a check
- [ ] Regression check on the affected pipeline or report

## Rollback
How the change is backed out if it fails.",
  'Incident' => "## What is happening
Symptoms, affected services and when it started.

## Impact
Who is affected and what they cannot do.

## Immediate mitigation
- 

## Acceptance criteria
- [ ] Service restored and confirmed by the reporter
- [ ] Root cause recorded and any follow-up raised as its own item",
  'Service request' => "## Request
What is being asked for.

## Who it is for
Requester, team and any approver.

## Acceptance criteria
- [ ] Access or resource in place and confirmed by the requester
- [ ] Recorded in the access register",
];

$WT = []; // name => id
$wtRows = [
  ['Project', 'Projects', 'WI', '#3B6BD6', 'planned', 1, 1, 'L', null, 'days', 'Planned work · scheduled by the engine · needs an estimate and a benefit case before scheduling'],
  ['Small change', 'Small changes', 'WI', '#178F8A', 'planned', 1, 0, 'S', null, 'days', 'Planned work · scheduled by the engine · estimate required, benefit case optional'],
  ['Incident', 'Incidents', 'INC', '#C8102E', 'interrupt', 0, 0, null, null, 'hours', 'Interrupt-driven · consumes the incident reserve first, then displaces the lowest-priority planned work'],
  ['Service request', 'Service requests', 'SR', '#6D5BD0', 'planned', 0, 0, 'S', 'S', 'days', 'Planned work · Small only · scheduled into gaps within 10 working days'],
];
foreach ($wtRows as $i => $r) $WT[$r[0]] = xid($conn, 'work_types', ['workspace_id' => $W, 'name' => $r[0], 'plural' => $r[1], 'prefix' => $r[2], 'colour' => $r[3], 'policy' => $r[4],
  'requires_estimate' => $r[5], 'requires_benefit' => $r[6], 'default_size_stamp' => $r[7], 'allowed_sizes' => $r[8], 'size_unit' => $r[9], 'description' => $r[10],
  'requirements_template' => $reqTemplates[$r[0]] ?? null, 'sort_order' => $i + 1]);
foreach ([['WI', 1072], ['INC', 4472], ['SR', 216]] as $rs) x($conn, "INSERT INTO dbo.ref_sequences (workspace_id, prefix, next_value) VALUES (?,?,?)", [$W, $rs[0], $rs[1]]);

$SZ = []; // stamp => id (workspace scope)
$szRows = [['S', 'Small', 0, 3, 2, 4, 'halfDay', 0, 0], ['M', 'Medium', 4, 15, 9, 3, 'day', 1, 0], ['L', 'Large', 16, 60, 30, 3, 'week', 1, 0], ['C', 'Custom', null, null, null, 3, 'week', 1, 1]];
foreach ($szRows as $i => $r) $SZ[$r[0]] = xid($conn, 'size_classes', ['workspace_id' => $W, 'work_type_id' => null, 'name' => $r[1], 'stamp' => $r[0], 'min_days' => $r[2], 'max_days' => $r[3], 'planning_days' => $r[4],
  'default_estimate_class' => $r[5], 'granularity' => $r[6], 'counts_for_wip' => $r[7], 'is_custom' => $r[8], 'sort_order' => $i + 1]);
$SZI = []; // incident overrides (hours)
foreach ([['S', 'Small', 0, 4, 2], ['M', 'Medium', 4, 15, 8], ['L', 'Large', 15, null, 30]] as $i => $r) $SZI[$r[0]] = xid($conn, 'size_classes', ['workspace_id' => $W, 'work_type_id' => $WT['Incident'], 'name' => $r[1], 'stamp' => $r[0],
  'min_days' => $r[2], 'max_days' => $r[3], 'planning_days' => $r[4], 'default_estimate_class' => 4, 'granularity' => 'halfDay', 'counts_for_wip' => 0, 'is_custom' => 0, 'sort_order' => $i + 1]);

// ---------------------------------------------------------------- team, people, users
$TEAM = xid($conn, 'teams', ['workspace_id' => $W, 'name' => 'Data Platform']);
$full = '{"Mon":7.5,"Tue":7.5,"Wed":7.5,"Thu":7.5,"Fri":7.5}';
$peopleRows = [ // name, initials, colour, role, days, pattern, pattern_label, tagline, prefers, avoid, max_conc
  ['Priya Kaur', 'PK', '#3B6BD6', 'Senior engineer', 4.5, '{"Mon":7.5,"Tue":7.5,"Wed":7.5,"Thu":7.5,"Fri":3.75}', 'Mon–Thu full, Fri half day', 'Terraform and Databricks lead', 'Platform and infrastructure work', 'Power BI report building', null],
  ['Jon Okafor', 'JO', '#178F8A', 'Engineer', 5, $full, 'Mon–Fri full time', 'Streaming and integration engineer', 'Event streaming and API work', null, null],
  ['Amira Mansour', 'AM', '#6D5BD0', 'Analyst engineer', 5, $full, 'Mon–Fri full time', 'SQL and reporting specialist', 'Data quality and reporting', null, null],
  ['Ravi Shah', 'RS', '#C8102E', 'Support engineer', 5, $full, 'Mon–Fri full time', 'Incident lead and SQL expert', 'Operational support', 'Long design phases', 3],
  ['Lena Torres', 'LT', '#D99A00', 'Security & platform', 4.0, '{"Mon":7.5,"Tue":7.5,"Wed":7.5,"Thu":7.5}', 'Mon–Thu, no Fridays', 'Security and Azure platform', 'Security and access work', null, null],
  ['Sam Doyle', 'SD', '#1F9D6B', 'Data modeller', 5, $full, 'Mon–Fri full time', 'Data modelling and SQL lead', 'Modelling and design', 'Infrastructure work', null],
  ['Hana Novak', 'HN', '#16284D', 'Engineer', 5, $full, 'Mon–Fri full time', 'Databricks and Python engineer', 'Pipeline engineering', null, null],
  ['Ewan Wright', 'EW', '#F28C28', 'BI developer', 5, $full, 'Mon–Fri full time', 'Power BI and reporting', 'Report and dashboard build', 'Infrastructure work', null],
];
$P = []; $PN = []; // full name => id ; first name => id
foreach ($peopleRows as $r) {
  [$first, $last] = explode(' ', $r[0]);
  $id = xid($conn, 'people', ['workspace_id' => $W, 'team_id' => $TEAM, 'name' => $r[0], 'initials' => $r[1], 'email' => strtolower("$first.$last@example.org"), 'role_title' => $r[3], 'tagline' => $r[7],
    'days_per_week' => $r[4], 'working_pattern' => $r[5], 'pattern_label' => $r[6], 'max_concurrent' => $r[10], 'min_focus_days' => null, 'prefers' => $r[8], 'avoid' => $r[9],
    'line_manager' => 'Ben A.', 'colour' => $r[2], 'active' => 1, 'created_at' => '2026-03-30 09:30:00']);
  $P[$r[0]] = $id; $PN[$first] = $id;
}
x($conn, "UPDATE dbo.teams SET lead_person_id = ? WHERE id = ?", [$PN['Priya'], $TEAM]);

$U = [];
$U['ben'] = xid($conn, 'users', ['workspace_id' => $W, 'email' => 'ben.a@example.org', 'display_name' => 'Ben Stevenson', 'short_name' => 'Ben A.', 'role' => 'delivery_lead', 'person_id' => null, 'active' => 1, 'created_at' => '2026-03-30 09:00:00']);
$U['admin'] = xid($conn, 'users', ['workspace_id' => $W, 'email' => 'admin@example.org', 'display_name' => 'Dispatch Admin', 'short_name' => 'Admin', 'role' => 'admin', 'person_id' => null, 'active' => 1, 'created_at' => '2026-03-30 09:00:00']);
foreach ($peopleRows as $r) { [$first, $last] = explode(' ', $r[0]);
  $U[$first] = xid($conn, 'users', ['workspace_id' => $W, 'email' => strtolower("$first.$last@example.org"), 'display_name' => $r[0], 'short_name' => $first . ' ' . $last[0] . '.', 'role' => 'team_member', 'person_id' => $P[$r[0]], 'active' => 1, 'created_at' => '2026-03-30 09:30:00']); }
$U['requester'] = xid($conn, 'users', ['workspace_id' => $W, 'email' => 'procurement.requests@example.org', 'display_name' => 'Procurement Requester', 'short_name' => 'Procurement', 'role' => 'requester', 'active' => 1]);
$U['finance'] = xid($conn, 'users', ['workspace_id' => $W, 'email' => 'finance.benefits@example.org', 'display_name' => 'Finance Benefit Owner', 'short_name' => 'Finance', 'role' => 'benefit_owner', 'active' => 1]);

$POLICY = xid($conn, 'scheduling_policies', ['workspace_id' => $W, 'version' => 1, 'is_current' => 1, 'created_at' => '2026-04-01 09:00:00', 'created_by' => $U['ben']]);
xid($conn, 'day_rates', ['workspace_id' => $W, 'name' => 'Blended engineer', 'rate' => 700, 'currency' => 'GBP', 'effective_from' => '2026-04-01', 'is_blended' => 1]);

// ---------------------------------------------------------------- skills
$skillNames = ['Azure', 'Databricks', 'Terraform', 'Python', 'SQL', 'Data modelling', 'Event streaming', 'Power BI', 'API integration', 'Security'];
$skillCat = ['Azure' => 'Platform', 'Databricks' => 'Platform', 'Terraform' => 'Platform', 'Python' => 'Engineering', 'SQL' => 'Engineering', 'Data modelling' => 'Engineering', 'Event streaming' => 'Engineering', 'Power BI' => 'Reporting', 'API integration' => 'Engineering', 'Security' => 'Platform'];
$S = [];
foreach ($skillNames as $i => $n) $S[$n] = xid($conn, 'skills', ['workspace_id' => $W, 'name' => $n, 'category' => $skillCat[$n], 'sort_order' => $i + 1]);
$S['Azure Data Factory'] = xid($conn, 'skills', ['workspace_id' => $W, 'name' => 'Azure Data Factory', 'category' => 'Platform', 'description' => 'Orchestration and copy pipelines', 'sort_order' => 11]);
$S['Procurement domain'] = xid($conn, 'skills', ['workspace_id' => $W, 'name' => 'Procurement domain', 'category' => 'Domain', 'description' => 'Supplier, contract and PO processes', 'sort_order' => 12]);
// matrix per web-06 (0 = no row); last two columns are the catalogue extras (ADF, Procurement domain)
$matrix = [
  'Priya' => [4, 4, 3, 3, 3, 2, 3, 1, 2, 2, 3, 0], 'Jon' => [3, 3, 2, 3, 2, 2, 3, 0, 3, 1, 2, 0], 'Amira' => [2, 2, 0, 3, 4, 3, 1, 3, 2, 1, 3, 2],
  'Ravi' => [3, 2, 1, 2, 4, 1, 2, 1, 2, 2, 3, 0], 'Lena' => [4, 1, 2, 2, 2, 1, 0, 0, 1, 4, 1, 0], 'Sam' => [2, 3, 0, 2, 4, 4, 0, 2, 1, 0, 2, 1],
  'Hana' => [3, 3, 1, 3, 3, 2, 2, 0, 2, 1, 2, 0], 'Ewan' => [2, 1, 0, 1, 3, 2, 0, 4, 1, 0, 1, 1],
];
$allSkills = array_merge($skillNames, ['Azure Data Factory', 'Procurement domain']);
foreach ($matrix as $first => $levels) foreach ($levels as $i => $lvl) { if ($lvl === 0) continue;
  $sk = $allSkills[$i]; $extra = [];
  if ($first === 'Priya' && $sk === 'Azure') $extra['endorsed_by'] = implode(',', [$PN['Jon'], $PN['Lena'], $PN['Hana']]);
  if ($first === 'Priya' && $sk === 'Databricks') $extra['certified'] = 1;
  if ($first === 'Jon' && $sk === 'Terraform') $extra = ['development_target' => 3, 'pairing_enabled' => 1];
  if ($first === 'Amira' && $sk === 'Databricks') $extra = ['development_target' => 3, 'pairing_enabled' => 1];
  if ($first === 'Ewan' && $sk === 'Data modelling') $extra = ['development_target' => 3, 'pairing_enabled' => 0];
  $cols = array_merge(['person_id' => $PN[$first], 'skill_id' => $S[$sk], 'proficiency' => $lvl, 'updated_at' => '2026-08-20 10:00:00'], $extra);
  x($conn, "INSERT INTO dbo.person_skills (" . implode(',', array_keys($cols)) . ") VALUES (" . implode(',', array_fill(0, count($cols), '?')) . ")", array_values($cols));
}

// ---------------------------------------------------------------- availability, rota, capacity
$avail = [ // person, from, to, type, source, label
  ['Hana', '2026-09-07', '2026-09-11', 'leave', 'hr', 'Leave'],
  ['Jon', '2026-09-17', '2026-09-18', 'training', 'manual', 'Training'],
  ['Ravi', '2026-10-19', '2026-10-23', 'leave', 'hr', 'Leave'],
  ['Sam', '2026-08-24', '2026-08-28', 'leave', 'hr', 'Leave'],
  ['Ewan', '2026-11-02', '2026-11-06', 'leave', 'hr', 'Leave'],
  ['Amira', '2026-12-21', '2027-01-01', 'leave', 'hr', 'Leave'],
];
foreach ($avail as $a) xid($conn, 'availability', ['workspace_id' => $W, 'person_id' => $PN[$a[0]], 'from_date' => $a[1], 'to_date' => $a[2], 'type' => $a[3], 'fraction' => 1.0, 'source' => $a[4], 'label' => $a[5], 'created_by' => $U['ben'], 'created_at' => '2026-08-15 09:00:00']);
$rota = ['2026-09-07' => 'Ravi', '2026-09-14' => 'Ravi', '2026-09-21' => 'Jon', '2026-09-28' => 'Priya', '2026-10-05' => 'Hana'];
foreach ($rota as $wk => $who) xid($conn, 'incident_rota', ['workspace_id' => $W, 'person_id' => $PN[$who], 'week_start' => $wk]);

foreach ($peopleRows as $r) {
  $pid = $P[$r[0]]; $pattern = json_decode($r[5], true);
  foreach (workDays('2026-08-31', '2027-03-05') as $d) {
    $hours = $pattern[date('D', strtotime($d))] ?? 0;
    $frac = 0;
    foreach ($avail as $a) if ($PN[$a[0]] === $pid && $d >= $a[1] && $d <= $a[2]) $frac = 1.0;
    $availH = round($hours * (1 - $frac), 2);
    $onRota = isset($rota[weekMonday($d)]) && $PN[$rota[weekMonday($d)]] === $pid;
    $reserve = round($availH * ($onRota ? 0.25 : 0.12), 2);
    x($conn, "INSERT INTO dbo.capacity_days (workspace_id, person_id, day, available_hours, reserve_hours, derived_at) VALUES (?,?,?,?,?,?)", [$W, $pid, $d, $availH, $reserve, '2026-09-08 02:00:00']);
  }
}
echo "Config, team, skills, capacity done.\n";

require __DIR__ . '/seed_demo_items.php';   // work items, estimates, benefits, plans, proposals, reporting rows
