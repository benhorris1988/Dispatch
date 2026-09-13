<?php
// Outbound webhooks (INT-07). Pure PHP, no HTTP entry point of its own.
//
// Events are derived from dbo.audit_events rather than emitted by each endpoint. Every
// mutation already writes an audit row carrying its before and after, so the audit log is
// a natural outbox: nothing has to remember to fire a webhook, and an event cannot be
// recorded in the database but missed on the wire. webhook_scan() turns new audit rows
// into queued deliveries; webhook_dispatch() sends them, signed, with back-off.

const DP_WEBHOOK_EVENTS = [
    'plan.committed'         => 'A new plan version was committed',
    'proposal.created'       => 'A replan cycle produced a proposal',
    'change.decided'         => 'A proposed change was accepted or rejected',
    'workitem.statusChanged' => 'A work item moved to a different status',
];

/** Back-off between attempts, in seconds: ~1m, 5m, 30m, 2h, 6h, then abandon. */
const DP_WEBHOOK_BACKOFF = [60, 300, 1800, 7200, 21600];

/** Map an audit row onto an event name, or null when it is not a webhook-worthy change. */
function webhook_event_for(array $a) {
    $action = $a['action'] ?? '';
    $entity = $a['entity'] ?? '';
    if ($entity === 'plan_version' && $action === 'commit') return 'plan.committed';
    if ($entity === 'proposal' && $action === 'create') return 'proposal.created';
    if ($entity === 'change_proposal' && in_array($action, ['approve', 'reject', 'decide'], true)) return 'change.decided';
    if ($entity === 'work_item' && in_array($action, ['status', 'update'], true)) {
        // Only a genuine status transition counts, not every field edit. work_items.php
        // audits a field edit as {"field": "...", "value": "..."} and a status move under
        // its own 'status' action, so both shapes have to be read.
        [$from, $to] = webhook_status_pair($a);
        if ($from !== $to) return 'workitem.statusChanged';
    }
    return null;
}

/** The before and after status in an audit row, whichever shape it was written in. */
function webhook_status_pair(array $a) {
    $before = json_col($a['before_json'] ?? null, []);
    $after = json_col($a['after_json'] ?? null, []);
    $read = function ($j) {
        if (($j['field'] ?? null) === 'status') return $j['value'] ?? null;
        return array_key_exists('status', $j) ? $j['status'] : null;
    };
    return [$read($before), $read($after)];
}

/** The body sent to subscribers. Deliberately small: identifiers plus what changed. */
function webhook_payload($conn, $wsId, $event, array $a) {
    $body = [
        'event' => $event,
        'workspace_id' => (int)$wsId,
        'occurred_at' => $a['occurred_at'] ?? null,
        'actor' => $a['actor_name'] ?? null,
        'entity' => ['type' => $a['entity'], 'id' => $a['entity_id'] !== null ? (int)$a['entity_id'] : null, 'label' => $a['entity_label']],
    ];
    $before = json_col($a['before_json'] ?? null, []);
    $after = json_col($a['after_json'] ?? null, []);
    switch ($event) {
        case 'workitem.statusChanged':
            $wi = row($conn, "SELECT ref, title, status, health, needed_by FROM dbo.work_items WHERE id = ?", [(int)$a['entity_id']]);
            $body['work_item'] = $wi ? ['ref' => $wi['ref'], 'title' => $wi['title'], 'status' => $wi['status'], 'health' => $wi['health'], 'needed_by' => $wi['needed_by']] : null;
            [$body['from'], $body['to']] = webhook_status_pair($a);
            break;
        case 'plan.committed':
            $pv = row($conn, "SELECT version_no, status, committed_at, committed_through, objective_score, stability_cost_days FROM dbo.plan_versions WHERE id = ?", [(int)$a['entity_id']]);
            $body['plan_version'] = $pv;
            break;
        case 'proposal.created':
            $p = row($conn, "SELECT kind, status, generated_at, improvement_pct, below_threshold FROM dbo.proposals WHERE id = ?", [(int)$a['entity_id']]);
            $body['proposal'] = $p;
            $body['changes'] = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.change_proposals WHERE proposal_id = ?", [(int)$a['entity_id']]);
            break;
        case 'change.decided':
            $c = row($conn, "SELECT headline, decision, guardrail_status, stability_cost_days, decided_at FROM dbo.change_proposals WHERE id = ?", [(int)$a['entity_id']]);
            $body['change'] = $c;
            break;
    }
    return $body;
}

