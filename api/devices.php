<?php
// Device registrations for push notifications (MOB-04).
//   register{platform, token, device_label?}  -> upsert on token for the signed-in user
//   unregister{token}                          -> deactivates (own token; an admin may deactivate any in the workspace)
//   list{all?}                                 -> own devices (+ whether a sender is configured); admin with all:true sees the workspace
//   test_push                                  -> queues a test push to the caller's active devices and dispatches it now
//   deliveries{limit?, all?}                   -> recent push_deliveries for own devices (admin with all:true: the workspace)
//
// A token identifies a device, not a person: a device that signs in as someone else is
// re-homed to the new user on register, so a push goes to whoever is signed in there.
// Tokens are never returned whole — only a hint — because a token is a capability to push to
// that device.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/push_lib.php';
$action = param('action', 'list');

function device_shape(array $d) {
    $t = (string)$d['token'];
    return ['id' => (int)$d['id'], 'user_id' => (int)$d['user_id'], 'user_name' => $d['user_name'] ?? null, 'platform' => $d['platform'],
        'token_hint' => strlen($t) > 12 ? substr($t, 0, 6) . '…' . substr($t, -4) : '…' . substr($t, -4),
        'device_label' => $d['device_label'], 'created_at' => $d['created_at'], 'last_seen_at' => $d['last_seen_at'], 'active' => (bool)$d['active']];
}
function delivery_shape(array $d) {
    return ['id' => (int)$d['id'], 'notification_id' => $d['notification_id'] === null ? null : (int)$d['notification_id'], 'device_token_id' => (int)$d['device_token_id'],
        'platform' => $d['platform'] ?? null, 'title' => $d['title'], 'body' => $d['body'], 'link' => $d['link'], 'status' => $d['status'],
        'attempts' => (int)$d['attempts'], 'next_attempt_at' => $d['next_attempt_at'], 'last_status' => $d['last_status'], 'created_at' => $d['created_at'], 'sent_at' => $d['sent_at']];
}
/** What a client should say about push on this server. */
function push_status_shape() {
    $c = push_config();
    return ['fcm' => $c['fcm'], 'apns' => $c['apns'], 'configured' => $c['fcm'] || $c['apns'],
        'note' => ($c['fcm'] || $c['apns']) ? null : 'No push sender is configured on this server; registrations are kept and deliveries are recorded as unconfigured.'];
}

if ($action === 'register') {
    $platform = strtolower(trim((string)require_param('platform')));
    if (!in_array($platform, DP_PUSH_PLATFORMS, true)) fail('platform must be ios, android or web', 400);
    $token = trim((string)require_param('token'));
    if (strlen($token) < 16 || strlen($token) > 400 || !preg_match('/^[A-Za-z0-9:_\-\.]+$/', $token)) fail('token does not look like an APNs or FCM registration token', 400);
    $label = param('device_label');
    $label = $label === null ? null : mb_substr(trim((string)$label), 0, 120);

    $existing = row($conn, "SELECT * FROM dbo.device_tokens WHERE token = ?", [$token]);
    if ($existing) {
        $id = (int)$existing['id'];
        $data = ['workspace_id' => $wsId, 'user_id' => $userId, 'platform' => $platform, 'active' => 1, 'last_seen_at' => date('Y-m-d H:i:s')];
        if ($label !== null && $label !== '') $data['device_label'] = $label;
        update($conn, 'device_tokens', $data, 'id = ?', [$id]);
        $after = row($conn, "SELECT * FROM dbo.device_tokens WHERE id = ?", [$id]);
        $rehomed = (int)$existing['user_id'] !== $userId || (int)$existing['workspace_id'] !== $wsId;
        audit($conn, $wsId, 'update', 'device_token', $id, device_shape($existing), device_shape($after), $after['device_label'] ?: $platform,
            $rehomed ? 'Device re-homed to the user now signed in on it' : null);
        ok(['device' => device_shape($after), 'created' => false, 'push' => push_status_shape()]);
    }
    $id = insert($conn, 'device_tokens', ['workspace_id' => $wsId, 'user_id' => $userId, 'platform' => $platform, 'token' => $token, 'device_label' => $label]);
    $row = row($conn, "SELECT * FROM dbo.device_tokens WHERE id = ?", [$id]);
    audit($conn, $wsId, 'create', 'device_token', $id, null, device_shape($row), $label ?: $platform);
    ok(['device' => device_shape($row), 'created' => true, 'push' => push_status_shape()]);
}

