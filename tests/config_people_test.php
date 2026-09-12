<?php
// End-to-end test for workspace_config.php, people.php, skills.php, notifications.php, audit.php over HTTP.
//   C:\xampp\php\php.exe tests\config_people_test.php
// Starts the built-in server on :8090 if nothing answers there. Needs seed_demo.php to have been run.
$BASE = getenv('DISPATCH_BASE') ?: 'http://localhost:8090/api';
$PHP = 'C:\\xampp\\php\\php.exe';
$ROOT = realpath(__DIR__ . '/..');
$pass = 0; $fail = 0; $skipped = 0; $server = null;

function api($file, array $body, $token = null) {
    global $BASE;
    $headers = "Content-Type: application/json\r\n"; if ($token) $headers .= "Authorization: Bearer $token\r\n";
    $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers, 'content' => json_encode($body), 'ignore_errors' => true, 'timeout' => 30]]);
    $raw = @file_get_contents("$BASE/$file", false, $ctx);
    $code = 0; foreach ($http_response_header ?? [] as $h) if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int)$m[1];
    $j = json_decode((string)$raw, true);
    return [$code, is_array($j) ? $j : ['raw' => $raw]];
}
function check($label, $cond, $detail = '') {
    global $pass, $fail;
    if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label" . ($detail !== '' ? " -- $detail" : '') . "\n"; }
    return (bool)$cond;
}
function skip($label, $why) { global $skipped; $skipped++; echo "  skip $label -- $why\n"; }
function short($v) { $s = json_encode($v, JSON_UNESCAPED_UNICODE); return strlen($s) > 300 ? substr($s, 0, 300) . '…' : $s; }

// ---- server -------------------------------------------------------------------------------
[$code] = api('auth.php', ['action' => 'list_dev_users']);
if ($code === 0) {
    echo "Starting php -S localhost:8090 ...\n";
    $server = proc_open("\"$PHP\" -S localhost:8090 -t \"$ROOT\" \"$ROOT\\router.php\"", [['pipe','r'], ['file', sys_get_temp_dir() . '/dispatch_test_server.log', 'a'], ['file', sys_get_temp_dir() . '/dispatch_test_server.log', 'a']], $pipes);
    for ($i = 0; $i < 30; $i++) { usleep(300000); [$code] = api('auth.php', ['action' => 'list_dev_users']); if ($code) break; }
    if (!$code) { echo "Could not start the API server\n"; exit(2); }
}

// ---- sign in ------------------------------------------------------------------------------
echo "auth\n";
[$code, $r] = api('auth.php', ['action' => 'list_dev_users']);
check('list_dev_users 200', $code === 200 && isset($r['users']), short($r));
$users = $r['users'] ?? [];
if (!$users) { echo "No seeded users - run seed_demo.php first\n"; exit(2); }
$pick = function ($role, $withPerson = null) use ($users) { foreach ($users as $u) if ($u['role'] === $role && ($withPerson === null || ($u['person_id'] !== null) === $withPerson)) return $u; return null; };
$adminU = $pick('admin') ?: $pick('delivery_lead'); $leadU = $pick('delivery_lead') ?: $adminU; $memberU = $pick('team_member', true);
$login = function ($u) { [$c, $r] = api('auth.php', ['action' => 'dev_login', 'user_id' => $u['id']]); return $c === 200 ? $r['token'] : null; };
$admin = $login($adminU); $lead = $login($leadU); $member = $memberU ? $login($memberU) : null;
check('admin token', (bool)$admin); check('delivery lead token', (bool)$lead); check('team member token', (bool)$member, 'no team_member user linked to a person');

