<?php
// =====================================================================================
// seed_demo_items.php — work items, requirements, tasks, dependencies, estimates,
// benefits and benefit realisations for the Dispatch demo dataset.
// Included from seed_demo.php (which supplies $conn, $W, $WT, $SZ, $SZI, $P, $PN, $U,
// $S, $TODAY and the helpers j/isWorkDay/addDays/workDays/isoMonday/weekMonday).
// Demo "today" is Tue 8 Sep 2026.
// =====================================================================================
if (!isset($conn) || !isset($W)) { fwrite(STDERR, "seed_demo_items.php must be included from seed_demo.php\n"); exit(1); }

$I  = [];   // ref => work_item id
$WI = [];   // ref => row (for later sections)
$N  = [];   // table => inserted count

/** Insert one work item. $o keys mirror the column names, plus type/size/owner shorthands. */
function addItem($conn, array $o) {
    global $W, $WT, $SZ, $SZI, $P, $PN, $U, $I, $WI, $N;
    $typeName = $o['type'];
    $sizes    = ($typeName === 'Incident') ? $SZI : $SZ;
    $stamp    = $o['size'] ?? null;
    $cols = [
        'workspace_id'          => $W,
        'ref'                   => $o['ref'],
        'work_type_id'          => $WT[$typeName],
        'size_class_id'         => $stamp === null ? null : $sizes[$stamp],
        'custom_effort_days'    => $o['custom_effort_days'] ?? null,
        'title'                 => $o['title'],
        'summary'               => $o['summary'] ?? null,
        'requirements_text'     => $o['requirements_text'] ?? null,
        'tags'                  => $o['tags'] ?? null,
        'status'                => $o['status'],
        'health'                => $o['health'] ?? null,
        'priority_score'        => $o['score'] ?? null,
        'priority_terms'        => null,   // filled in by the priority engine post-seed
        'risk_weight'           => $o['risk_weight'] ?? null,
        'severity'              => $o['severity'] ?? null,
        'requested_by'          => $o['requested_by'] ?? null,
        'sponsor'               => $o['sponsor'] ?? null,
        'owner_person_id'       => isset($o['owner']) ? $PN[$o['owner']] : null,
        'needed_by'             => $o['needed_by'] ?? null,
        'earliest_start'        => $o['earliest_start'] ?? null,
        'ready_at'              => $o['ready_at'] ?? null,
        'started_at'            => $o['started_at'] ?? null,
        'delivered_at'          => $o['delivered_at'] ?? null,
        'actual_effort_days'    => $o['actual_effort_days'] ?? null,
        'progress_pct'          => $o['progress_pct'] ?? 0,
        'external_ref'          => $o['external_ref'] ?? null,
        'created_by'            => $o['created_by'] ?? $U['ben'],
        'created_at'            => $o['created_at'] ?? '2026-07-01 09:00:00',
        'updated_at'            => $o['updated_at'] ?? '2026-09-08 02:00:00',
    ];
    $id = xid($conn, 'work_items', $cols);
    $I[$o['ref']]  = $id;
    $WI[$o['ref']] = $o + ['id' => $id];
    $N['work_items'] = ($N['work_items'] ?? 0) + 1;
    return $id;
}

// -------------------------------------------------------------------------------------
// 1. OPEN WORK ITEMS — 42 in total (35 WI, 4 SR, 3 INC).
//    24 are scheduled / in progress; 18 are unscheduled, of which 6 need an estimate.
// -------------------------------------------------------------------------------------

// Priority scores and their term breakdowns are NOT hand-written here. They are computed
// by the real engine (api/engine/priority.php) at the end of seed_demo.php, so the demo
// database holds exactly what a nightly cycle would produce and `recompute_priorities`
// is a no-op rather than a screen-wide renumbering. The per-item 'score' values below are
// therefore only a fallback for anything the engine cannot score.

