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
