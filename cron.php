<?php
// Nightly runner (STAB-05 cadence "propose nightly"). CLI only.
//   C:\xampp\php\php.exe C:\xampp\htdocs\dispatch\cron.php [--workspace=1] [--engine=cpsat]
// Runs replan.php action run_nightly for every workspace: derive capacity → recompute priorities →
// nightly proposal → stability_weeks roll-up for the current week. Prints one JSON line per workspace.
//
// Windows Task Scheduler (02:00 daily):
//   schtasks /Create /SC DAILY /ST 02:00 /TN "Dispatch nightly replan" /RU SYSTEM ^
//     /TR "\"C:\xampp\php\php.exe\" \"C:\xampp\htdocs\dispatch\cron.php\" >> \"C:\xampp\htdocs\dispatch\cron.log\" 2>&1"
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$_GET['action'] = 'run_nightly';
foreach (array_slice($argv, 1) as $arg) {
    if (preg_match('/^--workspace=(\d+)$/', $arg, $m)) $_GET['workspace_id'] = (int)$m[1];
    if (preg_match('/^--engine=(\w+)$/', $arg, $m)) $_GET['engine'] = $m[1];
}
$_SERVER['REQUEST_METHOD'] = 'POST';
echo '[' . date('Y-m-d H:i:s') . "] nightly replan starting\n";
require __DIR__ . '/api/replan.php';
