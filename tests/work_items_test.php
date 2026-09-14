<?php
// CLI HTTP tests for work_items.php / estimates.php / benefits.php / engine/priority.php.
//   php tests/work_items_test.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php). Re-seed after running:
// the tests create WI-1072 and mutate WI-1042's estimate/benefits.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 60]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr($raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function near($a, $b, $tol, $label) { check(abs((float)$a - (float)$b) <= $tol, "$label (got " . var_export($a, true) . ", want ≈$b ±$tol)"); }

echo "== sign in as delivery lead\n";
[, $users] = api('auth', ['action' => 'list_dev_users']);
$lead = null; foreach ($users['users'] ?? [] as $u) if ($u['role'] === 'delivery_lead') { $lead = $u; break; }
check($lead !== null, 'a delivery_lead dev user exists');
[, $login] = api('auth', ['action' => 'dev_login', 'user_id' => $lead['id']]);
$token = $login['token'] ?? null; check(!empty($token), 'dev_login returns a token');

echo "== list\n";
[, $L] = api('work_items', ['action' => 'list']);
check(count($L['items']) >= 40, 'list returns ≥40 items (' . count($L['items']) . ')');
check($L['total'] === count($L['items']), 'total matches item count without paging');
foreach (['all','unscheduled','scheduled','in_progress','delivered','needs_estimate','needs_benefit','skills_gap'] as $k) check(isset($L['counts'][$k]), "counts.$k present");
check($L['counts']['unscheduled'] > 0 && $L['counts']['needs_estimate'] > 0, "counts: unscheduled={$L['counts']['unscheduled']} needs_estimate={$L['counts']['needs_estimate']}");
check(isset($L['queue_health']['needs_estimate']['oldest_days']), 'queue_health.needs_estimate.oldest_days present');
$first = $L['items'][0];
foreach (['id','ref','title','work_type_id','type_name','type_colour','type_policy','size_stamp','is_custom','status','priority_score','benefit_value','rom_low','rom_high','rom_unit','skills','needed_by','planned_from','planned_to','assignees','requested_by','sponsor','progress_pct','created_at','updated_at'] as $k) check(array_key_exists($k, $first), "WorkItemRow.$k present");
$scores = array_map(fn($i) => $i['priority_score'] ?? 0, $L['items']);
check($scores === array_values(array_filter($scores, fn($s) => true)) && $scores[0] >= end($scores), 'default sort is priority_score desc');
$byRef = []; foreach ($L['items'] as $i) $byRef[$i['ref']] = $i;
check(isset($byRef['WI-1042']), 'WI-1042 is in the list');
if (isset($byRef['WI-1042'])) { $r = $byRef['WI-1042']; check($r['size_stamp'] === 'L' && $r['type_name'] === 'Project', 'WI-1042 is a Large Project'); near($r['rom_low'], 28, 0.01, 'WI-1042 rom_low'); near($r['rom_high'], 52, 0.01, 'WI-1042 rom_high'); check($r['benefit_value'] === 210000, 'WI-1042 benefit_value 210000'); check(count($r['assignees']) === 3, 'WI-1042 has 3 assignees from the committed plan'); check($r['planned_from'] === '2026-09-21' && $r['planned_to'] === '2026-11-13', "WI-1042 planned window {$r['planned_from']}..{$r['planned_to']}"); }
$custom = array_filter($L['items'], fn($i) => $i['is_custom']); check(count($custom) >= 1 && reset($custom)['size_stamp'] === 'C', 'custom-size items carry stamp C');
[, $F] = api('work_items', ['action' => 'list', 'status' => 'unscheduled']);
check(count($F['items']) === $L['counts']['unscheduled'], 'status=unscheduled filter count matches counts.unscheduled');
check(count(array_filter($F['items'], fn($i) => $i['planned_from'] !== null)) === 0, 'unscheduled items have no committed window');
[, $F] = api('work_items', ['action' => 'list', 'status' => 'needs_estimate']); check(count($F['items']) === $L['counts']['needs_estimate'] && count(array_filter($F['items'], fn($i) => $i['status'] !== 'needs_estimate')) === 0, 'status=needs_estimate filter');
[, $F] = api('work_items', ['action' => 'list', 'status' => 'delivered']); check(count($F['items']) === $L['counts']['delivered'], 'status=delivered filter matches count');
[, $F] = api('work_items', ['action' => 'list', 'type_id' => $byRef['WI-1042']['work_type_id'] ?? 0]); check(count($F['items']) > 0 && count(array_filter($F['items'], fn($i) => $i['type_name'] !== 'Project')) === 0, 'type_id filter');
[, $F] = api('work_items', ['action' => 'list', 'size_stamp' => 'L']); check(count($F['items']) > 0 && count(array_filter($F['items'], fn($i) => $i['size_stamp'] !== 'L')) === 0, 'size_stamp=L filter');
[, $F] = api('work_items', ['action' => 'list', 'q' => 'supplier']); check(count($F['items']) >= 1 && isset(array_column($F['items'], null, 'ref')['WI-1042']), 'q=supplier finds WI-1042');
$tf = null; foreach ($byRef['WI-1042']['skills'] ?? [] as $s) if ($s['name'] === 'Terraform') $tf = $s['skill_id'];
[, $F] = api('work_items', ['action' => 'list', 'skill_id' => $tf]); check(count($F['items']) >= 1 && count(array_filter($F['items'], fn($i) => !in_array('Terraform', array_column($i['skills'], 'name'), true))) === 0, 'skill_id=Terraform filter');
[, $F] = api('work_items', ['action' => 'list', 'sort' => 'benefit_value', 'dir' => 'desc', 'limit' => 5]); check(count($F['items']) === 5 && $F['total'] === $L['total'] && $F['items'][0]['benefit_value'] >= $F['items'][4]['benefit_value'], 'sort=benefit_value desc + limit 5 keeps total');