if ($action === 'unregister') {
    $token = trim((string)require_param('token'));
    $d = row($conn, "SELECT * FROM dbo.device_tokens WHERE token = ? AND workspace_id = ?", [$token, $wsId]);
    // Another user's device reads as absent rather than forbidden: existence is the secret.
    if (!$d || ((int)$d['user_id'] !== $userId && !has_role('admin'))) fail('Unknown device', 404);
    if ((int)$d['active']) {
        update($conn, 'device_tokens', ['active' => 0, 'last_seen_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$d['id']]);
        $after = row($conn, "SELECT * FROM dbo.device_tokens WHERE id = ?", [(int)$d['id']]);
        audit($conn, $wsId, 'delete', 'device_token', (int)$d['id'], device_shape($d), device_shape($after), $d['device_label'] ?: $d['platform']);
    }
    ok(['device' => device_shape(row($conn, "SELECT * FROM dbo.device_tokens WHERE id = ?", [(int)$d['id']]))]);
}

if ($action === 'list') {
    $all = (bool)param('all', false) && has_role('admin');
    $sql = "SELECT d.*, u.display_name AS user_name FROM dbo.device_tokens d JOIN dbo.users u ON u.id = d.user_id WHERE d.workspace_id = ?";
    $params = [$wsId];
    if (!$all) { $sql .= " AND d.user_id = ?"; $params[] = $userId; }
    $devices = rows($conn, "$sql ORDER BY d.active DESC, d.last_seen_at DESC, d.id DESC", $params);
    ok(['devices' => array_map('device_shape', $devices), 'push' => push_status_shape()]);
}

if ($action === 'test_push') {
    $active = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.device_tokens WHERE workspace_id = ? AND user_id = ? AND active = 1", [$wsId, $userId]);
    if ($active === 0) fail('No active device is registered for you. Register this device first.', 409);
    $firstId = (int)(scalar($conn, "SELECT ISNULL(MAX(id), -1) FROM dbo.push_deliveries") ?? -1);
    $queued = push_queue($conn, $wsId, $userId, 'Test notification from Dispatch', "Sent by $userName to check this device.", '/notifications', null);
    $result = push_dispatch($conn, $wsId, max(1, $queued));
    $deliveries = rows($conn, "SELECT d.*, t.platform FROM dbo.push_deliveries d JOIN dbo.device_tokens t ON t.id = d.device_token_id
        WHERE d.workspace_id = ? AND t.user_id = ? AND d.id > ? AND d.notification_id IS NULL ORDER BY d.id", [$wsId, $userId, $firstId]);
    audit($conn, $wsId, 'test', 'push', null, null, ['queued' => $queued] + $result, "$userName · test push");
    ok(['queued' => $queued, 'result' => $result, 'deliveries' => array_map('delivery_shape', $deliveries), 'push' => push_status_shape()]);
}

if ($action === 'deliveries') {
    $limit = max(1, min(200, (int)param('limit', 50)));
    $all = (bool)param('all', false) && has_role('admin');
    $sql = "SELECT TOP ($limit) d.*, t.platform FROM dbo.push_deliveries d JOIN dbo.device_tokens t ON t.id = d.device_token_id WHERE d.workspace_id = ?";
    $params = [$wsId];
    if (!$all) { $sql .= " AND t.user_id = ?"; $params[] = $userId; }
    ok(['deliveries' => array_map('delivery_shape', rows($conn, "$sql ORDER BY d.id DESC", $params)), 'push' => push_status_shape()]);
}

fail('Unknown action', 400);
