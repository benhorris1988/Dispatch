<?php
// Router for PHP's built-in server (run_local.ps1): serve static files, run api/*.php,
// deny CLI-only areas (tests/ db/ engine/ docs/ and seed_/migrate_ scripts).
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/' || $path === '') { header('Location: /mobile/build/web/'); exit; }
if (preg_match('#^/(tests|db|engine|docs)/#', $path) || preg_match('#/(seed|migrate)_[^/]*\.php$#', $path)) { http_response_code(404); exit; }
// Public REST API (INT-07): /v1/<resource> is served by api/v1.php with the rest of the
// path handed over, so the public surface has real resource paths rather than an action body.
if (preg_match('#^/v1(/.*)?$#', $path, $m)) {
    $_GET['_path'] = $m[1] ?? '';
    require __DIR__ . '/api/v1.php';
    exit;
}

$file = __DIR__ . $path;
if (is_dir($file) && file_exists(rtrim($file, '/') . '/index.html')) { $file = rtrim($file, '/') . '/index.html'; }
if (is_file($file)) {
    if (substr($file, -4) === '.php') return false;
    $types = ['html'=>'text/html','js'=>'application/javascript','css'=>'text/css','json'=>'application/json','png'=>'image/png','svg'=>'image/svg+xml','wasm'=>'application/wasm','ttf'=>'font/ttf','otf'=>'font/otf','woff2'=>'font/woff2','ico'=>'image/x-icon','map'=>'application/json','txt'=>'text/plain'];
    $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
    header('Content-Type: ' . ($types[$ext] ?? 'application/octet-stream'));
    header('Cache-Control: no-cache');
    readfile($file); exit;
}
http_response_code(404); echo 'Not found';
