<?php
// ORG-01..05: the team tree. Pure PHP, no HTTP — required by engine/capacity.php, so every
// endpoint that already includes capacity.php gets these for free.
//
// Teams nest under teams. Rather than a recursive CTE per question, the whole workspace's
// tree is read once per request (team_closure) and every ancestor/descendant/visibility
// answer comes out of that array. Anything that writes parent_team_id, sort_order,
// lead_person_id or visibility must call team_closure($conn, $wsId, true) afterwards — the
// same rule current_policy() follows in lib.php.
//
// Nothing here trusts the tree to be acyclic: the API prevents cycles, the schema cannot,
// and a walk that looped would hang a request rather than return a wrong answer.

/**
 * The workspace's team tree, memoised per request.
 * @return array{teams: array<int,array>, parent: array<int,?int>, children: array<string,int[]>, roots: int[]}
 */
function team_closure($conn, $wsId, $fresh = false) {
    static $cache = [];
    $key = (int)$wsId;
    if ($fresh) unset($cache[$key]);
    if (isset($cache[$key])) return $cache[$key];
    $teams = []; $parent = []; $children = [];
    $rows = rows($conn, "SELECT id, name, parent_team_id, sort_order, lead_person_id, visibility, visibility_reason, description, directory_object_id
                         FROM dbo.teams WHERE workspace_id = ? ORDER BY sort_order, name", [$wsId]);
    foreach ($rows as $t) {
        $id = (int)$t['id'];
        $t['id'] = $id;
        $t['parent_team_id'] = $t['parent_team_id'] !== null ? (int)$t['parent_team_id'] : null;
        $t['sort_order'] = (int)$t['sort_order'];
        $t['lead_person_id'] = $t['lead_person_id'] !== null ? (int)$t['lead_person_id'] : null;
        $teams[$id] = $t;
        $parent[$id] = $t['parent_team_id'];
    }
    // A parent outside the workspace (not reachable through the API) is treated as no parent,
    // so every team stays reachable from a root and nothing vanishes from the chart.
    foreach ($teams as $id => $t) {
        $p = $t['parent_team_id'];
        if ($p !== null && !isset($teams[$p])) { $p = null; $parent[$id] = null; }
        $children[(string)($p ?? '')][] = $id;
    }
    $cache[$key] = ['teams' => $teams, 'parent' => $parent, 'children' => $children, 'roots' => $children[''] ?? []];
    return $cache[$key];
}

/** One team row from the closure, or null. */
function team_node($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    return $c['teams'][(int)$teamId] ?? null;
}

/** Child team ids of $teamId (null = the roots), in sort order. */
function team_children($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    return $c['children'][(string)($teamId === null ? '' : (int)$teamId)] ?? [];
}

/** $teamId and every descendant, depth first in sort order. Unknown id gives []. */
function team_descendants($conn, $wsId, $teamId, $includeSelf = true) {
    $c = team_closure($conn, $wsId);
    $teamId = (int)$teamId;
    if (!isset($c['teams'][$teamId])) return [];
    $out = []; $seen = []; $stack = [$teamId];
    while ($stack) {
        $id = array_shift($stack);
        if (isset($seen[$id])) continue;          // a cycle would otherwise never terminate
        $seen[$id] = true;
        $out[] = $id;
        array_splice($stack, 0, 0, $c['children'][(string)$id] ?? []);
    }
    if (!$includeSelf) array_shift($out);
    return $out;
}

/** Parent chain above $teamId, nearest first, excluding $teamId. */
function team_ancestors($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    $out = []; $seen = [];
    $id = $c['parent'][(int)$teamId] ?? null;
    while ($id !== null && !isset($seen[$id])) { $seen[$id] = true; $out[] = $id; $id = $c['parent'][$id] ?? null; }
    return $out;
}

/** Depth of a team: 0 for a root. */
function team_depth($conn, $wsId, $teamId) { return count(team_ancestors($conn, $wsId, $teamId)); }

/** The names from the root down to this team, joined for a label or an audit reason. */
function team_path($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    $names = [];
    foreach (array_reverse(team_ancestors($conn, $wsId, $teamId)) as $a) $names[] = $c['teams'][$a]['name'];
    if (isset($c['teams'][(int)$teamId])) $names[] = $c['teams'][(int)$teamId]['name'];
    return implode(' > ', $names);
}

/** True when $maybeAncestor is $teamId itself or sits above it. The cycle guard for a move. */
function team_is_within($conn, $wsId, $teamId, $maybeAncestor) {
    if ($teamId === null || $maybeAncestor === null) return false;
    if ((int)$teamId === (int)$maybeAncestor) return true;
    return in_array((int)$maybeAncestor, team_ancestors($conn, $wsId, $teamId), true);
}

/** The lead person ids of $teamId and of every ancestor. */
function team_lead_chain($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    $out = [];
    foreach (array_merge([(int)$teamId], team_ancestors($conn, $wsId, $teamId)) as $id) {
        $lead = $c['teams'][$id]['lead_person_id'] ?? null;
        if ($lead !== null) $out[] = $lead;
    }
    return array_values(array_unique($out));
}

/** The nearest team at or above $teamId marked 'restricted', or null. */
function team_restricted_by($conn, $wsId, $teamId) {
    $c = team_closure($conn, $wsId);
    foreach (array_merge([(int)$teamId], team_ancestors($conn, $wsId, $teamId)) as $id) {
        if (($c['teams'][$id]['visibility'] ?? 'everyone') === 'restricted') return $id;
    }
    return null;
}

/**
 * ORG-04. Everything is visible to everyone unless a team has been restricted for a stated
 * reason; a restricted subtree is then visible to administrators, to the lead chain of the
 * restricting team, and to anyone whose own home team sits inside that subtree. A delivery
 * lead does not bypass it — being able to hide a reorganisation from the delivery lead is
 * most of the point of restricting one.
 */
function team_visible_to($conn, $wsId, $teamId, $role, $personId) {
    $restrictedBy = team_restricted_by($conn, $wsId, $teamId);
    if ($restrictedBy === null) return true;
    if ((DP_ROLE_RANK[$role ?? 'viewer'] ?? 0) >= DP_ROLE_RANK['admin']) return true;
    if ($personId === null) return false;
    $personId = (int)$personId;
    if (in_array($personId, team_lead_chain($conn, $wsId, $restrictedBy), true)) return true;
    $home = scalar($conn, "SELECT team_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$personId, $wsId]);
    return $home !== null && in_array((int)$home, team_descendants($conn, $wsId, $restrictedBy), true);
}

/**
 * ORG-05. May the caller edit this team — its people, its place in the tree, its sub-teams?
 * A delivery lead or administrator may edit anywhere; a team lead may edit the team they lead
 * and everything beneath it. A team lead with no linked person has nothing to scope the check
 * to and passes on role alone, as require_loan_authority does. $teamId null means the top of
 * the tree, which only a delivery lead may touch.
 */
function can_edit_team($conn, $wsId, $teamId) {
    global $personId;
    if (has_role('delivery_lead')) return true;
    if (!has_role('team_lead')) return false;
    if ($personId === null) return true;
    if ($teamId === null) return false;
    return in_array((int)$personId, team_lead_chain($conn, $wsId, $teamId), true);
}

function require_team_authority($conn, $wsId, $teamId) {
    if (can_edit_team($conn, $wsId, $teamId)) return;
    if (!has_role('team_lead')) fail('Forbidden: requires team_lead', 403);
    $where = $teamId === null ? 'the top of the organisation' : team_path($conn, $wsId, $teamId);
    fail("Forbidden: you can only change the team you lead and the teams beneath it; $where is outside yours", 403);
}

/** Team ids the caller may edit, so the client can hide controls rather than rely on 403s. */
function editable_team_ids($conn, $wsId) {
    global $personId;
    if (has_role('delivery_lead')) return '*';
    if (!has_role('team_lead')) return [];
    if ($personId === null) return '*';
    $c = team_closure($conn, $wsId);
    $out = [];
    foreach ($c['teams'] as $id => $t) if ($t['lead_person_id'] === (int)$personId) $out = array_merge($out, team_descendants($conn, $wsId, $id));
    return array_values(array_unique($out));
}

/**
 * ORG-02. A manager must be a real, active person in the workspace, must not be the person
 * themselves, and must not already report to them — a reporting line that loops has no top.
 * Returns the validated id (or null), or fails.
 */
function validate_manager($conn, $wsId, $subjectId, $managerId) {
    if ($managerId === null || $managerId === '') return null;
    $managerId = (int)$managerId;
    if ($subjectId !== null && $managerId === (int)$subjectId) fail('Somebody cannot be their own manager', 409);
    $m = row($conn, "SELECT id, name, active FROM dbo.people WHERE id = ? AND workspace_id = ?", [$managerId, $wsId]);
    if (!$m) fail('Manager not found', 404);
    if (!(int)$m['active']) fail("{$m['name']} is no longer active and cannot be a manager", 409);
    if ($subjectId !== null) {
        $seen = []; $up = $managerId;
        while ($up !== null && !isset($seen[$up])) {
            if ($up === (int)$subjectId) fail("That would make {$m['name']} report to themselves through " . person_display_name($conn, $wsId, $subjectId), 409);
            $seen[$up] = true;
            $next = scalar($conn, "SELECT manager_person_id FROM dbo.people WHERE id = ? AND workspace_id = ?", [$up, $wsId]);
            $up = $next !== null ? (int)$next : null;
        }
    }
    return $managerId;
}

function person_display_name($conn, $wsId, $id) {
    return (string)scalar($conn, "SELECT name FROM dbo.people WHERE id = ? AND workspace_id = ?", [(int)$id, $wsId]);
}

/**
 * Move somebody's home team (ORG-03). Shared by org.php move_person and people.php save, so a
 * drag on the chart and an edit in the person dialog obey exactly the same rules.
 *
 * A loan is a statement about a home team: "Mei, who belongs to Integration Platform, is lent
 * to Data Platform until the 25th". Moving Mei while that loan runs would make the statement
 * false, so an outstanding loan out of the old team, or into the new one, blocks the move (409)
 * until the caller says to go ahead. With $force a running loan is shortened to yesterday and
 * one that has not started is deleted, both audited: a loan nobody is honouring is worse than
 * no loan at all.
 *
 * @return array{before: array, after: array, loans_ended: array}
 */
function move_person_home_team($conn, $wsId, array $person, $newTeamId, $reason = null, $force = false) {
    $today = today();
    $pid = (int)$person['id'];
    $oldTeamId = $person['team_id'] !== null ? (int)$person['team_id'] : null;
    $newTeamId = $newTeamId !== null && $newTeamId !== '' ? (int)$newTeamId : null;
    if ($newTeamId !== null && !team_node($conn, $wsId, $newTeamId)) fail('Team not found', 404);

    $clashes = [];
    if ($oldTeamId !== $newTeamId) {
        foreach (loans_in_window($conn, $wsId, $today, '9999-12-31', [$pid]) as $l) {
            if (($oldTeamId !== null && $l['from_team_id'] === $oldTeamId) || ($newTeamId !== null && $l['to_team_id'] === $newTeamId)) $clashes[] = $l;
        }
    }
    if ($clashes && !$force) {
        $l = $clashes[0];
        fail("{$person['name']} is on loan from {$l['from_team_name']} to {$l['to_team_name']} until " . fmt_day($l['to_date'])
            . '. Moving them now would contradict that loan.', 409, ['loans' => $clashes]);
    }
    $ended = [];
    foreach ($clashes as $l) {
        if ($l['from_date'] > $today) {
            q($conn, "DELETE FROM dbo.person_loans WHERE id = ? AND workspace_id = ?", [$l['id'], $wsId]);
            audit($conn, $wsId, 'delete', 'loan', $l['id'], $l, null, "{$person['name']}: {$l['from_team_name']} to {$l['to_team_name']}", 'Loan had not started when the person changed team');
        } else {
            $end = date('Y-m-d', strtotime("$today -1 day"));
            update($conn, 'person_loans', ['to_date' => $end], 'id = ? AND workspace_id = ?', [$l['id'], $wsId]);
            audit($conn, $wsId, 'update', 'loan', $l['id'], $l, ['to_date' => $end] + $l, "{$person['name']}: {$l['from_team_name']} to {$l['to_team_name']}", 'Loan ended early because the person changed team');
        }
        $ended[] = $l;
    }

    update($conn, 'people', ['team_id' => $newTeamId], 'id = ? AND workspace_id = ?', [$pid, $wsId]);
    $c = team_closure($conn, $wsId);
    $fromName = $oldTeamId !== null ? ($c['teams'][$oldTeamId]['name'] ?? 'no team') : 'no team';
    $toName = $newTeamId !== null ? ($c['teams'][$newTeamId]['name'] ?? 'no team') : 'no team';
    audit($conn, $wsId, 'update', 'person', $pid,
        ['team_id' => $oldTeamId, 'team_name' => $fromName], ['team_id' => $newTeamId, 'team_name' => $toName],
        "{$person['name']}: $fromName to $toName", $reason !== null && $reason !== '' ? $reason : 'Home team changed on the organisation chart');
    if ($oldTeamId !== $newTeamId) add_trigger($conn, $wsId, 'leave', 'batched', "{$person['name']} moved from $fromName to $toName", 'person', $pid, [$pid]);
    $after = row($conn, "SELECT * FROM dbo.people WHERE id = ? AND workspace_id = ?", [$pid, $wsId]);
    return ['before' => $person, 'after' => $after, 'loans_ended' => $ended];
}
