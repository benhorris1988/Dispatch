<?php
// BEN-02: non-financial benefits on a qualitative scale, with an optional proxy value, that still
// weigh on the priority score without inflating the financial totals.
//   php tests/benefits_qualitative_test.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB. Mutates WI-1068's benefits: re-seed after.
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
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr((string)$raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }
function loginRole($role) { global $token; $token = null; [, $u] = api('auth', ['action' => 'list_dev_users']); foreach ($u['users'] ?? [] as $x) if ($x['role'] === $role) { [, $r] = api('auth', ['action' => 'dev_login', 'user_id' => $x['id']]); $token = $r['token'] ?? null; return $x; } return null; }

section('Sign in');
$lead = loginRole('delivery_lead');
check($lead !== null && !empty($token), 'signed in as the delivery lead');

section('The register publishes the scale and the per-point default (BEN-02)');
[, $L0] = api('benefits', ['action' => 'list']);
check(count($L0['qualitative_scales'] ?? []) === 5 && ($L0['qualitative_scales'][0]['label'] ?? '') === 'Minor' && ($L0['qualitative_scales'][4]['label'] ?? '') === 'Transformational', 'five scale points with labels, minor to transformational');
check(($L0['qualitative_value_per_point'] ?? 0) === 25000, 'the default is 25,000 per scale point (' . ($L0['qualitative_value_per_point'] ?? '-') . ')');
check(array_key_exists('non_financial_count', $L0['totals']) && array_key_exists('qualitative_proxy_total', $L0['totals']), 'totals carry non_financial_count and qualitative_proxy_total');
check(strpos($L0['priority_note'] ?? '', 'non-financial') !== false, 'the priority note explains how a non-financial benefit counts');
$nf0 = (int)$L0['totals']['non_financial_count']; $pipe0 = (int)$L0['totals']['in_pipeline']; $plan0 = (int)$L0['totals']['in_plan'];
$perPoint = (int)$L0['qualitative_value_per_point'];

section('A non-financial benefit needs a scale; a financial one still needs a value');
[, $G] = api('work_items', ['action' => 'get', 'ref' => 'WI-1068']);
$item = $G['item']; $itemId = $item['id'];
$score0 = (float)$item['priority_score']; $value0 = $item['priority_terms']['value'];
check($item['status'] !== 'cancelled' && ($value0['qualitative'] ?? -1) === 0, "WI-1068 starts with no qualitative value (score $score0, value input {$value0['input']})");
[$c] = api('benefits', ['action' => 'save', 'work_item_id' => $itemId, 'type' => 'compliance', 'is_financial' => false, 'confidence' => 'high'], 422);
check($c === 422, 'a non-financial benefit without a qualitative_scale is refused');
[$c, $e] = api('benefits', ['action' => 'save', 'work_item_id' => $itemId, 'type' => 'compliance', 'is_financial' => false, 'qualitative_scale' => 9], 422);
check($c === 422 && count($e['qualitative_scales'] ?? []) === 5, 'a scale outside 1..5 is refused and the valid scale is returned');
[$c] = api('benefits', ['action' => 'save', 'work_item_id' => $itemId, 'type' => 'compliance', 'is_financial' => false, 'qualitative_scale' => 3, 'proxy_value' => -5], 422);
check($c === 422, 'a negative proxy value is refused');
[$c] = api('benefits', ['action' => 'save', 'work_item_id' => $itemId, 'type' => 'compliance', 'is_financial' => true], 422);
check($c === 422, 'a financial benefit without annual_value is still refused');

section('Without a proxy, the per-point default carries the benefit into the score');
[, $S1] = api('benefits', ['action' => 'save', 'work_item_id' => $itemId, 'type' => 'compliance', 'is_financial' => false, 'qualitative_scale' => 4, 'confidence' => 'high', 'owner_name' => 'CISO', 'narrative' => 'Closes the audit finding on segregation of duties']);
$b = $S1['benefit'] ?? [];
check(($b['is_financial'] ?? true) === false && ($b['qualitative_scale'] ?? 0) === 4 && ($b['qualitative_label'] ?? '') === 'Major', 'saved as non-financial, scale 4 "Major"');
check(($b['annual_value'] ?? -1) === 0 && array_key_exists('proxy_value', $b) && $b['proxy_value'] === null, 'annual_value defaults to 0 and there is no proxy');
$v1 = $S1['priority_terms']['value'] ?? [];
check(($v1['qualitative'] ?? 0) === 4 * $perPoint, "the Value term counts 4 × $perPoint at high confidence (" . ($v1['qualitative'] ?? '-') . ')');
check(($v1['qualitative_source'] ?? '') === 'scale_default' && ($v1['proxy_used'] ?? true) === false, 'and records that the per-point default was used');
check(($v1['financial'] ?? -1) === $value0['input'] && ($v1['input'] ?? 0) === ($v1['financial'] ?? 0) + ($v1['qualitative'] ?? 0), 'input = financial + qualitative, financial half unchanged');
check((float)$S1['priority_score'] > $score0, "the priority score rose ($score0 -> {$S1['priority_score']})");
$score1 = (float)$S1['priority_score'];