echo "== get WI-1042\n";
[, $G] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
$it = $G['item'];
check(count($it['skills']) === 5, 'WI-1042 declares 5 skills (' . count($it['skills']) . ')');
$tfs = null; foreach ($it['skills'] as $s) if ($s['name'] === 'Terraform') $tfs = $s;
check($tfs && $tfs['single_point'] === true && $tfs['coverage_count'] === 1 && $tfs['coverage_label'] === 'Only Priya is L3', 'Terraform single point: ' . ($tfs['coverage_label'] ?? '-'));
$db = null; foreach ($it['skills'] as $s) if ($s['name'] === 'Databricks') $db = $s;
check($db && $db['single_point'] === false && preg_match('/^\d+ people at L3 or above$/', $db['coverage_label']), 'Databricks coverage label: ' . ($db['coverage_label'] ?? '-'));
check(in_array('WI-1033', array_column($it['dependencies']['needs'], 'ref'), true), 'dependencies.needs includes WI-1033');
check(in_array('WI-1068', array_column($it['dependencies']['unblocks'], 'ref'), true), 'dependencies.unblocks includes WI-1068');
$e = $it['estimate'];
check($e && (int)$e['version'] === 3 && $e['method'] === 'three_point', 'latest estimate is v3 three-point');
near($e['expected'] ?? 0, 37.3, 0.06, 'estimate.expected'); near($e['p80'] ?? 0, 40.7, 0.06, 'estimate.p80'); near($e['sd'] ?? 0, 4.0, 0.06, 'estimate.sd');
check(($e['implied_stamp'] ?? '') === 'L', 'estimate.implied_stamp L');
check(($e['cost_likely'] ?? 0) === 25200, 'estimate.cost_likely 25200 (36 × £700)');
check(($e['cost_low'] ?? 0) === 17640 && ($e['cost_high'] ?? 0) === 32760, 'estimate cost range ±30%');
check($it['estimate_count'] === 3, 'estimate_count 3');
check($it['benefit_total'] === 210000 && count($it['benefits']) === 3, 'benefit_total 210000 over 3 benefits');
check($it['benefit_confidence'] === 'medium', 'benefit_confidence medium');
near($it['payback_months'], 1.5, 0.1, 'payback_months');
check($it['plan']['planned_from'] === '2026-09-21' && $it['plan']['slack_days'] === 10 && $it['plan']['slack_label'] === '2 weeks slack', 'plan slack: ' . json_encode([$it['plan']['slack_days'], $it['plan']['slack_label']]));
check(in_array($it['plan']['stability_label'], ['Steady','Moving'], true) && isset($it['plan']['changes_30d']), 'plan.stability_label ' . $it['plan']['stability_label']);
check(isset($it['readiness']['items']) && $it['readiness']['ready'] === true, 'readiness complete for WI-1042');
check(count($it['tasks']) === 7, 'tasks (7)');
check(count($it['comments']) >= 1, 'comments present');
check(isset($it['priority_terms']['value']['contribution']), 'priority_terms present');
$pt = $it['priority_terms'];
echo "     terms: value {$pt['value']['normalised']}→{$pt['value']['contribution']}, urgency {$pt['urgency']['normalised']}→{$pt['urgency']['contribution']}, risk {$pt['risk']['normalised']}→{$pt['risk']['contribution']}, leverage {$pt['leverage']['normalised']}→{$pt['leverage']['contribution']}, age {$pt['age']['normalised']}→{$pt['age']['contribution']}, raw {$pt['raw_total']} scaled {$pt['scaled']}\n";
near($pt['value']['normalised'], 0.37, 0.06, 'Appendix B value normalised ≈0.37');
check($pt['value']['input'] === 147000, 'Appendix B value input £147k (210k × 0.7)');
near($pt['urgency']['normalised'], 0.75, 0.1, 'Appendix B urgency ≈0.75-0.80 (2 weeks slack)');
near($pt['risk']['normalised'], 0.6, 0.001, 'Appendix B risk 0.60');
near($pt['leverage']['normalised'], 0.10, 0.03, 'Appendix B leverage ≈0.10 (WI-1068 £95k low → £38k)');
check(in_array('WI-1068', $pt['leverage']['unblocks'], true), 'leverage lists WI-1068');
near($pt['age']['normalised'], 0.25, 0.1, 'Appendix B age ≈0.25 (3 of 12 weeks)');
near($pt['raw_total'], 47.2, 4, 'Appendix B raw total ≈47.2');
check($pt['scaled'] >= 60 && $pt['scaled'] <= 100, "scaled score in a sensible band ({$pt['scaled']})");
check($it['priority_score'] === $pt['scaled'], 'priority_score equals terms.scaled');

