<?php
// Cloning, filling and emptying a workspace (ADM-07 campaigns).
//
// Every table already carried workspace_id and every query already filtered on it, so a second
// workspace is isolated the moment it exists. What this file does is MAKE one: copy the shape of
// an existing workspace into it (and, for a full copy, the work and the committed plan), or fill
// it with the demo dataset, or empty it again.
//
// Two rules the copy order exists to satisfy:
//   * Five references are circular — users.person_id, teams.lead_person_id / parent_team_id,
//     people.manager_person_id / role_family_id, role_families.lead_person_id. Everything is
//     inserted with those NULL and a second pass fills them in once both ends have new ids.
//   * Nothing that identifies the source system is copied. Secrets (webhook and intake), device
//     tokens, calendar feed tokens, notifications and the audit trail all stay where they are:
//     a sandbox that could post to a real webhook is not a sandbox.
//
// Pure PHP over $conn. The caller does the role gating.
require_once __DIR__ . '/capacity.php';

/** Vocabulary tables, in an order that never references a row that does not exist yet. */
const CLONE_CONFIG_TABLES = ['work_types', 'size_classes', 'day_rates', 'skills'];

/**
 * Copy a workspace. Returns the new workspace id.
 *
 * @param array $opts {name, description?, mode: 'full'|'config', creator_email?, open_to_all?}
 *   mode 'config' copies the vocabulary, the policy, the skills, the teams and the people —
 *   everything you need to plan — but no work items and no plan. 'full' adds the pipeline and the
 *   current committed plan, so the sandbox opens on a copy of what is really happening.
 */
