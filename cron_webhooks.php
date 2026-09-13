<?php
// Webhook dispatcher (INT-07). CLI only. Scans the audit log for new events, queues a
// delivery per matching subscription, and sends what is due with signing and back-off.
//   C:\xampp\php\php.exe C:\xampp\htdocs\dispatch\cron_webhooks.php [--limit=50]
//
// Windows Task Scheduler, every five minutes:
//   schtasks /Create /SC MINUTE /MO 5 /TN "Dispatch webhooks" /RU SYSTEM ^
//     /TR "\"C:\xampp\php\php.exe\" \"C:\xampp\htdocs\dispatch\cron_webhooks.php\""
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require __DIR__ . '/migration_connect.php';
require_once __DIR__ . '/api/lib.php';
require_once __DIR__ . '/api/engine/webhook_lib.php';

$limit = 50;
foreach (array_slice($argv, 1) as $arg) if (preg_match('/^--limit=(\d+)$/', $arg, $m)) $limit = (int)$m[1];

$out = [];
foreach (xrows($conn, "SELECT id FROM dbo.workspaces ORDER BY id") as $w) {
    $out[] = webhook_run($conn, (int)$w['id'], $limit);
}
echo '[' . date('Y-m-d H:i:s') . '] ' . json_encode(['status' => 'ok', 'workspaces' => $out], JSON_UNESCAPED_SLASHES) . "\n";