echo "== create a Project item -> WI-1072\n";
$sk = ['Power BI' => null, 'Data modelling' => null];
foreach ($L['items'] as $i) foreach ($i['skills'] as $s) if (array_key_exists($s['name'], $sk)) $sk[$s['name']] = $s['skill_id'];
[, $C] = api('work_items', ['action' => 'create', 'title' => 'Vendor risk scoring dashboard v2', 'work_type_id' => $byRef['WI-1042']['work_type_id'], 'size_stamp' => 'M', 'needed_by' => '2026-11-30', 'sponsor' => 'Head of Procurement', 'requested_by' => 'Procurement', 'summary' => 'Test item created by tests/work_items_test.php',
    'skills' => [['skill_id' => $sk['Power BI'], 'min_proficiency' => 3], ['skill_id' => $sk['Data modelling'], 'min_proficiency' => 2]], 'benefit' => ['type' => 'compliance', 'annual_value' => 95000, 'confidence' => 'low', 'realisation_from' => '2027-04-01', 'owner_name' => 'Finance Benefit Owner']]);
$new = $C['item'] ?? [];
check(($new['ref'] ?? '') === 'WI-1072', 'ref allocated WI-1072 (got ' . ($new['ref'] ?? '-') . ')');
check(($new['status'] ?? '') === 'needs_estimate', 'status needs_estimate per Project policy');
check(isset($new['priority_score']) && $new['priority_score'] >= 0, 'priority computed (' . ($new['priority_score'] ?? 'null') . ')');
check(($new['priority_terms']['risk']['normalised'] ?? 0) == 0.8, 'risk defaults 0.8 from compliance benefit');
check(count($new['skills'] ?? []) === 2 && $new['size_stamp'] === 'M', 'skills + size M stored');
check(!empty($new['requirements_text']), 'requirements_text pre-populated from the type template');
check(count(array_filter($new['readiness']['items'], fn($i) => $i['key'] === 'estimate' && !$i['done'])) === 1, 'readiness shows estimate missing');
$newId = $new['id'];