function clone_workspace($conn, $srcWsId, array $opts) {
    $full = ($opts['mode'] ?? 'full') === 'full';
    $src = row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$srcWsId]);
    if (!$src) fail('The workspace to copy no longer exists', 404);

    $newId = insert($conn, 'workspaces', [
        'name' => mb_substr(trim((string)$opts['name']), 0, 120),
        'time_zone' => $src['time_zone'], 'working_days' => $src['working_days'],
        'hours_per_day' => $src['hours_per_day'], 'currency' => $src['currency'],
        'plan_history_months' => $src['plan_history_months'], 'audit_retention_years' => $src['audit_retention_years'],
        'leave_year_start_month' => $src['leave_year_start_month'] ?? 1,
        'default_annual_leave_days' => $src['default_annual_leave_days'] ?? 25,
        'kind' => 'campaign', 'description' => $opts['description'] ?? null,
        'source_workspace_id' => $srcWsId, 'seeded_from' => $full ? 'full' : 'config',
        'open_to_all' => !empty($opts['open_to_all']) ? 1 : 0,
        'created_by_email' => $opts['creator_email'] ?? null,
    ]);

    $map = [];   // table => [old id => new id]

    // ---- vocabulary and policy -------------------------------------------------------------
    foreach (CLONE_CONFIG_TABLES as $t) {
        $map[$t] = clone_rows($conn, $t, $srcWsId, $newId, function ($r) use (&$map, $t) {
            if ($t === 'size_classes') $r['work_type_id'] = clone_ref($map, 'work_types', $r['work_type_id']);
            return $r;
        });
    }
    // Only the policy in force: a sandbox does not need the history of how it got there.
    $pol = row($conn, "SELECT * FROM dbo.scheduling_policies WHERE workspace_id = ? ORDER BY is_current DESC, version DESC, id DESC", [$srcWsId]);
    if ($pol) {
        unset($pol['id']);
        $pol['workspace_id'] = $newId; $pol['version'] = 1; $pol['is_current'] = 1; $pol['created_by'] = null;
        insert($conn, 'scheduling_policies', $pol);
    }

    // ---- the organisation: two passes, because it points at itself ---------------------------
    $map['role_families'] = clone_rows($conn, 'role_families', $srcWsId, $newId, function ($r) { $r['lead_person_id'] = null; return $r; });
    $map['teams'] = clone_rows($conn, 'teams', $srcWsId, $newId, function ($r) { $r['parent_team_id'] = null; $r['lead_person_id'] = null; return $r; });
    $map['people'] = clone_rows($conn, 'people', $srcWsId, $newId, function ($r) use (&$map) {
        $r['team_id'] = clone_ref($map, 'teams', $r['team_id']);
        $r['manager_person_id'] = null; $r['role_family_id'] = null;
        return $r;
    });
    foreach (rows($conn, "SELECT id, parent_team_id, lead_person_id FROM dbo.teams WHERE workspace_id = ?", [$srcWsId]) as $t) {
        $newTeam = clone_ref($map, 'teams', $t['id']);
        if ($newTeam === null) continue;
        update($conn, 'teams', ['parent_team_id' => clone_ref($map, 'teams', $t['parent_team_id']), 'lead_person_id' => clone_ref($map, 'people', $t['lead_person_id'])], 'id = ?', [$newTeam]);
    }
    foreach (rows($conn, "SELECT id, manager_person_id, role_family_id FROM dbo.people WHERE workspace_id = ?", [$srcWsId]) as $p) {
        $newPerson = clone_ref($map, 'people', $p['id']);
        if ($newPerson === null) continue;
        update($conn, 'people', ['manager_person_id' => clone_ref($map, 'people', $p['manager_person_id']), 'role_family_id' => clone_ref($map, 'role_families', $p['role_family_id'])], 'id = ?', [$newPerson]);
    }
    foreach (rows($conn, "SELECT id, lead_person_id FROM dbo.role_families WHERE workspace_id = ?", [$srcWsId]) as $rf) {
        $newRf = clone_ref($map, 'role_families', $rf['id']);
        if ($newRf === null) continue;
        update($conn, 'role_families', ['lead_person_id' => clone_ref($map, 'people', $rf['lead_person_id'])], 'id = ?', [$newRf]);
    }

    // ---- accounts. Everyone who can reach the source can reach the copy, at the role they held
    // there; the creator is an administrator of their own sandbox whatever they are in Live.
    $map['users'] = clone_rows($conn, 'users', $srcWsId, $newId, function ($r) use (&$map, $opts) {
        $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
        $r['last_digest_at'] = null;
        if (!empty($opts['creator_email']) && strcasecmp((string)$r['email'], (string)$opts['creator_email']) === 0) $r['role'] = 'admin';
        return $r;
    }, "active = 1");
    if (!empty($opts['creator_email']) && !scalar($conn, "SELECT TOP 1 id FROM dbo.users WHERE workspace_id = ? AND LOWER(email) = ?", [$newId, strtolower($opts['creator_email'])])) {
        insert($conn, 'users', ['workspace_id' => $newId, 'email' => strtolower($opts['creator_email']),
            'display_name' => $opts['creator_name'] ?? $opts['creator_email'], 'role' => 'admin', 'active' => 1, 'auth_provider' => 'campaign']);
    }

    // ---- the supply side -------------------------------------------------------------------
    clone_child_rows($conn, 'person_skills', "person_id IN (SELECT id FROM dbo.people WHERE workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
        $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
        $r['skill_id'] = clone_ref($map, 'skills', $r['skill_id']);
        return $r['person_id'] === null || $r['skill_id'] === null ? null : $r;
    });
    clone_rows($conn, 'availability', $srcWsId, $newId, function ($r) use (&$map) {
        $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
        $r['created_by'] = null;
        return $r['person_id'] === null ? null : $r;
    });
    clone_rows($conn, 'incident_rota', $srcWsId, $newId, function ($r) use (&$map) {
        $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
        return $r['person_id'] === null ? null : $r;
    });
    clone_rows($conn, 'person_loans', $srcWsId, $newId, function ($r) use (&$map) {
        $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
        $r['from_team_id'] = clone_ref($map, 'teams', $r['from_team_id']);
        $r['to_team_id'] = clone_ref($map, 'teams', $r['to_team_id']);
        $r['created_by'] = null;
        return $r['person_id'] === null || $r['from_team_id'] === null || $r['to_team_id'] === null ? null : $r;
    });
    if (public_holidays_table_exists($conn)) {
        clone_rows($conn, 'public_holidays', $srcWsId, $newId, function ($r) { $r['created_by'] = null; return $r; });
    }
    clone_rows($conn, 'ref_sequences', $srcWsId, $newId, null, null, false);

    // ---- the work and the plan (full copies only) -------------------------------------------
    if ($full) {
        $map['work_items'] = clone_rows($conn, 'work_items', $srcWsId, $newId, function ($r) use (&$map) {
            $r['work_type_id'] = clone_ref($map, 'work_types', $r['work_type_id']);
            $r['size_class_id'] = clone_ref($map, 'size_classes', $r['size_class_id']);
            $r['owner_person_id'] = clone_ref($map, 'people', $r['owner_person_id']);
            $r['created_by'] = clone_ref($map, 'users', $r['created_by']);
            $r['priority_override_by'] = clone_ref($map, 'users', $r['priority_override_by']);
            return $r['work_type_id'] === null ? null : $r;
        });
        clone_child_rows($conn, 'tasks', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
            $r['work_item_id'] = clone_ref($map, 'work_items', $r['work_item_id']);
            $r['size_class_id'] = clone_ref($map, 'size_classes', $r['size_class_id']);
            $r['skill_id'] = clone_ref($map, 'skills', $r['skill_id']);
            return $r['work_item_id'] === null ? null : $r;
        });
        clone_rows($conn, 'dependencies', $srcWsId, $newId, function ($r) use (&$map) {
            $r['from_work_item_id'] = clone_ref($map, 'work_items', $r['from_work_item_id']);
            $r['to_work_item_id'] = clone_ref($map, 'work_items', $r['to_work_item_id']);
            return $r['from_work_item_id'] === null || $r['to_work_item_id'] === null ? null : $r;
        });
        clone_child_rows($conn, 'skill_requirements', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
            $r['work_item_id'] = clone_ref($map, 'work_items', $r['work_item_id']);
            $r['skill_id'] = clone_ref($map, 'skills', $r['skill_id']);
            return $r['work_item_id'] === null || $r['skill_id'] === null ? null : $r;
        });
        clone_child_rows($conn, 'estimates', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
            $r['work_item_id'] = clone_ref($map, 'work_items', $r['work_item_id']);
            $r['author_user_id'] = clone_ref($map, 'users', $r['author_user_id']);
            return $r['work_item_id'] === null ? null : $r;
        });
        $map['benefits'] = clone_rows($conn, 'benefits', $srcWsId, $newId, function ($r) use (&$map) {
            $r['work_item_id'] = clone_ref($map, 'work_items', $r['work_item_id']);
            $r['owner_person_id'] = clone_ref($map, 'people', $r['owner_person_id']);
            return $r['work_item_id'] === null ? null : $r;
        });
        clone_child_rows($conn, 'benefit_realisations', "benefit_id IN (SELECT b.id FROM dbo.benefits b WHERE b.workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
            $r['benefit_id'] = clone_ref($map, 'benefits', $r['benefit_id']);
            $r['confirmed_by'] = null;
            return $r['benefit_id'] === null ? null : $r;
        });
        clone_child_rows($conn, 'progress_logs', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)", [$srcWsId], function ($r) use (&$map) {
            $r['work_item_id'] = clone_ref($map, 'work_items', $r['work_item_id']);
            $r['person_id'] = clone_ref($map, 'people', $r['person_id']);
            return $r['work_item_id'] === null ? null : $r;
        });

        // The committed plan only. Proposals, scenarios and superseded versions are the source's
        // history, not the sandbox's; the campaign starts from what is being worked to today.
        $cur = row($conn, "SELECT * FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$srcWsId]);
        if ($cur) {
            $srcVersion = (int)$cur['id'];
            unset($cur['id']);
            $cur['workspace_id'] = $newId; $cur['version_no'] = 1; $cur['generated_by'] = null; $cur['committed_by'] = null;
            $cur['notes'] = 'Copied from ' . $src['name'];
            $newVersion = insert($conn, 'plan_versions', $cur);
            foreach (rows($conn, "SELECT * FROM dbo.assignments WHERE plan_version_id = ?", [$srcVersion]) as $a) {
                unset($a['id']);
                $a['plan_version_id'] = $newVersion;
                $a['work_item_id'] = clone_ref($map, 'work_items', $a['work_item_id']);
                $a['person_id'] = clone_ref($map, 'people', $a['person_id']);
                $a['fixed_by'] = null;
                if ($a['work_item_id'] === null || $a['person_id'] === null) continue;
                insert($conn, 'assignments', $a);
            }
        }
    }

    // capacity_days is derived, never copied: one function decides what a day is worth, and running
    // it here proves the copy's own people and calendar agree with it.
    $horizon = date('Y-m-d', strtotime(week_start(today()) . ' +' . (int)current_policy($conn, $newId)['model_horizon_weeks'] . ' weeks'));
    derive_capacity($conn, $newId, date('Y-m-d', strtotime(today() . ' -8 weeks')), $horizon);
    return $newId;
}

