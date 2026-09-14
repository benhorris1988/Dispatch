<?php
// Capacity derivation (TEAM-06/08/10) + small plan/load helpers shared by people.php and skills.php.
// Pure PHP, no HTTP. Requires lib.php helpers (rows/q/today/week_start...).

// current_policy() is canonical in lib.php (loaded by db_connect.php for every endpoint).


function workspace_row($conn, $wsId) {
    return row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]);
}
// workspace_working_days() is canonical in lib.php.

/** Last committed day of the freeze horizon (today + freeze_horizon_days working days). */
function freeze_horizon_end($conn, $wsId, $policy = null) {
    $policy = $policy ?: current_policy($conn, $wsId);
    return add_working_days(today(), (int)$policy['freeze_horizon_days'], workspace_working_days($conn, $wsId));
}

/**
 * Derive dbo.capacity_days for [$from, $to] from people.working_pattern × availability rows, with the incident reserve
 * (policy incident_reserve_pct, or rota_reserve_pct in weeks the person is on the incident rota). Leave days write 0/0.
 * Upserts via MERGE. Returns the number of rows written.
 */
function derive_capacity($conn, $wsId, $from, $to, $personIds = null) {
    if ($to < $from) return 0;
    $policy = current_policy($conn, $wsId);
    $incPct = (float)$policy['incident_reserve_pct'] / 100;
    $rotaPct = (float)$policy['rota_reserve_pct'] / 100;
    $workingDays = workspace_working_days($conn, $wsId);

    $sql = "SELECT id, working_pattern FROM dbo.people WHERE workspace_id = ? AND active = 1";
    $params = [$wsId];
    $personIds = $personIds === null ? null : array_values(array_map('intval', array_filter((array)$personIds, fn($v) => $v !== null && $v !== '')));
    if ($personIds !== null) {
        if (!$personIds) return 0;
        $sql .= " AND id IN (" . implode(',', array_fill(0, count($personIds), '?')) . ")";
        $params = array_merge($params, $personIds);
    }
    $people = rows($conn, $sql, $params);
    if (!$people) return 0;
    $ids = array_map(fn($p) => (int)$p['id'], $people);
    $in = implode(',', array_fill(0, count($ids), '?'));

    // Availability overlapping the window, per person.
    $avail = [];
    foreach (rows($conn, "SELECT person_id, from_date, to_date, fraction FROM dbo.availability WHERE workspace_id = ? AND person_id IN ($in) AND from_date <= ? AND to_date >= ?",
        array_merge([$wsId], $ids, [$to, $from])) as $a) $avail[(int)$a['person_id']][] = $a;
    // Rota weeks overlapping the window, per person.
    $rota = [];
    $wkFrom = week_start($from); $wkTo = week_start($to);
    foreach (rows($conn, "SELECT person_id, week_start FROM dbo.incident_rota WHERE workspace_id = ? AND person_id IN ($in) AND week_start BETWEEN ? AND ?",
        array_merge([$wsId], $ids, [$wkFrom, $wkTo])) as $r) $rota[(int)$r['person_id']][substr($r['week_start'], 0, 10)] = true;

    $values = []; $params = [];
    $flush = function () use ($conn, &$values, &$params) {
        if (!$values) return;
        $sql = "MERGE dbo.capacity_days AS t USING (VALUES " . implode(',', $values) . ") AS s(workspace_id, person_id, day, available_hours, reserve_hours)
                ON t.person_id = s.person_id AND t.day = s.day
                WHEN MATCHED THEN UPDATE SET available_hours = s.available_hours, reserve_hours = s.reserve_hours, workspace_id = s.workspace_id, derived_at = SYSDATETIME()
                WHEN NOT MATCHED THEN INSERT (workspace_id, person_id, day, available_hours, reserve_hours) VALUES (s.workspace_id, s.person_id, s.day, s.available_hours, s.reserve_hours);";
        q($conn, $sql, $params);
        $values = []; $params = [];
    };

    $written = 0;
    foreach ($people as $p) {
        $pid = (int)$p['id'];
        $pattern = json_col($p['working_pattern'], ['Mon'=>7.5,'Tue'=>7.5,'Wed'=>7.5,'Thu'=>7.5,'Fri'=>7.5]);
        $d = new DateTime($from); $end = new DateTime($to);
        while ($d <= $end) {
            $dow = $d->format('D'); $day = $d->format('Y-m-d');
            if (in_array($dow, $workingDays, true)) {
                $hours = (float)($pattern[$dow] ?? 0);
                $away = 0.0;
                foreach ($avail[$pid] ?? [] as $a) {
                    if ($day >= substr($a['from_date'], 0, 10) && $day <= substr($a['to_date'], 0, 10)) $away += (float)$a['fraction'];
                }
                $away = min(1.0, $away);
                $available = $away >= 1.0 ? 0.0 : round($hours * (1 - $away), 2);
                $pct = isset($rota[$pid][week_start($day)]) ? $rotaPct : $incPct;
                $reserve = $available > 0 ? round($available * $pct, 2) : 0.0;
                $values[] = '(?,?,?,?,?)';
                array_push($params, $wsId, $pid, $day, $available, $reserve);
                $written++;
                if (count($values) >= 200) $flush();
            }
            $d->modify('+1 day');
        }
    }
    $flush();
    return $written;
}