$open = [
    // ---- Projects -------------------------------------------------------------------
    ['ref' => 'WI-1033', 'title' => 'Contract data quality rules', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 66, 'risk_weight' => 0.55, 'needed_by' => '2026-09-18', 'owner' => 'Amira',
     'tags' => 'Contracts,Data quality,Master data', 'requested_by' => 'Commercial', 'sponsor' => 'Commercial Director',
     'summary' => 'Codify the agreed contract data quality rules (mandatory fields, party matching, expiry handling) as testable checks in the lakehouse, with a daily exception report for the commercial team. Prerequisite for the supplier master data pipeline (WI-1042).',
     'created_at' => '2026-07-14 10:20:00', 'ready_at' => '2026-07-28 09:00:00', 'started_at' => '2026-09-09'],

    ['ref' => 'WI-1038', 'title' => 'Fleet telemetry ingestion – phase 2', 'type' => 'Project', 'size' => 'L', 'status' => 'in_progress', 'health' => 'on_track',
     'score' => 74, 'risk_weight' => 0.40, 'needed_by' => '2026-09-11', 'owner' => 'Priya',
     'tags' => 'Telemetry,Streaming,Fleet', 'requested_by' => 'Fleet Operations', 'sponsor' => 'Director of Operations',
     'summary' => 'Second phase of the fleet telemetry platform: event streaming for the remaining 1,400 vehicles, late-arriving event handling and a curated telemetry layer for the operations reporting pack.',
     'created_at' => '2026-06-02 11:00:00', 'ready_at' => '2026-06-16 09:00:00', 'started_at' => '2026-08-17', 'progress_pct' => 70],

    ['ref' => 'WI-1039', 'title' => 'Reference data service', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 63, 'risk_weight' => 0.45, 'needed_by' => '2026-10-30', 'owner' => 'Jon',
     'tags' => 'Reference data,API', 'requested_by' => 'Data Governance', 'sponsor' => 'Chief Data Officer',
     'summary' => 'A single API-fronted reference data service for country, currency, unit and cost-centre code lists, replacing four hand-maintained copies.',
     'created_at' => '2026-07-06 09:30:00', 'ready_at' => '2026-07-20 09:00:00'],

    ['ref' => 'WI-1040', 'title' => 'Finance data mart', 'type' => 'Project', 'size' => 'L', 'status' => 'in_progress', 'health' => 'on_track',
     'score' => 69, 'risk_weight' => 0.35, 'needed_by' => '2026-09-18', 'owner' => 'Sam',
     'tags' => 'Finance,Data mart,Reporting', 'requested_by' => 'Finance', 'sponsor' => 'Finance Director',
     'summary' => 'Conformed finance data mart covering GL, AP and AR, replacing the month-end spreadsheet pack. Final sprint is the close dashboard hand-over to Hana.',
     'created_at' => '2026-05-18 14:00:00', 'ready_at' => '2026-06-01 09:00:00', 'started_at' => '2026-07-20', 'progress_pct' => 82],

    ['ref' => 'WI-1042', 'title' => 'Supplier master data pipeline', 'type' => 'Project', 'size' => 'L', 'status' => 'scheduled', 'health' => 'at_risk',
     'score' => 78, 'risk_weight' => 0.60, 'needed_by' => '2026-11-27', 'owner' => 'Sam',
     'tags' => 'Supplier data,Lakehouse,Procurement,Master data', 'requested_by' => 'Procurement', 'sponsor' => 'Head of Supply Chain',
     'summary' => 'Build a governed supplier master dataset in the lakehouse, sourced from the ERP and the supplier onboarding portal, with survivorship rules and a daily publish to Finance and Procurement reporting. Replaces three spreadsheet reconciliations and unblocks the vendor risk scoring dashboard (WI-1068).',
     'requirements_text' => "Single supplier golden record keyed on the ERP vendor number.\nSurvivorship rules agreed with Procurement, applied in a documented order.\nDaily publish by 06:00 to the Finance and Procurement semantic models.\nFull audit of source and rule applied for every surviving attribute.\nHistorical back-fill limited to 24 months.",
     'created_at' => '2026-08-03 09:15:00', 'ready_at' => '2026-08-18 09:00:00', 'created_by' => $U['requester']],

    ['ref' => 'WI-1043', 'title' => 'Data catalogue rollout', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 57, 'risk_weight' => 0.40, 'needed_by' => '2026-11-13', 'owner' => 'Ewan',
     'tags' => 'Governance,Catalogue', 'requested_by' => 'Data Governance', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Roll the data catalogue out to the remaining four domains, with owner assignment, glossary terms and automated lineage harvesting from Azure Data Factory.',
     'created_at' => '2026-07-21 10:00:00', 'ready_at' => '2026-08-04 09:00:00'],

    ['ref' => 'WI-1044', 'title' => 'Asset hierarchy loader', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 64, 'risk_weight' => 0.45, 'needed_by' => '2026-10-09', 'owner' => 'Jon',
     'tags' => 'Assets,Hierarchy,Master data', 'requested_by' => 'Asset Management', 'sponsor' => 'Head of Asset Management',
     'summary' => 'Load the engineering asset hierarchy from the maintenance system into the lakehouse, with parent-child validation and a published slowly-changing dimension.',
     'created_at' => '2026-07-27 09:45:00', 'ready_at' => '2026-08-10 09:00:00'],

    ['ref' => 'WI-1050', 'title' => 'Exec scorecard', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 60, 'risk_weight' => 0.30, 'needed_by' => '2026-10-09', 'owner' => 'Ewan',
     'tags' => 'Reporting,Executive,Power BI', 'requested_by' => 'Executive Office', 'sponsor' => 'Chief Operating Officer',
     'summary' => 'A single executive scorecard replacing the monthly slide pack: safety, delivery, cost and people measures from the conformed layer, refreshed daily.',
     'created_at' => '2026-08-04 13:00:00', 'ready_at' => '2026-08-18 09:00:00'],

    ['ref' => 'WI-1051', 'title' => 'Customer 360 discovery', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_benefit', 'health' => null,
     'score' => 47, 'risk_weight' => 0.30, 'needed_by' => '2027-01-29',
     'tags' => 'Customer,Discovery', 'requested_by' => 'Sales Operations', 'sponsor' => 'Sales Director',
     'summary' => 'Discovery sprint for a customer 360 view across CRM, billing and service. Needs a benefit case before it can be scheduled.',
     'created_at' => '2026-08-19 11:30:00'],

    ['ref' => 'WI-1056', 'title' => 'Self-service semantic layer', 'type' => 'Project', 'size' => 'L', 'status' => 'draft', 'health' => null,
     'score' => 35, 'tags' => 'Self-service,Semantic layer', 'requested_by' => 'Data Platform', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Draft idea: a governed self-service semantic layer so analysts can build their own models without copying data out of the lakehouse.',
     'created_at' => '2026-08-26 15:10:00'],

    ['ref' => 'WI-1058', 'title' => 'Pipeline hardening', 'type' => 'Project', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 53, 'risk_weight' => 0.65, 'needed_by' => '2026-10-16', 'owner' => 'Ravi',
     'tags' => 'Reliability,Pipelines', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Retry, idempotency and alerting work across the twelve pipelines that caused the most out-of-hours calls in the last two quarters.',
     'created_at' => '2026-08-06 09:00:00', 'ready_at' => '2026-08-20 09:00:00'],

    ['ref' => 'WI-1062', 'title' => 'Marketing attribution feed', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_benefit', 'health' => null,
     'score' => 44, 'tags' => 'Marketing,Attribution', 'requested_by' => 'Marketing', 'sponsor' => 'Marketing Director',
     'summary' => 'Feed campaign and web analytics data into the lakehouse for multi-touch attribution. Benefit case with Marketing Finance still outstanding.',
     'created_at' => '2026-08-24 10:00:00'],

    ['ref' => 'WI-1064', 'title' => 'Warehouse slot optimisation', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_estimate', 'health' => null,
     'score' => 48, 'needed_by' => '2027-02-26',
     'tags' => 'Logistics,Optimisation', 'requested_by' => 'Logistics', 'sponsor' => 'Head of Logistics',
     'summary' => 'Model inbound dock slot allocation to reduce waiting time. Cannot be scheduled until a rough order of magnitude exists.',
     'created_at' => '2026-08-11 09:20:00', 'ready_at' => '2026-08-25 09:00:00'],

    ['ref' => 'WI-1065', 'title' => 'Supplier portal analytics', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_benefit', 'health' => null,
     'score' => 40, 'tags' => 'Supplier data,Analytics', 'requested_by' => 'Procurement', 'sponsor' => 'Head of Supply Chain', 'created_by' => $U['requester'],
     'summary' => 'Usage and onboarding analytics for the supplier portal. Waiting on Procurement to confirm the productivity benefit.',
     'created_at' => '2026-08-25 14:40:00'],

    ['ref' => 'WI-1066', 'title' => 'Cost allocation model rebuild', 'type' => 'Project', 'size' => 'C', 'custom_effort_days' => 115, 'status' => 'ready', 'health' => null,
     'score' => 70, 'risk_weight' => 0.50, 'needed_by' => '2027-03-31',
     'tags' => 'Finance,Cost allocation,Custom size', 'requested_by' => 'Finance', 'sponsor' => 'Finance Director',
     'summary' => 'Rebuild the group cost allocation model on the lakehouse. Effort is entered directly as a custom size (115 days) because no size class fits.',
     'created_at' => '2026-06-29 09:00:00', 'ready_at' => '2026-07-13 09:00:00'],

    ['ref' => 'WI-1067', 'title' => 'Master data stewardship workflow', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_estimate', 'health' => null,
     'score' => 46, 'tags' => 'Master data,Workflow', 'requested_by' => 'Data Governance', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Stewardship workflow for master data change requests: raise, review, approve, apply, audit. Awaiting an estimate.',
     'created_at' => '2026-08-27 11:00:00', 'ready_at' => '2026-09-01 09:00:00'],

    ['ref' => 'WI-1068', 'title' => 'Vendor risk scoring dashboard', 'type' => 'Project', 'size' => 'M', 'status' => 'needs_estimate', 'health' => null,
     'score' => 55, 'risk_weight' => 0.70, 'needed_by' => '2027-01-29',
     'tags' => 'Risk,Supplier data,Power BI', 'requested_by' => 'Procurement', 'sponsor' => 'Head of Supply Chain', 'created_by' => $U['requester'],
     'summary' => 'Vendor risk scoring dashboard combining supplier master data, spend concentration and financial health signals. Blocked behind WI-1042 and has no rough order of magnitude yet.',
     'created_at' => '2026-08-10 10:30:00', 'ready_at' => '2026-08-24 09:00:00'],

    ['ref' => 'WI-1071', 'title' => 'Zero-trust network segmentation', 'type' => 'Project', 'size' => 'L', 'status' => 'ready', 'health' => null,
     'score' => 52, 'risk_weight' => 0.80, 'needed_by' => '2027-03-31',
     'tags' => 'Security,Network,Platform', 'requested_by' => 'Information Security', 'sponsor' => 'Chief Information Security Officer',
     'summary' => 'Segment the data platform networks to the zero-trust target architecture: private endpoints, per-workload identities and explicit east-west rules.',
     'created_at' => '2026-08-17 09:00:00', 'ready_at' => '2026-09-01 09:00:00'],

    // ---- Small changes --------------------------------------------------------------
    ['ref' => 'WI-1041', 'title' => 'Sensor ingest backfill', 'type' => 'Small change', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 52, 'needed_by' => '2026-10-23', 'owner' => 'Amira',
     'tags' => 'Telemetry,Backfill', 'requested_by' => 'Fleet Operations', 'sponsor' => 'Director of Operations',
     'summary' => 'Backfill eleven months of sensor readings that were dropped when the old gateway certificate expired.',
     'created_at' => '2026-08-05 09:00:00', 'ready_at' => '2026-08-19 09:00:00'],

    ['ref' => 'WI-1045', 'title' => 'Streaming checkpoint recovery', 'type' => 'Small change', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 49, 'risk_weight' => 0.60, 'needed_by' => '2026-10-16', 'owner' => 'Ravi',
     'tags' => 'Streaming,Reliability', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Automatic checkpoint recovery for the four streaming jobs that currently need a manual restart after a cluster restart.',
     'created_at' => '2026-08-07 09:00:00', 'ready_at' => '2026-08-21 09:00:00'],

    ['ref' => 'WI-1046', 'title' => 'Data quality scorecard', 'type' => 'Small change', 'size' => 'M', 'status' => 'ready', 'health' => null,
     'score' => 42, 'needed_by' => '2026-11-20',
     'tags' => 'Data quality,Reporting', 'requested_by' => 'Data Governance', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Publish the existing data quality check results as a scorecard by domain and owner.',
     'created_at' => '2026-08-12 09:00:00', 'ready_at' => '2026-08-26 09:00:00'],

    ['ref' => 'WI-1047', 'title' => 'Ops dashboard', 'type' => 'Small change', 'size' => 'M', 'status' => 'scheduled', 'health' => 'at_risk',
     'score' => 51, 'needed_by' => '2026-09-11', 'owner' => 'Ewan',
     'tags' => 'Reporting,Operations,Power BI', 'requested_by' => 'Operations', 'sponsor' => 'Director of Operations',
     'summary' => 'Daily operations dashboard for depot performance. Re-estimated from 4 to 6 days after the design review added two extra pages.',
     'created_at' => '2026-08-10 09:00:00', 'ready_at' => '2026-08-24 09:00:00', 'started_at' => '2026-09-07'],

    ['ref' => 'WI-1048', 'title' => 'Cost reporting refresh', 'type' => 'Small change', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 39, 'needed_by' => '2026-10-02', 'owner' => 'Lena',
     'tags' => 'Finance,Reporting', 'requested_by' => 'Finance', 'sponsor' => 'Finance Director',
     'summary' => 'Move the cost reporting refresh to the new capacity and cut the window from 90 to 30 minutes.',
     'created_at' => '2026-08-13 09:00:00', 'ready_at' => '2026-08-27 09:00:00'],

    ['ref' => 'WI-1049', 'title' => 'Power BI capacity upgrade', 'type' => 'Small change', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 44, 'needed_by' => '2026-09-15', 'owner' => 'Ewan',
     'tags' => 'Power BI,Capacity,Platform', 'requested_by' => 'Reporting', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Move the reporting workspaces onto the larger Power BI capacity and re-point the gateways.',
     'created_at' => '2026-08-14 09:00:00', 'ready_at' => '2026-08-28 09:00:00'],

    ['ref' => 'WI-1052', 'title' => 'Monitoring alerts', 'type' => 'Small change', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 41, 'risk_weight' => 0.55, 'needed_by' => '2026-09-18', 'owner' => 'Ravi',
     'tags' => 'Monitoring,Reliability', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Alert rules and on-call routing for the overnight load. Lowest-priority planned item in Ravi'."'".'s window, so the first thing the engine looks at when an incident lands.',
     'created_at' => '2026-08-17 09:00:00', 'ready_at' => '2026-08-31 09:00:00'],

    ['ref' => 'WI-1053', 'title' => 'Notebook runtime upgrade', 'type' => 'Small change', 'size' => 'S', 'status' => 'draft', 'health' => null,
     'score' => 28, 'tags' => 'Databricks,Platform', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Draft: move the shared notebooks to the current Databricks runtime before the old one falls out of support.',
     'created_at' => '2026-08-28 09:00:00'],

    ['ref' => 'WI-1054', 'title' => 'Purge job for staging tables', 'type' => 'Small change', 'size' => 'S', 'status' => 'draft', 'health' => null,
     'score' => 24, 'tags' => 'Housekeeping,Storage', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Draft: scheduled purge of staging tables older than 30 days.',
     'created_at' => '2026-09-01 09:00:00'],

    ['ref' => 'WI-1055', 'title' => 'Terraform module refresh', 'type' => 'Small change', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 46, 'risk_weight' => 0.50, 'needed_by' => '2026-09-18', 'owner' => 'Priya',
     'tags' => 'Terraform,Platform', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Refresh the shared Terraform modules to the current provider versions so the WI-1042 workspace build does not inherit deprecated resources.',
     'created_at' => '2026-08-18 09:00:00', 'ready_at' => '2026-09-01 09:00:00'],

    ['ref' => 'WI-1057', 'title' => 'Payroll interface fix (duplicate postings)', 'type' => 'Small change', 'size' => 'S', 'status' => 'in_progress', 'health' => 'on_track',
     'score' => 72, 'risk_weight' => 0.70, 'needed_by' => '2026-09-09', 'owner' => 'Amira',
     'tags' => 'Payroll,Finance,Defect', 'requested_by' => 'HR Services', 'sponsor' => 'HR Director',
     'summary' => 'Stop the payroll interface posting duplicate journal lines when a run is re-submitted within the same day.',
     'created_at' => '2026-08-26 08:40:00', 'ready_at' => '2026-08-28 09:00:00', 'started_at' => '2026-09-07', 'progress_pct' => 55],

    ['ref' => 'WI-1059', 'title' => 'Conditional access policy update', 'type' => 'Small change', 'size' => 'S', 'status' => 'in_progress', 'health' => 'on_track',
     'score' => 43, 'risk_weight' => 0.60, 'needed_by' => '2026-09-08', 'owner' => 'Lena',
     'tags' => 'Security,Identity', 'requested_by' => 'Information Security', 'sponsor' => 'Chief Information Security Officer',
     'summary' => 'Apply the revised conditional access policy to the data platform service principals.',
     'created_at' => '2026-08-24 09:00:00', 'ready_at' => '2026-09-01 09:00:00', 'started_at' => '2026-09-07', 'progress_pct' => 60],

    ['ref' => 'WI-1060', 'title' => 'Lineage capture for ADF', 'type' => 'Small change', 'size' => 'M', 'status' => 'ready', 'health' => null,
     'score' => 37, 'needed_by' => '2026-12-11',
     'tags' => 'Lineage,Governance,Azure Data Factory', 'requested_by' => 'Data Governance', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Harvest pipeline lineage from Azure Data Factory into the catalogue automatically instead of by hand.',
     'created_at' => '2026-08-20 09:00:00', 'ready_at' => '2026-09-03 09:00:00'],

    ['ref' => 'WI-1061', 'title' => 'Lakehouse access review – Q3', 'type' => 'Small change', 'size' => 'M', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 58, 'risk_weight' => 0.75, 'needed_by' => '2026-09-14', 'owner' => 'Lena',
     'tags' => 'Security,Access review,Compliance', 'requested_by' => 'Information Security', 'sponsor' => 'Chief Information Security Officer',
     'summary' => 'Quarterly access review for the lakehouse workspaces: confirm or revoke every standing grant and evidence the result for audit. Depends on the identity export (WI-1036), which landed four days early.',
     'created_at' => '2026-08-03 09:00:00', 'ready_at' => '2026-08-17 09:00:00'],

    ['ref' => 'WI-1063', 'title' => 'HR leave feed into planning system', 'type' => 'Small change', 'size' => 'M', 'status' => 'needs_estimate', 'health' => null,
     'score' => 61, 'needed_by' => '2026-10-30',
     'tags' => 'HR,Integration,Availability', 'requested_by' => 'HR Services', 'sponsor' => 'HR Director',
     'summary' => 'Feed approved leave from the HR system into Dispatch so availability stops being maintained by hand. The current estimate is class 5, so it must be re-estimated before it can enter the committed window.',
     'created_at' => '2026-08-21 09:00:00', 'ready_at' => '2026-09-04 09:00:00'],

    ['ref' => 'WI-1069', 'title' => 'Data sharing with Group Finance', 'type' => 'Small change', 'size' => 'M', 'status' => 'needs_estimate', 'health' => null,
     'score' => 33, 'tags' => 'Sharing,Finance', 'requested_by' => 'Group Finance', 'sponsor' => 'Finance Director',
     'summary' => 'Share three curated finance datasets with the Group Finance tenant using Delta Sharing. No rough order of magnitude yet.',
     'created_at' => '2026-09-02 09:00:00'],

    ['ref' => 'WI-1070', 'title' => 'Archive legacy reporting server', 'type' => 'Small change', 'size' => 'M', 'status' => 'ready', 'health' => null,
     'score' => 38, 'risk_weight' => 0.45, 'needed_by' => '2026-12-18',
     'tags' => 'Decommission,Reporting,Azure', 'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Archive and switch off the last on-premises reporting server once the final four reports have been re-pointed.',
     'created_at' => '2026-08-24 09:00:00', 'ready_at' => '2026-09-07 09:00:00'],

    // ---- Service requests -----------------------------------------------------------
    ['ref' => 'SR-0212', 'title' => 'New workspace for asset analytics team', 'type' => 'Service request', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 40, 'needed_by' => '2026-09-17', 'owner' => 'Jon',
     'tags' => 'Workspace,Databricks', 'requested_by' => 'Asset Management', 'sponsor' => 'Head of Asset Management', 'created_by' => $U['requester'],
     'summary' => 'Create a Databricks workspace, catalogue and access groups for the new asset analytics team.',
     'created_at' => '2026-09-01 08:30:00', 'ready_at' => '2026-09-01 10:00:00'],

    ['ref' => 'SR-0213', 'title' => 'Add Power BI workspace for HR', 'type' => 'Service request', 'size' => 'S', 'status' => 'ready', 'health' => null,
     'score' => 31, 'needed_by' => '2026-09-25',
     'tags' => 'Workspace,Power BI', 'requested_by' => 'HR Services', 'sponsor' => 'HR Director', 'created_by' => $U['requester'],
     'summary' => 'New Power BI workspace and deployment pipeline for the HR reporting team.',
     'created_at' => '2026-09-04 09:10:00', 'ready_at' => '2026-09-04 11:00:00'],

    ['ref' => 'SR-0214', 'title' => 'Restore archived dataset', 'type' => 'Service request', 'size' => 'S', 'status' => 'needs_estimate', 'health' => null,
     'score' => 26, 'tags' => 'Restore,Storage', 'requested_by' => 'Finance', 'sponsor' => 'Finance Director', 'created_by' => $U['requester'],
     'summary' => 'Restore the 2023 statutory reporting extract from archive for an external audit question. Effort unknown until the archive tier is checked.',
     'created_at' => '2026-09-07 15:20:00'],

    ['ref' => 'SR-0215', 'title' => 'Report access for new starters', 'type' => 'Service request', 'size' => 'S', 'status' => 'scheduled', 'health' => 'on_track',
     'score' => 34, 'needed_by' => '2026-09-23', 'owner' => 'Ewan',
     'tags' => 'Access,Power BI', 'requested_by' => 'Operations', 'sponsor' => 'Director of Operations', 'created_by' => $U['requester'],
     'summary' => 'Grant report access to eleven new starters in the depot network and add them to the standing distribution.',
     'created_at' => '2026-09-03 09:00:00', 'ready_at' => '2026-09-03 10:30:00'],

    // ---- Incidents ------------------------------------------------------------------
    ['ref' => 'INC-4469', 'title' => 'Databricks job cluster start failures', 'type' => 'Incident', 'size' => 'M', 'status' => 'in_progress', 'health' => 'at_risk',
     'score' => 68, 'severity' => 'P3', 'risk_weight' => 0.70, 'needed_by' => '2026-09-10', 'owner' => 'Hana',
     'tags' => 'Databricks,Incident', 'requested_by' => 'Service Desk', 'sponsor' => 'Head of Data Platform',
     'summary' => 'Intermittent job cluster start failures in the shared pool since the runtime patch on 2 September.',
     'created_at' => '2026-09-03 07:45:00', 'started_at' => '2026-09-03', 'progress_pct' => 40],

    ['ref' => 'INC-4470', 'title' => 'Power BI gateway timeouts', 'type' => 'Incident', 'size' => 'S', 'status' => 'in_progress', 'health' => 'on_track',
     'score' => 74, 'severity' => 'P3', 'risk_weight' => 0.60, 'needed_by' => '2026-09-09', 'owner' => 'Ewan',
     'tags' => 'Power BI,Incident', 'requested_by' => 'Service Desk', 'sponsor' => 'Chief Data Officer',
     'summary' => 'Scheduled refreshes through the on-premises gateway time out roughly one run in four.',
     'created_at' => '2026-09-05 06:20:00', 'started_at' => '2026-09-07', 'progress_pct' => 30],

    ['ref' => 'INC-4471', 'title' => 'Nightly finance load failing since 06 Sep', 'type' => 'Incident', 'size' => 'M', 'status' => 'in_progress', 'health' => 'blocked',
     'score' => 95, 'severity' => 'P2', 'risk_weight' => 0.90, 'needed_by' => '2026-09-08', 'owner' => 'Ravi',
     'tags' => 'Finance,Incident,ADF,P2', 'requested_by' => 'Service Desk', 'sponsor' => 'Finance Director',
     'summary' => 'The nightly finance load has failed every run since Sunday 6 September. Blocked on a vendor case for the source system connector; the month-end close date is at risk.',
     'created_at' => '2026-09-06 21:40:00', 'started_at' => '2026-09-07', 'progress_pct' => 45],
];