/** Copy every row of a workspace-scoped table. $shape may rewrite a row, or return null to skip it. */
function clone_rows($conn, $table, $srcWsId, $newWsId, ?callable $shape = null, $extraWhere = null, $hasIdentity = true) {
    $sql = "SELECT * FROM dbo.$table WHERE workspace_id = ?" . ($extraWhere ? " AND $extraWhere" : '');
    $map = [];
    foreach (rows($conn, $sql, [$srcWsId]) as $r) {
        $oldId = $hasIdentity ? (int)$r['id'] : null;
        if ($hasIdentity) unset($r['id']);
        $r['workspace_id'] = $newWsId;
        if ($shape) { $r = $shape($r); if ($r === null) continue; }
        $newId = insert_row($conn, $table, $r, $hasIdentity);
        if ($hasIdentity) $map[$oldId] = $newId;
    }
    return $map;
}

/** Copy rows of a table with no workspace_id of its own, reached through its parent. */
function clone_child_rows($conn, $table, $where, array $params, callable $shape) {
    foreach (rows($conn, "SELECT * FROM dbo.$table WHERE $where", $params) as $r) {
        $hasId = array_key_exists('id', $r);
        if ($hasId) unset($r['id']);
        $r = $shape($r);
        if ($r === null) continue;
        insert_row($conn, $table, $r, $hasId);
    }
}

