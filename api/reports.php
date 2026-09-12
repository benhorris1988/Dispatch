<?php
// Reports (REP-01/REP-04, web-11). Actions:
//   get {range:'4w'|'12w'|'12m'}  -> stability trend, load, estimate accuracy, delivered by month, cycle time, definitions
//   export_csv {report:'stability'|'load'|'accuracy'|'delivered', range?} -> {csv}
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/watchlist.php';
$action = param('action', 'get');

$today = today();
$policy = wl_policy($conn, $wsId);
$ws = wl_workspace($conn, $wsId);
$range = (string)param('range', '12w');
$weeks = ['4w' => 4, '12w' => 12, '12m' => 52][$range] ?? 12;
$thisMon = week_start($today);
$rangeFrom = date('Y-m-d', strtotime("$thisMon -" . (($weeks - 1) * 7) . " days"));       // first Monday in range
$rangeTo = date('Y-m-d', strtotime("$thisMon +6 days"));                                  // end of this week
$prevFrom = date('Y-m-d', strtotime("$rangeFrom -" . ($weeks * 7) . " days"));
$prevTo = date('Y-m-d', strtotime("$rangeFrom -1 day"));
$rangeLabel = ['4w' => 'last 4 weeks', '12w' => 'last 12 weeks', '12m' => 'last 12 months'][$range] ?? 'last 12 weeks';

function rp_median(array $v) { if (!$v) return null; sort($v); $n = count($v); return $n % 2 ? $v[intdiv($n, 2)] : ($v[$n / 2 - 1] + $v[$n / 2]) / 2; }
function rp_week_label($date) { return 'w' . (int)date('W', strtotime($date)); }