echo "== estimate save moves status on\n";
[, $E] = api('estimates', ['action' => 'save', 'work_item_id' => $newId, 'method' => 'three_point', 'optimistic' => 8, 'likely' => 10, 'pessimistic' => 16, 'estimate_class' => 3, 'assumptions' => 'Test', 'reason' => 'first estimate']);
check(($E['estimate']['version'] ?? 0) === 1 && $E['status'] === 'ready', "estimate v1 saved; status -> {$E['status']} (benefit already present so ready)");
near($E['estimate']['expected'], 10.67, 0.06, 'expected (8+40+16)/6'); check($E['implied_stamp'] === 'M', 'implied stamp M');
[, $E2] = api('estimates', ['action' => 'save', 'work_item_id' => $newId, 'method' => 'three_point', 'optimistic' => 10, 'likely' => 14, 'pessimistic' => 20, 'estimate_class' => 3, 'reason' => 'scope grew']);
check(($E2['estimate']['version'] ?? 0) === 2, 'estimate v2 saved (upward → STAB-09 trigger)');
[, $EG] = api('estimates', ['action' => 'get', 'work_item_id' => $newId]);
check(count($EG['versions']) === 2 && $EG['latest']['likely'] == 14 && isset($EG['calibration']['recommendation']) && count($EG['classes']) === 5, 'estimates.get: versions, latest, calibration, classes');
[, $EL] = api('estimates', ['action' => 'list']);
check(count($EL['items']) > 0 && $EL['items'][0]['status'] === 'needs_estimate' && isset($EL['calibration']['by_stamp']), 'estimates.list puts needs_estimate first + calibration');
echo "     calibration: {$EL['calibration']['recommendation']}\n";
check(strpos($EL['calibration']['recommendation'], 'Large projects have finished') === 0, 'calibration recommendation mentions Large projects');

echo "== benefits save changes priority\n";
[, $B0] = api('work_items', ['action' => 'get', 'id' => $newId]); $before = $B0['item']['priority_score'];
[, $BS] = api('benefits', ['action' => 'save', 'work_item_id' => $newId, 'type' => 'cost_avoidance', 'annual_value' => 300000, 'confidence' => 'high', 'realisation_from' => '2027-01-01', 'owner_name' => 'Finance Benefit Owner']);
check(($BS['benefit']['annual_value'] ?? 0) === 300000 && $BS['benefit']['type_label'] === 'Cost avoidance', 'benefit saved with type label');
check($BS['priority_score'] > $before, "priority rose after benefit ({$before} -> {$BS['priority_score']})");
[, $BL] = api('benefits', ['action' => 'list']);
foreach (['in_plan','realised_ytd','at_risk','items_without_case','items_total','added_this_quarter','target_pct'] as $k) check(array_key_exists($k, $BL['totals']), "benefits.totals.$k");
check(count($BL['by_type']) >= 4 && $BL['by_type'][0]['colour'][0] === '#', 'by_type with colours');
check(count($BL['by_quarter']) >= 2 && $BL['by_quarter'][1]['planned'] >= $BL['by_quarter'][0]['planned'], 'by_quarter cumulative');
check(count($BL['by_owner']) >= 1, 'by_owner present');
check(count(array_filter($BL['benefits'], fn($b) => $b['ref'] === 'WI-1042')) === 3, 'register lists WI-1042 benefits');
[, $BR] = api('benefits', ['action' => 'record_realisation', 'benefit_id' => $BS['benefit']['id'], 'quarter' => 'Q1 2027', 'realised_value' => 50000]);
check($BR['benefit']['status'] === 'realising' && $BR['benefit']['realised_value'] === 50000, 'record_realisation -> realising');
[, $CSV] = api('benefits', ['action' => 'export_csv']); check(strpos($CSV['csv'] ?? '', 'Ref,Title') === 0 && $CSV['rows'] > 10, 'export_csv');