/**
 * Turn audit rows newer than the cursor into queued deliveries.
 * Returns ['scanned' => n, 'queued' => n, 'last_audit_id' => id].
 */
function webhook_scan($conn, $wsId) {
    $subs = rows($conn, "SELECT * FROM dbo.webhook_subscriptions WHERE workspace_id = ? AND active = 1", [$wsId]);
    $cursorRow = row($conn, "SELECT last_audit_id FROM dbo.webhook_cursor WHERE workspace_id = ?", [$wsId]);
    if ($cursorRow === null) {
        // First run: start from the present, so adding a subscription does not replay history.
        $latest = (int)(scalar($conn, "SELECT ISNULL(MAX(id), 0) FROM dbo.audit_events WHERE workspace_id = ?", [$wsId]) ?? 0);
        q($conn, "INSERT INTO dbo.webhook_cursor (workspace_id, last_audit_id) VALUES (?, ?)", [$wsId, $latest]);
        return ['scanned' => 0, 'queued' => 0, 'last_audit_id' => $latest];
    }
    $from = (int)$cursorRow['last_audit_id'];
    // A cursor ahead of the newest audit row means the log was rebuilt beneath us — a
    // restore from backup, a retention purge, or a re-seeded demo. Left alone the scan
    // would match nothing and webhooks would stop silently and for ever. Rewind to the
    // end of the new log: replaying history to subscribers would be worse than skipping it.
    $maxAudit = (int)(scalar($conn, "SELECT ISNULL(MAX(id), 0) FROM dbo.audit_events WHERE workspace_id = ?", [$wsId]) ?? 0);
    if ($from > $maxAudit) {
        update($conn, 'webhook_cursor', ['last_audit_id' => $maxAudit, 'scanned_at' => date('Y-m-d H:i:s')], 'workspace_id = ?', [$wsId]);
        return ['scanned' => 0, 'queued' => 0, 'last_audit_id' => $maxAudit, 'rewound' => true];
    }
    $events = rows($conn, "SELECT TOP 500 * FROM dbo.audit_events WHERE workspace_id = ? AND id > ? ORDER BY id", [$wsId, $from]);
    $queued = 0; $last = $from;
    foreach ($events as $a) {
        $last = (int)$a['id'];
        if (!$subs) continue;                       // still advance the cursor: no subscribers, nothing owed
        $event = webhook_event_for($a);
        if ($event === null) continue;
        $payload = null;
        foreach ($subs as $s) {
            $wanted = trim($s['events']) === '*' ? array_keys(DP_WEBHOOK_EVENTS) : array_map('trim', explode(',', $s['events']));
            if (!in_array($event, $wanted, true)) continue;
            $payload = $payload ?? json_encode(webhook_payload($conn, $wsId, $event, $a), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            insert($conn, 'webhook_deliveries', [
                'workspace_id' => $wsId, 'subscription_id' => (int)$s['id'], 'event' => $event,
                'payload' => $payload, 'source_audit_id' => (int)$a['id'],
            ]);
            $queued++;
        }
    }
    if ($last > $from) update($conn, 'webhook_cursor', ['last_audit_id' => $last, 'scanned_at' => date('Y-m-d H:i:s')], 'workspace_id = ?', [$wsId]);
    return ['scanned' => count($events), 'queued' => $queued, 'last_audit_id' => $last];
}

/** Sign a body exactly as a subscriber must verify it. */
function webhook_signature($body, $secret) {
    return 'sha256=' . hash_hmac('sha256', $body, $secret);
}

/**
 * Send everything due. Returns ['sent' => n, 'failed' => n, 'abandoned' => n].
 * A delivery that keeps failing backs off and is eventually abandoned rather than retried forever.
 */
function webhook_dispatch($conn, $wsId, $limit = 50) {
    $due = rows($conn, "SELECT TOP ($limit) d.*, s.url, s.secret FROM dbo.webhook_deliveries d
        JOIN dbo.webhook_subscriptions s ON s.id = d.subscription_id
        WHERE d.workspace_id = ? AND d.status IN ('pending','failed') AND d.next_attempt_at <= SYSDATETIME() AND s.active = 1
        ORDER BY d.id", [$wsId]);
    $sent = 0; $failed = 0; $abandoned = 0;
    foreach ($due as $d) {
        $attempt = (int)$d['attempts'] + 1;
        [$okDelivery, $status] = webhook_send($d['url'], $d['payload'], $d['secret'], $d['event'], (int)$d['id']);
        if ($okDelivery) {
            update($conn, 'webhook_deliveries', ['status' => 'delivered', 'attempts' => $attempt, 'delivered_at' => date('Y-m-d H:i:s'), 'last_status' => $status], 'id = ?', [(int)$d['id']]);
            update($conn, 'webhook_subscriptions', ['last_delivery_at' => date('Y-m-d H:i:s'), 'last_status' => $status, 'consecutive_failures' => 0], 'id = ?', [(int)$d['subscription_id']]);
            $sent++;
            continue;
        }
        if ($attempt > count(DP_WEBHOOK_BACKOFF)) {
            update($conn, 'webhook_deliveries', ['status' => 'abandoned', 'attempts' => $attempt, 'last_status' => $status], 'id = ?', [(int)$d['id']]);
            $abandoned++;
        } else {
            $next = date('Y-m-d H:i:s', time() + DP_WEBHOOK_BACKOFF[$attempt - 1]);
            update($conn, 'webhook_deliveries', ['status' => 'failed', 'attempts' => $attempt, 'next_attempt_at' => $next, 'last_status' => $status], 'id = ?', [(int)$d['id']]);
            $failed++;
        }
        q($conn, "UPDATE dbo.webhook_subscriptions SET consecutive_failures = consecutive_failures + 1, last_status = ?, last_delivery_at = SYSDATETIME() WHERE id = ?", [$status, (int)$d['subscription_id']]);
    }
    return ['sent' => $sent, 'failed' => $failed, 'abandoned' => $abandoned, 'due' => count($due)];
}

/** POST one delivery. Returns [ok, status text]. Never throws. */
function webhook_send($url, $body, $secret, $event, $deliveryId) {
    $headers = [
        'Content-Type: application/json',
        'X-Dispatch-Event: ' . $event,
        'X-Dispatch-Delivery: ' . $deliveryId,
        'X-Dispatch-Signature: ' . webhook_signature($body, $secret),
        'User-Agent: Dispatch-Webhook/1.0',
    ];
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $body, CURLOPT_HTTPHEADER => $headers,
            CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10, CURLOPT_CONNECTTIMEOUT => 5]);
        $res = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($res === false || $code === 0) return [false, 'transport: ' . substr($err ?: 'no response', 0, 120)];
        return [$code >= 200 && $code < 300, "HTTP $code"];
    }
    $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => implode("\r\n", $headers), 'content' => $body, 'timeout' => 10, 'ignore_errors' => true]]);
    $res = @file_get_contents($url, false, $ctx);
    $code = 0;
    foreach ($http_response_header ?? [] as $h) if (preg_match('#^HTTP/\S+\s+(\d{3})#', $h, $m)) $code = (int)$m[1];
    if ($res === false && $code === 0) return [false, 'transport: request failed'];
    return [$code >= 200 && $code < 300, "HTTP $code"];
}

/** Scan then dispatch, for the cron runner. */
function webhook_run($conn, $wsId, $limit = 50) {
    $scan = webhook_scan($conn, $wsId);
    $send = webhook_dispatch($conn, $wsId, $limit);
    return ['workspace_id' => (int)$wsId] + $scan + $send;
}
