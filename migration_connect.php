<?php
// Admin (db_owner) connection for CLI-only seed/migration scripts. Refuses HTTP entry.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
date_default_timezone_set('Europe/London');
$cfg = require __DIR__ . '/api/config.php';
$a = $cfg['db_admin'];
$conn = sqlsrv_connect($a['server'], ['Database' => $a['database'], 'Uid' => $a['uid'], 'Pwd' => $a['pwd'], 'CharacterSet' => 'UTF-8', 'ReturnDatesAsStrings' => true, 'TrustServerCertificate' => true]);
if ($conn === false) { fwrite(STDERR, print_r(sqlsrv_errors(), true)); exit(1); }
function x($conn, $sql, $params = []) {
    $s = sqlsrv_query($conn, $sql, $params);
    if ($s === false) { fwrite(STDERR, "SQL failed: $sql\n" . print_r(sqlsrv_errors(), true)); exit(1); }
    return $s;
}
function xid($conn, $table, array $data) {
    $cols = array_keys($data);
    $s = x($conn, "INSERT INTO dbo.$table (" . implode(',', $cols) . ") OUTPUT INSERTED.id VALUES (" . implode(',', array_fill(0, count($cols), '?')) . ")", array_values($data));
    sqlsrv_fetch($s); return (int)sqlsrv_get_field($s, 0);
}
function xrows($conn, $sql, $params = []) {
    $s = x($conn, $sql, $params); $out = [];
    while ($r = sqlsrv_fetch_array($s, SQLSRV_FETCH_ASSOC)) $out[] = $r;
    return $out;
}
