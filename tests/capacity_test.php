<?php
// Supply-side tests: public holidays, working patterns, leave balances and the one piece of
// arithmetic that decides what a person-day is worth.
//   php tests/capacity_test.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php). Re-seed after
// running: it adds and removes holidays, edits a pattern and books leave.
//
// The thing under test is that there is now ONE implementation of "hours on a day". There used to
// be five, and two of them disagreed about overlapping leave, so the planner and the person page
// could give different answers for the same Tuesday.
require_once __DIR__ . '/_auth.php';

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr((string)$raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function near($a, $b, $tol, $label) { check(abs((float)$a - (float)$b) <= $tol, "$label (got " . var_export($a, true) . ", want ~$b +/-$tol)"); }
function section($t) { echo "\n== $t\n"; }
function login($who) { global $token; $token = strpos($who, '@') !== false ? token_for_email($who) : token_for($who); return $token; }

/** Capacity for one person over a window, as [day => available]. */
function capacity_days($personId, $from, $to) {
    [, $r] = api('people', ['action' => 'capacity', 'person_id' => $personId, 'from' => $from, 'to' => $to]);
    $out = [];
    foreach ($r['days'] ?? [] as $d) if ((int)$d['person_id'] === $personId) $out[substr($d['day'], 0, 10)] = (float)$d['available_hours'];
    return $out;
}

section('sign in');
check(login('admin') !== null, 'an administrator token');
[, $P] = api('people', ['action' => 'list']);
$people = [];
foreach ($P['people'] as $p) $people[$p['name']] = $p;
$priya = (int)$people['Priya Kaur']['id'];      // Mon-Thu full, Fri half day (3.75h)
$lena  = (int)$people['Lena Torres']['id'];     // Mon-Thu, no Friday at all
$jon   = (int)$people['Jon Okafor']['id'];      // full time
check($priya > 0 && $lena > 0 && $jon > 0, 'the three patterns under test are present');

section('the working pattern decides the day, not the workspace');
$week = capacity_days($priya, '2026-09-07', '2026-09-13');
near($week['2026-09-07'] ?? 0, 7.5, 0.01, 'Priya Monday is a full day');
near($week['2026-09-11'] ?? 0, 3.75, 0.01, 'Priya Friday is a half day');
check(!isset($week['2026-09-12']) && !isset($week['2026-09-13']), 'no rows are written for the weekend');
$lenaWeek = capacity_days($lena, '2026-09-07', '2026-09-11');
near($lenaWeek['2026-09-11'] ?? -1, 0, 0.01, 'Lena Friday is zero: she does not work it');

section('public holidays are zero hours for everyone');
[, $H] = api('holidays', ['action' => 'list', 'from' => '2026-01-01', 'to' => '2027-12-31']);
$byDay = [];
foreach ($H['holidays'] as $h) $byDay[$h['day']] = $h['label'];
check(count($H['holidays']) >= 16, 'the demo seeds two years of bank holidays (' . count($H['holidays']) . ')');
foreach (['2026-01-01' => "New Year's Day", '2026-04-03' => 'Good Friday', '2026-04-06' => 'Easter Monday',
          '2026-05-04' => 'Early May bank holiday', '2026-05-25' => 'Spring bank holiday',
          '2026-08-31' => 'Summer bank holiday', '2026-12-25' => 'Christmas Day', '2026-12-28' => 'Boxing Day'] as $day => $label) {
    check(($byDay[$day] ?? null) === $label, "2026 England and Wales: $day is $label" . (isset($byDay[$day]) ? '' : ' (missing)'));
}
check(($byDay['2026-12-28'] ?? '') === 'Boxing Day', 'Boxing Day 2026 falls on a Saturday and substitutes to Monday 28 December');

$xmas = capacity_days($jon, '2026-12-21', '2026-12-31');
near($xmas['2026-12-25'] ?? -1, 0, 0.01, 'Christmas Day has no hours');
near($xmas['2026-12-28'] ?? -1, 0, 0.01, 'the substitute Boxing Day has none either');
near($xmas['2026-12-24'] ?? 0, 7.5, 0.01, 'Christmas Eve is an ordinary working day');

section('adding and removing a holiday rewrites capacity');
[, $A] = api('holidays', ['action' => 'save', 'day' => '2026-10-12', 'label' => 'Company shutdown']);
$hid = (int)$A['holiday']['id'];
check($A['holiday']['source'] === 'manual', 'a hand-entered day is marked manual');
check($A['capacity_days_rewritten'] > 0, "adding it rewrote {$A['capacity_days_rewritten']} capacity days");
near(capacity_days($jon, '2026-10-12', '2026-10-12')['2026-10-12'] ?? -1, 0, 0.01, 'and that Monday is now zero for everyone');
api('holidays', ['action' => 'save', 'day' => '2026-10-12', 'label' => 'Duplicate'], 409);
[, $D] = api('holidays', ['action' => 'delete', 'id' => $hid]);
check($D['deleted'] === true, 'removing it works');
near(capacity_days($jon, '2026-10-12', '2026-10-12')['2026-10-12'] ?? -1, 7.5, 0.01, 'and the day comes back');

section('who may change the calendar');
login('lena.torres@example.org');   // a team lead
api('holidays', ['action' => 'save', 'day' => '2026-10-13', 'label' => 'Not allowed'], 403);
[, $R] = api('holidays', ['action' => 'list']);
check($R['can_edit'] === false, 'a team lead is told they cannot edit it, so the client hides the controls');
check(count($R['holidays']) > 0, 'but can read the calendar, because every screen that draws a week needs it');
login('admin');

section('leave is counted in the person own days');
// Lena works Monday to Thursday. A full week off is four days of leave, not five.
[, $L] = api('people', ['action' => 'add_availability', 'person_id' => $lena, 'from_date' => '2026-10-19', 'to_date' => '2026-10-23', 'type' => 'leave']);
$leaveId = (int)$L['availability']['id'];
[, $LP] = api('people', ['action' => 'get', 'id' => $lena]);
near($LP['leave']['booked_days'], 4, 0.01, 'Lena books four days for a Monday-to-Friday week, not five');
check($LP['leave']['entitlement_source'] === 'workspace', 'she uses the workspace default entitlement');
near($LP['leave']['remaining_days'], (float)$LP['leave']['entitlement_days'] - 4, 0.01, 'and the remainder follows');

// Priya's Friday is a half day, so a week costs 4.5 — and she has her own entitlement.
[, $L2] = api('people', ['action' => 'add_availability', 'person_id' => $priya, 'from_date' => '2026-11-02', 'to_date' => '2026-11-06', 'type' => 'leave']);
[, $PP] = api('people', ['action' => 'get', 'id' => $priya]);
near($PP['leave']['booked_days'], 5, 0.01, 'a booked day is a booked day: Priya spends five, whole or half');
check($PP['leave']['entitlement_days'] == 30 && $PP['leave']['entitlement_source'] === 'person', 'Priya has her own 30-day entitlement');

// A bank holiday inside a booking costs nobody any leave.
[, $L3] = api('people', ['action' => 'add_availability', 'person_id' => $jon, 'from_date' => '2026-12-21', 'to_date' => '2026-12-31', 'type' => 'leave']);
[, $JP] = api('people', ['action' => 'get', 'id' => $jon]);
near($JP['leave']['booked_days'], 7, 0.01, 'nine weekdays over Christmas minus two bank holidays is seven days of leave');

section('correcting a record (TEAM-07)');
[, $U] = api('people', ['action' => 'update_availability', 'id' => $leaveId, 'to_date' => '2026-10-21']);
check($U['availability']['to_date'] === '2026-10-21', 'the dates can be corrected');
[, $LP2] = api('people', ['action' => 'get', 'id' => $lena]);
near($LP2['leave']['booked_days'], 3, 0.01, 'shortening the leave hands the days back to the balance');
near(capacity_days($lena, '2026-10-22', '2026-10-22')['2026-10-22'] ?? -1, 7.5, 0.01, 'and to capacity');

// An imported record may be corrected but never deleted here.
[, $LG] = api('people', ['action' => 'get', 'id' => (int)$people['Hana Novak']['id']]);
$hr = null;
foreach ($LG['availability'] as $a) if ($a['source'] === 'hr') { $hr = $a; break; }
check($hr !== null, 'the demo has an imported leave record to test with');
if ($hr) {
    api('people', ['action' => 'update_availability', 'id' => $hr['id'], 'type' => 'training']);
    api('people', ['action' => 'delete_availability', 'id' => $hr['id']], 409);
    check(true, 'an imported record is correctable but not deletable');
    api('people', ['action' => 'update_availability', 'id' => $hr['id'], 'type' => 'leave']);
}

section('a pattern can be changed, and a weekend worker exists');
[, $SP] = api('people', ['action' => 'save', 'id' => $jon,
    'working_pattern' => ['Mon' => 7.5, 'Tue' => 7.5, 'Wed' => 7.5, 'Thu' => 7.5, 'Sat' => 6],
    'pattern_label' => 'Mon–Thu and Saturdays']);
check($SP['person']['working_pattern']['Sat'] == 6, 'a Saturday can be part of a working pattern');
near($SP['person']['days_per_week'], 4.8, 0.05, 'days per week is re-derived from the hours');
$sat = capacity_days($jon, '2026-10-10', '2026-10-16');
near($sat['2026-10-10'] ?? -1, 6, 0.01, 'and Saturday 10 October now has capacity');
near($sat['2026-10-16'] ?? -1, 0, 0.01, 'while the Friday he dropped has none');
// Put him back so the rest of the demo is unchanged.
api('people', ['action' => 'save', 'id' => $jon,
    'working_pattern' => ['Mon' => 7.5, 'Tue' => 7.5, 'Wed' => 7.5, 'Thu' => 7.5, 'Fri' => 7.5], 'pattern_label' => 'Mon–Fri full time']);

section('the schedule and the digest agree with all of it');
login('delivery_lead');
[, $S] = api('plan', ['action' => 'schedule', 'from' => '2026-12-21', 'to' => '2026-12-31']);
$holidayBlocks = array_values(array_filter($S['availability'], fn($a) => $a['type'] === 'holiday'));
check(count($holidayBlocks) > 0, 'the schedule marks public holidays as away time (' . count($holidayBlocks) . ' blocks)');
$labels = array_unique(array_map(fn($a) => $a['label'], $holidayBlocks));
check(in_array('Christmas Day', $labels, true), 'named, not blank: ' . implode(', ', $labels));

login('lena.torres@example.org');
[, $DG] = api('digest', ['action' => 'preview']);
near($DG['digest']['summary']['capacity_days'], 4, 0.01, "a Mon-Thu worker's digest week is four days, not five");

echo "\n" . str_repeat('-', 60) . "\n";
echo "capacity, holidays and leave: $pass passed, $fail failed\n";
echo "Re-seed before using the demo again: php seed_demo.php\n";
exit($fail ? 1 : 0);
