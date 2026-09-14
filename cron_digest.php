<?php
// Weekly digest (NOT-04). CLI only. Composes and delivers each opted-in user's digest of next
// week's plan and what changed for them since their last one, for every workspace.
//   C:\xampp\php\php.exe C:\xampp\htdocs\dispatch\cron_digest.php [--workspace=1] [--user=3]
//
// Delivery is by email when api/config.php has an smtp block (or mail.php_mail), otherwise
// in-app as a notification of kind `digest`. The JSON line printed per run says which happened
// for each recipient (`sent` = emailed, `in_app` = delivered in the app, `reason` when neither).
//
// Windows Task Scheduler, Friday afternoon so the week ahead is the committed one:
//   schtasks /Create /SC WEEKLY /D FRI /ST 16:00 /TN "Dispatch weekly digest" /RU SYSTEM ^
//     /TR "\"C:\xampp\php\php.exe\" \"C:\xampp\htdocs\dispatch\cron_digest.php\" >> \"C:\xampp\htdocs\dispatch\cron.log\" 2>&1"
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$_GET['action'] = 'send';
foreach (array_slice($argv, 1) as $arg) {
    if (preg_match('/^--workspace=(\d+)$/', $arg, $m)) $_GET['workspace_id'] = (int)$m[1];
    if (preg_match('/^--user=(\d+)$/', $arg, $m)) $_GET['user_id'] = (int)$m[1];
}
$_SERVER['REQUEST_METHOD'] = 'POST';
echo '[' . date('Y-m-d H:i:s') . "] weekly digest starting\n";
require __DIR__ . '/api/digest.php';