foreach ($open as $o) addItem($conn, $o);

// -------------------------------------------------------------------------------------
// 2. DELIVERED WORK ITEMS — 46 items, Nov 2025 to Sep 2026.
//    Engineered so the per-size median of actual / most-likely is
//    S 0.98, M 1.07, L 1.18, C 1.32 (the web-08 calibration bars).
// -------------------------------------------------------------------------------------
// [ref, title, type, stamp, most-likely days, actual/likely ratio, delivered_at, owner]
$delivered = [
    // Large — median 1.18 across 9 items
    ['WI-0912', 'Asset register consolidation',        'Project', 'L', 30, 38 / 30,  '2025-11-21', 'Sam'],
    ['WI-0934', 'Finance GL extract rebuild',          'Project', 'L', 24, 0.95,     '2025-12-19', 'Sam'],
    ['WI-0951', 'Warehouse telemetry ingestion',       'Project', 'L', 28, 1.02,     '2026-01-30', 'Jon'],
    ['WI-0968', 'Customer consent store',              'Project', 'L', 20, 1.08,     '2026-02-27', 'Hana'],
    ['WI-0987', 'Customer master data hub',            'Project', 'L', 34, 41 / 34,  '2026-03-27', 'Sam'],
    ['WI-0995', 'Sales order pipeline migration',      'Project', 'L', 26, 1.12,     '2026-04-24', 'Hana'],
    ['WI-1004', 'Group reporting conformed layer',     'Project', 'L', 32, 1.18,     '2026-05-29', 'Sam'],
    ['WI-1019', 'Procurement spend cube',              'Project', 'L', 22, 1.24,     '2026-07-03', 'Ewan'],
    ['WI-1027', 'Site operations lakehouse',           'Project', 'L', 18, 1.45,     '2026-08-14', 'Priya'],
    // Custom — median 1.32 across 4 items
    ['WI-0925', 'ERP migration data workstream',       'Project', 'C', 80, 1.15,     '2025-12-05', 'Sam'],
    ['WI-0972', 'Regulatory reporting programme',      'Project', 'C', 95, 1.32,     '2026-03-06', 'Amira'],
    ['WI-1008', 'Group data warehouse decommission',   'Project', 'C', 70, 1.32,     '2026-06-12', 'Priya'],
    ['WI-1024', 'Multi-region DR build-out',           'Project', 'C', 60, 1.55,     '2026-07-31', 'Priya'],
    // Medium — median 1.07 across 19 items
    ['WI-0908', 'Nightly load retry logic',            'Small change', 'M',  6, 0.72,      '2025-11-07', 'Ravi'],
    ['WI-0917', 'Supplier feed validation',            'Small change', 'M',  5, 0.80,      '2025-11-28', 'Amira'],
    ['WI-0929', 'Cost centre mapping refresh',         'Small change', 'M',  8, 0.86,      '2025-12-12', 'Amira'],
    ['WI-0941', 'Databricks workspace hardening',      'Project',      'M', 10, 0.90,      '2026-01-16', 'Priya'],
    ['INC-4402', 'Month-end load outage',              'Incident',     'M',  4, 0.95,      '2026-01-23', 'Ravi'],
    ['WI-0957', 'Payroll extract rebuild',             'Small change', 'M',  7, 0.99,      '2026-02-06', 'Amira'],
    ['WI-0963', 'HR dimension conformance',            'Project',      'M',  9, 1.02,      '2026-02-20', 'Sam'],
    ['WI-0979', 'Inventory snapshot fact',             'Project',      'M', 12, 1.05,      '2026-03-13', 'Sam'],
    ['WI-0983', 'Alerting runbook automation',         'Small change', 'M',  6, 1.06,      '2026-03-20', 'Ravi'],
    ['WI-0991', 'Purchase order fact table',           'Project',      'M', 11, 1.07,      '2026-04-10', 'Sam'],
    ['WI-0999', 'Contract dimension load',             'Project',      'M', 10, 1.10,      '2026-04-30', 'Amira'],
    ['INC-4428', 'Gateway certificate expiry',         'Incident',     'M',  5, 1.14,      '2026-05-08', 'Ravi'],
    ['WI-1007', 'Finance close dashboard',             'Small change', 'M',  8, 1.18,      '2026-05-22', 'Ewan'],
    ['WI-1011', 'Product hierarchy loader',            'Project',      'M', 14, 15 / 14,   '2026-06-19', 'Sam'],
    ['WI-1015', 'Vendor onboarding feed',              'Project',      'M', 13, 1.22,      '2026-06-26', 'Jon'],
    ['WI-1021', 'Asset depreciation model',            'Project',      'M',  9, 1.28,      '2026-07-17', 'Sam'],
    ['WI-1029', 'Energy usage mart',                   'Project',      'M', 12, 1.35,      '2026-08-21', 'Hana'],
    ['INC-4455', 'Cluster autoscaling failure',        'Incident',     'M',  6, 1.42,      '2026-08-28', 'Ravi'],
    ['WI-1034', 'Quality rules engine pilot',          'Project',      'M',  7, 1.50,      '2026-09-04', 'Amira'],
    // Small — median 0.98 across 14 items
    ['SR-0181', 'Add analyst to workspace',            'Service request', 'S', 2, 0.70, '2025-11-14', 'Jon'],
    ['WI-0921', 'Fix duplicate rows in stock view',    'Small change',    'S', 2, 0.75, '2025-12-05', 'Amira'],
    ['SR-0190', 'Restore deleted dataset',             'Service request', 'S', 1, 0.80, '2026-01-09', 'Ravi'],
    ['WI-0946', 'Retire legacy linked service',        'Small change',    'S', 3, 0.85, '2026-01-23', 'Jon'],
    ['INC-4411', 'Power BI refresh failure',           'Incident',        'S', 2, 0.88, '2026-02-13', 'Ewan'],
    ['SR-0196', 'New Power BI workspace',              'Service request', 'S', 2, 0.92, '2026-03-06', 'Ewan'],
    ['WI-0975', 'Key vault secret rotation',           'Small change',    'S', 2, 0.98, '2026-03-20', 'Lena'],
    ['WI-1002', 'Add audit columns to dim tables',     'Small change',    'S', 3, 0.98, '2026-05-15', 'Sam'],
    ['SR-0203', 'Access for new starters',             'Service request', 'S', 2, 1.05, '2026-06-05', 'Ewan'],
    ['WI-1013', 'Notebook lint and format rules',      'Small change',    'S', 2, 1.10, '2026-06-26', 'Hana'],
    ['INC-4440', 'SQL endpoint throttling',            'Incident',        'S', 2, 1.15, '2026-07-10', 'Ravi'],
    ['SR-0208', 'Dataset export for audit',            'Service request', 'S', 1, 1.20, '2026-07-24', 'Ravi'],
    ['WI-1031', 'Decommission old ADF triggers',       'Small change',    'S', 3, 1.30, '2026-08-28', 'Jon'],
    ['WI-1036', 'Identity export for access review',   'Small change',    'S', 2, 1.40, '2026-09-04', 'Lena'],
];

