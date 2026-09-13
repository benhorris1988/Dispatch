<?php
// Webhook subscriptions (INT-07). Administrators only.
//   list                                  -> subscriptions + recent deliveries + the event catalogue
//   save{id?, url, events, description?, active?}   -> creates (with a generated secret) or updates
//   rotate_secret{id}                     -> new signing secret, returned once
//   delete{id}
//   test{id}                              -> queues a ping and dispatches it immediately
//   deliveries{subscription_id?, status?} -> delivery log
//   retry{delivery_id}                    -> puts a failed or abandoned delivery back in the queue
//   run                                   -> scan the audit log and dispatch what is due (also the cron path)
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/webhook_lib.php';
$action = param('action', 'list');
require_role('admin');

/** The secret is write-only: it is shown once when generated and never returned again. */
function webhook_public(array $s) {
    return [
        'id' => (int)$s['id'], 'url' => $s['url'], 'events' => $s['events'] === '*' ? array_keys(DP_WEBHOOK_EVENTS) : array_map('trim', explode(',', $s['events'])),
        'all_events' => trim($s['events']) === '*', 'description' => $s['description'], 'active' => (bool)$s['active'],
        'created_at' => $s['created_at'], 'last_delivery_at' => $s['last_delivery_at'], 'last_status' => $s['last_status'],
        'consecutive_failures' => (int)$s['consecutive_failures'],
        'secret_hint' => substr($s['secret'], 0, 4) . '…' . substr($s['secret'], -4),
    ];
}