/** Derive capacity for the window when no rows exist yet (self-healing for fresh workspaces). */
function ensure_capacity($conn, $wsId, $from, $to) {
    $n = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.capacity_days WHERE workspace_id = ? AND day BETWEEN ? AND ?", [$wsId, $from, $to]);
    if ($n === 0) derive_capacity($conn, $wsId, $from, $to);
}

/** Id of the current committed plan version (latest committed), or null. */
function committed_plan_version_id($conn, $wsId) {
    $id = scalar($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC, id DESC", [$wsId]);
    return $id === null ? null : (int)$id;
}

/** capacity map: [person_id][day] => ['available'=>h,'reserve'=>h] for the window. */
function capacity_map($conn, $wsId, $from, $to, $personIds = null) {
    $sql = "SELECT person_id, day, available_hours, reserve_hours FROM dbo.capacity_days WHERE workspace_id = ? AND day BETWEEN ? AND ?";
    $params = [$wsId, $from, $to];
    if ($personIds) { $sql .= " AND person_id IN (" . implode(',', array_fill(0, count($personIds), '?')) . ")"; $params = array_merge($params, array_values($personIds)); }
    $map = [];
    foreach (rows($conn, $sql, $params) as $r) $map[(int)$r['person_id']][substr($r['day'], 0, 10)] = ['available' => (float)$r['available_hours'], 'reserve' => (float)$r['reserve_hours']];
    return $map;
}

/**
 * Assigned hours per person per day from the committed plan over the window:
 * allocation_pct/100 × capacity available hours for each working day of the assignment inside the window.
 * Returns [person_id][day] => hours. Pass $capMap from capacity_map() (missing days fall back to hours_per_day).
 */
function assigned_hours_map($conn, $wsId, $from, $to, $capMap, $personIds = null, $hoursPerDay = 7.5) {
    $pv = committed_plan_version_id($conn, $wsId);
    if ($pv === null) return [];
    $workingDays = workspace_working_days($conn, $wsId);
    $sql = "SELECT a.person_id, a.from_date, a.to_date, a.allocation_pct FROM dbo.assignments a WHERE a.plan_version_id = ? AND a.is_reserve = 0 AND a.from_date <= ? AND a.to_date >= ?";
    $params = [$pv, $to, $from];
    if ($personIds) { $sql .= " AND a.person_id IN (" . implode(',', array_fill(0, count($personIds), '?')) . ")"; $params = array_merge($params, array_values($personIds)); }
    $out = [];
    foreach (rows($conn, $sql, $params) as $a) {
        $pid = (int)$a['person_id'];
        $s = max($from, substr($a['from_date'], 0, 10)); $e = min($to, substr($a['to_date'], 0, 10));
        $d = new DateTime($s); $end = new DateTime($e);
        while ($d <= $end) {
            $day = $d->format('Y-m-d');
            if (in_array($d->format('D'), $workingDays, true)) {
                $avail = $capMap[$pid][$day]['available'] ?? $hoursPerDay;
                $out[$pid][$day] = ($out[$pid][$day] ?? 0) + $avail * ((int)$a['allocation_pct']) / 100;
            }
            $d->modify('+1 day');
        }
    }
    return $out;
}

/** load % per person (assigned ÷ available) over [$from,$to] from the committed plan. Returns [person_id => int pct]. */
function load_pct_map($conn, $wsId, $from, $to, $personIds = null) {
    ensure_capacity($conn, $wsId, $from, $to);
    $ws = workspace_row($conn, $wsId);
    $cap = capacity_map($conn, $wsId, $from, $to, $personIds);
    $asg = assigned_hours_map($conn, $wsId, $from, $to, $cap, $personIds, (float)($ws['hours_per_day'] ?? 7.5));
    $out = [];
    foreach ($cap as $pid => $days) {
        $avail = 0; foreach ($days as $d) $avail += $d['available'];
        $used = 0; foreach ($asg[$pid] ?? [] as $h) $used += $h;
        $out[$pid] = $avail > 0 ? (int)round($used / $avail * 100) : 0;
    }
    foreach ($asg as $pid => $_) if (!isset($out[$pid])) $out[$pid] = 0;
    return $out;
}

/** Date helpers for labels: "14 Sep", "17–18 Sep". */
function fmt_day($date) { return ltrim(date('j M', strtotime($date)), '0'); }
function fmt_range($from, $to) {
    if ($from === $to) return fmt_day($from);
    if (date('M Y', strtotime($from)) === date('M Y', strtotime($to))) return date('j', strtotime($from)) . '–' . fmt_day($to);
    return fmt_day($from) . ' – ' . fmt_day($to);
}
/** Person row → API Person shape (working_pattern decoded). */
function person_shape(array $p) {
    return [
        'id' => (int)$p['id'], 'name' => $p['name'], 'initials' => $p['initials'] !== null ? trim($p['initials']) : null, 'colour' => $p['colour'],
        'role_title' => $p['role_title'], 'tagline' => $p['tagline'], 'team_id' => $p['team_id'] !== null ? (int)$p['team_id'] : null,
        'team_name' => $p['team_name'] ?? null, 'days_per_week' => (float)$p['days_per_week'],
        'working_pattern' => json_col($p['working_pattern'], ['Mon'=>7.5,'Tue'=>7.5,'Wed'=>7.5,'Thu'=>7.5,'Fri'=>7.5]),
        'pattern_label' => $p['pattern_label'], 'max_concurrent' => $p['max_concurrent'] !== null ? (int)$p['max_concurrent'] : null,
        'min_focus_days' => $p['min_focus_days'] !== null ? (int)$p['min_focus_days'] : null, 'prefers' => $p['prefers'], 'avoid' => $p['avoid'],
        'line_manager' => $p['line_manager'], 'active' => (bool)$p['active'], 'email' => $p['email'],
        'protected_until' => $p['protected_until'] ? substr($p['protected_until'], 0, 10) : null,
    ];
}

// ---- TEAM-09: teams, portfolios and loans ---------------------------------------------------------
// A loan moves a SHARE of a person's time to another team for a dated period. capacity_days stays
// one row per person-day (how many hours exist); these helpers answer "whose hours are they" at read
// time, so every reader of capacity_days keeps working and a loan is a fact about ownership, not size.

/** Team ids for a planning scope: ['team_id' => n] | ['portfolio_id' => n] | [] (whole workspace → team_ids null). Unknown id → null. */
function scope_team_ids($conn, $wsId, array $opts) {
    if (isset($opts['team_id']) && $opts['team_id'] !== '') {
        $t = row($conn, "SELECT id, name FROM dbo.teams WHERE id = ? AND workspace_id = ?", [(int)$opts['team_id'], $wsId]);
        return $t ? ['kind' => 'team', 'team_id' => (int)$t['id'], 'portfolio_id' => null, 'name' => $t['name'], 'team_ids' => [(int)$t['id']]] : null;
    }
    if (isset($opts['portfolio_id']) && $opts['portfolio_id'] !== '') {
        $pf = row($conn, "SELECT id, name FROM dbo.portfolios WHERE id = ? AND workspace_id = ?", [(int)$opts['portfolio_id'], $wsId]);
        if (!$pf) return null;
        $ids = array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.teams WHERE workspace_id = ? AND portfolio_id = ? ORDER BY id", [$wsId, (int)$pf['id']]));
        return ['kind' => 'portfolio', 'team_id' => null, 'portfolio_id' => (int)$pf['id'], 'name' => $pf['name'], 'team_ids' => $ids];
    }
    return ['kind' => 'workspace', 'team_id' => null, 'portfolio_id' => null, 'name' => null, 'team_ids' => null];
}

/** Loan rows overlapping [$from,$to], dates as Y-m-d, share as a fraction. Optional person / team filters. */
function loans_in_window($conn, $wsId, $from, $to, $personIds = null, $teamIds = null) {
    $sql = "SELECT l.*, tf.name AS from_team_name, tt.name AS to_team_name, p.name AS person_name
            FROM dbo.person_loans l JOIN dbo.teams tf ON tf.id = l.from_team_id JOIN dbo.teams tt ON tt.id = l.to_team_id JOIN dbo.people p ON p.id = l.person_id
            WHERE l.workspace_id = ? AND l.from_date <= ? AND l.to_date >= ?";
    $params = [$wsId, $to, $from];
    if ($personIds !== null) {
        $personIds = array_values(array_map('intval', (array)$personIds)); if (!$personIds) return [];
        $sql .= " AND l.person_id IN (" . implode(',', array_fill(0, count($personIds), '?')) . ")"; $params = array_merge($params, $personIds);
    }
    if ($teamIds !== null) {
        $teamIds = array_values(array_map('intval', (array)$teamIds)); if (!$teamIds) return [];
        $in = implode(',', array_fill(0, count($teamIds), '?'));
        $sql .= " AND (l.from_team_id IN ($in) OR l.to_team_id IN ($in))"; $params = array_merge($params, $teamIds, $teamIds);
    }
    $out = [];
    foreach (rows($conn, $sql . " ORDER BY l.from_date, l.id", $params) as $l) $out[] = loan_shape($l);
    return $out;
}
function loan_shape(array $l) {
    return ['id' => (int)$l['id'], 'person_id' => (int)$l['person_id'], 'person_name' => $l['person_name'] ?? null,
        'from_team_id' => (int)$l['from_team_id'], 'from_team_name' => $l['from_team_name'] ?? null,
        'to_team_id' => (int)$l['to_team_id'], 'to_team_name' => $l['to_team_name'] ?? null,
        'from_date' => substr($l['from_date'], 0, 10), 'to_date' => substr($l['to_date'], 0, 10),
        'allocation_pct' => (int)$l['allocation_pct'], 'share' => (int)$l['allocation_pct'] / 100,
        'reason' => $l['reason'] ?? null, 'created_by' => $l['created_by'] !== null ? (int)$l['created_by'] : null, 'created_at' => $l['created_at'] ?? null];
}

/**
 * The people whose time belongs, wholly or partly, to a set of teams during [$from,$to]:
 * active home members plus anyone loaned into one of the teams. Keyed by person id:
 *   ['home' => bool (home team in the set), 'team_id' => home team, 'loans' => [loan_shape + 'to_in','from_in']]
 * Pass $teamIds = null for the whole workspace (everyone, share 1).
 */
function team_pool($conn, $wsId, $teamIds, $from, $to) {
    $people = rows($conn, "SELECT id, team_id FROM dbo.people WHERE workspace_id = ? AND active = 1 ORDER BY id", [$wsId]);
    $homeTeam = []; foreach ($people as $p) $homeTeam[(int)$p['id']] = $p['team_id'] !== null ? (int)$p['team_id'] : null;
    if ($teamIds === null) { $out = []; foreach ($homeTeam as $pid => $tid) $out[$pid] = ['home' => true, 'team_id' => $tid, 'loans' => []]; return $out; }
    $set = array_flip(array_map('intval', $teamIds));
    $out = [];
    foreach ($homeTeam as $pid => $tid) if ($tid !== null && isset($set[$tid])) $out[$pid] = ['home' => true, 'team_id' => $tid, 'loans' => []];
    foreach (loans_in_window($conn, $wsId, $from, $to, null, $teamIds) as $l) {
        $pid = $l['person_id'];
        if (!array_key_exists($pid, $homeTeam)) continue;          // inactive person: no capacity to lend
        $l['to_in'] = isset($set[$l['to_team_id']]); $l['from_in'] = isset($set[$l['from_team_id']]);
        if (!isset($out[$pid])) { if (!$l['to_in']) continue; $out[$pid] = ['home' => false, 'team_id' => $homeTeam[$pid], 'loans' => []]; }
        $out[$pid]['loans'][] = $l;
    }
    return $out;
}

/** Share (0..1) of a pooled person's capacity on $day that belongs to the team set: home ? (1 - loaned out) : loaned in. */
function team_share_for(array $entry, $day) {
    $ls = 0.0; $toIn = false;
    foreach ($entry['loans'] as $l) if ($day >= $l['from_date'] && $day <= $l['to_date']) { $ls = $l['share']; $toIn = !empty($l['to_in']); break; }
    $share = ($entry['home'] ? 1 - $ls : 0.0) + ($toIn ? $ls : 0.0);
    return max(0.0, min(1.0, round($share, 4)));
}

/**
 * Team-attributed load over [$from,$to]: per person and in total, with capacity and committed
 * assignment hours both weighted by the team's share of that person on each day, so a person
 * lent at 50% counts half for each team and the two teams' figures add up to the person.
 * Returns ['people' => [pid => {available_hours, assigned_hours, load_pct, home, share_days}],
 *          'available_hours', 'assigned_hours', 'load_pct', 'headcount', 'loaned_in', 'loaned_out'].
 */
function team_load($conn, $wsId, $teamIds, $from, $to) {
    ensure_capacity($conn, $wsId, $from, $to);
    $pool = team_pool($conn, $wsId, $teamIds, $from, $to);
    if (!$pool) return ['people' => [], 'available_hours' => 0.0, 'assigned_hours' => 0.0, 'load_pct' => 0, 'headcount' => 0, 'loaned_in' => 0, 'loaned_out' => 0];
    $ids = array_keys($pool);
    $ws = workspace_row($conn, $wsId);
    $cap = capacity_map($conn, $wsId, $from, $to, $ids);
    $asg = assigned_hours_map($conn, $wsId, $from, $to, $cap, $ids, (float)($ws['hours_per_day'] ?? 7.5));
    $people = []; $availT = 0.0; $usedT = 0.0; $in = 0; $outN = 0;
    foreach ($pool as $pid => $e) {
        $avail = 0.0; $used = 0.0; $shareDays = 0.0;
        foreach ($cap[$pid] ?? [] as $day => $c) {
            $s = team_share_for($e, $day);
            $avail += $c['available'] * $s; $used += ($asg[$pid][$day] ?? 0) * $s;
            if ($c['available'] > 0) $shareDays += $s;
        }
        $people[$pid] = ['available_hours' => round($avail, 2), 'assigned_hours' => round($used, 2), 'load_pct' => $avail > 0 ? (int)round($used / $avail * 100) : 0, 'home' => $e['home'], 'share_days' => round($shareDays, 2)];
        $availT += $avail; $usedT += $used;
        if (!$e['home']) $in++;
        elseif (array_filter($e['loans'], fn($l) => empty($l['to_in']))) $outN++;
    }
    return ['people' => $people, 'available_hours' => round($availT, 2), 'assigned_hours' => round($usedT, 2), 'load_pct' => $availT > 0 ? (int)round($usedT / $availT * 100) : 0,
        'headcount' => count(array_filter($pool, fn($e) => $e['home'])), 'loaned_in' => $in, 'loaned_out' => $outN];
}