// ---- workspace_config ---------------------------------------------------------------------
echo "workspace_config\n";
[$code, $cfg] = api('workspace_config.php', ['action' => 'get'], $lead);
check('get 200', $code === 200, short($cfg));
check('get has workspace/work_types/size_classes/incident_size_classes/policy/day_rates', isset($cfg['workspace'], $cfg['work_types'], $cfg['size_classes'], $cfg['incident_size_classes'], $cfg['policy'], $cfg['day_rates']));
check('4 work types with item_count/open_item_count', count($cfg['work_types'] ?? []) === 4 && isset($cfg['work_types'][0]['item_count'], $cfg['work_types'][0]['open_item_count']), short(array_map(fn($t) => [$t['name'] ?? null, $t['item_count'] ?? null], $cfg['work_types'] ?? [])));
check('incident_size_classes is the interrupt type override', count($cfg['incident_size_classes'] ?? []) >= 1 && ($cfg['incident_size_classes'][0]['work_type_id'] ?? null) === ($cfg['incident_work_type_id'] ?? -1));
check('policy weights decoded to objects', is_array($cfg['policy']['objective_weights'] ?? null) && isset($cfg['policy']['objective_weights']['lateness']) && is_array($cfg['policy']['priority_weights'] ?? null) && isset($cfg['policy']['priority_weights']['value']));
check('policy numeric fields typed', is_int($cfg['policy']['freeze_horizon_days'] ?? null) && is_float($cfg['policy']['incident_reserve_pct'] ?? null));
check('size band planning values present', isset($cfg['size_classes'][0]['planning_days'], $cfg['size_classes'][0]['granularity'], $cfg['size_classes'][0]['counts_for_wip']));
$byName = []; foreach ($cfg['size_classes'] as $s) if ($s['work_type_id'] === null) $byName[$s['name']] = $s;
$large = $byName['Large'] ?? null; $medium = $byName['Medium'] ?? null;

// save_size_class overlap (CFG-05)
if ($large && $medium) {
    [$code, $r] = api('workspace_config.php', ['action' => 'save_size_class', 'id' => $large['id'], 'min_days' => $medium['max_days']], $admin);
    check('overlapping band → 409', $code === 409, "$code " . short($r));
    $expected = "This size band overlaps Medium. Change the start of Large to " . ($medium['max_days'] + 1) . " days or the end of Medium to " . ($medium['max_days'] - 1) . ".";
    check('overlap message wording', ($r['message'] ?? '') === $expected, short($r['message'] ?? null) . " expected " . short($expected));
    check('overlap payload names the band', ($r['overlaps']['name'] ?? null) === 'Medium');
    [$code, $r] = api('workspace_config.php', ['action' => 'save_size_class', 'id' => $large['id'], 'min_days' => $large['min_days']], $admin);
    check('non-overlapping resave → 200', $code === 200 && ($r['size_class']['min_days'] ?? null) == $large['min_days'], short($r));
    [$code, $r] = api('workspace_config.php', ['action' => 'save_size_class', 'id' => $large['id'], 'min_days' => 1], $lead);
    check('save_size_class as delivery lead → 403', $code === 403);
} else skip('size band overlap', 'Large/Medium not seeded');

// rename work type (CFG-01)
$project = null; foreach ($cfg['work_types'] as $t) if ($t['policy'] === 'planned' && $project === null) $project = $t;
[$code, $r] = api('workspace_config.php', ['action' => 'save_work_type', 'id' => $project['id'], 'name' => $project['name'] . ' X'], $admin);
check('rename work type → 200', $code === 200 && ($r['work_type']['name'] ?? null) === $project['name'] . ' X', short($r));
[$code, $r2] = api('workspace_config.php', ['action' => 'get'], $lead);
$renamed = null; foreach ($r2['work_types'] ?? [] as $t) if ($t['id'] === $project['id']) $renamed = $t;
check('rename reflected in get, prefix unchanged', ($renamed['name'] ?? null) === $project['name'] . ' X' && ($renamed['prefix'] ?? null) === $project['prefix']);
api('workspace_config.php', ['action' => 'save_work_type', 'id' => $project['id'], 'name' => $project['name']], $admin);
[$code, $r] = api('workspace_config.php', ['action' => 'save_work_type', 'id' => $project['id'], 'name' => 'Nope'], $lead);
check('save_work_type as delivery lead → 403', $code === 403);

