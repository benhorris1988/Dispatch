<?php
// In-app notifications + per-kind channel preferences (NOT-01..03).
// Actions: list | mark_read {id | all:true} | prefs | save_prefs {kind, in_app, push, email_digest, teams, digest}
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
$action = param('action', 'list');

const NOTIFICATION_KINDS = [
    'change_proposed'    => ['label' => 'A change is proposed that affects me', 'urgent_capable' => false],
    'change_committed'   => ['label' => 'A change to my plan is committed', 'urgent_capable' => true],
    'approval_requested' => ['label' => 'My approval is requested', 'urgent_capable' => true],
    'item_assigned'      => ['label' => 'An item is assigned to me', 'urgent_capable' => false],
    'estimate_requested' => ['label' => 'An estimate is requested', 'urgent_capable' => false],
    'realisation_due'    => ['label' => 'A benefit realisation is due', 'urgent_capable' => false],
    'watch_list'         => ['label' => 'A watch-list item I own', 'urgent_capable' => false],
];
function notif_shape(array $n) {
    return ['id' => (int)$n['id'], 'kind' => $n['kind'], 'title' => $n['title'], 'body' => $n['body'], 'link' => $n['link'], 'urgent' => (bool)$n['urgent'],
        'channel' => $n['channel'], 'created_at' => $n['created_at'], 'read_at' => $n['read_at'], 'read' => $n['read_at'] !== null];
}
function prefs_for($conn, $userId) {
    $stored = [];
    foreach (rows($conn, "SELECT * FROM dbo.notification_prefs WHERE user_id = ?", [$userId]) as $r) $stored[$r['kind']] = $r;
    $out = [];
    foreach (NOTIFICATION_KINDS as $kind => $meta) {
        $r = $stored[$kind] ?? ['in_app' => 1, 'push' => 1, 'email_digest' => 0, 'teams' => 0, 'digest' => 'daily'];
        $out[] = ['kind' => $kind, 'label' => $meta['label'], 'in_app' => (bool)$r['in_app'], 'push' => (bool)$r['push'], 'email_digest' => (bool)$r['email_digest'],
            'teams' => (bool)$r['teams'], 'digest' => $r['digest'], 'urgent_bypasses_digest' => $meta['urgent_capable'], 'is_default' => !isset($stored[$kind])];
    }
    return $out;
}

if ($action === 'list') {
    $limit = max(1, min(200, (int)param('limit', 100)));
    $unreadOnly = (bool)param('unread_only', false);
    $list = rows($conn, "SELECT TOP ($limit) * FROM dbo.notifications WHERE workspace_id = ? AND user_id = ?" . ($unreadOnly ? ' AND read_at IS NULL' : '') . " ORDER BY created_at DESC, id DESC", [$wsId, $userId]);
    $unread = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.notifications WHERE workspace_id = ? AND user_id = ? AND read_at IS NULL", [$wsId, $userId]);
    ok(['notifications' => array_map('notif_shape', $list), 'unread' => $unread]);
}

if ($action === 'mark_read') {
    if (param('all')) {
        $stmt = q($conn, "UPDATE dbo.notifications SET read_at = SYSDATETIME() WHERE workspace_id = ? AND user_id = ? AND read_at IS NULL", [$wsId, $userId]);
        $n = sqlsrv_rows_affected($stmt);
        ok(['marked' => $n === false ? 0 : $n, 'unread' => 0]);
    }
    $id = (int)require_param('id');
    $n = row($conn, "SELECT * FROM dbo.notifications WHERE id = ? AND workspace_id = ? AND user_id = ?", [$id, $wsId, $userId]);
    if (!$n) fail('Notification not found', 404);
    if ($n['read_at'] === null) q($conn, "UPDATE dbo.notifications SET read_at = SYSDATETIME() WHERE id = ?", [$id]);
    $unread = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.notifications WHERE workspace_id = ? AND user_id = ? AND read_at IS NULL", [$wsId, $userId]);
    ok(['notification' => notif_shape(row($conn, "SELECT * FROM dbo.notifications WHERE id = ?", [$id])), 'unread' => $unread]);
}

if ($action === 'prefs') ok(['prefs' => prefs_for($conn, $userId), 'kinds' => array_keys(NOTIFICATION_KINDS)]);

if ($action === 'save_prefs') {
    $kind = require_param('kind');
    if (!isset(NOTIFICATION_KINDS[$kind])) fail('Unknown notification kind', 400, ['kinds' => array_keys(NOTIFICATION_KINDS)]);
    $before = row($conn, "SELECT * FROM dbo.notification_prefs WHERE user_id = ? AND kind = ?", [$userId, $kind]);
    $cur = $before ?: ['in_app' => 1, 'push' => 1, 'email_digest' => 0, 'teams' => 0, 'digest' => 'daily'];
    $b = body();
    $data = [];
    foreach (['in_app','push','email_digest','teams'] as $f) $data[$f] = array_key_exists($f, $b) ? ($b[$f] ? 1 : 0) : (int)$cur[$f];
    $digest = $b['digest'] ?? $cur['digest'];
    if (!in_array($digest, ['immediate','daily','weekly','off'], true)) fail('digest must be immediate, daily, weekly or off', 400);
    $data['digest'] = $digest;
    if ($before) update($conn, 'notification_prefs', $data, 'user_id = ? AND kind = ?', [$userId, $kind]);
    else q($conn, "INSERT INTO dbo.notification_prefs (user_id, kind, in_app, push, email_digest, teams, digest) VALUES (?,?,?,?,?,?,?)", [$userId, $kind, $data['in_app'], $data['push'], $data['email_digest'], $data['teams'], $data['digest']]);
    $after = row($conn, "SELECT * FROM dbo.notification_prefs WHERE user_id = ? AND kind = ?", [$userId, $kind]);
    audit($conn, $wsId, 'update', 'notification_prefs', $userId, $before, $after, "$userName · $kind");
    ok(['prefs' => prefs_for($conn, $userId)]);
}

fail('Unknown action', 400);