/** insert() wants an identity to return; tables without one need a plain INSERT. */
function insert_row($conn, $table, array $data, $hasIdentity = true) {
    if ($hasIdentity) return insert($conn, $table, $data);
    $cols = array_keys($data);
    q($conn, "INSERT INTO dbo.$table (" . implode(',', $cols) . ") VALUES (" . implode(',', array_fill(0, count($cols), '?')) . ")", array_values($data));
    return null;
}

/** Translate an id from the source workspace to the copy. Null in, null out. */
function clone_ref(array $map, $table, $id) {
    if ($id === null || $id === '') return null;
    return $map[$table][(int)$id] ?? null;
}

/**
 * Fill an empty workspace with the demo dataset, by including the same file the CLI seed does.
 *
 * The seed is a straight-line script written for the command line: it uses x()/xid() from
 * migration_connect.php, a few date helpers, and it prints a summary. Over HTTP none of those
 * exist and the printing would land in the middle of a JSON response, so the shims and an output
 * buffer go around it. Including the real file rather than reimplementing it is the point: the
 * demo a campaign gets is the demo the tests run against.
 */
function seed_demo_into($conn, $wsId) {
    require_once __DIR__ . '/seed_shims.php';   // x()/xid()/xrows() and the date helpers, when the CLI ones are absent

    // seed_demo_items.php's addItem() reaches its lookups with `global`, which finds them when the
    // seed runs as a script and finds nothing when the same file is required inside a function.
    // Declaring that exact set global here puts them where addItem() looks.
    global $W, $WT, $SZ, $SZI, $P, $PN, $U, $I, $WI, $N;
    $W = $wsId;
    $TODAY = today();
    $t0 = microtime(true);
    ob_start();
    try {
        require dirname(__DIR__, 2) . '/seed_demo_content.php';
    } finally {
        ob_end_clean();
    }
    return true;
}