// retire blocked with open items (CFG-03)
$busy = null; foreach ($r2['work_types'] as $t) if (($t['open_item_count'] ?? 0) > 0) { $busy = $t; break; }
if ($busy) {
    [$code, $r] = api('workspace_config.php', ['action' => 'retire_work_type', 'id' => $busy['id']], $admin);
    check('retire with open items → 409 + open_items', $code === 409 && count($r['open_items'] ?? []) === $busy['open_item_count'] && isset($r['open_items'][0]['ref']), "$code " . short($r));
    [$code, $r3] = api('workspace_config.php', ['action' => 'get'], $lead);
    $still = null; foreach ($r3['work_types'] as $t) if ($t['id'] === $busy['id']) $still = $t;
    check('type not retired after blocked attempt', ($still['retired'] ?? true) === false);
} else skip('retire blocked', 'no work type has open items yet (seed_demo items not loaded)');

// policy versioning (CFG-08/09)
$v0 = $cfg['policy']['version'];
[$code, $r] = api('workspace_config.php', ['action' => 'save_policy', 'freeze_horizon_days' => $cfg['policy']['freeze_horizon_days'], 'objective_weights' => ['lateness' => 3]], $admin);
check('save_policy inserts a new version', $code === 200 && ($r['policy']['version'] ?? 0) === $v0 + 1 && ($r['policy']['is_current'] ?? false) === true, short($r));
[$code, $r] = api('workspace_config.php', ['action' => 'export'], $lead);
check('export in Appendix A shape', $code === 200 && isset($r['config']['workspace']['workingWeek'], $r['config']['workTypes'][0]['requiresEstimate'], $r['config']['sizeClasses'][0]['stamp'], $r['config']['policy']['freezeHorizonDays'], $r['config']['objectiveWeights'], $r['config']['priorityWeights']), short(array_keys($r['config'] ?? [])));

// ---- people -------------------------------------------------------------------------------
echo "people\n";
[$code, $pl] = api('people.php', ['action' => 'list'], $lead);
check('list 200 with 8 people', $code === 200 && count($pl['people'] ?? []) === 8, short(count($pl['people'] ?? [])));
$allLoad = true; foreach ($pl['people'] ?? [] as $p) if (!is_int($p['load_pct'] ?? null)) $allLoad = false;
check('every person has a numeric load_pct', $allLoad, short(array_map(fn($p) => [$p['name'], $p['load_pct'] ?? null], $pl['people'] ?? [])));
check('person shape (working_pattern decoded, skills, on_rota_weeks, team_name)', is_array($pl['people'][0]['working_pattern'] ?? null) && isset($pl['people'][0]['skills'], $pl['people'][0]['on_rota_weeks']) && array_key_exists('team_name', $pl['people'][0]));
check('teams returned', count($pl['teams'] ?? []) >= 1);
$priya = null; $jon = null; foreach ($pl['people'] as $p) { if (str_starts_with($p['name'], 'Priya')) $priya = $p; if (str_starts_with($p['name'], 'Jon')) $jon = $p; }
check('Priya and Jon present', $priya && $jon);