echo "== dependency cycle -> 409\n";
$id1033 = $byRef['WI-1033']['id']; $id1068 = $byRef['WI-1068']['id'];
[$code] = api('work_items', ['action' => 'add_dependency', 'from_id' => $id1068, 'to_id' => $id1033, 'type' => 'finish_start'], 409);
[, $D] = api('work_items', ['action' => 'add_dependency', 'from_id' => $newId, 'to_id' => $id1068, 'type' => 'soft']);
check(isset($D['dependency']['id']), 'valid dependency added');
api('work_items', ['action' => 'remove_dependency', 'id' => $D['dependency']['id']]);

echo "== set_status\n";
[$code, $S] = api('work_items', ['action' => 'set_status', 'id' => $newId, 'status' => 'delivered'], 409);
check(strpos($S['message'] ?? '', 'Cannot move') === 0, 'ready -> delivered rejected: ' . ($S['message'] ?? ''));
[$code, $S] = api('work_items', ['action' => 'set_status', 'id' => $byRef['WI-1068']['id'], 'status' => 'ready'], 409);
check(strpos($S['message'] ?? '', 'readiness') !== false, 'needs_estimate -> ready without estimate rejected: ' . ($S['message'] ?? ''));
[, $S] = api('work_items', ['action' => 'set_status', 'id' => $newId, 'status' => 'in_progress']);
check($S['item']['status'] === 'in_progress' && $S['item']['started_at'] === '2026-09-08', 'ready -> in_progress sets started_at to fake today');
[$code, $S] = api('work_items', ['action' => 'set_status', 'id' => $newId, 'status' => 'delivered'], 409);
check(strpos($S['message'] ?? '', 'actual effort') !== false, 'delivered without actual_effort_days rejected');
[, $S] = api('work_items', ['action' => 'set_status', 'id' => $newId, 'status' => 'delivered', 'actual_effort_days' => 13]);
check($S['item']['status'] === 'delivered' && $S['item']['delivered_at'] === '2026-09-08' && $S['item']['actual_effort_days'] == 13, 'delivered with actual effort');

echo "== update + history\n";
[, $U] = api('work_items', ['action' => 'update', 'id' => $newId, 'title' => 'Vendor risk scoring dashboard v3', 'needed_by' => '2026-12-15', 'reason' => 'test edit']);
check($U['changed'] === ['title','needed_by'], 'update reports changed fields ' . json_encode($U['changed']));
[, $H] = api('work_items', ['action' => 'history', 'id' => $newId]);
$titleEv = array_values(array_filter($H['events'], fn($e) => $e['field'] === 'title'));
check(count($titleEv) === 1 && $titleEv[0]['before'] === 'Vendor risk scoring dashboard v2' && $titleEv[0]['after'] === 'Vendor risk scoring dashboard v3' && !empty($titleEv[0]['actor_name']), 'history has title before/after with actor');
check(count(array_filter($H['events'], fn($e) => $e['field'] === 'status')) >= 3, 'history has status transitions');
check(count(array_filter($H['events'], fn($e) => $e['entity'] === 'estimate')) === 2 && count(array_filter($H['events'], fn($e) => $e['entity'] === 'benefit')) >= 1, 'history includes estimate + benefit events');

echo "== override, similar, bulk, recompute\n";
[, $O] = api('work_items', ['action' => 'override_priority', 'id' => $byRef['WI-1070']['id'] ?? $id1068, 'points' => 15, 'reason' => 'Exec ask', 'expires' => '2026-10-31']);
check($O['priority_terms']['override']['points'] === 15 && $O['priority_score'] > ($byRef['WI-1070']['priority_score'] ?? 0), 'override adds points');
api('work_items', ['action' => 'clear_override', 'id' => $byRef['WI-1070']['id'] ?? $id1068]);
[, $SIM] = api('work_items', ['action' => 'similar', 'id' => $byRef['WI-1042']['id']]);
check(count($SIM['items']) >= 1 && isset($SIM['items'][0]['actual_days']), 'similar delivered items for WI-1042 (' . count($SIM['items']) . ')');
[, $BK] = api('work_items', ['action' => 'bulk', 'ids' => [$newId], 'op' => 'tag', 'value' => ['test']]);
check($BK['updated'] === 1, 'bulk tag');
[, $R] = api('work_items', ['action' => 'recompute_priorities']);
check($R['updated'] >= 40, "recompute_priorities updated {$R['updated']}");
[, $G2] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check($G2['item']['priority_score'] === $G2['item']['priority_terms']['scaled'], 'WI-1042 score consistent after recompute');
[, $LL] = api('work_items', ['action' => 'list', 'status' => 'open']);
$max = max(array_map(fn($i) => $i['type_policy'] === 'planned' ? $i['priority_score'] : 0, $LL['items']));
near($max, 100, 0.2, 'top planned item ≈100 after rescale');
$inc = array_values(array_filter($LL['items'], fn($i) => $i['type_policy'] === 'interrupt'));
check($inc && in_array((int)$inc[0]['priority_score'], [50,70,90,100], true), 'incident score from severity (' . ($inc[0]['priority_score'] ?? '-') . ')');

