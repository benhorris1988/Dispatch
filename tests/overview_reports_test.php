<?php
// CLI test for api/overview.php + api/reports.php over HTTP.
// Usage: php tests/overview_reports_test.php [base_url]   (default http://localhost:8090)
// Needs seed_demo.php applied and fake_today = 2026-09-08.
$base = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $failN = 0;
function call($base, $path, array $body, $token = null) {
    $ch = curl_init("$base/api/$path");
    $h = ['Content-Type: application/json'];
    if ($token) $h[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $h, CURLOPT_RETURNTRANSFER => true]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    return [$code, is_array($j) ? $j : ['raw' => $raw]];
}
function check($label, $cond, $detail = '') {
    global $pass, $failN;
    if ($cond) { $pass++; echo "  ok   $label\n"; } else { $failN++; echo "  FAIL $label" . ($detail !== '' ? "  -- $detail" : '') . "\n"; }
}

// ---- sign in -------------------------------------------------------------------------
[$c, $users] = call($base, 'auth.php', ['action' => 'list_dev_users']);
if ($c !== 200) { echo "Cannot reach $base ($c): " . json_encode($users) . "\n"; exit(1); }
$lead = null; $priya = null;
foreach ($users['users'] as $u) {
    if (!$lead && $u['role'] === 'delivery_lead') $lead = $u;
    if (!$priya && stripos($u['display_name'], 'Priya') !== false && $u['person_id']) $priya = $u;
}
if (!$lead) { echo "No delivery_lead dev user\n"; exit(1); }
if (!$priya) { echo "No Priya dev user (team member)\n"; exit(1); }
[, $r] = call($base, 'auth.php', ['action' => 'dev_login', 'user_id' => $lead['id']]);   $leadTok = $r['token'] ?? null;
[, $r] = call($base, 'auth.php', ['action' => 'dev_login', 'user_id' => $priya['id']]);  $priyaTok = $r['token'] ?? null;
check('dev_login lead + Priya', $leadTok && $priyaTok);

