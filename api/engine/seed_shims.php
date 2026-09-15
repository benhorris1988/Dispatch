<?php
// The handful of helpers seed_demo_content.php expects, for the times it runs somewhere other than
// the command line.
//
// The seed is a straight-line script written against migration_connect.php (x/xid/xrows over a
// db_owner connection) plus a few date helpers. api/engine/workspace_clone.php includes the same
// content file to fill a campaign with demo data over HTTP, where none of that exists — so these
// map the same names onto lib.php's own query helpers. Included only when the CLI versions are
// absent, so running the real seed is completely unaffected.
if (!function_exists('x')) {
    function x($conn, $sql, $params = []) { return q($conn, $sql, $params); }
    function xid($conn, $table, array $data) { return insert($conn, $table, $data); }
    function xrows($conn, $sql, $params = []) { return rows($conn, $sql, $params); }
}

if (!function_exists('j')) {
    function j($v) { return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); }
    function isWorkDay($d) { return (int)date('N', strtotime($d)) <= 5; }
    function addDays($d, $n) { return date('Y-m-d', strtotime("$d +$n day")); }
    /** Working days from $from to $to inclusive. */
    function workDays($from, $to) { $out = []; for ($d = $from; $d <= $to; $d = addDays($d, 1)) if (isWorkDay($d)) $out[] = $d; return $out; }
    /** Monday of ISO week $w in $y. */
    function isoMonday($y, $w) { $d = new DateTime(); $d->setISODate($y, $w); return $d->format('Y-m-d'); }
    function weekMonday($d) { return date('Y-m-d', strtotime('monday this week', strtotime($d))); }
}