echo "== external record link (REQ-05)\n";
[, $G3] = api('work_items', ['action' => 'get', 'ref' => 'WI-1068']);
check(array_key_exists('external_link', $G3['item']) && $G3['item']['external_link'] === null, 'an item with no URL has external_link null');
[$code, $X] = api('work_items', ['action' => 'set_external_link', 'ref' => 'WI-1068', 'url' => 'ftp://files.example.org/x'], 422);
check($code === 422, 'a non-http(s) URL is refused');
[, $X] = api('work_items', ['action' => 'set_external_link', 'ref' => 'WI-1068', 'url' => 'https://acme.atlassian.net/browse/DP-42', 'external_ref' => 'DP-42']);
$lnk = $X['external_link'] ?? [];
check(($lnk['url'] ?? '') === 'https://acme.atlassian.net/browse/DP-42' && ($lnk['ref'] ?? '') === 'DP-42', 'set_external_link stores url and external_ref');
check(($lnk['system'] ?? '') === 'jira' && ($lnk['system_label'] ?? '') === 'Jira', 'system inferred from the atlassian.net host');
check(($lnk['badge']['state'] ?? '') === 'link_only' && ($lnk['badge']['live'] ?? true) === false, 'a typed-in link gets an honest link_only badge');
check(strpos($lnk['badge']['note'] ?? '', 'No integration for Jira is connected') === 0, 'and says why: ' . ($lnk['badge']['note'] ?? '-'));
check(($X['item']['external_link']['system'] ?? '') === 'jira' && ($X['item']['external_ref'] ?? '') === 'DP-42', 'the item shape carries the same link');
foreach (['https://acme.service-now.com/incident.do?sys_id=1' => 'servicenow', 'https://contoso.sharepoint.com/sites/dp/SitePages/Runbook.aspx' => 'sharepoint', 'https://dev.azure.com/acme/_workitems/edit/7' => 'azure_devops', 'https://wiki.example.org/page' => 'other'] as $u => $sys) {
    [, $X] = api('work_items', ['action' => 'set_external_link', 'id' => $G3['item']['id'], 'url' => $u]);
    check(($X['external_link']['system'] ?? '') === $sys, "$sys inferred from $u");
}
[, $X] = api('work_items', ['action' => 'set_external_link', 'id' => $G3['item']['id'], 'url' => 'https://dev.azure.com/acme/_workitems/edit/7', 'system' => 'other']);
check(($X['external_link']['system'] ?? '') === 'other' && !empty($X['external_link']['system_note']), 'an explicit system is echoed and the response says reads re-infer it');
[$code] = api('work_items', ['action' => 'set_external_link', 'id' => $G3['item']['id'], 'url' => 'https://x.example.org', 'system' => 'trello'], 400);
[, $H2] = api('work_items', ['action' => 'history', 'id' => $G3['item']['id']]);
check(count(array_filter($H2['events'], fn($e) => $e['field'] === 'external_link')) >= 2, 'each link change is audited as field external_link');
[, $X] = api('work_items', ['action' => 'clear_external_link', 'id' => $G3['item']['id']]);
check($X['external_link'] === null && $X['item']['external_url'] === null && $X['item']['external_ref'] === null, 'clear_external_link removes both');
// Role gate: a team member cannot set one.
$member = null; foreach ($users['users'] ?? [] as $u) if ($u['role'] === 'team_member') { $member = $u; break; }
if ($member) { $leadToken = $token; [, $ml] = api('auth', ['action' => 'dev_login', 'user_id' => $member['id']]); $token = $ml['token'];
    [$code] = api('work_items', ['action' => 'set_external_link', 'id' => $G3['item']['id'], 'url' => 'https://acme.atlassian.net/browse/DP-1'], 403);
    check($code === 403, 'a team member is refused (team_lead+)'); $token = $leadToken; }

