<?php
// Retention purge (ADM-05, NFR-DATA-02). CLI only. Removes plan history and audit rows
// older than each workspace's configured periods.
//   C:\xampp\php\php.exe C:\xampp\htdocs\dispatch\cron_retention.php
//
// Windows Task Scheduler, weekly (there is nothing to gain from running it nightly):
//   schtasks /Create /SC WEEKLY /D SUN /ST 03:00 /TN "Dispatch retention" /RU SYSTEM ^
//     /TR "\"C:\xampp\php\php.exe\" \"C:\xampp\htdocs\dispatch\cron_retention.php\""
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$_GET['action'] = 'run_purge';
$_SERVER['REQUEST_METHOD'] = 'POST';
echo '[' . date('Y-m-d H:i:s') . "] retention purge starting\n";
require __DIR__ . '/api/retention.php';