$sevFor = ['INC-4402' => 'P1', 'INC-4428' => 'P2', 'INC-4455' => 'P3', 'INC-4411' => 'P3', 'INC-4440' => 'P4'];
$estSpec = [];   // ref => [optimistic, likely, pessimistic, class, method]
foreach ($delivered as $d) {
    [$ref, $title, $type, $stamp, $likely, $ratio, $del, $owner] = $d;
    $actual  = round($likely * $ratio, 2);
    $created = date('Y-m-d', strtotime($del . ' -' . (30 + ($likely * 2)) . ' day'));
    $started = date('Y-m-d', strtotime($del . ' -' . (14 + (int)$likely) . ' day'));
    addItem($conn, [
        'ref' => $ref, 'title' => $title, 'type' => $type, 'size' => $stamp,
        'custom_effort_days' => $stamp === 'C' ? $likely : null,
        'status' => 'delivered', 'health' => null, 'progress_pct' => 100,
        'score' => null, 'terms' => null,
        'severity' => $sevFor[$ref] ?? null,
        'owner' => $owner, 'tags' => 'Delivered',
        'summary' => $title . ' — delivered on ' . date('j M Y', strtotime($del)) . '.',
        'requested_by' => 'Data Platform', 'sponsor' => 'Head of Data Platform',
        'needed_by' => $del, 'created_at' => $created . ' 09:00:00', 'ready_at' => $created . ' 15:00:00',
        'started_at' => $started, 'delivered_at' => $del, 'actual_effort_days' => $actual,
        'updated_at' => $del . ' 17:00:00',
    ]);
    $estSpec[$ref] = [round($likely * 0.8, 2), $likely, round($likely * 1.3, 2), $stamp === 'S' ? 2 : 3, 'three_point',
                      date('Y-m-d', strtotime($created)) . ' 11:00:00'];
}

