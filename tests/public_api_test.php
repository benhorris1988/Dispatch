<?php
// Public REST API, outbound webhooks and the iCalendar feed (INT-07, VIEW-09, INT-04 publish half).
//   php tests/public_api_test.php [base=http://localhost:8090]
// Needs the local server and a seeded demo DB. Starts its own webhook receiver on 8099.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
// Pick a free port rather than assuming one. A stray receiver left listening by an earlier
// run would otherwise win the bind and answer 404 for a file it does not serve, which looks
// exactly like a broken webhook and is not.
$RECEIVER_PORT = 8099;
for ($p = 8099; $p < 8130; $p++) {
    $busy = @fsockopen('localhost', $p, $e1, $e2, 0.2);
    if ($busy) { fclose($busy); continue; }
    $RECEIVER_PORT = $p; break;
}
$RECEIVER_DIR = rtrim(str_replace('/', DIRECTORY_SEPARATOR, sys_get_temp_dir()), DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . 'dispatch_hooks';
$HOOK_LOG = $RECEIVER_DIR . DIRECTORY_SEPARATOR . 'hooks.log';
$pass = 0; $fail = 0; $token = null;

function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }

function http($method, $url, $body = null, $bearer = null, &$code = null, &$headers = null) {
    $ch = curl_init($url);
    $h = ['Content-Type: application/json'];
    if ($bearer) $h[] = "Authorization: Bearer $bearer";
    curl_setopt_array($ch, [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_HTTPHEADER => $h,
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 60, CURLOPT_HEADER => true]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, is_string($body) ? $body : json_encode($body));
    $raw = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $hlen = (int)curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);
    $headers = substr((string)$raw, 0, $hlen);
    return substr((string)$raw, $hlen);
}
function api($endpoint, array $body, $bearer = null) {
    global $BASE;
    $raw = http('POST', "$BASE/api/$endpoint.php", $body, $bearer, $code);
    return [$code, json_decode($raw, true) ?? []];
}

// ---------------------------------------------------------------------------------------
section('Sign in');
[, $users] = api('auth', ['action' => 'list_dev_users']);
$lead = null; $admin = null;
foreach ($users['users'] ?? [] as $u) {
    if ($u['role'] === 'delivery_lead' && $lead === null) $lead = $u;
    if ($u['role'] === 'admin' && $admin === null) $admin = $u;
}
check($lead !== null && $admin !== null, 'a delivery lead and an admin exist');
[, $l] = api('auth', ['action' => 'dev_login', 'user_id' => $lead['id']]);
$token = $l['token'] ?? null;
[, $a] = api('auth', ['action' => 'dev_login', 'user_id' => $admin['id']]);
$adminToken = $a['token'] ?? null;
check(!empty($token) && !empty($adminToken), 'both tokens issued');

// ---------------------------------------------------------------------------------------
section('Public REST API (INT-07)');
$raw = http('GET', "$BASE/v1", null, $token, $code);
$idx = json_decode($raw, true);
check($code === 200 && ($idx['version'] ?? '') === 'v1', "index responds (HTTP $code)");
check(($idx['read_only'] ?? false) === true, 'the index declares the surface read-only');
check(!empty($idx['resources']), 'and lists its resources (' . count($idx['resources'] ?? []) . ')');

$raw = http('GET', "$BASE/v1/work-items?limit=3", null, $token, $code);
$wi = json_decode($raw, true);
check($code === 200 && count($wi['work_items'] ?? []) === 3, 'work-items honours limit');
check(isset($wi['page']['next_cursor']), 'and returns a cursor');
$first = $wi['work_items'][0] ?? [];
foreach (['ref', 'title', 'status', 'type_name'] as $f) check(array_key_exists($f, $first), "a work item carries $f");

// The cursor must actually advance rather than repeat the first page.
$cursor = $wi['page']['next_cursor'];
$raw2 = http('GET', "$BASE/v1/work-items?limit=3&cursor=" . urlencode($cursor), null, $token, $code);
$wi2 = json_decode($raw2, true);
$firstRefs = array_column($wi['work_items'], 'ref');
$secondRefs = array_column($wi2['work_items'] ?? [], 'ref');
check(!array_intersect($firstRefs, $secondRefs), 'the next page does not repeat the first');