if ($action === 'list') {
    $subs = array_map('webhook_public', rows($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE workspace_id = ? ORDER BY id", [$wsId]));
    $recent = rows($conn, "SELECT TOP 50 id, subscription_id, event, status, attempts, last_status, created_at, delivered_at, next_attempt_at
        FROM dbo.webhook_deliveries WHERE workspace_id = ? ORDER BY id DESC", [$wsId]);
    $catalogue = [];
    foreach (DP_WEBHOOK_EVENTS as $k => $desc) $catalogue[] = ['event' => $k, 'description' => $desc];
    ok(['subscriptions' => $subs, 'deliveries' => $recent, 'events' => $catalogue,
        'signature' => 'Each request carries X-Dispatch-Signature: sha256=<HMAC-SHA256 of the raw body with your secret>. Compare it with a constant-time check.',
        'retries' => 'Retried on any non-2xx or transport failure after about 1 minute, 5 minutes, 30 minutes, 2 hours and 6 hours, then abandoned.']);
}

if ($action === 'save') {
    $url = trim((string)require_param('url'));
    if (!filter_var($url, FILTER_VALIDATE_URL) || !preg_match('#^https?://#i', $url)) fail('Give a full http or https URL for the endpoint.', 422);
    $events = param('events', '*');
    if (is_array($events)) $events = implode(',', $events);
    $events = trim((string)$events) === '' ? '*' : trim((string)$events);
    if ($events !== '*') {
        foreach (array_map('trim', explode(',', $events)) as $e) {
            if (!isset(DP_WEBHOOK_EVENTS[$e])) fail("Unknown event '$e'. Known events: " . implode(', ', array_keys(DP_WEBHOOK_EVENTS)), 422);
        }
    }
    $id = param('id') !== null ? (int)param('id') : null;
    $data = ['url' => $url, 'events' => $events, 'description' => param('description'), 'active' => param('active', true) ? 1 : 0];
    if ($id) {
        $before = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
        if (!$before) fail('Unknown subscription', 404);
        update($conn, 'webhook_subscriptions', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
        $after = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ?", [$id]);
        audit($conn, $wsId, 'update', 'webhook', $id, webhook_public($before), webhook_public($after), $url);
        ok(['subscription' => webhook_public($after)]);
    }
    $secret = bin2hex(random_bytes(24));
    $data += ['workspace_id' => $wsId, 'secret' => $secret, 'created_by' => $userId];
    // Start the cursor before the subscription exists, so the very next event is delivered
    // rather than being skipped until the first scan happens to run.
    webhook_ensure_cursor($conn, $wsId);
    $newId = insert($conn, 'webhook_subscriptions', $data);
    $row = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ?", [$newId]);
    audit($conn, $wsId, 'create', 'webhook', $newId, null, webhook_public($row), $url);
    // The only time the secret is ever returned.
    ok(['subscription' => webhook_public($row), 'secret' => $secret,
        'note' => 'Copy the secret now. It is stored for signing and never shown again; rotate it if you lose it.']);
}

if ($action === 'rotate_secret') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Unknown subscription', 404);
    $secret = bin2hex(random_bytes(24));
    update($conn, 'webhook_subscriptions', ['secret' => $secret], 'id = ?', [$id]);
    audit($conn, $wsId, 'update', 'webhook', $id, null, ['secret' => 'rotated'], $s['url'], 'Signing secret rotated');
    ok(['secret' => $secret, 'note' => 'Update the subscriber before the next event, or deliveries will fail their signature check.']);
}

if ($action === 'delete') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Unknown subscription', 404);
    q($conn, "DELETE FROM dbo.webhook_deliveries WHERE subscription_id = ?", [$id]);
    q($conn, "DELETE FROM dbo.webhook_subscriptions WHERE id = ?", [$id]);
    audit($conn, $wsId, 'delete', 'webhook', $id, webhook_public($s), null, $s['url']);
    ok();
}

if ($action === 'test') {
    $id = (int)require_param('id');
    $s = row($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$s) fail('Unknown subscription', 404);
    $payload = json_encode(['event' => 'ping', 'workspace_id' => (int)$wsId, 'occurred_at' => date('Y-m-d H:i:s'),
        'actor' => $userName, 'note' => 'Test delivery from Dispatch.'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $deliveryId = insert($conn, 'webhook_deliveries', ['workspace_id' => $wsId, 'subscription_id' => $id, 'event' => 'ping', 'payload' => $payload]);
    [$okDelivery, $status] = webhook_send($s['url'], $payload, $s['secret'], 'ping', $deliveryId);
    update($conn, 'webhook_deliveries', ['status' => $okDelivery ? 'delivered' : 'failed', 'attempts' => 1,
        'delivered_at' => $okDelivery ? date('Y-m-d H:i:s') : null, 'last_status' => $status], 'id = ?', [$deliveryId]);
    update($conn, 'webhook_subscriptions', ['last_delivery_at' => date('Y-m-d H:i:s'), 'last_status' => $status], 'id = ?', [$id]);
    ok(['delivered' => $okDelivery, 'status' => $status, 'delivery_id' => $deliveryId]);
}

if ($action === 'deliveries') {
    $where = ['workspace_id = ?']; $params = [$wsId];
    if (($sid = param('subscription_id')) !== null && $sid !== '') { $where[] = 'subscription_id = ?'; $params[] = (int)$sid; }
    if ($st = param('status')) { $where[] = 'status = ?'; $params[] = $st; }
    ok(['deliveries' => rows($conn, "SELECT TOP 200 * FROM dbo.webhook_deliveries WHERE " . implode(' AND ', $where) . " ORDER BY id DESC", $params)]);
}

if ($action === 'retry') {
    $id = (int)require_param('delivery_id');
    $d = row($conn, "SELECT * FROM dbo.webhook_deliveries WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$d) fail('Unknown delivery', 404);
    update($conn, 'webhook_deliveries', ['status' => 'pending', 'next_attempt_at' => date('Y-m-d H:i:s'), 'attempts' => 0], 'id = ?', [$id]);
    ok(webhook_dispatch($conn, $wsId, 5));
}

if ($action === 'run') ok(webhook_run($conn, $wsId, (int)param('limit', 50)));

fail('Unknown action', 400);
