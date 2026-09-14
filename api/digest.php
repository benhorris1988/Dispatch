<?php
// Weekly digest per person (NOT-04).
//
//   preview                 -> your own digest, composed now, nothing sent (any role)
//   preview{user_id}        -> someone else's (team_lead+)
//   send{user_id}           -> compose and deliver one digest (admin)
//   send                    -> deliver to everyone with an email digest on in notification_prefs (admin, or CLI via cron_digest.php)
//
// compose_digest($conn, $wsId, $userId) is the pure part: next week's assignments for the user's
// person from the committed plan, what changed for them since users.last_digest_at, changes still
// awaiting their acknowledgement, watch-list entries naming them, and the notifications their
// own preferences routed to the digest channel since then — with a plain-text and an HTML
// rendering of all of it.
//
// Delivery is engine/mail_lib.php's business and is reported, not assumed: `sent` is true only
// when a configured transport accepted the mail; otherwise the digest lands as an in-app
// notification of kind `digest` and the result says `in_app: true` with the reason. Either way it
// is a real weekly digest — the in-app one is readable in the app — and last_digest_at advances
// only when one of the two actually happened, so nothing is silently skipped.
//
// Two clocks, deliberately. "Next week" is relative to today() (the planner's date, which the
// demo pins) because it is a statement about the plan. "Since the last digest" is real time
// (last_digest_at is stamped when a digest goes out) because it is a statement about sends —
// and it is the DATABASE's real time (SYSDATETIME()), not PHP's, because every row it is
// compared against (person_change_log.changed_at, proposals.decided_at, notifications.created_at)
// was stamped by a SQL default. PHP runs in Europe/London and SQL Server on the host's clock; on
// a box where those differ a PHP timestamp would silently drop or repeat an hour of changes.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/items_lib.php';
require_once __DIR__ . '/engine/mail_lib.php';
require_once __DIR__ . '/engine/watchlist.php';

const DP_DIGEST_KINDS = ['move' => 'Moved', 'extend' => 'Extended', 'reassign' => 'Reassigned', 'add' => 'Added', 'remove' => 'Removed', 'split' => 'Split', 'pair' => 'Paired'];

function dg_date($d, $fmt = 'D j M') { return $d ? date($fmt, strtotime(substr((string)$d, 0, 10))) : ''; }
function dg_h($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }

