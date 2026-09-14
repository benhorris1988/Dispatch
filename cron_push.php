<?php
// Push dispatcher (MOB-04). CLI only. Sends queued push_deliveries through FCM / APNs when a
// sender is configured in api/config.php ('push' keys); otherwise marks them unconfigured.
//   C:\xampp\php\php.exe C:\xampp\htdocs\dispatch\cron_push.php [--limit=50]
//
// Windows Task Scheduler, every minute (a push that arrives five minutes late is not a push):
//   schtasks /Create /SC MINUTE /MO 1 /TN "Dispatch push" /RU SYSTEM ^
//     /TR "\"C:\xampp\php\php.exe\" \"C:\xampp\htdocs\dispatch\cron_push.php\""
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require __DIR__ . '/migration_connect.php';
require_once __DIR__ . '/api/lib.php';
require_once __DIR__ . '/api/engine/push_lib.php';

$limit = 50;
foreach (array_slice($argv, 1) as $arg) if (preg_match('/^--limit=(\d+)$/', $arg, $m)) $limit = (int)$m[1];

$conf = push_config();
$out = ['status' => 'ok', 'senders' => ['fcm' => $conf['fcm'], 'apns' => $conf['apns']], 'workspaces' => push_run_all($conn, $limit)];
if (!$conf['fcm'] && !$conf['apns']) $out['note'] = 'No push sender configured; due rows were marked unconfigured, none sent.';
echo '[' . date('Y-m-d H:i:s') . '] ' . json_encode($out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