section('With a proxy value, the proxy replaces the default');
[, $S2] = api('benefits', ['action' => 'save', 'id' => $b['id'], 'proxy_value' => 400000]);
$v2 = $S2['priority_terms']['value'] ?? [];
check(($S2['benefit']['proxy_value'] ?? 0) === 400000 && ($S2['benefit']['is_financial'] ?? true) === false, 'the proxy is stored and the benefit stays non-financial');
check(($v2['qualitative'] ?? 0) === 400000 && ($v2['qualitative_source'] ?? '') === 'proxy' && ($v2['proxy_used'] ?? false) === true, 'the Value term now counts the proxy (' . ($v2['qualitative'] ?? '-') . ')');
check((float)$S2['priority_score'] > $score1, "and the score rose again ($score1 -> {$S2['priority_score']})");
[, $G2] = api('work_items', ['action' => 'get', 'id' => $itemId]);
check(($G2['item']['priority_terms']['value']['proxy_used'] ?? false) === true && $G2['item']['priority_score'] === $S2['priority_score'], 'the item page shows the same working');
$mine = array_values(array_filter($G2['item']['benefits'], fn($x) => $x['id'] === $b['id']));
check(count($mine) === 1 && $mine[0]['is_financial'] === false && $mine[0]['qualitative_label'] === 'Major' && $mine[0]['proxy_value'] === 400000, 'the item lists the benefit with its scale label and proxy');
check(($G2['item']['benefit_total'] ?? -1) === ($item['benefit_total'] ?? -2), 'benefit_total on the item is still financial-only');

section('Financial totals exclude it; the register counts it separately');
[, $L1] = api('benefits', ['action' => 'list']);
check((int)$L1['totals']['in_pipeline'] === $pipe0 && (int)$L1['totals']['in_plan'] === $plan0, 'in_pipeline and in_plan are unchanged by a non-financial benefit');
check((int)$L1['totals']['non_financial_count'] === $nf0 + 1, 'non_financial_count went up by one (' . $L1['totals']['non_financial_count'] . ')');
check((int)$L1['totals']['qualitative_proxy_total'] >= 400000, 'qualitative_proxy_total carries the proxy (' . $L1['totals']['qualitative_proxy_total'] . ')');
$row = array_values(array_filter($L1['benefits'], fn($x) => $x['id'] === $b['id']));
check(count($row) === 1 && $row[0]['is_financial'] === false && $row[0]['qualitative_scale'] === 4, 'the register row carries is_financial and the scale');
[, $CSV] = api('benefits', ['action' => 'export_csv']);
$lines = explode("\n", $CSV['csv'] ?? '');
check(strpos($lines[0], 'Financial') !== false && strpos($lines[0], 'Qualitative scale') !== false && strpos($lines[0], 'Proxy value') !== false, 'export_csv carries the new columns');
$csvRow = array_values(array_filter($lines, fn($l) => strpos($l, 'WI-1068') === 0 && strpos($l, 'Major') !== false));
check(count($csvRow) === 1 && strpos($csvRow[0], ',No,') !== false && strpos($csvRow[0], '400000') !== false, 'and the row says No / 4 / Major / 400000');

section('Switching it back to financial drops the proxy and re-scores');
[, $S3] = api('benefits', ['action' => 'save', 'id' => $b['id'], 'is_financial' => true, 'annual_value' => 50000]);
check(($S3['benefit']['is_financial'] ?? false) === true && array_key_exists('proxy_value', $S3['benefit'] ?? []) && $S3['benefit']['proxy_value'] === null && ($S3['benefit']['annual_value'] ?? 0) === 50000, 'financial again: proxy cleared, value kept');
check(($S3['priority_terms']['value']['qualitative'] ?? -1) === 0 && ($S3['priority_terms']['value']['non_financial_count'] ?? -1) === 0, 'no qualitative half remains in the Value term');
api('benefits', ['action' => 'delete', 'id' => $b['id']]);

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
