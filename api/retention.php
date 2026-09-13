<?php
// Data retention (ADM-05, NFR-DATA-02).
//   get                          -> the policy and what is currently older than it
//   save{plan_history_months, audit_retention_years}   (admin)
//   preview                      -> exactly what a purge would remove, removing nothing
//   purge{confirm:true}          (admin, or CLI via cron_retention.php)
//
// Two retention periods, because the two bodies of data answer to different rules. Plan
// history is operational: 24 months by default, and past that a superseded plan version is
// of no use to anyone. The audit trail is a compliance record: 7 years by default, and it
// is trimmed separately and far more slowly.
//
// What is never purged: the committed plan (whatever its age — the team is working to it),
// any plan version a proposal still references, and work items, people, benefits or
// estimates. This removes *history*, not the record of what the team does.
require_once __DIR__ . '/db_connect.php';

/** Resolve the cut-off dates for a workspace. */
function retention_windows($conn, $wsId) {
    $ws = row($conn, "SELECT plan_history_months, audit_retention_years, retention_last_run_at FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $planMonths = max(1, (int)($ws['plan_history_months'] ?? 24));
    $auditYears = max(1, (int)($ws['audit_retention_years'] ?? 7));
    return [
        'plan_history_months' => $planMonths,
        'audit_retention_years' => $auditYears,
        'plan_cutoff' => date('Y-m-d', strtotime(today() . " -$planMonths months")),
        'audit_cutoff' => date('Y-m-d', strtotime(today() . " -$auditYears years")),
        'last_run_at' => $ws['retention_last_run_at'] ?? null,
    ];
}

/**
 * What is older than the policy. Returns counts only; nothing is removed.
 *
 * A plan version is purgeable when it is superseded or discarded, older than the cut-off,
 * and not referenced by any proposal that still exists. The committed version is excluded
 * whatever its age, and so is the newest superseded one — restoring the plan you were on
 * last week is a real need, and a workspace that has been quiet for two years should not
 * lose its only fallback.
 */
function retention_scan($conn, $wsId) {
    $w = retention_windows($conn, $wsId);
    // Each half needs its own ORDER BY: in a UNION the trailing ORDER BY binds to the whole
    // result, so a bare TOP 1 in the second arm picks an arbitrary row — which silently
    // purged the very fallback version this is meant to keep.
    $keepIds = array_map(fn($r) => (int)$r['id'], rows($conn,
        "SELECT id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed'
         UNION
         SELECT id FROM (SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'superseded' ORDER BY version_no DESC, id DESC) newest",
        [$wsId, $wsId]));
    $keepSql = $keepIds ? ' AND pv.id NOT IN (' . implode(',', $keepIds) . ')' : '';

    $versions = rows($conn, "SELECT pv.id, pv.version_no, pv.status, pv.generated_at
        FROM dbo.plan_versions pv
        WHERE pv.workspace_id = ? AND pv.status IN ('superseded','discarded')
          AND pv.generated_at < ? $keepSql
          AND NOT EXISTS (SELECT 1 FROM dbo.proposals p WHERE p.candidate_plan_version_id = pv.id OR p.base_plan_version_id = pv.id)
        ORDER BY pv.id", [$wsId, $w['plan_cutoff']]);
    $ids = array_map(fn($r) => (int)$r['id'], $versions);
    $assignments = 0;
    if ($ids) $assignments = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.assignments WHERE plan_version_id IN (" . implode(',', $ids) . ")");

    $auditRows = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.audit_events WHERE workspace_id = ? AND occurred_at < ?", [$wsId, $w['audit_cutoff']]);
    $deliveries = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.webhook_deliveries WHERE workspace_id = ? AND status IN ('delivered','abandoned') AND created_at < ?",
        [$wsId, date('Y-m-d', strtotime(today() . ' -90 days'))]);

    return $w + [
        'plan_versions' => count($versions), 'plan_version_ids' => $ids, 'assignments' => $assignments,
        'audit_events' => $auditRows, 'webhook_deliveries' => $deliveries,
        'oldest_kept_version' => $keepIds ? min($keepIds) : null,
        'sample' => array_slice($versions, 0, 5),
    ];
}

/** Remove what the scan found. Returns the same shape with what was actually removed. */
function retention_purge($conn, $wsId, $actorName = null) {
    $scan = retention_scan($conn, $wsId);
    $removed = ['plan_versions' => 0, 'assignments' => 0, 'audit_events' => 0, 'webhook_deliveries' => 0];

    if ($scan['plan_version_ids']) {
        $in = implode(',', $scan['plan_version_ids']);
        // change_proposals reference a proposal, not a version, so only assignments hang off
        // a version directly. Delete children first: SQL Server will not do it for us.
        $removed['assignments'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.assignments WHERE plan_version_id IN ($in)");
        q($conn, "DELETE FROM dbo.assignments WHERE plan_version_id IN ($in)");
        $removed['plan_versions'] = count($scan['plan_version_ids']);
        q($conn, "DELETE FROM dbo.plan_versions WHERE id IN ($in)");
    }

    $deliveryCutoff = date('Y-m-d', strtotime(today() . ' -90 days'));
    $removed['webhook_deliveries'] = $scan['webhook_deliveries'];
    q($conn, "DELETE FROM dbo.webhook_deliveries WHERE workspace_id = ? AND status IN ('delivered','abandoned') AND created_at < ?", [$wsId, $deliveryCutoff]);

    // The audit purge happens last and is recorded first, so the evidence of it survives in
    // the very table being trimmed.
    if ($scan['audit_events'] > 0) {
        audit($conn, $wsId, 'purge', 'audit_events', null, null,
            ['removed' => $scan['audit_events'], 'older_than' => $scan['audit_cutoff'], 'retention_years' => $scan['audit_retention_years']],
            'Retention purge', $actorName ? "Run by $actorName" : 'Scheduled retention run');
        $removed['audit_events'] = $scan['audit_events'];
        q($conn, "DELETE FROM dbo.audit_events WHERE workspace_id = ? AND occurred_at < ?", [$wsId, $scan['audit_cutoff']]);
    }

    if ($removed['plan_versions'] || $removed['webhook_deliveries']) {
        audit($conn, $wsId, 'purge', 'plan_versions', null, null, $removed, 'Retention purge',
            $actorName ? "Run by $actorName" : 'Scheduled retention run');
    }
    update($conn, 'workspaces', ['retention_last_run_at' => date('Y-m-d H:i:s')], 'id = ?', [$wsId]);
    return ['removed' => $removed] + $scan;
}

// ---------------------------------------------------------------------------------------
// CLI (cron_retention.php) runs every workspace and returns before the HTTP guard.
if (PHP_SAPI === 'cli' && (($_GET['action'] ?? '') === 'run_purge')) {
    $userId = null; $userName = 'Retention';
    $out = [];
    foreach (rows($conn, "SELECT id FROM dbo.workspaces ORDER BY id") as $w) {
        $r = retention_purge($conn, (int)$w['id'], null);
        $out[] = ['workspace_id' => (int)$w['id'], 'removed' => $r['removed'],
            'plan_cutoff' => $r['plan_cutoff'], 'audit_cutoff' => $r['audit_cutoff']];
    }
    ok(['results' => $out]);
}

require_once __DIR__ . '/auth_middleware.php';
$action = param('action', 'get');

if ($action === 'get') {
    $scan = retention_scan($conn, $wsId);
    ok(['policy' => [
            'plan_history_months' => $scan['plan_history_months'],
            'audit_retention_years' => $scan['audit_retention_years'],
            'last_run_at' => $scan['last_run_at'],
        ],
        'older_than_policy' => [
            'plan_versions' => $scan['plan_versions'], 'assignments' => $scan['assignments'],
            'audit_events' => $scan['audit_events'], 'webhook_deliveries' => $scan['webhook_deliveries'],
        ],
        'plan_cutoff' => $scan['plan_cutoff'], 'audit_cutoff' => $scan['audit_cutoff'],
        'note' => 'Purging removes superseded plan history and expired audit rows. The committed plan, the most recent superseded version, and every work item, person, benefit and estimate are kept whatever their age.']);
}

if ($action === 'save') {
    require_role('admin');
    $months = (int)param('plan_history_months', 24);
    $years = (int)param('audit_retention_years', 7);
    if ($months < 1 || $months > 120) fail('Plan history must be kept for between 1 and 120 months.', 422);
    if ($years < 1 || $years > 25) fail('The audit trail must be kept for between 1 and 25 years.', 422);
    $before = retention_windows($conn, $wsId);
    update($conn, 'workspaces', ['plan_history_months' => $months, 'audit_retention_years' => $years], 'id = ?', [$wsId]);
    $after = retention_windows($conn, $wsId);
    audit($conn, $wsId, 'config', 'retention', $wsId,
        ['plan_history_months' => $before['plan_history_months'], 'audit_retention_years' => $before['audit_retention_years']],
        ['plan_history_months' => $months, 'audit_retention_years' => $years], 'Retention policy');
    ok(['policy' => ['plan_history_months' => $months, 'audit_retention_years' => $years, 'last_run_at' => $after['last_run_at']]]);
}

if ($action === 'preview') {
    require_role('admin');
    ok(retention_scan($conn, $wsId));
}

if ($action === 'purge') {
    require_role('admin');
    if (!param('confirm')) fail('Pass confirm to run the purge. Preview it first: this cannot be undone.', 422);
    ok(retention_purge($conn, $wsId, $userName));
}

fail('Unknown action', 400);