$raw = http('GET', "$BASE/v1/work-items/WI-1042", null, $token, $code);
$one = json_decode($raw, true);
check($code === 200 && ($one['work_item']['ref'] ?? '') === 'WI-1042', 'a work item by reference');
$raw = http('GET', "$BASE/v1/work-items/WI-9999", null, $token, $code);
$nf = json_decode($raw, true);
check($code === 404 && isset($nf['title'], $nf['status']), "an unknown reference is an RFC 9457 problem (HTTP $code)");

foreach (['people', 'skills', 'plan', 'assignments', 'proposals', 'benefits', 'estimates', 'reports/stability'] as $res) {
    $raw = http('GET', "$BASE/v1/$res", null, $token, $code);
    check($code === 200 && json_decode($raw, true) !== null, "/v1/$res responds");
}

$plan = json_decode(http('GET', "$BASE/v1/plan", null, $token, $code), true);
check(!empty($plan['plan']['committed_through']), 'the plan reports how far it is committed');
$stab = json_decode(http('GET', "$BASE/v1/reports/stability", null, $token, $code), true);
$idxPct = $stab['weeks'][0]['stability_index_pct'] ?? null;
check($idxPct !== null && $idxPct >= 0 && $idxPct <= 100, 'stability index is a percentage');

http('GET', "$BASE/v1/work-items", null, null, $code);
check($code === 401, "an unauthenticated read is refused (HTTP $code)");
http('POST', "$BASE/v1/work-items", ['title' => 'nope'], $token, $code);
check($code === 405, "a write is refused: the surface is read-only (HTTP $code)");

$raw = http('GET', "$BASE/v1/openapi.yaml", null, $token, $code, $headers);
check($code === 200 && str_contains($raw, 'openapi: 3.1.0'), 'the OpenAPI 3.1 document is served');
check(str_contains($raw, 'webhooks:'), 'and documents the webhooks');