/** Build every report section for the range. */
function rp_build($conn, $wsId, $policy, $rangeFrom, $rangeTo, $prevFrom, $prevTo, $thisMon, $weeks) {
    // ---- stability trend + load (stability_weeks) ----
    // The trend is the last $weeks weekly roll-ups up to and including the current week. Taking the
    // newest $weeks rows (rather than a date window) always returns a full series whether or not the
    // current week has been rolled up yet - a 12-week range gives 12 points, a 4-week range gives 4.
    $sw = array_reverse(rows($conn, "SELECT TOP $weeks CONVERT(char(10), week_start, 23) week_start, total_assignment_days, moved_assignment_days, changes_inside_freeze, planned_load_pct, actual_load_pct, note
                       FROM dbo.stability_weeks WHERE workspace_id = ? AND week_start <= ? ORDER BY week_start DESC", [$wsId, $thisMon]));
    $stability = []; $load = [];
    foreach ($sw as $w) {
        $t = (float)$w['total_assignment_days']; $m = (float)$w['moved_assignment_days'];
        $idx = $t > 0 ? round((1 - $m / $t) * 100, 1) : null;
        $stability[] = ['week_start' => $w['week_start'], 'label' => rp_week_label($w['week_start']), 'index_pct' => $idx,
                        'total_assignment_days' => $t, 'moved_assignment_days' => $m, 'changes_inside_freeze' => (int)$w['changes_inside_freeze'], 'note' => $w['note']];
        $planned = $w['planned_load_pct'] === null ? null : (float)$w['planned_load_pct'];
        $actual = $w['actual_load_pct'] === null ? null : (float)$w['actual_load_pct'];
        $load[] = ['week_start' => $w['week_start'], 'label' => rp_week_label($w['week_start']), 'planned_pct' => $planned, 'actual_pct' => $actual,
                   'above_90' => ($actual ?? $planned ?? 0) > 90];
    }
    $thisWeek = null;
    foreach (array_reverse($stability) as $s) if ($s['index_pct'] !== null) { $thisWeek = $s['index_pct']; break; }

    // ---- estimate accuracy (delivered in range) ----
    $acc = rows($conn, "SELECT ref, stamp, estimated_days, actual_effort_days, ratio, CONVERT(char(10), delivered_at, 23) delivered_at, work_type
                        FROM dbo.vw_estimate_accuracy WHERE workspace_id = ? AND delivered_at BETWEEN ? AND ? AND estimated_days IS NOT NULL AND estimated_days > 0 ORDER BY delivered_at", [$wsId, $rangeFrom, $rangeTo]);
    $points = []; $sm = []; $lc = [];
    foreach ($acc as $r) {
        $stamp = trim((string)$r['stamp']);
        $group = in_array($stamp, ['S', 'M'], true) ? 'sm' : 'lc';
        $ratio = (float)$r['ratio'];
        $points[] = ['ref' => $r['ref'], 'stamp' => $stamp ?: 'C', 'estimated' => (float)$r['estimated_days'], 'actual' => (float)$r['actual_effort_days'], 'ratio' => round($ratio, 2), 'group' => $group, 'delivered_at' => $r['delivered_at'], 'type' => $r['work_type']];
        if ($group === 'sm') $sm[] = $ratio; else $lc[] = $ratio;
    }
    $accuracy = ['points' => $points, 'median_sm' => $sm ? round(rp_median($sm), 2) : null, 'median_lc' => $lc ? round(rp_median($lc), 2) : null,
                 'n' => count($points), 'n_sm' => count($sm), 'n_lc' => count($lc)];

    // ---- delivered by month by type ----
    $types = rows($conn, "SELECT id, name, plural, colour FROM dbo.work_types WHERE workspace_id = ? ORDER BY sort_order, id", [$wsId]);
    $del = rows($conn, "SELECT CONVERT(char(7), wi.delivered_at, 126) ym, wi.work_type_id, COUNT(*) n
                        FROM dbo.work_items wi WHERE wi.workspace_id = ? AND wi.status = 'delivered' AND wi.delivered_at BETWEEN ? AND ?
                        GROUP BY CONVERT(char(7), wi.delivered_at, 126), wi.work_type_id", [$wsId, $rangeFrom, $rangeTo]);
    $counts = [];
    foreach ($del as $d) $counts[$d['ym']][(int)$d['work_type_id']] = (int)$d['n'];
    $delivered = [];
    for ($m = substr($rangeFrom, 0, 7) . '-01'; $m <= $rangeTo; $m = date('Y-m-01', strtotime("$m +1 month"))) {
        $ym = substr($m, 0, 7);
        $byType = []; $total = 0;
        foreach ($types as $t) { $n = $counts[$ym][(int)$t['id']] ?? 0; $total += $n; $byType[] = ['type_id' => (int)$t['id'], 'type' => $t['plural'] ?: $t['name'], 'colour' => $t['colour'], 'count' => $n]; }
        $delivered[] = ['month' => $ym, 'label' => date('M', strtotime($m)) . (date('Y', strtotime($m)) !== date('Y', strtotime($rangeTo)) ? ' ' . date('y', strtotime($m)) : ''), 'by_type' => $byType, 'total' => $total];
    }

    // ---- cycle time: median created -> delivered (calendar days) this range vs previous ----
    $cyc = function($from, $to) use ($conn, $wsId) {
        $v = [];
        foreach (rows($conn, "SELECT DATEDIFF(day, created_at, delivered_at) d FROM dbo.work_items WHERE workspace_id = ? AND status = 'delivered' AND delivered_at BETWEEN ? AND ?", [$wsId, $from, $to]) as $r) $v[] = (float)$r['d'];
        return ['median' => rp_median($v), 'n' => count($v)];
    };
    $cur = $cyc($rangeFrom, $rangeTo); $prev = $cyc($prevFrom, $prevTo);
    $cycleDelta = ($cur['median'] !== null && $prev['median'] > 0) ? round(($cur['median'] - $prev['median']) / $prev['median'] * 100) : null;

    $tmin = (int)$policy['target_load_min']; $tmax = (int)$policy['target_load_max'];
    $definitions = [
        'stability' => "Plan stability index = 1 − (assignment-days changed inside the committed and planned windows ÷ total assignment-days in those windows), per week; the overview shows it rolling four weeks. Includes committed and planned assignments in the current plan. Excludes indicative assignments beyond the planning horizon and changes to them.",
        'load' => "Load = hours assigned in the committed plan ÷ hours available (working pattern minus leave, training and sickness) across the team, per week. Planned uses the committed plan; actual uses timesheets where integrated. Target band {$tmin}–{$tmax}%. Weeks above 90% are highlighted. Excludes inactive people and the incident reserve.",
        'accuracy' => "Estimate accuracy = actual effort days ÷ the latest most-likely estimate, per delivered item in the period. Small/Medium and Large/Custom are grouped separately; the median ratio is shown per group (×1.00 is exact, above 1 ran over). Includes delivered items with both an estimate and recorded actual effort. Excludes cancelled items and items without actuals.",
        'delivered' => "Delivered items = work items whose status reached delivered in the month, counted by work type. Cycle time = median calendar days from creation to delivery over the period, compared with the previous period of the same length. Excludes cancelled items.",
    ];

    return compact('stability', 'load', 'accuracy', 'delivered', 'definitions') + ['this_week_index' => $thisWeek, 'cycle_time_delta_pct' => $cycleDelta,
        'cycle_time' => ['median_days' => $cur['median'], 'n' => $cur['n'], 'previous_median_days' => $prev['median'], 'previous_n' => $prev['n']]];
}

$data = rp_build($conn, $wsId, $policy, $rangeFrom, $rangeTo, $prevFrom, $prevTo, $thisMon, $weeks);

if ($action === 'get') {
    ok($data + ['range' => $range, 'range_label' => $rangeLabel, 'range_from' => $rangeFrom, 'range_to' => $rangeTo,
                'workspace_name' => $ws['name'], 'target_min' => (int)$policy['target_load_min'], 'target_max' => (int)$policy['target_load_max'], 'today' => $today]);
}

if ($action === 'export_csv') {
    $report = (string)require_param('report');
    $csv = function(array $header, array $rows) {
        $fh = fopen('php://temp', 'r+');
        fputcsv($fh, $header);
        foreach ($rows as $r) fputcsv($fh, $r);
        rewind($fh); $s = stream_get_contents($fh); fclose($fh);
        return $s;
    };
    switch ($report) {
        case 'stability':
            $out = $csv(['week_start', 'label', 'index_pct', 'total_assignment_days', 'moved_assignment_days', 'changes_inside_freeze', 'note'],
                array_map(fn($s) => [$s['week_start'], $s['label'], $s['index_pct'], $s['total_assignment_days'], $s['moved_assignment_days'], $s['changes_inside_freeze'], $s['note']], $data['stability']));
            break;
        case 'load':
            $out = $csv(['week_start', 'label', 'planned_pct', 'actual_pct', 'above_90'],
                array_map(fn($l) => [$l['week_start'], $l['label'], $l['planned_pct'], $l['actual_pct'], $l['above_90'] ? 1 : 0], $data['load']));
            break;
        case 'accuracy':
            $out = $csv(['ref', 'type', 'stamp', 'group', 'estimated_days', 'actual_days', 'ratio', 'delivered_at'],
                array_map(fn($p) => [$p['ref'], $p['type'], $p['stamp'], $p['group'], $p['estimated'], $p['actual'], $p['ratio'], $p['delivered_at']], $data['accuracy']['points']));
            break;
        case 'delivered':
            $rowsOut = [];
            foreach ($data['delivered'] as $m) foreach ($m['by_type'] as $t) $rowsOut[] = [$m['month'], $m['label'], $t['type'], $t['count']];
            $out = $csv(['month', 'label', 'type', 'count'], $rowsOut);
            break;
        default:
            fail("Unknown report '$report' (stability|load|accuracy|delivered)", 400);
    }
    ok(['csv' => $out, 'report' => $report, 'range' => $range, 'filename' => "dispatch-$report-$range.csv"]);
}

fail('Unknown action', 400);
