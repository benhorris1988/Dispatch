<?php
// Runtime DB connection (least-privilege dispatch_app). Include first in every endpoint.
date_default_timezone_set('Europe/London');
// cron.php includes an endpoint from the command line, where there are no headers to send
// and PHP warns about every one of them. Guard the whole HTTP preamble on the SAPI.
if (PHP_SAPI !== 'cli') {
    header('Content-Type: application/json; charset=utf-8');
    header('Access-Control-Allow-Origin: *');
    header('Access-Control-Allow-Methods: POST, GET, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, Authorization, X-App-Version, Idempotency-Key');
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') { http_response_code(204); exit; }
}

require_once __DIR__ . '/lib.php';

$dpCfgPath = __DIR__ . '/config.php';
$dpCfg = file_exists($dpCfgPath) ? (require $dpCfgPath) : [];
if (empty($dpCfg['db']['server']) || empty($dpCfg['db']['database']) || empty($dpCfg['db']['uid']) || empty($dpCfg['db']['pwd'])) {
    fail('Server not configured (api/config.php missing a complete db block - copy config.example.php)', 500);
}
$conn = sqlsrv_connect($dpCfg['db']['server'], [
    'Database' => $dpCfg['db']['database'],
    'Uid' => $dpCfg['db']['uid'],
    'Pwd' => $dpCfg['db']['pwd'],
    'CharacterSet' => 'UTF-8',
    'ReturnDatesAsStrings' => true,
    'TrustServerCertificate' => true,
]);
if ($conn === false) {
    error_log('db_connect: ' . print_r(sqlsrv_errors(), true));
    fail('Database connection failed', 500);
}