// ---------------------------------------------------------------------------------------
section('Outbound webhooks (INT-07)');
// A receiver that verifies the signature exactly as a subscriber should.
@mkdir($RECEIVER_DIR, 0777, true);
@unlink($HOOK_LOG);
file_put_contents($RECEIVER_DIR . DIRECTORY_SEPARATOR . 'receiver.php', <<<'PHP'
<?php
// Only deliveries are logged; the suite's readiness probe is a GET and must not pollute it.
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') { http_response_code(401); exit; }
$body = file_get_contents('php://input');
$secret = trim(@file_get_contents(__DIR__ . '/secret.txt'));
$valid = hash_equals('sha256=' . hash_hmac('sha256', $body, $secret), $_SERVER['HTTP_X_DISPATCH_SIGNATURE'] ?? '');
file_put_contents(__DIR__ . '/hooks.log', json_encode([
    'event' => $_SERVER['HTTP_X_DISPATCH_EVENT'] ?? '?',
    'delivery' => $_SERVER['HTTP_X_DISPATCH_DELIVERY'] ?? '?',
    'signature_valid' => $valid,
    'payload' => json_decode($body, true),
]) . "\n", FILE_APPEND);
if (!$valid) { http_response_code(401); exit; }
http_response_code(200);
PHP);
file_put_contents($RECEIVER_DIR . DIRECTORY_SEPARATOR . 'quit.php', "<?php echo 'bye'; 
" . 'register_shutdown_function(function () { exit; }); ' . "
" . '$f = __DIR__ . "/stop"; touch($f); ' . "
" . 'if (function_exists("posix_kill")) { posix_kill(getmypid(), 15); } else { exec("taskkill /PID " . getmypid() . " /F 2>NUL"); }' . "
");

// Clear any subscription a previous run left behind.
[, $existing] = api('webhooks', ['action' => 'list'], $adminToken);
foreach ($existing['subscriptions'] ?? [] as $s) api('webhooks', ['action' => 'delete', 'id' => $s['id']], $adminToken);

[$code, $created] = api('webhooks', ['action' => 'save',
    'url' => "http://localhost:$RECEIVER_PORT/receiver.php", 'events' => '*', 'description' => 'test receiver'], $adminToken);
check($code === 200 && !empty($created['secret']), 'a subscription is created with a generated secret');
check(strlen($created['secret'] ?? '') >= 32, 'the secret is long enough to be worth signing with');
$subId = $created['subscription']['id'] ?? null;
file_put_contents($RECEIVER_DIR . DIRECTORY_SEPARATOR . 'secret.txt', $created['secret']);

[, $listed] = api('webhooks', ['action' => 'list'], $adminToken);
$sub = $listed['subscriptions'][0] ?? [];
check(!array_key_exists('secret', $sub), 'the secret is never returned again by list');
check(count($listed['events'] ?? []) === 4, 'the event catalogue has four events');

// A non-admin may not manage subscriptions.
[$code] = api('webhooks', ['action' => 'list'], $token);
check($code === 403, "a delivery lead cannot manage webhooks (HTTP $code)");

// Start the receiver fully detached. proc_open with pipes deadlocks on Windows when the
// child is a server that never exits, so this uses start /B and then polls for readiness
// rather than sleeping and hoping. If it will not come up, the delivery checks are skipped
// with a clear message instead of hanging the suite.
$php = PHP_BINARY;
$receiverUp = false;
if (stripos(PHP_OS_FAMILY, 'Windows') === 0 || PHP_OS_FAMILY === 'Windows') {
    pclose(popen("start /B \"\" \"$php\" -S localhost:$RECEIVER_PORT -t \"$RECEIVER_DIR\" > \"$RECEIVER_DIR\out.log\" 2>&1", 'r'));
} else {
    exec("\"$php\" -S localhost:$RECEIVER_PORT -t \"$RECEIVER_DIR\" > /dev/null 2>&1 &");
}
for ($i = 0; $i < 40; $i++) {
    usleep(200000);
    $probeCode = null;
    http('GET', "http://localhost:$RECEIVER_PORT/receiver.php", null, null, $probeCode);
    // The receiver answers 401 to an unsigned GET, which still proves it is serving the file.
    if ($probeCode === 200 || $probeCode === 401) { $receiverUp = true; break; }
}
check($receiverUp, 'the test receiver is listening on ' . $RECEIVER_PORT);

if (!$receiverUp) { echo "  ..   skipping delivery checks: no receiver
"; }
$ping = ['delivered' => false, 'status' => 'skipped'];
if ($receiverUp) [$code, $ping] = api('webhooks', ['action' => 'test', 'id' => $subId], $adminToken);
if ($receiverUp)
check($code === 200 && ($ping['delivered'] ?? false), 'a test ping is delivered (' . ($ping['status'] ?? '?') . ')');
$log = array_values(array_filter(array_map(fn($l) => json_decode($l, true), file($HOOK_LOG) ?: [])));
$pings = array_values(array_filter($log, fn($e) => ($e['event'] ?? '') === 'ping'));
check(!empty($pings) && ($pings[0]['signature_valid'] ?? false), 'and its HMAC signature verifies at the receiver');

// A real audited event must reach the subscriber.
[, $items] = api('work_items', ['action' => 'list', 'status' => 'ready', 'limit' => 1], $token);
$target = $items['items'][0] ?? null;
check($target !== null, 'there is a ready item to move');
if ($target && $receiverUp) {
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'blocked', 'reason' => 'webhook test'], $token);
    [, $run] = api('webhooks', ['action' => 'run'], $adminToken);
    check(($run['queued'] ?? 0) >= 1, 'the status change is derived from the audit log and queued');
    check(($run['sent'] ?? 0) >= 1, 'and dispatched');
    $log = array_filter(array_map(fn($l) => json_decode($l, true), file($HOOK_LOG) ?: []));
    $statusEvents = array_values(array_filter($log, fn($e) => ($e['event'] ?? '') === 'workitem.statusChanged'));
    check(!empty($statusEvents), 'the receiver got workitem.statusChanged');
    if ($statusEvents) {
        $p = $statusEvents[0]['payload'] ?? [];
        check(($statusEvents[0]['signature_valid'] ?? false), 'signed correctly');
        check(($p['to'] ?? null) === 'blocked', 'carrying the new status');
        check(!empty($p['work_item']['ref']), 'and the work item it refers to');
    }
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'ready', 'reason' => 'restore'], $token);
}