/**
 * Empty a workspace: every row that belongs to it, in an order the foreign keys allow.
 *
 * Refuses the live workspace outright. The five circular references are broken first, exactly as
 * the CLI seed's wipe does — this is the same list, kept next to the clone that has to undo itself.
 */
function delete_workspace_contents($conn, $wsId, $keepWorkspaceRow = false) {
    $ws = row($conn, "SELECT id, kind, name FROM dbo.workspaces WHERE id = ?", [$wsId]);
    if (!$ws) fail('Workspace not found', 404);
    if (($ws['kind'] ?? 'live') !== 'campaign') fail('Only a campaign can be emptied or deleted. ' . $ws['name'] . ' is the live workspace.', 409, ['kind' => $ws['kind']]);

    // Break the loops before deleting anything.
    q($conn, "UPDATE dbo.users SET person_id = NULL WHERE workspace_id = ?", [$wsId]);
    q($conn, "UPDATE dbo.teams SET lead_person_id = NULL, parent_team_id = NULL WHERE workspace_id = ?", [$wsId]);
    q($conn, "UPDATE dbo.people SET manager_person_id = NULL, role_family_id = NULL WHERE workspace_id = ?", [$wsId]);
    q($conn, "UPDATE dbo.role_families SET lead_person_id = NULL WHERE workspace_id = ?", [$wsId]);

    // Tables reached only through a parent: delete them by that parent first.
    $viaParent = [
        ['notification_prefs', "user_id IN (SELECT id FROM dbo.users WHERE workspace_id = ?)"],
        ['benefit_realisations', "benefit_id IN (SELECT id FROM dbo.benefits WHERE workspace_id = ?)"],
        ['assignments', "plan_version_id IN (SELECT id FROM dbo.plan_versions WHERE workspace_id = ?)"],
        ['progress_logs', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)"],
        ['estimates', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)"],
        ['skill_requirements', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)"],
        ['tasks', "work_item_id IN (SELECT id FROM dbo.work_items WHERE workspace_id = ?)"],
        ['person_skills', "person_id IN (SELECT id FROM dbo.people WHERE workspace_id = ?)"],
    ];
    foreach ($viaParent as [$t, $where]) q($conn, "DELETE FROM dbo.$t WHERE $where", [$wsId]);

    $scoped = ['webhook_deliveries', 'webhook_subscriptions', 'webhook_cursor', 'calendar_feeds', 'push_deliveries', 'device_tokens',
        'resource_requests', 'public_holidays', 'intake_log', 'intake_sources',
        'item_comments', 'notifications', 'person_change_log', 'replan_triggers',
        'change_proposals', 'proposals', 'plan_versions', 'benefits',
        'dependencies', 'work_items', 'ref_sequences', 'capacity_days', 'incident_rota', 'availability',
        'skills', 'day_rates', 'stability_weeks', 'audit_events', 'integrations', 'scheduling_policies', 'size_classes', 'work_types',
        'person_loans', 'people', 'users', 'role_families', 'teams'];
    foreach ($scoped as $t) {
        if (scalar($conn, "SELECT OBJECT_ID('dbo.$t')") === null) continue;
        q($conn, "DELETE FROM dbo.$t WHERE workspace_id = ?", [$wsId]);
    }
    if (!$keepWorkspaceRow) q($conn, "DELETE FROM dbo.workspaces WHERE id = ?", [$wsId]);
    return true;
}
