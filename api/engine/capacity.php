<?php
// Capacity derivation (TEAM-06/08/10) + small plan/load helpers shared by people.php and skills.php.
// Pure PHP, no HTTP. Requires lib.php helpers (rows/q/today/week_start...).
require_once __DIR__ . '/org_lib.php';   // the team tree: descendants, authority, visibility (ORG-01..05)

// current_policy() is canonical in lib.php (loaded by db_connect.php for every endpoint).


function workspace_row($conn, $wsId) {
    return row($conn, "SELECT * FROM dbo.workspaces WHERE id = ?", [$wsId]);
}
// workspace_working_days() is canonical in lib.php.

/**
 * Public holidays in a window: [day => [region => label]], where the key '' means everyone.
 *
 * A holiday is a property of the calendar, not of anybody's plans, so it is resolved here
 * rather than written into dbo.availability per person: a new joiner gets Christmas off
 * without anybody remembering to book it for them.
 */
function holiday_map($conn, $wsId, $from, $to) {
    if (public_holidays_table_exists($conn) === false) return [];
    $m = [];
    foreach (rows($conn, "SELECT CONVERT(char(10), day, 23) AS day, label, region FROM dbo.public_holidays WHERE workspace_id = ? AND day BETWEEN ? AND ?", [$wsId, $from, $to]) as $h) {
        $m[$h['day']][$h['region'] === null ? '' : $h['region']] = $h['label'];
    }
    return $m;
}

/** True when dbo.public_holidays exists: the schema grows, and a database applied before it must still serve requests. */
function public_holidays_table_exists($conn) {
    static $exists = null;
    if ($exists === null) $exists = scalar($conn, "SELECT OBJECT_ID('dbo.public_holidays')") !== null;
    return $exists;
}

/** The holiday label for a person on a day, or null. A NULL-region holiday applies to everyone. */
function holiday_label(array $holidays, $day, $region = null) {
    $onDay = $holidays[$day] ?? null;
    if (!$onDay) return null;
    if (array_key_exists('', $onDay)) return $onDay[''];
    if ($region !== null && array_key_exists($region, $onDay)) return $onDay[$region];
    return null;
}

/**
 * Hours a person can work on one day: their pattern for that weekday, less the share of the
 * day they are away, and nothing at all on a public holiday.
 *
 * The one implementation of this arithmetic. There used to be five, and two of them disagreed:
 * overlapping availability rows were added-and-clamped when capacity was derived and multiplied
 * when the model fell back, so two half-days read as a whole day off in one place and a quarter
 * day in the other. Fractions ADD and clamp at 1: two half-days off is a day off.
 *
 * @param array $pattern        weekday => hours, e.g. {"Mon":7.5,"Fri":3.75}
 * @param string $dow           'Mon'..'Sun'
 * @param float[] $awayFractions the fraction of each availability row covering the day
 */
function day_hours(array $pattern, $dow, array $awayFractions = [], $isHoliday = false) {
    if ($isHoliday) return 0.0;
    $hours = (float)($pattern[$dow] ?? 0);
    if ($hours <= 0) return 0.0;
    $away = 0.0;
    foreach ($awayFractions as $f) $away += (float)$f;
    $away = min(1.0, $away);
    return $away >= 1.0 ? 0.0 : round($hours * (1 - $away), 2);
}

/**
 * Which weekdays count as working days for a set of people.
 *
 * The workspace working week, plus any weekday somebody's own pattern gives hours to. Without
 * the second half a Saturday worker simply does not exist: derive_capacity() would write no row
 * for their Saturday and the planner would never see the time.
 */
function effective_working_days(array $workspaceDays, array $patterns) {
    $set = [];
    foreach ($workspaceDays as $d) $set[$d] = true;
    foreach ($patterns as $pattern) {
        foreach ((array)$pattern as $dow => $hours) if ((float)$hours > 0) $set[$dow] = true;
    }
    $order = ['Mon' => 0, 'Tue' => 1, 'Wed' => 2, 'Thu' => 3, 'Fri' => 4, 'Sat' => 5, 'Sun' => 6];
    $out = array_keys($set);
    usort($out, fn($a, $b) => ($order[$a] ?? 9) <=> ($order[$b] ?? 9));
    return $out;
}