// -------------------------------------------------------------------------------------
// 3. SKILL REQUIREMENTS — the chips shown on the pipeline and the work-item screen.
// -------------------------------------------------------------------------------------
$skillReq = [
    // ref => [ [skill, min proficiency, effort days, note], ... ]
    'WI-1042' => [['Databricks', 3, 14, null], ['Terraform', 3, 6, null], ['Data modelling', 3, 10, null],
                  ['Azure Data Factory', 2, 4, null], ['Procurement domain', 1, null, 'Working knowledge is enough']],
    'WI-1038' => [['Event streaming', 3, 20, null], ['Python', 3, 18, null], ['Azure', 2, 10, null]],
    'INC-4471' => [['SQL', 3, 2.5, null], ['Azure Data Factory', 2, 1.5, null]],
    'WI-1063' => [['API integration', 2, 6, null], ['Python', 2, 5, null]],
    'WI-1033' => [['Data modelling', 3, 8, null], ['SQL', 3, 7, null], ['Azure', 2, 3, null]],
    'WI-1061' => [['Security', 3, 4, null], ['Azure', 2, 3, null]],
    'SR-0212' => [['Databricks', 2, 1.5, null], ['Azure', 2, 1, null]],
    'WI-1066' => [['Data modelling', 3, 45, null], ['Databricks', 3, 40, null], ['SQL', 3, 30, null]],
    'WI-1057' => [['SQL', 3, 2, null], ['API integration', 2, 1, null]],
    'WI-1049' => [['Power BI', 3, 1.5, null], ['Azure', 2, 1, null]],
    'WI-1068' => [['Power BI', 3, null, null], ['Data modelling', 2, null, null]],
    'WI-1070' => [['Azure', 2, 6, null], ['Security', 2, 5, null]],
    'WI-1040' => [['Data modelling', 3, 16, null], ['SQL', 3, 12, null], ['Power BI', 2, 6, null]],
    'WI-1044' => [['Data modelling', 3, 8, null], ['Python', 2, 5, null]],
    'WI-1047' => [['Power BI', 3, 4, null], ['SQL', 2, 2, null]],
    'WI-1050' => [['Power BI', 3, 7, null], ['Data modelling', 2, 4, null]],
    'WI-1052' => [['Azure', 2, 1.5, null], ['Python', 2, 1, null]],
    'WI-1055' => [['Terraform', 3, 2.5, null]],
    'WI-1058' => [['Python', 3, 6, null], ['Azure Data Factory', 2, 4, null]],
    'WI-1059' => [['Security', 3, 2, null]],
    'WI-1071' => [['Security', 3, 20, null], ['Azure', 3, 14, null], ['Terraform', 3, 8, null]],
    'SR-0215' => [['Power BI', 2, 1.5, null]],
    'WI-1039' => [['API integration', 3, 6, null], ['Data modelling', 2, 4, null]],
    'WI-1041' => [['Databricks', 2, 5, null], ['SQL', 2, 3, null]],
    'WI-1043' => [['Azure', 2, 6, null], ['Data modelling', 2, 4, null]],
    'WI-1045' => [['Event streaming', 3, 5, null], ['Python', 2, 3, null]],
    'WI-1046' => [['SQL', 2, 5, null], ['Power BI', 2, 3, null]],
    'WI-1048' => [['Power BI', 2, 1.5, null]],
    'WI-1060' => [['Azure Data Factory', 3, 5, null], ['Python', 2, 3, null]],
    'WI-1062' => [['API integration', 2, null, null], ['Python', 2, null, null]],
    'WI-1064' => [['Python', 3, null, null], ['Data modelling', 2, null, null]],
    'WI-1065' => [['Power BI', 2, null, null]],
    'WI-1067' => [['Data modelling', 3, null, null], ['API integration', 2, null, null]],
    'WI-1069' => [['Databricks', 2, null, null], ['Security', 2, null, null]],
    'WI-1051' => [['Data modelling', 3, null, null], ['SQL', 2, null, null]],
    'WI-1053' => [['Databricks', 2, null, null]],
    'WI-1054' => [['SQL', 2, null, null]],
    'WI-1056' => [['Data modelling', 3, null, null], ['Power BI', 3, null, null]],
    'SR-0213' => [['Power BI', 2, 1, null]],
    'SR-0214' => [['Azure', 2, null, null]],
    'INC-4469' => [['Databricks', 3, 3, null], ['Azure', 2, 1, null]],
    'INC-4470' => [['Power BI', 2, 1, null], ['Azure', 2, 1, null]],
];
$N['skill_requirements'] = 0;
foreach ($skillReq as $ref => $rows) {
    foreach ($rows as $r) {
        xid($conn, 'skill_requirements', ['work_item_id' => $I[$ref], 'skill_id' => $S[$r[0]],
            'min_proficiency' => $r[1], 'effort_days' => $r[2], 'note' => $r[3]]);
        $N['skill_requirements']++;
    }
}

