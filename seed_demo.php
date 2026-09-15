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
// webhook_deliveries before its subscriptions, and the cursor with them: a cursor left
// pointing past a rebuilt audit log would stop every webhook silently (webhook_lib.php
// rewinds defensively, but the demo should not depend on that).
$wipe = ['webhook_deliveries','webhook_subscriptions','webhook_cursor','calendar_feeds','push_deliveries','device_tokens',
  'resource_requests','public_holidays',
  'item_comments','notifications','notification_prefs','person_change_log','progress_logs','replan_triggers',
  'change_proposals','proposals','assignments','plan_versions','benefit_realisations','benefits','estimates',
  'skill_requirements','dependencies','tasks','work_items','ref_sequences','capacity_days','incident_rota','availability',
  'person_skills','skills','day_rates','stability_weeks','audit_events','integrations','scheduling_policies','size_classes','work_types',
  'person_loans'];
// users <-> people <-> teams <-> role_families are circular, and both teams and people now point at
// themselves (parent team, manager): null every such link before deleting anything.
x($conn, "UPDATE dbo.users SET person_id = NULL");
x($conn, "UPDATE dbo.teams SET lead_person_id = NULL, parent_team_id = NULL");
x($conn, "UPDATE dbo.people SET manager_person_id = NULL, role_family_id = NULL");
x($conn, "UPDATE dbo.role_families SET lead_person_id = NULL");
foreach ($wipe as $t) x($conn, "DELETE FROM dbo.$t");
foreach (['people','users','role_families','teams','workspaces'] as $t) x($conn, "DELETE FROM dbo.$t");   // people before teams and role_families
$identityTables = ['workspaces','users','work_types','size_classes','scheduling_policies','teams','role_families','person_loans','people','skills','availability','incident_rota',
  'work_items','tasks','dependencies','skill_requirements','estimates','day_rates','benefits','benefit_realisations','plan_versions','assignments',
  'proposals','change_proposals','replan_triggers','audit_events','notifications','item_comments','person_change_log','progress_logs','integrations',
  'webhook_subscriptions','webhook_deliveries','calendar_feeds','device_tokens','push_deliveries','resource_requests','public_holidays'];
foreach ($identityTables as $t) x($conn, "DBCC CHECKIDENT ('dbo.$t', RESEED, 0) WITH NO_INFOMSGS");
echo "Wiped.\n";

// ---------------------------------------------------------------- workspace, work types, sizes, policy
$W = xid($conn, 'workspaces', ['name' => 'Data Platform', 'time_zone' => 'Europe/London', 'working_days' => 'Mon,Tue,Wed,Thu,Fri', 'hours_per_day' => 7.5, 'currency' => 'GBP', 'created_at' => '2026-03-30 09:00:00']);

// The content of the demo — everything except the workspace row itself — lives in its own file so
// it can be built into an EXISTING workspace as well as a freshly wiped one. api/engine/workspace_clone.php
// includes the same file to seed a campaign with demo data over HTTP, where there is nothing to wipe.
require __DIR__ . '/seed_demo_content.php';