[$code, $pg] = api('people.php', ['action' => 'get', 'id' => $priya['id']], $lead);
check('get 200', $code === 200, short($pg));
check('stats tiles present', isset($pg['stats']['load_pct_4w'], $pg['stats']['concurrent_now'], $pg['stats']['concurrent_max'], $pg['stats']['changes_8w'], $pg['stats']['team_median_changes_8w']) && array_key_exists('next_rota_week', $pg['stats']), short($pg['stats'] ?? null));
check('skills with single_point/endorsed_by', count($pg['skills'] ?? []) > 0 && array_key_exists('single_point', $pg['skills'][0]) && is_array($pg['skills'][0]['endorsed_by']));
$tf = null; foreach ($pg['skills'] ?? [] as $s) if ($s['name'] === 'Terraform') $tf = $s;
check('Priya Terraform = 3 and single point', $tf && $tf['proficiency'] === 3 && $tf['single_point'] === true, short($tf));
check('change_history has 8 weeks', count($pg['change_history'] ?? []) === 8 && isset($pg['change_history'][0]['week_start'], $pg['change_history'][0]['changes'], $pg['change_history'][0]['inside_freeze']));
check('stability_note sentence', preg_match('/^[A-Z][a-z]+ changes? in eight weeks.*Team median is [a-z0-9.]+\.$/', $pg['stability_note'] ?? '') === 1, short($pg['stability_note'] ?? null));
check('next rota note', $pg['stats']['next_rota_week'] === null || str_starts_with($pg['stats']['next_rota_note'], 'Reserve rises to'));
check('assignments is a list of committed-plan rows', is_array($pg['assignments']) && (!$pg['assignments'] || isset($pg['assignments'][0]['ref'], $pg['assignments'][0]['role_label'], $pg['assignments'][0]['state'])));
check('pattern labels', isset($pg['pattern']['hours_label'], $pg['pattern']['max_concurrent_label'], $pg['pattern']['focus_label']));

// add_availability → capacity zero days + trigger (TEAM-06, ADM-05)
$from = '2026-10-12'; $to = '2026-10-13';
[$code, $r] = api('people.php', ['action' => 'add_availability', 'person_id' => $jon['id'], 'from_date' => $from, 'to_date' => $to, 'type' => 'leave', 'reason' => 'dentist', 'note' => 'private'], $lead);
check('add_availability 200', $code === 200 && isset($r['availability']['id']), short($r));
$availId = $r['availability']['id'] ?? null;
check('no reason/note stored or echoed', !isset($r['availability']['reason']) && !isset($r['availability']['note']) && strpos(json_encode($r), 'dentist') === false);
check('trigger created, batched (outside freeze horizon)', ($r['trigger']['class'] ?? null) === 'batched' && is_int($r['trigger']['id'] ?? null), short($r['trigger'] ?? null));
check('days_written > 0', ($r['days_written'] ?? 0) === 2);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => $from, 'to' => $to], $lead);
$zero = true; foreach ($c['days'] ?? [] as $d) if ($d['available_hours'] != 0 || $d['reserve_hours'] != 0) $zero = false;
check('capacity rows are 0/0 on leave days', $code === 200 && count($c['days'] ?? []) === 2 && $zero, short($c));
[$code, $r] = api('people.php', ['action' => 'add_availability', 'person_id' => $jon['id'], 'from_date' => '2026-09-10', 'to_date' => '2026-09-10', 'type' => 'sickness'], $lead);
check('inside freeze horizon → urgent trigger', ($r['trigger']['class'] ?? null) === 'urgent', short($r['trigger'] ?? null));
$sickId = $r['availability']['id'] ?? null;
[$code, $r] = api('people.php', ['action' => 'delete_availability', 'id' => $availId], $lead);
check('delete manual availability 200', $code === 200);
if ($sickId !== null) api('people.php', ['action' => 'delete_availability', 'id' => $sickId], $lead);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => $from, 'to' => $to], $lead);
check('capacity restored after delete', ($c['days'][0]['available_hours'] ?? 0) == 7.5 && ($c['days'][0]['reserve_hours'] ?? 0) == 0.9, short($c));
$hr = null; foreach ($pg['availability'] ?? [] as $a) if ($a['source'] !== 'manual') $hr = $a;
if ($hr) { [$code] = api('people.php', ['action' => 'delete_availability', 'id' => $hr['id']], $lead); check('imported availability cannot be deleted → 409', $code === 409); }
else skip('imported availability 409', 'no non-manual record for Priya');
[$code, $r] = api('people.php', ['action' => 'add_availability', 'person_id' => $jon['id'], 'from_date' => $from, 'to_date' => $to, 'type' => 'holiday'], $lead);
check('bad type → 400', $code === 400);