// -------------------------------------------------------------------------------------
// 4. TASKS — the seven tasks behind the WI-1042 roll-up estimate (25 / 32 / 45).
// -------------------------------------------------------------------------------------
$tasks1042 = [
    ['Source discovery and API review',            3, 'Data modelling',      'done'],
    ['Landing and ingest pipelines (ADF)',         5, 'Azure Data Factory',  'todo'],
    ['Survivorship and match rules',               6, 'Data modelling',      'todo'],
    ['Databricks transformation build',            8, 'Databricks',          'todo'],
    ['Terraform workspace and access',             4, 'Terraform',           'todo'],
    ['Publish to Finance and Procurement models',  3, 'Power BI',            'todo'],
    ['Testing and handover',                       3, null,                  'todo'],
];
$N['tasks'] = 0; $rollup = 0;
foreach ($tasks1042 as $i => $t) {
    xid($conn, 'tasks', ['work_item_id' => $I['WI-1042'], 'title' => $t[0], 'size_class_id' => null,
        'effort_days' => $t[1], 'skill_id' => $t[2] ? $S[$t[2]] : null, 'sequence' => $i + 1, 'status' => $t[3]]);
    $rollup += $t[1]; $N['tasks']++;
}

// -------------------------------------------------------------------------------------
// 5. DEPENDENCIES
// -------------------------------------------------------------------------------------
$deps = [
    ['WI-1033', 'WI-1042', 'finish_start', null],           // contract DQ rules must land first
    ['WI-1042', 'WI-1068', 'finish_start', null],           // supplier master unblocks vendor risk
    ['WI-1036', 'WI-1061', 'finish_start', '2026-09-04'],   // identity export cleared four days early
    ['WI-1055', 'WI-1042', 'soft',         null],           // Terraform modules refreshed first
];
$N['dependencies'] = 0;
foreach ($deps as $d) {
    xid($conn, 'dependencies', ['workspace_id' => $W, 'from_work_item_id' => $I[$d[0]],
        'to_work_item_id' => $I[$d[1]], 'type' => $d[2], 'cleared_at' => $d[3]]);
    $N['dependencies']++;
}

// -------------------------------------------------------------------------------------
// 6. ESTIMATES
//    WI-1042 carries three versions (web-08). Every other item that shows a ROM range
//    carries a single latest estimate; the six "needs estimate" items carry none, apart
//    from WI-1063 whose class-5 guess is too poor to schedule against.
// -------------------------------------------------------------------------------------
$N['estimates'] = 0;
$est = function (array $c) use ($conn, &$N) { xid($conn, 'estimates', $c); $N['estimates']++; };

// --- WI-1042 v1: size class only, at intake
$est(['work_item_id' => $I['WI-1042'], 'version' => 1, 'method' => 'size', 'optimistic' => 16, 'likely' => 30, 'pessimistic' => 60,
      'estimate_class' => 5, 'day_rate' => 700, 'assumptions' => 'Sized from the Large size class (16-60 days) at intake. No design work done.',
      'reason' => 'at intake', 'author_user_id' => $U['ben'], 'author_name' => 'Ben A.', 'created_at' => '2026-08-03 09:40:00']);
// --- WI-1042 v2: task roll-up from the seven tasks
$est(['work_item_id' => $I['WI-1042'], 'version' => 2, 'method' => 'rollup', 'optimistic' => 25, 'likely' => $rollup, 'pessimistic' => 45,
      'estimate_class' => 4, 'day_rate' => 700, 'assumptions' => 'Rolled up from the seven delivery tasks. Assumes the ERP extract is reusable from WI-0987.',
      'reason' => 'task roll-up from 7 tasks', 'author_user_id' => $U['Sam'], 'author_name' => 'Sam Doyle', 'created_at' => '2026-08-21 14:10:00']);
// --- WI-1042 v3: three-point, the current estimate
$est(['work_item_id' => $I['WI-1042'], 'version' => 3, 'method' => 'three_point', 'optimistic' => 28, 'likely' => 36, 'pessimistic' => 52,
      'estimate_class' => 3, 'day_rate' => 700,
      'assumptions' => 'Source systems expose existing APIs; no changes to the ERP. Survivorship rules agreed with Procurement by 18 Sep. Excludes historical back-fill beyond 24 months.',
      'reason' => 'after design review widened Terraform scope',
      'skill_split' => j([
          ['skill_id' => $S['Databricks'],         'label' => 'Databricks',         'days' => 14],
          ['skill_id' => $S['Data modelling'],     'label' => 'Data modelling',     'days' => 10],
          ['skill_id' => $S['Terraform'],          'label' => 'Terraform',          'days' => 6],
          ['skill_id' => $S['Azure Data Factory'], 'label' => 'Azure Data Factory', 'days' => 4],
          ['skill_id' => null,                     'label' => 'Testing & handover', 'days' => 3],
      ]),
      'author_user_id' => $U['Sam'], 'author_name' => 'Sam Doyle', 'created_at' => '2026-09-04 16:45:00']);

