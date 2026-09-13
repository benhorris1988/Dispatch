<?php
// Runs every Dispatch test suite against the local server and reports one summary.
//   C:\xampp\php\php.exe tests\run_all.php [base=http://localhost:8090] [--no-seed]
//
// The suites mutate demo data (they create work items and edit estimates, benefits and
// the plan), so the database is re-seeded before the run and again at the end, leaving
// the demo in its documented state. Pass --no-seed to skip both.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

$root = dirname(__DIR__);
$php = PHP_BINARY;
$base = 'http://localhost:8090';
$seed = true;
foreach (array_slice($argv, 1) as $arg) {
    if ($arg === '--no-seed') $seed = false;
    elseif (preg_match('#^https?://#', $arg)) $base = rtrim($arg, '/');
}

// The suites need a live server; fail fast with a useful message rather than 200 red lines.
$probe = @file_get_contents("$base/api/auth.php", false, stream_context_create([
    'http' => ['method' => 'POST', 'header' => "Content-Type: application/json\r\n",
               'content' => '{"action":"list_dev_users"}', 'timeout' => 5, 'ignore_errors' => true],
]));
if ($probe === false || json_decode($probe, true) === null) {
    fwrite(STDERR, "No API at $base.\n  Start it with:  powershell -ExecutionPolicy Bypass -File run_local.ps1\n");
    exit(2);
}

function run_step($label, $cmd) {
    echo "\n=== $label\n";
    $started = microtime(true);
    passthru($cmd, $code);
    printf("--- %s: %s in %.1fs\n", $label, $code === 0 ? 'PASSED' : "FAILED (exit $code)", microtime(true) - $started);
    return $code;
}

$seedCmd = escapeshellarg($php) . ' ' . escapeshellarg("$root/seed_demo.php");
if ($seed && run_step('Re-seed demo data', $seedCmd) !== 0) {
    fwrite(STDERR, "Seeding failed; not running the suites against an unknown database.\n");
    exit(2);
}

$suites = [
    'Engine (planner, diff, guardrails, stability)' => 'engine_test.php',
    'Workspace config, people, skills'              => 'config_people_test.php',
    'Work items, estimates, benefits'               => 'work_items_test.php',
    'Overview, reports, watch list'                 => 'overview_reports_test.php',
    'Plan, proposals, changes (HTTP smoke)'         => 'http_smoke.php',
    'Public API, webhooks, calendar feed'          => 'public_api_test.php',
    // Last: it edits the scheduling policy, commits plan versions and runs the nightly cycle,
    // so it leaves the demo furthest from its seeded state.
    'Policy switches, notifications, urgent cycle'  => 'policy_notifications_test.php',
];

$results = [];
foreach ($suites as $label => $file) {
    $path = __DIR__ . "/$file";
    if (!file_exists($path)) { $results[$label] = 'skipped (not present)'; echo "\n=== $label\n--- skipped: $file not present\n"; continue; }
    $code = run_step($label, escapeshellarg($php) . ' ' . escapeshellarg($path) . ' ' . escapeshellarg($base));
    $results[$label] = $code === 0 ? 'passed' : "FAILED (exit $code)";
}

if ($seed) run_step('Restore demo data', $seedCmd);

echo "\n" . str_repeat('=', 70) . "\nSummary\n" . str_repeat('=', 70) . "\n";
$failed = 0;
foreach ($results as $label => $result) {
    if (strpos($result, 'FAILED') === 0) $failed++;
    printf("  %-48s %s\n", $label, $result);
}
echo $failed ? "\n$failed suite(s) failed.\n" : "\nAll suites passed.\n";
exit($failed ? 1 : 0);