// rota → reserve 25%
[$code, $r] = api('people.php', ['action' => 'set_rota', 'person_id' => $jon['id'], 'week_start' => '2026-11-16'], $lead);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => '2026-11-16', 'to' => '2026-11-16'], $lead);
check('rota week reserve = 25% of 7.5h', ($c['days'][0]['reserve_hours'] ?? 0) == 1.88, short($c));
api('people.php', ['action' => 'clear_rota', 'person_id' => $jon['id'], 'week_start' => '2026-11-16'], $lead);
[$code, $c] = api('people.php', ['action' => 'capacity', 'person_id' => $jon['id'], 'from' => '2026-11-16', 'to' => '2026-11-16'], $lead);
check('reserve back to 12% after clear_rota', ($c['days'][0]['reserve_hours'] ?? 0) == 0.9);

// role checks
if ($member) {
    $ownId = $memberU['person_id']; $other = $ownId === $priya['id'] ? $jon : $priya;
    [$code, $r] = api('people.php', ['action' => 'save', 'id' => $other['id'], 'tagline' => 'hacked'], $member);
    check("team_member cannot save another person's profile → 403", $code === 403, "$code " . short($r));
    [$code, $r] = api('people.php', ['action' => 'save', 'id' => $ownId, 'prefers' => 'Own-profile test'], $member);
    check('team_member can save own profile', $code === 200 && ($r['person']['prefers'] ?? null) === 'Own-profile test', "$code " . short($r));
    [$code, $r] = api('people.php', ['action' => 'set_skill', 'person_id' => $other['id'], 'skill_id' => 0, 'proficiency' => 4], $member);
    check("team_member cannot set another person's skill → 403", $code === 403);
    [$code, $r] = api('people.php', ['action' => 'deactivate', 'id' => $other['id']], $member);
    check('team_member cannot deactivate → 403', $code === 403);
    [$code, $r] = api('people.php', ['action' => 'add_availability', 'person_id' => $other['id'], 'from_date' => $from, 'to_date' => $to, 'type' => 'leave'], $member);
    check("team_member cannot add another person's leave → 403", $code === 403);
}
[$code, $r] = api('people.php', ['action' => 'recompute_capacity', 'from' => '2026-09-07', 'to' => '2026-09-18'], $lead);
check('recompute_capacity writes 8 people × 10 days', $code === 200 && ($r['days_written'] ?? 0) === 80, short($r));

// ---- skills -------------------------------------------------------------------------------
echo "skills\n";
[$code, $sl] = api('skills.php', ['action' => 'list'], $lead);
check('list 200 with demand/supply fields', $code === 200 && count($sl['skills'] ?? []) >= 10 && isset($sl['skills'][0]['people_at_3_plus'], $sl['skills'][0]['demand_days_6w'], $sl['skills'][0]['supply_days_6w'], $sl['skills'][0]['single_point']), short($sl));
[$code, $m] = api('skills.php', ['action' => 'matrix'], $lead);
check('matrix 200 with skills/people/cells/summary/availability_4w/development/demand_vs_supply', $code === 200 && isset($m['skills'], $m['people'], $m['cells'], $m['summary'], $m['availability_4w'], $m['development'], $m['demand_vs_supply']), short(array_keys($m)));
$tfSkill = null; foreach ($m['skills'] as $s) if ($s['name'] === 'Terraform') $tfSkill = $s;
$cell = $m['cells'][$priya['id'] . ':' . $tfSkill['id']] ?? null;
check('cell Priya:Terraform proficiency = 3', ($cell['proficiency'] ?? null) === 3, short($cell));
check('summary.single_point_skills contains Terraform', in_array('Terraform', $m['summary']['single_point_skills'] ?? [], true), short($m['summary'] ?? null));
check('Terraform footer people_at_3_plus = 1', ($tfSkill['people_at_3_plus'] ?? null) === 1);
check('people carry load_pct', is_int($m['people'][0]['load_pct'] ?? null));
$kinds = array_unique(array_map(fn($a) => $a['kind'], $m['availability_4w']));
check('availability_4w has pattern + rota rows', in_array('pattern', $kinds, true) && in_array('rota', $kinds, true), short($m['availability_4w']));
$pat = null; foreach ($m['availability_4w'] as $a) if ($a['kind'] === 'pattern' && str_starts_with($a['person'], 'Priya')) $pat = $a;
check('Priya pattern label "0.5 day Fridays, ongoing"', ($pat['label'] ?? null) === '0.5 day Fridays, ongoing', short($pat));
$rotaRow = null; foreach ($m['availability_4w'] as $a) if ($a['kind'] === 'rota') { $rotaRow = $a; break; }
check('rota row badge "Reserve 25%"', ($rotaRow['badge'] ?? null) === 'Reserve 25%' && str_starts_with($rotaRow['label'] ?? '', 'incident rota w/c '));
check('development rows shaped', !$m['development'] || isset($m['development'][0]['from_level'], $m['development'][0]['to_level'], $m['development'][0]['pairing_enabled'], $m['development'][0]['note']));
check('demand_vs_supply exceeds flags are bools', is_bool($m['demand_vs_supply'][0]['exceeds'] ?? null));
[$code, $r] = api('skills.php', ['action' => 'save', 'name' => 'Terraform'], $admin);
check('duplicate skill name → 409', $code === 409);
[$code, $r] = api('skills.php', ['action' => 'save', 'name' => 'Zig test skill', 'category' => 'Test'], $lead);
check('skills.save as delivery lead → 403', $code === 403);