// ---- overview get --------------------------------------------------------------------
echo "overview.get\n";
[$c, $o] = call($base, 'overview.php', ['action' => 'get'], $leadTok);
check('200 ok', $c === 200 && ($o['status'] ?? '') === 'ok', json_encode($o));
foreach (['today','today_label','workspace_name','people_count','plan_pill','committed','load','stability','reserve','proposals','watch_list','effort_by_week','next_proposal_at'] as $k) check("has $k", array_key_exists($k, $o));
check('today is 2026-09-08', ($o['today'] ?? '') === '2026-09-08', $o['today'] ?? '');
check('plan_pill mentions committed', stripos($o['plan_pill'] ?? '', 'Plan committed to') === 0, $o['plan_pill'] ?? '');
check('people_count = 8', ($o['people_count'] ?? 0) === 8, (string)($o['people_count'] ?? 'null'));
$cm = $o['committed'] ?? [];
check('committed.count > 0', ($cm['count'] ?? 0) > 0, (string)($cm['count'] ?? 'null'));
check('committed.items count matches', count($cm['items'] ?? []) === ($cm['count'] ?? -1));
check('committed.due_this_week <= count', ($cm['due_this_week'] ?? 99) <= ($cm['count'] ?? 0));
check('committed has delta_vs_last_fortnight', array_key_exists('delta_vs_last_fortnight', $cm));
$first = $cm['items'][0] ?? [];
foreach (['ref','title','type_name','type_colour','size_stamp','assignees','due','due_label','status_label','status','health'] as $k) check("item has $k", array_key_exists($k, $first));
$dues = array_map(fn($i) => $i['due'], $cm['items'] ?? []);
$sorted = $dues; sort($sorted);
check('items sorted by due', $dues === $sorted);
check('all due inside committed window', !array_filter($cm['items'] ?? [], fn($i) => $i['due'] < $o['today'] || $i['due'] > $cm['window_to']));
check('status_label vocabulary', !array_filter($cm['items'] ?? [], fn($i) => !in_array($i['status_label'], ['On track','In progress','Blocked','At risk'], true)));
$ld = $o['load'] ?? [];
check('load.pct plausible (60-110)', ($ld['pct'] ?? 0) >= 60 && ($ld['pct'] ?? 0) <= 110, (string)($ld['pct'] ?? 'null'));
check('load band label', in_array($ld['band_label'] ?? '', ['Within band','Below band','Above band'], true));
check('load target 80-90', ($ld['target_min'] ?? 0) === 80 && ($ld['target_max'] ?? 0) === 90);
$st = $o['stability'] ?? [];
check('stability.index_pct ~92 (85-99)', ($st['index_pct'] ?? 0) >= 85 && ($st['index_pct'] ?? 0) <= 99, (string)($st['index_pct'] ?? 'null'));
check('stability.delta_pts present', array_key_exists('delta_pts', $st));
check('stability.definition text', str_contains($st['definition'] ?? '', 'assignment-days'));
$rs = $o['reserve'] ?? [];
check('reserve fields', isset($rs['used_pct'], $rs['reserve_pct'], $rs['open_incidents']));
check('reserve.reserve_pct = 12', (float)($rs['reserve_pct'] ?? 0) == 12.0, (string)($rs['reserve_pct'] ?? 'null'));
$pr = $o['proposals'] ?? [];
check('proposals.count > 0 (open proposal)', ($pr['count'] ?? 0) > 0, (string)($pr['count'] ?? 'null'));
check('proposal item shape', isset($pr['items'][0]['id'], $pr['items'][0]['headline']) && array_key_exists('sub', $pr['items'][0]) && array_key_exists('person', $pr['items'][0]));
$wl = $o['watch_list'] ?? [];
check('watch_list non-empty', count($wl) > 0);
check('watch_list entry shape', !array_filter($wl, fn($w) => !isset($w['kind'], $w['title'], $w['body'], $w['suggestion'], $w['link'], $w['tone'])));
check('watch_list kinds valid', !array_filter($wl, fn($w) => !in_array($w['kind'], ['skills_gap','no_estimate','over_capacity','late','single_point'], true)));
$sp = array_values(array_filter($wl, fn($w) => $w['kind'] === 'single_point' && stripos($w['title'], 'Terraform') !== false));
check('single_point entry mentions Terraform', count($sp) > 0, json_encode(array_column($wl, 'title')));
check('single_point body names Priya', $sp && stripos($sp[0]['body'], 'Priya') !== false, $sp[0]['body'] ?? '');
check('no_estimate entry present', (bool)array_filter($wl, fn($w) => $w['kind'] === 'no_estimate'));
$ef = $o['effort_by_week'] ?? [];
check('effort_by_week has 6 weeks', count($ef) === 6, (string)count($ef));
check('effort week shape', isset($ef[0]['week_start'], $ef[0]['label'], $ef[0]['by_type'], $ef[0]['unallocated_days']));
check('effort first week label', ($ef[0]['label'] ?? '') === 'w/c 7 Sep', $ef[0]['label'] ?? '');
check('effort by_type days > 0 in first week', array_sum(array_column($ef[0]['by_type'] ?? [], 'days')) > 0);
check('next_proposal_at is a timestamp after today', preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/', $o['next_proposal_at'] ?? '') && $o['next_proposal_at'] > $o['today']);

// ---- my_week as Priya ----------------------------------------------------------------
echo "overview.my_week (Priya)\n";
[$c, $mw] = call($base, 'overview.php', ['action' => 'my_week'], $priyaTok);
check('200 ok', $c === 200 && ($mw['status'] ?? '') === 'ok', json_encode($mw));
check('person is Priya', stripos($mw['person']['name'] ?? '', 'Priya') !== false);
$days = $mw['week']['days'] ?? [];
check('5 days', count($days) === 5, (string)count($days));
check('week starts Mon 7 Sep', ($mw['week']['week_start'] ?? '') === '2026-09-07' && ($days[0]['dow'] ?? '') === 'Mon');
$tue = null; foreach ($days as $d) if ($d['date'] === '2026-09-08') $tue = $d;
check('Tue 8 Sep present + is_today', $tue && $tue['is_today'] === true);
$wi1038 = array_values(array_filter($tue['assignments'] ?? [], fn($a) => $a['ref'] === 'WI-1038'));
check('WI-1038 assignment on Tue 8 Sep', count($wi1038) > 0, json_encode(array_column($tue['assignments'] ?? [], 'ref')));
if ($wi1038) {
    $a = $wi1038[0];
    foreach (['pct_of_day','progress_pct','day_n','day_total','with','status_label','due','state','allocation_pct','from_date','to_date','type_name','size_stamp'] as $k) check("assignment has $k", array_key_exists($k, $a));
    check('day_n within day_total', $a['day_n'] >= 1 && $a['day_n'] <= $a['day_total'], "{$a['day_n']} of {$a['day_total']}");
}
foreach (['hours_available','hours_assigned','leave'] as $k) check("day has $k", array_key_exists($k, $days[0] ?? []));
check('changes_affecting is array', is_array($mw['changes_affecting'] ?? null));
check('reserve shape', isset($mw['reserve']['pct'], $mw['reserve']['hours_week'], $mw['reserve']['used_hours']));
check('reserve pct 12 or 25', in_array((float)($mw['reserve']['pct'] ?? 0), [12.0, 25.0], true));
check('coming_up is array with state_label', is_array($mw['coming_up'] ?? null) && (!$mw['coming_up'] || isset($mw['coming_up'][0]['state_label'])));
check('load_pct numeric', is_int($mw['load_pct'] ?? null));
[$c, $mw2] = call($base, 'overview.php', ['action' => 'my_week', 'week_start' => '2026-09-14'], $priyaTok);
check('my_week next week ok', $c === 200 && ($mw2['week']['week_start'] ?? '') === '2026-09-14');
[$c, $mw3] = call($base, 'overview.php', ['action' => 'my_week', 'person_id' => $priya['person_id']], $leadTok);
check('lead can view Priya\'s week via person_id', $c === 200 && stripos($mw3['person']['name'] ?? '', 'Priya') !== false);
// a team member may not view someone else's week
$otherPid = null; foreach ($users['users'] as $u) if ($u['person_id'] && $u['person_id'] !== $priya['person_id']) { $otherPid = $u['person_id']; break; }
if ($otherPid) { [$c] = call($base, 'overview.php', ['action' => 'my_week', 'person_id' => $otherPid], $priyaTok); check('team member gets 403 for another person', $c === 403, (string)$c); }
// user without a person -> 403 (if such a user exists)
$noPerson = null; foreach ($users['users'] as $u) if (!$u['person_id']) { $noPerson = $u; break; }
if ($noPerson) { [, $r] = call($base, 'auth.php', ['action' => 'dev_login', 'user_id' => $noPerson['id']]); [$c] = call($base, 'overview.php', ['action' => 'my_week'], $r['token'] ?? ''); check('user without person gets 403', $c === 403, (string)$c); }

// ---- reports -------------------------------------------------------------------------
echo "reports.get\n";
[$c, $rp] = call($base, 'reports.php', ['action' => 'get', 'range' => '12w'], $leadTok);
check('200 ok', $c === 200 && ($rp['status'] ?? '') === 'ok', json_encode($rp));
foreach (['stability','this_week_index','load','accuracy','delivered','cycle_time_delta_pct','definitions'] as $k) check("has $k", array_key_exists($k, $rp));
check('12 stability points for 12w', count($rp['stability'] ?? []) === 12, (string)count($rp['stability'] ?? []));
check('stability point shape', isset($rp['stability'][0]['week_start'], $rp['stability'][0]['label'], $rp['stability'][0]['index_pct']) && array_key_exists('changes_inside_freeze', $rp['stability'][0]) && array_key_exists('note', $rp['stability'][0]));
check('stability labels wNN', preg_match('/^w\d{1,2}$/', $rp['stability'][0]['label'] ?? ''));
check('this_week_index ~92', ($rp['this_week_index'] ?? 0) >= 85 && ($rp['this_week_index'] ?? 0) <= 99, (string)($rp['this_week_index'] ?? 'null'));
check('12 load points', count($rp['load'] ?? []) === 12);
check('load point shape', array_key_exists('planned_pct', $rp['load'][0] ?? []) && array_key_exists('actual_pct', $rp['load'][0] ?? []) && array_key_exists('above_90', $rp['load'][0] ?? []));
$ac = $rp['accuracy'] ?? [];
check('accuracy has points + medians + n', isset($ac['points'], $ac['n']) && array_key_exists('median_sm', $ac) && array_key_exists('median_lc', $ac));
check('accuracy n > 0', ($ac['n'] ?? 0) > 0, (string)($ac['n'] ?? 'null'));
check('accuracy median_sm numeric', is_numeric($ac['median_sm'] ?? null), json_encode($ac['median_sm'] ?? null));
check('accuracy median_lc numeric', is_numeric($ac['median_lc'] ?? null), json_encode($ac['median_lc'] ?? null));
check('accuracy point groups', !array_filter($ac['points'] ?? [], fn($p) => !in_array($p['group'], ['sm','lc'], true)));
check('delivered months non-empty with by_type colours', count($rp['delivered'] ?? []) > 0 && isset($rp['delivered'][0]['by_type'][0]['colour'], $rp['delivered'][0]['by_type'][0]['count']));
check('delivered total > 0 in range', array_sum(array_column($rp['delivered'] ?? [], 'total')) > 0);
check('definitions x4', count(array_filter(['stability','load','accuracy','delivered'], fn($k) => !empty($rp['definitions'][$k]))) === 4);
[$c, $rp4] = call($base, 'reports.php', ['action' => 'get', 'range' => '4w'], $leadTok);
check('4w gives 4 stability points', count($rp4['stability'] ?? []) === 4, (string)count($rp4['stability'] ?? []));
[$c, $rp12m] = call($base, 'reports.php', ['action' => 'get', 'range' => '12m'], $leadTok);
check('12m ok', $c === 200 && count($rp12m['delivered'] ?? []) >= 12);
[$c, $ex] = call($base, 'reports.php', ['action' => 'export_csv', 'report' => 'stability'], $leadTok);
check('export_csv stability', $c === 200 && str_starts_with($ex['csv'] ?? '', 'week_start,label,index_pct'), substr($ex['csv'] ?? json_encode($ex), 0, 80));
[$c, $ex] = call($base, 'reports.php', ['action' => 'export_csv', 'report' => 'accuracy'], $leadTok);
check('export_csv accuracy has rows', $c === 200 && substr_count($ex['csv'] ?? '', "\n") > 1);
[$c] = call($base, 'reports.php', ['action' => 'export_csv', 'report' => 'bogus'], $leadTok);
check('export_csv bogus -> 400', $c === 400);
[$c] = call($base, 'overview.php', ['action' => 'get']);
check('overview without token -> 401', $c === 401);

echo "\n$pass passed, $failN failed\n";
exit($failN ? 1 : 0);