// --- latest estimates for the rest of the open pipeline (ROM ranges per web-02)
$openEst = [
    // ref          opt   likely  pess  class  author          created              reason
    'WI-1038'  => [40,   48,    60,   3, 'Priya', '2026-06-10 10:00:00', 'design complete'],
    'INC-4471' => [3,     4,     6,   4, 'Ravi',  '2026-09-07 08:15:00', 'triage sizing'],
    'WI-1033'  => [15,   18,    24,   3, 'Sam',   '2026-07-24 11:00:00', 'after rules workshop'],
    'WI-1061'  => [6,     7,     9,   2, 'Lena',  '2026-08-14 09:30:00', 'same shape as the Q2 review'],
    'SR-0212'  => [2,   2.5,     3,   2, 'Jon',   '2026-09-01 09:20:00', 'standard workspace build'],
    'WI-1057'  => [2,     3,     4,   3, 'Amira', '2026-08-27 10:00:00', 'defect reproduced'],
    'WI-1049'  => [2,   2.5,     3,   2, 'Ewan',  '2026-08-26 09:00:00', 'capacity move, no report changes'],
    'WI-1066'  => [90, 115,    140,   4, 'Sam',   '2026-07-10 15:00:00', 'custom size entered directly'],
    'WI-1070'  => [10,   11,    12,   3, 'Lena',  '2026-09-02 09:00:00', 'four reports left to re-point'],
    'WI-1040'  => [26,   32,    41,   3, 'Sam',   '2026-05-29 14:00:00', 'after data mart design'],
    'WI-1044'  => [8,    11,    15,   3, 'Jon',   '2026-08-07 09:00:00', 'hierarchy depth confirmed'],
    'WI-1047'  => [5,     6,     8,   3, 'Ewan',  '2026-09-07 11:05:00', 're-estimated from 4 to 6 days after design review'],
    'WI-1050'  => [7,     9,    13,   3, 'Ewan',  '2026-08-17 09:00:00', 'page list agreed'],
    'WI-1052'  => [1.5,   2,     3,   2, 'Ravi',  '2026-08-28 09:00:00', 'alert rules only'],
    'WI-1055'  => [2,   2.5,     4,   3, 'Priya', '2026-08-31 09:00:00', 'provider upgrade path checked'],
    'WI-1058'  => [9,    12,    16,   3, 'Ravi',  '2026-08-19 09:00:00', 'twelve pipelines in scope'],
    'WI-1059'  => [1,   1.5,     2,   2, 'Lena',  '2026-08-31 09:00:00', 'policy change only'],
    'WI-1039'  => [8,    11,    15,   3, 'Jon',   '2026-07-17 09:00:00', 'after API contract review'],
    'WI-1041'  => [5,     7,    10,   3, 'Amira', '2026-08-18 09:00:00', 'backfill volume measured'],
    'WI-1043'  => [10,   13,    18,   4, 'Ewan',  '2026-08-03 09:00:00', 'four domains, rough'],
    'WI-1045'  => [4,     6,     9,   3, 'Ravi',  '2026-08-20 09:00:00', 'four streaming jobs'],
    'WI-1046'  => [4,     6,     8,   3, 'Amira', '2026-08-25 09:00:00', 'reuses existing checks'],
    'WI-1048'  => [1.5,   2,     3,   2, 'Lena',  '2026-08-26 09:00:00', 'capacity move'],
    'WI-1060'  => [5,     7,    10,   3, 'Jon',   '2026-09-02 09:00:00', 'connector available'],
    'WI-1071'  => [22,   30,    44,   4, 'Lena',  '2026-08-31 09:00:00', 'target architecture agreed, build not designed'],
    'WI-1051'  => [6,     9,    14,   4, 'Sam',   '2026-08-19 09:00:00', 'discovery sprint only'],
    'WI-1062'  => [7,    10,    15,   4, 'Jon',   '2026-08-24 09:00:00', 'rough, pending benefit case'],
    'WI-1065'  => [5,     8,    12,   4, 'Ewan',  '2026-08-25 09:00:00', 'rough, pending benefit case'],
    'WI-1053'  => [1,     2,     3,   4, 'Priya', '2026-08-28 09:00:00', 'draft sizing'],
    'WI-1054'  => [0.5,   1,     2,   4, 'Ravi',  '2026-09-01 09:00:00', 'draft sizing'],
    'WI-1056'  => [20,   34,    55,   5, 'Sam',   '2026-08-26 09:00:00', 'draft sizing, scope not agreed'],
    'SR-0213'  => [1,   1.5,     2,   2, 'Ewan',  '2026-09-04 09:20:00', 'standard workspace build'],
    'SR-0215'  => [1,   1.5,     2,   2, 'Ewan',  '2026-09-03 09:10:00', 'eleven starters'],
    'INC-4469' => [2,     3,     5,   4, 'Hana',  '2026-09-03 08:00:00', 'triage sizing'],
    'INC-4470' => [1,     2,     3,   4, 'Ewan',  '2026-09-05 07:00:00', 'triage sizing'],
    // class 5 guess — too poor to schedule against, so WI-1063 still reads "needs estimate"
    'WI-1063'  => [8,    11,    14,   5, 'Jon',   '2026-09-04 09:00:00', 'class 5 guess; must be re-estimated before the committed window'],
];
foreach ($openEst as $ref => $e) {
    $est(['work_item_id' => $I[$ref], 'version' => 1, 'method' => 'three_point',
          'optimistic' => $e[0], 'likely' => $e[1], 'pessimistic' => $e[2], 'estimate_class' => $e[3], 'day_rate' => 700,
          'assumptions' => 'Blended day rate £700. No third-party licence costs assumed.',
          'reason' => $e[6], 'author_user_id' => $U[$e[4]], 'author_name' => $e[4], 'created_at' => $e[5]]);
}
// --- one estimate per delivered item (drives the calibration chart)
foreach ($estSpec as $ref => $e) {
    $est(['work_item_id' => $I[$ref], 'version' => 1, 'method' => $e[4],
          'optimistic' => $e[0], 'likely' => $e[1], 'pessimistic' => $e[2], 'estimate_class' => $e[3], 'day_rate' => 700,
          'assumptions' => 'Blended day rate £700.', 'reason' => 'baseline at scheduling',
          'author_user_id' => $U['ben'], 'author_name' => 'Ben A.', 'created_at' => $e[5]]);
}

