<?php
// Per-person iCalendar feed of committed assignments (VIEW-09; the publish half of INT-04).
//
// Two shapes in one file, because a calendar client cannot send a bearer token:
//   GET  /api/calendar.php?token=…   -> text/calendar, no session, authorised by the token alone
//   POST {"action": "my_feed"|"revoke"} with a bearer token -> manage your own feed URL
//
// The token grants read access to one person's committed assignments and nothing else. It
// is revocable, and the feed carries no personal data beyond what the schedule already
// shows: work item, dates and allocation. Leave is deliberately excluded — ADM-05 keeps
// availability reasons out of the system, and publishing absence to a shared calendar is
// not something this feed should decide for someone.
require_once __DIR__ . '/db_connect.php';

/** RFC 5545 line folding at 75 octets, which real calendar clients do enforce. */
function ics_fold($line) {
    $out = ''; $len = 0;
    foreach (preg_split('//u', $line, -1, PREG_SPLIT_NO_EMPTY) as $ch) {
        $w = strlen($ch);
        if ($len + $w > 73) { $out .= "\r\n "; $len = 1; }
        $out .= $ch; $len += $w;
    }
    return $out;
}
function ics_escape($s) {
    return str_replace(["\\", "\n", ";", ","], ["\\\\", "\\n", "\\;", "\\,"], (string)$s);
}

$action = param('action', '');
$token = param('token');

// ---------------------------------------------------------------------------- public feed
if ($token !== null && $token !== '' && $action === '') {
    $feed = row($conn, "SELECT f.*, p.name AS person_name FROM dbo.calendar_feeds f JOIN dbo.people p ON p.id = f.person_id
        WHERE f.token = ? AND f.revoked = 0", [$token]);
    if (!$feed) {
        http_response_code(404);
        header('Content-Type: text/plain; charset=utf-8');
        echo "This calendar feed has been revoked or does not exist.";
        exit;
    }
    $wsId = (int)$feed['workspace_id'];
    $pid = (int)$feed['person_id'];
    $pvId = (int)(scalar($conn, "SELECT TOP 1 id FROM dbo.plan_versions WHERE workspace_id = ? AND status = 'committed' ORDER BY version_no DESC", [$wsId]) ?? -1);
    $rowsOut = rows($conn, "SELECT a.id, a.from_date, a.to_date, a.allocation_pct, a.state, a.role_label,
            wi.ref, wi.title, wi.status, wt.name AS type_name
        FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id
        WHERE a.plan_version_id = ? AND a.person_id = ? ORDER BY a.from_date", [$pvId, $pid]);
    $ws = row($conn, "SELECT name, time_zone FROM dbo.workspaces WHERE id = ?", [$wsId]);
    update($conn, 'calendar_feeds', ['last_read_at' => date('Y-m-d H:i:s')], 'id = ?', [(int)$feed['id']]);

    $stamp = gmdate('Ymd\THis\Z');
    $lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Dispatch//Delivery planning//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH'];
    $lines[] = 'X-WR-CALNAME:' . ics_escape('Dispatch · ' . $feed['person_name']);
    $lines[] = 'X-WR-CALDESC:' . ics_escape('Committed assignments from the ' . ($ws['name'] ?? 'Dispatch') . ' plan. Read-only.');
    $lines[] = 'X-WR-TIMEZONE:' . ics_escape($ws['time_zone'] ?? 'Europe/London');
    foreach ($rowsOut as $a) {
        // All-day events: DTEND is exclusive in iCalendar, so add a day to the inclusive finish.
        $end = date('Ymd', strtotime($a['to_date'] . ' +1 day'));
        $state = $a['state'] === 'committed' ? 'Committed' : ($a['state'] === 'planned' ? 'Planned' : 'Indicative');
        $desc = "{$a['type_name']} · {$a['allocation_pct']}% · $state";
        if (!empty($a['role_label'])) $desc .= " · {$a['role_label']}";
        $lines[] = 'BEGIN:VEVENT';
        $lines[] = 'UID:dispatch-' . $wsId . '-' . (int)$a['id'] . '@dispatch';
        $lines[] = 'DTSTAMP:' . $stamp;
        $lines[] = 'DTSTART;VALUE=DATE:' . date('Ymd', strtotime($a['from_date']));
        $lines[] = 'DTEND;VALUE=DATE:' . $end;
        $lines[] = 'SUMMARY:' . ics_escape("{$a['ref']} {$a['title']}");
        $lines[] = 'DESCRIPTION:' . ics_escape($desc);
        $lines[] = 'CATEGORIES:' . ics_escape($a['type_name']);
        // Indicative work is not a commitment; mark it free so it does not block someone's diary.
        $lines[] = 'TRANSP:' . ($a['state'] === 'indicative' ? 'TRANSPARENT' : 'OPAQUE');
        $lines[] = 'STATUS:' . ($a['state'] === 'indicative' ? 'TENTATIVE' : 'CONFIRMED');
        $lines[] = 'END:VEVENT';
    }
    $lines[] = 'END:VCALENDAR';

    header_remove('Content-Type');
    header('Content-Type: text/calendar; charset=utf-8');
    header('Content-Disposition: inline; filename="dispatch.ics"');
    header('Cache-Control: max-age=900');
    echo implode("\r\n", array_map('ics_fold', $lines)) . "\r\n";
    exit;
}

// ------------------------------------------------------------------------ managing the feed
require_once __DIR__ . '/auth_middleware.php';

/** Base URL of this deployment, for handing the subscriber a working link. */
function feed_base_url() {
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    return "$scheme://$host/api/calendar.php";
}

if ($action === 'my_feed') {
    $target = param('person_id') !== null ? (int)param('person_id') : $personId;
    if ($target === null) fail('Your account is not linked to a team member, so there is no calendar to publish.', 409);
    if ($target !== $personId) require_role('team_lead');
    $feed = row($conn, "SELECT * FROM dbo.calendar_feeds WHERE workspace_id = ? AND person_id = ? AND revoked = 0", [$wsId, $target]);
    if (!$feed) {
        $newToken = bin2hex(random_bytes(24));
        $id = insert($conn, 'calendar_feeds', ['workspace_id' => $wsId, 'person_id' => $target, 'token' => $newToken]);
        audit($conn, $wsId, 'create', 'calendar_feed', $id, null, ['person_id' => $target], 'Calendar feed issued');
        $feed = row($conn, "SELECT * FROM dbo.calendar_feeds WHERE id = ?", [$id]);
    }
    ok(['url' => feed_base_url() . '?token=' . $feed['token'], 'person_id' => $target,
        'last_read_at' => $feed['last_read_at'],
        'note' => 'Anyone with this link can read your committed assignments. Revoke it if you share it by mistake.']);
}

if ($action === 'revoke') {
    $target = param('person_id') !== null ? (int)param('person_id') : $personId;
    if ($target === null) fail('Your account is not linked to a team member.', 409);
    if ($target !== $personId) require_role('team_lead');
    q($conn, "UPDATE dbo.calendar_feeds SET revoked = 1 WHERE workspace_id = ? AND person_id = ?", [$wsId, $target]);
    audit($conn, $wsId, 'update', 'calendar_feed', $target, null, ['revoked' => true], 'Calendar feed revoked');
    ok(['revoked' => true]);
}

fail('Unknown action. Use my_feed or revoke, or request the feed itself with ?token=…', 400);