/** The structured digest for one user, or null when the user is not in the workspace. */
function compose_digest($conn, $wsId, $userId) {
    // last_digest_at is compared at full datetime2 precision: truncated to the second, a change
    // stamped earlier in the same second as the previous send would be carried twice.
    $u = row($conn, "SELECT u.id, u.email, u.display_name, u.person_id, CONVERT(varchar(27), u.last_digest_at, 121) AS last_digest_at, p.name AS person_name FROM dbo.users u LEFT JOIN dbo.people p ON p.id = u.person_id WHERE u.id = ? AND u.workspace_id = ?", [(int)$userId, $wsId]);
    if (!$u) return null;
    $pid = $u['person_id'] !== null ? (int)$u['person_id'] : null;
    $wsName = (string)scalar($conn, "SELECT name FROM dbo.workspaces WHERE id = ?", [$wsId]);
    $today = today(); $wd = workspace_working_days($conn, $wsId);
    $from = date('Y-m-d', strtotime(week_start($today) . ' +7 days'));
    $to = date('Y-m-d', strtotime("$from +6 days"));
    $capacityDays = working_days_between($from, $to, $wd);
    $sinceIsFirst = $u['last_digest_at'] === null;
    $clock = row($conn, "SELECT CONVERT(varchar(19), SYSDATETIME(), 120) AS now, CONVERT(varchar(27), DATEADD(day, -7, SYSDATETIME()), 121) AS week_ago");
    $since = $sinceIsFirst ? $clock['week_ago'] : $u['last_digest_at'];
    $now = $clock['now'];
    $pv = committed_plan_id($conn, $wsId);

    // 1. Next week's plan: committed assignments for the person overlapping the week.
    $nextWeek = []; $effort = 0.0;
    if ($pid !== null && $pv !== null) {
        foreach (rows($conn, "SELECT a.id, a.work_item_id, CONVERT(char(10), a.from_date, 23) AS from_date, CONVERT(char(10), a.to_date, 23) AS to_date, a.allocation_pct, a.role_label, a.is_reserve, a.state,
                                     wi.ref, wi.title, wi.status, CONVERT(char(10), wi.needed_by, 23) AS needed_by, wi.priority_score, wt.name AS type_name, wt.colour AS type_colour
                              FROM dbo.assignments a JOIN dbo.work_items wi ON wi.id = a.work_item_id JOIN dbo.work_types wt ON wt.id = wi.work_type_id
                              WHERE a.plan_version_id = ? AND a.person_id = ? AND a.from_date <= ? AND a.to_date >= ? ORDER BY a.from_date, wi.priority_score DESC, wi.ref", [$pv, $pid, $to, $from]) as $a) {
            $s = max($a['from_date'], $from); $e = min($a['to_date'], $to);
            $days = working_days_between($s, $e, $wd);
            $pct = (int)$a['allocation_pct'];
            $eff = round($days * $pct / 100, 1); $effort += $eff;
            $nextWeek[] = ['assignment_id' => (int)$a['id'], 'work_item_id' => (int)$a['work_item_id'], 'ref' => $a['ref'], 'title' => $a['title'], 'type_name' => $a['type_name'], 'type_colour' => $a['type_colour'],
                'status' => $a['status'], 'from_date' => $a['from_date'], 'to_date' => $a['to_date'], 'in_week_from' => $s, 'in_week_to' => $e, 'days_in_week' => $days, 'allocation_pct' => $pct, 'effort_days' => $eff,
                'role_label' => $a['role_label'], 'is_reserve' => (bool)$a['is_reserve'], 'starts_in_week' => $a['from_date'] >= $from, 'finishes_in_week' => $a['to_date'] <= $to,
                'needed_by' => $a['needed_by'], 'priority_score' => $a['priority_score'] !== null ? (float)$a['priority_score'] : null, 'link' => "/items/{$a['ref']}"];
        }
    }
    // Time away next week (type and label only — never a reason, ADM-05).
    $leave = $pid === null ? [] : array_map(fn($r) => ['from_date' => $r['f'], 'to_date' => $r['t'], 'type' => $r['type'], 'label' => $r['label'] ?: ucfirst($r['type']), 'fraction' => (float)$r['fraction']],
        rows($conn, "SELECT CONVERT(char(10), from_date, 23) f, CONVERT(char(10), to_date, 23) t, type, label, fraction FROM dbo.availability WHERE workspace_id = ? AND person_id = ? AND from_date <= ? AND to_date >= ? ORDER BY from_date", [$wsId, $pid, $to, $from]));

    // 2. Changes affecting them since the last digest: the person's own change log, plus committed
    //    changes that name them as affected without having logged a row for them.
    $changes = []; $seenCp = [];
    if ($pid !== null) {
        foreach (rows($conn, "SELECT l.id, l.changed_at, CONVERT(char(10), l.week_start, 23) AS week_start, l.inside_freeze, l.assignment_days, l.reason, l.change_proposal_id,
                                     wi.ref, wi.title, cp.headline, cp.kind, cp.proposal_id
                              FROM dbo.person_change_log l LEFT JOIN dbo.work_items wi ON wi.id = l.work_item_id LEFT JOIN dbo.change_proposals cp ON cp.id = l.change_proposal_id
                              WHERE l.workspace_id = ? AND l.person_id = ? AND l.changed_at > ? ORDER BY l.changed_at DESC, l.id DESC", [$wsId, $pid, $since]) as $r) {
            if ($r['change_proposal_id'] !== null) $seenCp[(int)$r['change_proposal_id']] = true;
            $changes[] = ['at' => substr($r['changed_at'], 0, 19), 'ref' => $r['ref'], 'title' => $r['title'], 'kind' => $r['kind'], 'kind_label' => DP_DIGEST_KINDS[$r['kind'] ?? ''] ?? 'Changed',
                'headline' => $r['headline'] ?: ($r['ref'] ? "{$r['ref']} " . ($r['reason'] ?: 'moved') : ($r['reason'] ?: 'Plan changed')), 'reason' => $r['reason'],
                'week_start' => $r['week_start'], 'inside_freeze' => (bool)$r['inside_freeze'], 'assignment_days' => (float)$r['assignment_days'],
                'change_proposal_id' => $r['change_proposal_id'] !== null ? (int)$r['change_proposal_id'] : null, 'link' => $r['proposal_id'] !== null ? "/changes/{$r['proposal_id']}" : ($r['ref'] ? "/items/{$r['ref']}" : '/my-week'), 'source' => 'person_change_log'];
        }
        foreach (rows($conn, "SELECT cp.id, cp.proposal_id, cp.headline, cp.kind, cp.reason, cp.inside_freeze, cp.stability_cost_days, p.decided_at, wi.ref, wi.title
                              FROM dbo.change_proposals cp JOIN dbo.proposals p ON p.id = cp.proposal_id LEFT JOIN dbo.work_items wi ON wi.id = cp.work_item_id
                              WHERE cp.workspace_id = ? AND cp.decision IN ('accepted','edited') AND p.decided_at > ? AND (cp.person_id = ? OR ',' + ISNULL(cp.affected_person_ids,'') + ',' LIKE ?)
                              ORDER BY p.decided_at DESC, cp.sort_order", [$wsId, $since, $pid, "%,$pid,%"]) as $r) {
            if (isset($seenCp[(int)$r['id']])) continue;
            $changes[] = ['at' => substr($r['decided_at'], 0, 19), 'ref' => $r['ref'], 'title' => $r['title'], 'kind' => $r['kind'], 'kind_label' => DP_DIGEST_KINDS[$r['kind']] ?? 'Changed',
                'headline' => $r['headline'], 'reason' => $r['reason'], 'week_start' => null, 'inside_freeze' => (bool)$r['inside_freeze'], 'assignment_days' => (float)$r['stability_cost_days'],
                'change_proposal_id' => (int)$r['id'], 'link' => "/changes/{$r['proposal_id']}", 'source' => 'change_proposals'];
        }
        usort($changes, fn($a, $b) => strcmp($b['at'], $a['at']));
    }

    // 3. Committed changes still awaiting their acknowledgement (CHG-06).
    $awaiting = $pid === null ? [] : array_map(fn($r) => ['change_proposal_id' => (int)$r['id'], 'proposal_id' => (int)$r['proposal_id'], 'headline' => $r['headline'], 'reason' => $r['reason'], 'ref' => $r['ref'], 'title' => $r['title'],
            'inside_freeze' => (bool)$r['inside_freeze'], 'decided_at' => $r['decided_at'] ? substr($r['decided_at'], 0, 19) : null, 'link' => "/changes/{$r['proposal_id']}"],
        rows($conn, "SELECT cp.id, cp.proposal_id, cp.headline, cp.reason, cp.inside_freeze, p.decided_at, wi.ref, wi.title
                     FROM dbo.change_proposals cp JOIN dbo.proposals p ON p.id = cp.proposal_id LEFT JOIN dbo.work_items wi ON wi.id = cp.work_item_id
                     WHERE cp.workspace_id = ? AND cp.decision IN ('accepted','edited') AND cp.ack_required = 1 AND cp.acknowledged_at IS NULL
                       AND (cp.person_id = ? OR ',' + ISNULL(cp.affected_person_ids,'') + ',' LIKE ?) ORDER BY p.decided_at DESC, cp.sort_order", [$wsId, $pid, "%,$pid,%"]));

    // 4. Watch-list entries that name them.
    $watch = [];
    if ($pid !== null) {
        $wl = build_watch_list($conn, $wsId);
        foreach ((is_array($wl) && isset($wl['items']) ? $wl['items'] : $wl) as $w) {
            if ((int)($w['person_id'] ?? -1) !== $pid) continue;
            $watch[] = ['kind' => $w['kind'], 'title' => $w['title'], 'body' => $w['body'] ?? null, 'suggestion' => $w['suggestion'] ?? null, 'tone' => $w['tone'] ?? 'info', 'link' => $w['link'] ?? '/overview'];
        }
    }

    // 5. Notifications their own preferences routed to the digest channel since the last one (NOT-02).
    $carried = array_map(fn($n) => ['id' => (int)$n['id'], 'kind' => $n['kind'], 'title' => $n['title'], 'body' => $n['body'], 'link' => $n['link'], 'created_at' => substr($n['created_at'], 0, 19), 'read' => $n['read_at'] !== null],
        rows($conn, "SELECT id, kind, title, body, link, created_at, read_at FROM dbo.notifications WHERE workspace_id = ? AND user_id = ? AND channel = 'digest' AND created_at > ? ORDER BY created_at DESC", [$wsId, (int)$u['id'], $since]));

    $summary = ['has_person' => $pid !== null, 'assignments' => count($nextWeek), 'effort_days' => round($effort, 1), 'capacity_days' => $capacityDays,
        'load_pct' => $capacityDays > 0 ? (int)round($effort / $capacityDays * 100) : null, 'leave' => count($leave), 'changes' => count($changes), 'awaiting_ack' => count($awaiting),
        'watch_list' => count($watch), 'carried_notifications' => count($carried)];
    $bits = [];
    $bits[] = $summary['assignments'] === 0 ? 'nothing planned for you next week' : ($summary['assignments'] === 1 ? '1 assignment next week' : "{$summary['assignments']} assignments next week") . ($capacityDays > 0 ? " ({$summary['effort_days']} of $capacityDays days)" : '');
    $bits[] = $summary['changes'] === 1 ? '1 change since ' . dg_date($since, 'j M') : "{$summary['changes']} changes since " . dg_date($since, 'j M');
    if ($summary['awaiting_ack']) $bits[] = $summary['awaiting_ack'] . ' awaiting your acknowledgement';
    if ($summary['watch_list']) $bits[] = $summary['watch_list'] . ' watch-list ' . ($summary['watch_list'] === 1 ? 'entry names' : 'entries name') . ' you';
    if ($summary['carried_notifications']) $bits[] = $summary['carried_notifications'] . ' notification' . ($summary['carried_notifications'] === 1 ? '' : 's') . ' carried';
    $summaryLine = ucfirst(implode('; ', $bits)) . '.';

    $d = ['user' => ['id' => (int)$u['id'], 'name' => $u['display_name'], 'email' => $u['email'], 'person_id' => $pid, 'person_name' => $u['person_name']],
        'workspace' => $wsName, 'generated_at' => $now,
        'period' => ['today' => $today, 'week_from' => $from, 'week_to' => $to, 'label' => 'w/c ' . dg_date($from, 'j M Y'), 'capacity_days' => $capacityDays],
        'since' => $since, 'since_is_default' => $sinceIsFirst, 'last_digest_at' => $u['last_digest_at'],
        'summary' => $summary, 'summary_line' => $summaryLine,
        'next_week' => $nextWeek, 'leave' => $leave, 'changes' => $changes, 'awaiting_ack' => $awaiting, 'watch_list' => $watch, 'carried_notifications' => $carried,
        'empty' => $summary['assignments'] + $summary['changes'] + $summary['awaiting_ack'] + $summary['watch_list'] + $summary['carried_notifications'] + $summary['leave'] === 0];
    $d['subject'] = "Your week ahead: " . dg_date($from, 'j M') . ' – ' . dg_date($to, 'j M') . ($d['empty'] ? ' (nothing planned)' : " · {$summary['assignments']} " . ($summary['assignments'] === 1 ? 'assignment' : 'assignments') . ", {$summary['changes']} " . ($summary['changes'] === 1 ? 'change' : 'changes'));
    $d['text'] = digest_render_text($d);
    $d['html'] = digest_render_html($d);
    return $d;
}

function digest_render_text(array $d) {
    $L = []; $s = $d['summary'];
    $L[] = "Dispatch weekly digest — {$d['user']['name']}";
    $L[] = "{$d['workspace']} · {$d['period']['label']}";
    $L[] = $d['summary_line'];
    $L[] = '';
    $L[] = strtoupper("Next week's plan") . " ({$s['assignments']}" . ($d['period']['capacity_days'] ? ", {$s['effort_days']} of {$d['period']['capacity_days']} days" : '') . ')';
    if (!$s['has_person']) $L[] = '  No person is linked to your account, so there is no plan to show.';
    elseif (!$d['next_week']) $L[] = '  Nothing is assigned to you next week in the committed plan.';
    foreach ($d['next_week'] as $a) $L[] = sprintf('  %s – %s  %s %s (%s%s) %d%%%s', dg_date($a['in_week_from']), dg_date($a['in_week_to'], 'D j'), $a['ref'], $a['title'], $a['type_name'], $a['role_label'] ? ', ' . $a['role_label'] : '', $a['allocation_pct'],
        $a['finishes_in_week'] ? ' · finishes' : ($a['starts_in_week'] ? ' · starts' : ' · continues'));
    foreach ($d['leave'] as $l) $L[] = '  Away: ' . dg_date($l['from_date']) . ($l['to_date'] !== $l['from_date'] ? ' – ' . dg_date($l['to_date']) : '') . " ({$l['label']})";
    $L[] = '';
    $L[] = strtoupper('Changes since ' . dg_date($d['since'], 'j M Y')) . " ({$s['changes']})";
    if (!$d['changes']) $L[] = '  ' . ($s['has_person'] ? 'No committed change has touched your plan.' : 'No person is linked to your account.');
    foreach ($d['changes'] as $c) $L[] = '  ' . dg_date($c['at'], 'j M') . "  {$c['headline']}" . ($c['reason'] && stripos($c['headline'], $c['reason']) === false ? " — {$c['reason']}" : '') . ($c['inside_freeze'] ? ' [inside freeze horizon]' : '');
    if ($d['awaiting_ack']) {
        $L[] = ''; $L[] = strtoupper('Awaiting your acknowledgement') . " ({$s['awaiting_ack']})";
        foreach ($d['awaiting_ack'] as $a) $L[] = "  {$a['headline']}" . ($a['reason'] ? " — {$a['reason']}" : '') . "  ({$a['link']})";
    }
    if ($d['watch_list']) {
        $L[] = ''; $L[] = strtoupper('Watch list naming you') . " ({$s['watch_list']})";
        foreach ($d['watch_list'] as $w) $L[] = "  {$w['title']}" . ($w['body'] ? " {$w['body']}" : '') . ($w['suggestion'] ? " {$w['suggestion']}" : '');
    }
    if ($d['carried_notifications']) {
        $L[] = ''; $L[] = strtoupper('Notifications carried in this digest') . " ({$s['carried_notifications']})";
        foreach ($d['carried_notifications'] as $n) $L[] = '  ' . dg_date($n['created_at'], 'j M') . "  {$n['title']}" . ($n['body'] ? " — " . mb_substr($n['body'], 0, 120) : '');
    }
    $L[] = ''; $L[] = 'Generated ' . $d['generated_at'] . '. Open My week in Dispatch for the live view.';
    return implode("\n", $L) . "\n";
}

function digest_render_html(array $d) {
    $s = $d['summary']; $h = 'dg_h';
    $row = fn($cells) => '<tr>' . implode('', array_map(fn($c) => '<td style="padding:4px 8px;border-bottom:1px solid #e6e9ef;vertical-align:top;font-size:13px">' . $c . '</td>', $cells)) . '</tr>';
    $sec = fn($title, $count) => '<h3 style="margin:18px 0 6px;font-size:14px;color:#1c2333">' . $h($title) . ' <span style="color:#8a94a6;font-weight:normal">(' . (int)$count . ')</span></h3>';
    $o = '<div style="font-family:Segoe UI,Arial,sans-serif;color:#1c2333;max-width:720px">';
    $o .= '<h2 style="margin:0 0 2px;font-size:18px">Dispatch weekly digest — ' . $h($d['user']['name']) . '</h2>';
    $o .= '<div style="color:#5b6b84;font-size:13px">' . $h($d['workspace']) . ' · ' . $h($d['period']['label']) . '</div>';
    $o .= '<p style="font-size:14px">' . $h($d['summary_line']) . '</p>';
    $o .= $sec("Next week's plan" . ($d['period']['capacity_days'] ? " · {$s['effort_days']} of {$d['period']['capacity_days']} days" : ''), $s['assignments']);
    if (!$s['has_person']) $o .= '<p style="font-size:13px;color:#5b6b84">No person is linked to your account, so there is no plan to show.</p>';
    elseif (!$d['next_week']) $o .= '<p style="font-size:13px;color:#5b6b84">Nothing is assigned to you next week in the committed plan.</p>';
    else {
        $o .= '<table style="border-collapse:collapse;width:100%">';
        foreach ($d['next_week'] as $a) $o .= $row([$h(dg_date($a['in_week_from']) . ' – ' . dg_date($a['in_week_to'], 'D j')),
            '<span style="display:inline-block;width:8px;height:8px;border-radius:2px;background:' . $h($a['type_colour']) . ';margin-right:6px"></span><strong>' . $h($a['ref']) . '</strong> ' . $h($a['title']) . '<div style="color:#8a94a6;font-size:12px">' . $h($a['type_name'] . ($a['role_label'] ? ' · ' . $a['role_label'] : '')) . '</div>',
            $h($a['allocation_pct'] . '%'), $h($a['finishes_in_week'] ? 'finishes' : ($a['starts_in_week'] ? 'starts' : 'continues'))]);
        $o .= '</table>';
    }
    foreach ($d['leave'] as $l) $o .= '<div style="font-size:13px;color:#5b6b84">Away: ' . $h(dg_date($l['from_date']) . ($l['to_date'] !== $l['from_date'] ? ' – ' . dg_date($l['to_date']) : '') . " ({$l['label']})") . '</div>';
    $o .= $sec('Changes since ' . dg_date($d['since'], 'j M Y'), $s['changes']);
    if (!$d['changes']) $o .= '<p style="font-size:13px;color:#5b6b84">' . ($s['has_person'] ? 'No committed change has touched your plan.' : 'No person is linked to your account.') . '</p>';
    else { $o .= '<table style="border-collapse:collapse;width:100%">'; foreach ($d['changes'] as $c) $o .= $row([$h(dg_date($c['at'], 'j M')), $h($c['headline']) . ($c['reason'] && stripos($c['headline'], $c['reason']) === false ? '<div style="color:#8a94a6;font-size:12px">' . $h($c['reason']) . '</div>' : '') . ($c['inside_freeze'] ? ' <span style="color:#b42318;font-size:12px">inside freeze horizon</span>' : '')]); $o .= '</table>'; }
    if ($d['awaiting_ack']) { $o .= $sec('Awaiting your acknowledgement', $s['awaiting_ack']); $o .= '<ul style="font-size:13px;margin:0;padding-left:18px">'; foreach ($d['awaiting_ack'] as $a) $o .= '<li>' . $h($a['headline']) . ($a['reason'] ? ' <span style="color:#8a94a6">— ' . $h($a['reason']) . '</span>' : '') . '</li>'; $o .= '</ul>'; }
    if ($d['watch_list']) { $o .= $sec('Watch list naming you', $s['watch_list']); $o .= '<ul style="font-size:13px;margin:0;padding-left:18px">'; foreach ($d['watch_list'] as $w) $o .= '<li><strong>' . $h($w['title']) . '</strong> ' . $h($w['body']) . ($w['suggestion'] ? ' <em>' . $h($w['suggestion']) . '</em>' : '') . '</li>'; $o .= '</ul>'; }
    if ($d['carried_notifications']) { $o .= $sec('Notifications carried in this digest', $s['carried_notifications']); $o .= '<table style="border-collapse:collapse;width:100%">'; foreach ($d['carried_notifications'] as $n) $o .= $row([$h(dg_date($n['created_at'], 'j M')), '<strong>' . $h($n['title']) . '</strong>' . ($n['body'] ? '<div style="color:#8a94a6;font-size:12px">' . $h(mb_substr($n['body'], 0, 160)) . '</div>' : '')]); $o .= '</table>'; }
    $o .= '<p style="color:#8a94a6;font-size:12px;margin-top:18px">Generated ' . $h($d['generated_at']) . '. Open My week in Dispatch for the live view.</p></div>';
    return $o;
}

/** Active users who have asked for an email digest for any kind (email_digest on, cadence not off). */
function digest_recipients($conn, $wsId) {
    return rows($conn, "SELECT DISTINCT u.id, u.email, u.display_name, u.person_id, u.last_digest_at FROM dbo.users u JOIN dbo.notification_prefs np ON np.user_id = u.id
                        WHERE u.workspace_id = ? AND u.active = 1 AND np.email_digest = 1 AND np.digest <> 'off' ORDER BY u.id", [$wsId]);
}

/** Compose, deliver (mail or in-app), advance last_digest_at when something was delivered, audit. */
function send_digest($conn, $wsId, array $u) {
    $d = compose_digest($conn, $wsId, (int)$u['id']);
    if ($d === null) return ['user_id' => (int)$u['id'], 'delivered' => false, 'sent' => false, 'in_app' => false, 'reason' => 'user not in workspace'];
    $r = mail_send($u['email'], $d['subject'], $d['text'], $d['html'], ['conn' => $conn, 'workspace_id' => $wsId, 'user_id' => (int)$u['id'], 'body' => $d['summary_line'], 'link' => '/my-week']);
    $delivered = $r['sent'] || $r['in_app'];
    $now = $d['generated_at'];
    if ($delivered) {
        // Stamped on the database clock (see the header): the next digest's "since" must sit
        // on the same clock as the rows it filters.
        q($conn, "UPDATE dbo.users SET last_digest_at = SYSDATETIME() WHERE id = ?", [(int)$u['id']]);
        $now = (string)scalar($conn, "SELECT CONVERT(varchar(27), last_digest_at, 121) FROM dbo.users WHERE id = ?", [(int)$u['id']]);
    }
    audit($conn, $wsId, 'send', 'digest', (int)$u['id'], ['last_digest_at' => $d['last_digest_at']],
        ['delivered' => $delivered, 'sent' => $r['sent'], 'transport' => $r['transport'], 'in_app' => $r['in_app'], 'notification_id' => $r['notification_id'], 'reason' => $r['reason'],
         'since' => $d['since'], 'week_from' => $d['period']['week_from'], 'summary' => $d['summary'], 'last_digest_at' => $delivered ? $now : $d['last_digest_at']],
        $u['display_name'] ?? $u['email']);
    return ['user_id' => (int)$u['id'], 'name' => $u['display_name'] ?? null, 'email' => $u['email'], 'delivered' => $delivered, 'sent' => $r['sent'], 'transport' => $r['transport'],
        'in_app' => $r['in_app'], 'notification_id' => $r['notification_id'], 'reason' => $r['reason'], 'since' => $d['since'], 'last_digest_at' => $delivered ? $now : $d['last_digest_at'],
        'subject' => $d['subject'], 'summary' => $d['summary']];
}

// =============================================================================================
$action = param('action', 'preview');
$cfg = dp_config();

// ---- send: CLI (cron_digest.php) or shared cron_key; every workspace, everyone opted in --------
if ($action === 'send' && (PHP_SAPI === 'cli' || (param('cron_key') && hash_equals((string)($cfg['cron_key'] ?? ''), (string)param('cron_key'))))) {
    $userId = null; $userName = 'Weekly digest';
    $results = [];
    $wsIds = param('workspace_id') ? [(int)param('workspace_id')] : array_map(fn($r) => (int)$r['id'], rows($conn, "SELECT id FROM dbo.workspaces ORDER BY id"));
    foreach ($wsIds as $wsId) {
        $only = param('user_id');
        $recipients = ($only !== null && $only !== '') ? rows($conn, "SELECT id, email, display_name, person_id, last_digest_at FROM dbo.users WHERE id = ? AND workspace_id = ? AND active = 1", [(int)$only, $wsId]) : digest_recipients($conn, $wsId);
        $sent = [];
        foreach ($recipients as $u) $sent[] = send_digest($conn, $wsId, $u);
        $results[] = ['workspace_id' => $wsId, 'transport' => mail_transport(), 'recipients' => count($sent), 'emailed' => count(array_filter($sent, fn($x) => $x['sent'])), 'in_app' => count(array_filter($sent, fn($x) => $x['in_app'])),
            'undelivered' => count(array_filter($sent, fn($x) => !$x['delivered'])), 'results' => $sent];
    }
    ok(['results' => $results]);
}

require_once __DIR__ . '/auth_middleware.php';

if ($action === 'preview') {
    $target = idp('user_id');
    if ($target !== null && $target !== $userId) require_role('team_lead');
    $d = compose_digest($conn, $wsId, $target ?? $userId);
    if ($d === null) fail('User not found', 404);
    ok(['digest' => $d, 'transport' => mail_transport(), 'delivery_note' => mail_transport() === null
        ? 'No mail transport is configured (api/config.php smtp / mail). A send would land this digest as an in-app notification of kind digest, not as an email.'
        : 'A send would email this digest via ' . mail_transport() . ', falling back to an in-app notification if the transport refuses it.']);
}

if ($action === 'send') {
    require_role('admin');
    $only = idp('user_id');
    if ($only !== null) {
        $u = row($conn, "SELECT id, email, display_name, person_id, last_digest_at FROM dbo.users WHERE id = ? AND workspace_id = ?", [$only, $wsId]);
        if (!$u) fail('User not found', 404);
        $recipients = [$u];
    } else {
        $recipients = digest_recipients($conn, $wsId);
    }
    $sent = [];
    foreach ($recipients as $u) $sent[] = send_digest($conn, $wsId, $u);
    ok(['transport' => mail_transport(), 'recipients' => count($sent), 'emailed' => count(array_filter($sent, fn($x) => $x['sent'])), 'in_app' => count(array_filter($sent, fn($x) => $x['in_app'])),
        'undelivered' => count(array_filter($sent, fn($x) => !$x['delivered'])), 'results' => $sent,
        'note' => mail_transport() === null ? 'No mail transport is configured, so nothing was emailed: each digest was delivered in-app (kind digest) where the recipient allows it.' : null]);
}

fail('Unknown action', 400);