/**
 * A person's leave year and what they have booked in it.
 *
 * Booked days are counted in THAT PERSON'S days, not calendar days: somebody who works Monday to
 * Thursday and books Monday to Friday off has used four days, not five, and a bank holiday inside
 * the range costs nobody any leave. A half-day row costs half a day.
 *
 * Informational only. Dispatch is not the system of record for leave approval (requirements
 * section 3), nothing here blocks a booking, and the rows still carry a type and never a reason
 * (ADM-05).
 *
 * @return array {leave_year_from, leave_year_to, entitlement_days, entitlement_source,
 *                booked_days, taken_days, upcoming_days, remaining_days}
 */
function leave_balance($conn, $wsId, $personId, $asOf = null) {
    $asOf = $asOf ?: today();
    $ws = workspace_row($conn, $wsId);
    $startMonth = (int)($ws['leave_year_start_month'] ?? 1) ?: 1;
    $year = (int)date('Y', strtotime($asOf));
    if ((int)date('n', strtotime($asOf)) < $startMonth) $year--;
    $from = sprintf('%04d-%02d-01', $year, $startMonth);
    $to = date('Y-m-d', strtotime($from . ' +1 year -1 day'));

    $p = row($conn, "SELECT id, working_pattern, annual_leave_days, holiday_region FROM dbo.people WHERE id = ? AND workspace_id = ?", [$personId, $wsId]);
    if (!$p) return null;
    $pattern = json_col($p['working_pattern'], []);
    $entitlement = $p['annual_leave_days'] !== null ? (float)$p['annual_leave_days'] : (float)($ws['default_annual_leave_days'] ?? 25);
    $holidays = holiday_map($conn, $wsId, $from, $to);
    $region = $p['holiday_region'] ?? null;

    $booked = 0.0; $taken = 0.0; $upcoming = 0.0;
    foreach (rows($conn, "SELECT CONVERT(char(10), from_date, 23) f, CONVERT(char(10), to_date, 23) t, fraction
                          FROM dbo.availability WHERE workspace_id = ? AND person_id = ? AND type = 'leave' AND from_date <= ? AND to_date >= ?",
        [$wsId, $personId, $to, $from]) as $a) {
        $d = new DateTime(max($from, $a['f']));
        $end = new DateTime(min($to, $a['t']));
        while ($d <= $end) {
            $day = $d->format('Y-m-d');
            // A day the person does not work, or a public holiday, costs no leave.
            if (day_hours($pattern, $d->format('D'), [], holiday_label($holidays, $day, $region) !== null) > 0) {
                $part = min(1.0, (float)$a['fraction']);
                $booked += $part;
                if ($day < $asOf) $taken += $part; else $upcoming += $part;
            }
            $d->modify('+1 day');
        }
    }
    return [
        'leave_year_from' => $from, 'leave_year_to' => $to,
        'entitlement_days' => round($entitlement, 1),
        'entitlement_source' => $p['annual_leave_days'] !== null ? 'person' : 'workspace',
        'booked_days' => round($booked, 2), 'taken_days' => round($taken, 2), 'upcoming_days' => round($upcoming, 2),
        'remaining_days' => round($entitlement - $booked, 2),
        'note' => 'For planning only. Dispatch is not the system of record for leave.',
    ];
}

/** Last committed day of the freeze horizon (today + freeze_horizon_days working days). */
function freeze_horizon_end($conn, $wsId, $policy = null) {
    $policy = $policy ?: current_policy($conn, $wsId);
    return add_working_days(today(), (int)$policy['freeze_horizon_days'], workspace_working_days($conn, $wsId));
}