// ---- notifications + audit ------------------------------------------------------------------
echo "notifications / audit\n";
[$code, $n] = api('notifications.php', ['action' => 'list'], $lead);
check('notifications list 200 with unread count', $code === 200 && isset($n['notifications']) && is_int($n['unread'] ?? null), short($n));
[$code, $r] = api('notifications.php', ['action' => 'prefs'], $lead);
check('prefs has 7 default kinds', $code === 200 && count($r['prefs'] ?? []) === 7 && ($r['prefs'][0]['is_default'] ?? null) !== null);
[$code, $r] = api('notifications.php', ['action' => 'save_prefs', 'kind' => 'change_committed', 'teams' => true, 'digest' => 'weekly'], $lead);
$cc = null; foreach ($r['prefs'] ?? [] as $p) if ($p['kind'] === 'change_committed') $cc = $p;
check('save_prefs persists', $code === 200 && ($cc['teams'] ?? null) === true && ($cc['digest'] ?? null) === 'weekly', short($cc));
[$code, $r] = api('notifications.php', ['action' => 'mark_read', 'all' => true], $lead);
check('mark_read all', $code === 200 && ($r['unread'] ?? 1) === 0);

[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'availability', 'limit' => 5], $admin);
check('audit list 200 with events/total', $code === 200 && isset($a['events'], $a['total']) && $a['total'] >= 2, short($a));
check('audit event shape (actor_name, action, entity, entity_label, before/after decoded)', isset($a['events'][0]['actor_name'], $a['events'][0]['action'], $a['events'][0]['entity']) && array_key_exists('entity_label', $a['events'][0]) && (is_array($a['events'][0]['after']) || is_array($a['events'][0]['before'])), short($a['events'][0] ?? null));
[$code, $a] = api('audit.php', ['action' => 'list', 'q' => 'Scheduling policy'], $admin);
check('audit q filter finds the policy change', $code === 200 && ($a['total'] ?? 0) >= 1);
[$code, $r] = api('audit.php', ['action' => 'export_csv', 'entity' => 'availability'], $admin);
check('audit export_csv returns csv', $code === 200 && str_starts_with($r['csv'] ?? '', 'id,occurred_at,actor'));
[$code] = api('audit.php', ['action' => 'list'], $lead);
check('audit as delivery lead → 403', $code === 403);

// ---- done ---------------------------------------------------------------------------------
echo "\n$pass passed, $fail failed, $skipped skipped\n";
if ($server) proc_terminate($server);
exit($fail ? 1 : 0);