// -------------------------------------------------------------------------------------
// 7. BENEFITS — 31 benefits across 24 items (web-09).
//    Items in the committed/planned window total £1,448,000 a year.
//    Two benefits are at risk (£30k + £65k = £95k).
// -------------------------------------------------------------------------------------
$benefitRows = [
    // ref, type, annual value, confidence, realisation_from, status, owner name, narrative
    ['WI-1038', 'revenue',        340000, 'high',   '2026-10-01', 'in_flight', 'Fleet Operations',  'Uplift from telemetry-based service packages sold to fleet customers.'],
    ['WI-1042', 'cost_avoidance', 140000, 'medium', '2027-01-01', 'in_flight', 'Finance',           'Cost avoidance - 3 reconciliations retired.'],
    ['WI-1042', 'productivity',    55000, 'medium', '2027-01-01', 'in_flight', 'Finance',           'Productivity - Procurement analysts no longer maintain the supplier spreadsheet.'],
    ['WI-1042', 'risk_reduction',  15000, 'medium', '2027-01-01', 'in_flight', 'Finance',           'Risk reduction - duplicate vendor payments.'],
    ['WI-1033', 'risk_reduction', 120000, 'high',   '2026-10-01', 'in_flight', 'Commercial',        'Contract exposure found earlier through enforced data quality rules.'],
    ['WI-1040', 'productivity',   160000, 'high',   '2026-10-01', 'realising', 'Finance',           'Month-end close effort cut by four analyst days per cycle.'],
    ['WI-1057', 'risk_reduction',  30000, 'high',   '2026-07-01', 'at_risk',   'HR Services',       'Duplicate payroll postings corrected at source rather than by journal.'],
    ['WI-1049', 'cost_avoidance',  18000, 'medium', '2026-10-01', 'planned',   'Reporting',         'Avoids a second premium capacity for the reporting workspaces.'],
    ['WI-1044', 'cost_avoidance',  90000, 'medium', '2026-10-01', 'planned',   'Asset Management',  'Manual hierarchy maintenance retired across three teams.'],
    ['WI-1039', 'productivity',    85000, 'medium', '2027-01-01', 'planned',   'Data Governance',   'Four hand-maintained code lists replaced by one service.'],
    ['WI-1041', 'cost_avoidance',  40000, 'medium', '2026-10-01', 'planned',   'Fleet Operations',  'Avoids re-running the sensor capture exercise manually.'],
    ['WI-1043', 'cost_avoidance',  75000, 'low',    '2027-01-01', 'planned',   'Data Governance',   'Discovery effort reduced across the four remaining domains.'],
    ['WI-1045', 'risk_reduction',  35000, 'medium', '2026-10-01', 'planned',   'Data Platform',     'Out-of-hours restarts removed for the streaming jobs.'],
    ['WI-1047', 'productivity',    50000, 'high',   '2026-10-01', 'planned',   'Operations',        'Depot supervisors stop rebuilding the daily pack by hand.'],
    ['WI-1050', 'productivity',   110000, 'medium', '2027-01-01', 'planned',   'Executive Office',  'Monthly executive slide pack replaced by a live scorecard.'],
    ['WI-1058', 'risk_reduction',  65000, 'medium', '2027-01-01', 'at_risk',   'Data Platform',     'Fewer failed overnight loads; the benefit slips a quarter if the work moves again.'],
    ['WI-1058', 'compliance',      20000, 'medium', '2027-01-01', 'planned',   'Data Platform',     'Evidence of pipeline controls for the annual audit.'],
    // unscheduled pipeline
    ['WI-1063', 'productivity',    45000, 'medium', '2026-10-01', 'planned',   'HR Services',       'Availability maintained automatically instead of by hand.'],
    ['WI-1066', 'cost_avoidance', 480000, 'medium', '2027-04-01', 'planned',   'Finance',           'Retires the licensed allocation engine and its support contract.'],
    ['WI-1066', 'productivity',   120000, 'medium', '2027-04-01', 'planned',   'Finance',           'Allocation cycle cut from nine days to two.'],
    ['WI-1068', 'compliance',      95000, 'low',    '2027-04-01', 'planned',   'Procurement',       'Evidence for the supplier due-diligence obligation.'],
    ['WI-1070', 'cost_avoidance',  22000, 'medium', '2027-01-01', 'planned',   'Data Platform',     'Hosting and support for the legacy reporting server retired.'],
    ['WI-1071', 'risk_reduction', 140000, 'medium', '2027-04-01', 'planned',   'Information Security', 'Lateral movement risk reduced across the platform networks.'],
    ['WI-1071', 'compliance',      55000, 'medium', '2027-04-01', 'planned',   'Information Security', 'Closes the outstanding segmentation finding.'],
    // delivered
    ['WI-0987', 'cost_avoidance', 180000, 'high',   '2026-04-01', 'realised',  'Finance',           'Customer reconciliation spreadsheets retired.'],
    ['WI-0987', 'productivity',    65000, 'high',   '2026-04-01', 'realised',  'Finance',           'Data stewards spend less time on duplicate resolution.'],
    ['WI-0912', 'cost_avoidance', 120000, 'high',   '2026-01-01', 'realised',  'Asset Management',  'Two asset register extracts decommissioned.'],
    ['WI-1011', 'productivity',    60000, 'high',   '2026-07-01', 'realising', 'Commercial',        'Product hierarchy maintained once, used everywhere.'],
    ['WI-1011', 'cost_avoidance',  25000, 'high',   '2026-07-01', 'realising', 'Commercial',        'Third-party hierarchy feed cancelled.'],
    ['WI-1036', 'risk_reduction',  40000, 'medium', '2026-10-01', 'planned',   'Information Security', 'Standing access grants reviewed on a schedule rather than ad hoc.'],
    ['WI-1004', 'productivity',    70000, 'high',   '2026-07-01', 'realised',  'Finance',           'Group reporting pack built from one conformed layer.'],
];
$benefitIds = [];   // index => benefit id, with annual value and realisation_from for the realisation loop
$N['benefits'] = 0;
foreach ($benefitRows as $b) {
    $id = xid($conn, 'benefits', ['workspace_id' => $W, 'work_item_id' => $I[$b[0]], 'type' => $b[1],
        'annual_value' => $b[2], 'currency' => 'GBP', 'confidence' => $b[3], 'qualitative_scale' => null,
        'realisation_from' => $b[4], 'owner_person_id' => null, 'owner_name' => $b[6], 'narrative' => $b[7],
        'status' => $b[5], 'realised_value' => in_array($b[5], ['realised', 'realising'], true) ? round($b[2] * 0.6, 2) : null,
        'created_at' => '2026-08-01 09:00:00']);
    $benefitIds[] = ['id' => $id, 'value' => $b[2], 'from' => $b[4]];
    $N['benefits']++;
}

// -------------------------------------------------------------------------------------
// 8. BENEFIT REALISATIONS — Q1 2026 to Q2 2027. Realised 2026 rows total £380,000.
// -------------------------------------------------------------------------------------
$quarters = [
    // label,     quarter end,  planned total, realised total (null = not yet confirmed)
    ['Q1 2026', '2026-03-31',  60000,  45000],
    ['Q2 2026', '2026-06-30', 150000, 130000],
    ['Q3 2026', '2026-09-30', 220000, 205000],
    ['Q4 2026', '2026-12-31', 300000,   null],
    ['Q1 2027', '2027-03-31', 380000,   null],
    ['Q2 2027', '2027-06-30', 450000,   null],
];
$N['benefit_realisations'] = 0;
foreach ($quarters as $q) {
    [$label, $qEnd, $planTotal, $realTotal] = $q;
    $eligible = array_values(array_filter($benefitIds, fn($b) => $b['from'] <= $qEnd));
    if (!$eligible) $eligible = [$benefitIds[0]];
    $weight = array_sum(array_column($eligible, 'value'));
    $planLeft = $planTotal; $realLeft = $realTotal;
    $n = count($eligible);
    foreach ($eligible as $k => $b) {
        $last = ($k === $n - 1);
        $plan = $last ? $planLeft : round($planTotal * $b['value'] / $weight, 2);
        $real = $realTotal === null ? null : ($last ? $realLeft : round($realTotal * $b['value'] / $weight, 2));
        $planLeft = round($planLeft - $plan, 2);
        if ($realTotal !== null) $realLeft = round($realLeft - $real, 2);
        xid($conn, 'benefit_realisations', ['benefit_id' => $b['id'], 'quarter' => $label,
            'planned_value' => $plan, 'realised_value' => $real,
            'confirmed_by' => $real === null ? null : $U['finance'],
            'confirmed_at' => $real === null ? null : date('Y-m-d', strtotime($qEnd)) . ' 16:00:00']);
        $N['benefit_realisations']++;
    }
}

echo "Work items, estimates and benefits done.\n";

require __DIR__ . '/seed_demo_plan.php';   // plan versions, assignments, proposals, reporting rows