/**
 * Derive dbo.capacity_days for [$from, $to] from people.working_pattern × availability rows, with the incident reserve
 * (policy incident_reserve_pct, or rota_reserve_pct in weeks the person is on the incident rota). Leave days
 * and public holidays write 0/0. The day grid is the workspace working week widened by any weekday one of
 * these people's own patterns gives hours to, so a Saturday worker gets Saturday rows.
 * Upserts via MERGE. Returns the number of rows written.
 */
function derive_capacity($conn, $wsId, $from, $to, $personIds = null) {
    if ($to < $from) return 0;
    $policy = current_policy($conn, $wsId);
    $incPct = (float)$policy['incident_reserve_pct'] / 100;
    $rotaPct = (float)$policy['rota_reserve_pct'] / 100;
    $workingDays = workspace_working_days($conn, $wsId);

    $hasRegion = (bool)scalar($conn, "SELECT COL_LENGTH('dbo.people', 'holiday_region')");
    $sql = "SELECT id, working_pattern" . ($hasRegion ? ", holiday_region" : "") . " FROM dbo.people WHERE workspace_id = ? AND active = 1";
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

    // Public holidays are workspace-wide facts, read once for the window.
    $holidays = holiday_map($conn, $wsId, $from, $to);
    // A weekday somebody's own pattern gives hours to is a working day for them, whatever the
    // workspace week says — otherwise a Saturday worker's Saturdays are never written at all.
    $patterns = [];
    foreach ($people as $p) $patterns[(int)$p['id']] = json_col($p['working_pattern'], []);
    $workingDays = effective_working_days($workingDays, $patterns);

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
        $pattern = $patterns[$pid] ?: ['Mon' => 7.5, 'Tue' => 7.5, 'Wed' => 7.5, 'Thu' => 7.5, 'Fri' => 7.5];
        $region = $hasRegion ? ($p['holiday_region'] ?? null) : null;
        $d = new DateTime($from); $end = new DateTime($to);
        while ($d <= $end) {
            $dow = $d->format('D'); $day = $d->format('Y-m-d');
            if (in_array($dow, $workingDays, true)) {
                $fractions = [];
                foreach ($avail[$pid] ?? [] as $a) {
                    if ($day >= substr($a['from_date'], 0, 10) && $day <= substr($a['to_date'], 0, 10)) $fractions[] = (float)$a['fraction'];
                }
                $available = day_hours($pattern, $dow, $fractions, holiday_label($holidays, $day, $region) !== null);
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
        'manager_person_id' => isset($p['manager_person_id']) && $p['manager_person_id'] !== null ? (int)$p['manager_person_id'] : null,
        'manager_name' => $p['manager_name'] ?? null,
        'role_family_id' => isset($p['role_family_id']) && $p['role_family_id'] !== null ? (int)$p['role_family_id'] : null,
        'role_family_name' => $p['role_family_name'] ?? null,
        // ORG-02: the reporting line is a real person now. line_manager is the old free-text column,
        // still returned so nothing that reads it breaks, but never written again.
        'line_manager' => $p['manager_name'] ?? ($p['line_manager'] ?? null), 'active' => (bool)$p['active'], 'email' => $p['email'],
        'annual_leave_days' => isset($p['annual_leave_days']) && $p['annual_leave_days'] !== null ? (float)$p['annual_leave_days'] : null,
        'holiday_region' => $p['holiday_region'] ?? null,
        'protected_until' => $p['protected_until'] ? substr($p['protected_until'], 0, 10) : null,
    ];
}

// ---- TEAM-09 / ORG-01: scopes, teams and loans -----------------------------------------------------
// A loan moves a SHARE of a person's time to another team for a dated period. capacity_days stays
// one row per person-day (how many hours exist); these helpers answer "whose hours are they" at read
// time, so every reader of capacity_days keeps working and a loan is a fact about ownership, not size.

/**
 * A planning scope: the whole workspace, one team, or one role family.
 *
 * A team scope covers the team AND every team beneath it (ORG-01), so planning for
 * 'Data Platform' plans for its sub-teams too. A role family is a discipline people belong to
 * across the tree (ORG-02), so it is a set of PEOPLE, not of teams: team_ids stays null and
 * person_ids carries the family. Everything downstream keys off whichever of the two is set.
 *
 * @return array{kind:string, team_id:?int, role_family_id:?int, name:?string, team_ids:?int[], person_ids:?int[]}|null
 *         null for an unknown team or role family.
 */
function scope_team_ids($conn, $wsId, array $opts) {
    $empty = ['kind' => 'workspace', 'team_id' => null, 'role_family_id' => null, 'name' => null, 'team_ids' => null, 'person_ids' => null];
    if (isset($opts['team_id']) && $opts['team_id'] !== '' && $opts['team_id'] !== null) {
        $t = team_node($conn, $wsId, (int)$opts['team_id']);
        if (!$t) return null;
        return ['kind' => 'team', 'team_id' => (int)$t['id'], 'role_family_id' => null, 'name' => $t['name'],
                'team_ids' => team_descendants($conn, $wsId, (int)$t['id']), 'person_ids' => null];
    }
    if (isset($opts['role_family_id']) && $opts['role_family_id'] !== '' && $opts['role_family_id'] !== null) {
        $rf = row($conn, "SELECT id, name FROM dbo.role_families WHERE id = ? AND workspace_id = ?", [(int)$opts['role_family_id'], $wsId]);
        if (!$rf) return null;
        $ids = array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.people WHERE workspace_id = ? AND role_family_id = ? AND active = 1 ORDER BY id", [$wsId, (int)$rf['id']]));
        return ['kind' => 'role_family', 'team_id' => null, 'role_family_id' => (int)$rf['id'], 'name' => $rf['name'], 'team_ids' => null, 'person_ids' => $ids];
    }
    return $empty;
}

/** The keys a scope echoes back to the client. */
function scope_public(array $scope) {
    return array_intersect_key($scope, array_flip(['kind', 'team_id', 'role_family_id', 'name', 'team_ids', 'person_ids']));
}

/** True when the scope is narrower than the workspace. */
function scope_is_partial(array $scope) {
    return ($scope['team_ids'] ?? null) !== null || ($scope['person_ids'] ?? null) !== null;
}

/** team_pool for a scope array. */
function scope_pool($conn, $wsId, array $scope, $from, $to) {
    return team_pool($conn, $wsId, $scope['team_ids'] ?? null, $from, $to, $scope['person_ids'] ?? null);
}

/** team_load for a scope array. */
function scope_load($conn, $wsId, array $scope, $from, $to) {
    return team_load($conn, $wsId, $scope['team_ids'] ?? null, $from, $to, $scope['person_ids'] ?? null);
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
 *
 * $personIds names a set of people directly (a role family, ORG-02). They are all "home" and
 * every hour of theirs belongs to the set wherever they sit, so a loan between two teams moves
 * nothing: the discipline still has the person either way.
 */
function team_pool($conn, $wsId, $teamIds, $from, $to, $personIds = null) {
    $people = rows($conn, "SELECT id, team_id FROM dbo.people WHERE workspace_id = ? AND active = 1 ORDER BY id", [$wsId]);
    $homeTeam = []; foreach ($people as $p) $homeTeam[(int)$p['id']] = $p['team_id'] !== null ? (int)$p['team_id'] : null;
    if ($personIds !== null) {
        $out = [];
        foreach (array_map('intval', $personIds) as $pid) if (array_key_exists($pid, $homeTeam)) $out[$pid] = ['home' => true, 'team_id' => $homeTeam[$pid], 'loans' => []];
        return $out;
    }
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
function team_load($conn, $wsId, $teamIds, $from, $to, $personIds = null) {
    ensure_capacity($conn, $wsId, $from, $to);
    $pool = team_pool($conn, $wsId, $teamIds, $from, $to, $personIds);
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