// Unsubscribed events must not be delivered.
api('webhooks', ['action' => 'save', 'id' => $subId, 'url' => "http://localhost:$RECEIVER_PORT/receiver.php", 'events' => 'plan.committed'], $adminToken);
api('webhooks', ['action' => 'run'], $adminToken);   // drain
$before = count(file($HOOK_LOG) ?: []);
if ($target && $receiverUp) {
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'blocked', 'reason' => 'filter test'], $token);
    [, $run2] = api('webhooks', ['action' => 'run'], $adminToken);
    check(($run2['queued'] ?? 0) === 0, 'an event the subscription did not ask for is not queued');
    check(count(file($HOOK_LOG) ?: []) === $before, 'and nothing further reaches the receiver');
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'ready', 'reason' => 'restore'], $token);
}

// A failing endpoint must back off rather than be retried forever, and must not be lost.
api('webhooks', ['action' => 'save', 'id' => $subId, 'url' => 'http://localhost:9/nothing-here', 'events' => '*'], $adminToken);
if ($target) {
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'blocked', 'reason' => 'failure test'], $token);
    [, $run3] = api('webhooks', ['action' => 'run'], $adminToken);
    check(($run3['failed'] ?? 0) >= 1, 'a delivery to a dead endpoint is recorded as failed');
    [, $dels] = api('webhooks', ['action' => 'deliveries', 'status' => 'failed'], $adminToken);
    $d = $dels['deliveries'][0] ?? [];
    check(($d['attempts'] ?? 0) === 1, 'with one attempt counted');
    check(!empty($d['next_attempt_at']), 'and a later retry scheduled, not dropped');
    api('work_items', ['action' => 'set_status', 'id' => $target['id'], 'status' => 'ready', 'reason' => 'restore'], $token);
}

api('webhooks', ['action' => 'delete', 'id' => $subId], $adminToken);
if ($receiverUp) { @file_get_contents("http://localhost:$RECEIVER_PORT/quit.php", false, stream_context_create(['http' => ['timeout' => 2, 'ignore_errors' => true]])); }

// ---------------------------------------------------------------------------------------
section('iCalendar feed (VIEW-09, and the publish half of INT-04)');
[$code, $feed] = api('calendar', ['action' => 'my_feed', 'person_id' => 1], $token);
check($code === 200 && !empty($feed['url']), 'a feed URL is issued');
$ics = http('GET', $feed['url'], null, null, $code, $headers);
check($code === 200, "the feed is readable without a bearer token (HTTP $code)");
check(str_contains($headers, 'text/calendar'), 'served as text/calendar');
check(str_starts_with($ics, 'BEGIN:VCALENDAR'), 'and is a calendar');
check(substr_count($ics, 'BEGIN:VEVENT') >= 1, 'with events (' . substr_count($ics, 'BEGIN:VEVENT') . ')');
check(str_contains($ics, 'END:VCALENDAR'), 'properly terminated');
check(!preg_match('/^.{76,}$/m', str_replace("\r\n", "\n", $ics)), 'lines folded to the 75-octet limit');
check(!str_contains($ics, 'Leave'), 'leave is not published (ADM-05 keeps absence reasons out)');

// The same URL must stop working once revoked.
api('calendar', ['action' => 'revoke', 'person_id' => 1], $token);
http('GET', $feed['url'], null, null, $code);
check($code === 404, "a revoked feed stops resolving (HTTP $code)");

echo "\n$pass passed, $fail failed\n";
echo "Re-seed before using the demo again: php seed_demo.php\n";
exit($fail ? 1 : 0);