echo "== the badge is live only for an intake-raised item (REQ-05 + INT-02)\n";
$admin = null; foreach ($users['users'] ?? [] as $u) if ($u['role'] === 'admin') { $admin = $u; break; }
check($admin !== null, 'an admin dev user exists');
$leadToken = $token; [, $al] = api('auth', ['action' => 'dev_login', 'user_id' => $admin['id']]); $adminToken = $al['token'] ?? null;
$token = $adminToken;
[, $src] = api('intake', ['action' => 'save', 'name' => 'ServiceNow (badge test)', 'system' => 'servicenow']);
$srcId = $src['source']['id'] ?? null; $secret = $src['secret'] ?? '';
check($srcId !== null && $secret !== '', 'an intake source exists to post through');
$post = function (array $payload) use ($BASE, $srcId, $secret) {
    $ch = curl_init("$BASE/api/intake.php?source=$srcId");
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($payload), CURLOPT_HTTPHEADER => ['Content-Type: application/json', "X-Dispatch-Intake-Secret: $secret"], CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 60]);
    $raw = curl_exec($ch); curl_close($ch); return json_decode($raw, true) ?? [];
};
$r = $post(['number' => 'INC0077001', 'short_description' => 'Badge test incident', 'priority' => '2', 'url' => 'https://acme.service-now.com/incident.do?number=INC0077001']);
check(($r['outcome'] ?? '') === 'created', 'a ticket system raises an incident (' . ($r['ref'] ?? '-') . ')');
$token = $leadToken;
[, $I] = api('work_items', ['action' => 'get', 'id' => $r['work_item_id'] ?? 0]);
$lnk = $I['item']['external_link'] ?? [];
check(($lnk['ref'] ?? '') === 'INC0077001' && ($lnk['system'] ?? '') === 'servicenow', 'the raised item carries the ticket ref and the source system');
check(($lnk['badge']['state'] ?? '') === 'raised' && ($lnk['badge']['live'] ?? false) === true && ($lnk['badge']['source'] ?? '') === 'intake_log', "its badge is live from Dispatch's own intake record: raised");
check(!empty($lnk['badge']['last_seen_at']) && ($lnk['badge']['times_seen'] ?? 0) === 1, 'with last_seen_at and times_seen 1');
check(strpos($lnk['badge']['note'] ?? '', "not the ticket's current state") !== false, "and it does not claim to know the ticket's state in ServiceNow");
$post(['number' => 'INC0077001', 'short_description' => 'Badge test incident', 'priority' => '2']);
[, $I2] = api('work_items', ['action' => 'get', 'id' => $r['work_item_id'] ?? 0]);
$b2 = $I2['item']['external_link']['badge'] ?? [];
check(($b2['state'] ?? '') === 'duplicate_seen' && ($b2['times_seen'] ?? 0) === 2, 'a re-post moves the badge to duplicate_seen, times_seen 2');
check(($b2['last_seen_at'] ?? '') >= ($lnk['badge']['last_seen_at'] ?? 'z'), 'last_seen_at advanced');
$token = $adminToken; api('intake', ['action' => 'delete', 'id' => $srcId]); $token = $leadToken;
[, $I3] = api('work_items', ['action' => 'get', 'id' => $r['work_item_id'] ?? 0]);
check(($I3['item']['external_link']['badge']['state'] ?? '') === 'link_only', 'with the intake record gone the badge honestly falls back to link_only');
api('work_items', ['action' => 'set_status', 'id' => $r['work_item_id'] ?? 0, 'status' => 'cancelled', 'reason' => 'test incident']);

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
