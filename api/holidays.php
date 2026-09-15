<?php
// Public holidays (the supply side of the calendar). Actions: list | save | delete | import_uk | regions
//
// A holiday is a property of the calendar, not of anybody's plans: it is never written into
// dbo.availability per person. derive_capacity() reads this table, so a day entered here is
// zero hours for everyone it applies to — including people added afterwards.
//
// Reading is open to every signed-in role, because a bank holiday is not a secret and every
// screen that draws a week needs it. Writing is admin: it changes everyone's capacity at once.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/auth_middleware.php';
require_once __DIR__ . '/engine/capacity.php';
require_once __DIR__ . '/holidays_rules.php';   // UK_REGIONS and the date rules, shared with the seed
$action = param('action', 'list');

function holiday_shape(array $h) {
    return ['id' => (int)$h['id'], 'day' => substr($h['day'], 0, 10), 'label' => $h['label'],
        'region' => $h['region'], 'region_label' => $h['region'] === null ? 'Everyone' : (UK_REGIONS[$h['region']] ?? $h['region']),
        'source' => $h['source'], 'created_at' => $h['created_at']];
}

/** Everything that reads capacity has to be told when the calendar moves under it. */
function rederive_from($conn, $wsId, $from) {
    $to = date('Y-m-d', strtotime(week_start(today()) . ' +' . (int)current_policy($conn, $wsId)['model_horizon_weeks'] . ' weeks'));
    $start = $from !== null && $from < today() ? $from : today();
    if ($to < $start) return 0;
    return derive_capacity($conn, $wsId, $start, $to);
}

// ---------------------------------------------------------------------------------------------
if ($action === 'list') {
    $from = param('from') ? substr((string)param('from'), 0, 10) : date('Y-01-01', strtotime(today()));
    $to = param('to') ? substr((string)param('to'), 0, 10) : date('Y-12-31', strtotime(today() . ' +1 year'));
    $rows = rows($conn, "SELECT * FROM dbo.public_holidays WHERE workspace_id = ? AND day BETWEEN ? AND ? ORDER BY day, region", [$wsId, $from, $to]);
    $regionsInUse = array_values(array_unique(array_filter(array_map(fn($h) => $h['region'], $rows), fn($r) => $r !== null)));
    ok([
        'holidays' => array_map('holiday_shape', $rows),
        'window' => ['from' => $from, 'to' => $to],
        'regions' => array_map(fn($k, $v) => ['key' => $k, 'label' => $v], array_keys(UK_REGIONS), array_values(UK_REGIONS)),
        'regions_in_use' => $regionsInUse,
        'can_edit' => has_role('admin'),
        'note' => 'A public holiday is zero hours for everyone it applies to. It is never stored against a person.',
    ]);
}

if ($action === 'regions') ok(['regions' => array_map(fn($k, $v) => ['key' => $k, 'label' => $v], array_keys(UK_REGIONS), array_values(UK_REGIONS))]);

if ($action === 'save') {
    require_role('admin');
    $id = param('id') !== null && param('id') !== '' ? (int)param('id') : null;
    $day = substr((string)require_param('day'), 0, 10);
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $day)) fail('day must be YYYY-MM-DD', 400);
    $label = mb_substr(trim((string)require_param('label')), 0, 80);
    $region = param('region') !== null && param('region') !== '' ? (string)param('region') : null;
    if ($region !== null && !isset(UK_REGIONS[$region])) fail('Unknown region: use one of ' . implode(', ', array_keys(UK_REGIONS)) . ', or leave it empty for everyone', 400);

    $clash = row($conn, "SELECT id, label FROM dbo.public_holidays WHERE workspace_id = ? AND day = ? AND ((region IS NULL AND ? IS NULL) OR region = ?)" . ($id !== null ? " AND id <> ?" : ""),
        $id !== null ? [$wsId, $day, $region, $region, $id] : [$wsId, $day, $region, $region]);
    if ($clash) fail(fmt_day($day) . ' is already ' . $clash['label'] . ' for that region', 409, ['holiday_id' => (int)$clash['id']]);

    $before = $id !== null ? row($conn, "SELECT * FROM dbo.public_holidays WHERE id = ? AND workspace_id = ?", [$id, $wsId]) : null;
    if ($id !== null && !$before) fail('Holiday not found', 404);
    $data = ['day' => $day, 'label' => $label, 'region' => $region, 'source' => 'manual'];
    if ($id !== null) {
        update($conn, 'public_holidays', $data, 'id = ? AND workspace_id = ?', [$id, $wsId]);
    } else {
        $id = insert($conn, 'public_holidays', $data + ['workspace_id' => $wsId, 'created_by' => $userId]);
    }
    $written = rederive_from($conn, $wsId, min($day, $before ? substr($before['day'], 0, 10) : $day));
    audit($conn, $wsId, $before ? 'update' : 'create', 'holiday', $id,
        $before ? ['day' => substr($before['day'], 0, 10), 'label' => $before['label'], 'region' => $before['region']] : null,
        $data, $label);
    ok(['holiday' => holiday_shape(row($conn, "SELECT * FROM dbo.public_holidays WHERE id = ?", [$id])), 'capacity_days_rewritten' => $written]);
}

if ($action === 'delete') {
    require_role('admin');
    $id = (int)require_param('id');
    $h = row($conn, "SELECT * FROM dbo.public_holidays WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    if (!$h) fail('Holiday not found', 404);
    q($conn, "DELETE FROM dbo.public_holidays WHERE id = ? AND workspace_id = ?", [$id, $wsId]);
    $written = rederive_from($conn, $wsId, substr($h['day'], 0, 10));
    audit($conn, $wsId, 'delete', 'holiday', $id, ['day' => substr($h['day'], 0, 10), 'label' => $h['label'], 'region' => $h['region']], null, $h['label'], param('reason'));
    ok(['deleted' => true, 'capacity_days_rewritten' => $written]);
}

if ($action === 'import_uk') {
    require_role('admin');
    $year = (int)require_param('year');
    if ($year < 2000 || $year > 2100) fail('year must be between 2000 and 2100', 400);
    $region = (string)param('region', 'england-and-wales');
    if (!isset(UK_REGIONS[$region])) fail('Unknown region: use one of ' . implode(', ', array_keys(UK_REGIONS)), 400);
    // With one nation in the workspace the days belong to everybody, so they are stored with no
    // region; naming a nation only matters once two of them disagree about a Monday in August.
    $storeRegion = (bool)param('per_region', false) ? $region : null;

    $added = 0; $skipped = 0;
    foreach (uk_bank_holidays($year, $region) as $h) {
        $exists = scalar($conn, "SELECT TOP 1 id FROM dbo.public_holidays WHERE workspace_id = ? AND day = ? AND ((region IS NULL AND ? IS NULL) OR region = ?)",
            [$wsId, $h['day'], $storeRegion, $storeRegion]);
        if ($exists !== null) { $skipped++; continue; }
        insert($conn, 'public_holidays', ['workspace_id' => $wsId, 'day' => $h['day'], 'label' => $h['label'],
            'region' => $storeRegion, 'source' => 'import', 'created_by' => $userId]);
        $added++;
    }
    $written = $added > 0 ? rederive_from($conn, $wsId, sprintf('%04d-01-01', $year)) : 0;
    audit($conn, $wsId, 'create', 'holiday', null, null,
        ['year' => $year, 'region' => $region, 'stored_region' => $storeRegion, 'added' => $added, 'already_there' => $skipped],
        UK_REGIONS[$region] . " $year");
    ok(['added' => $added, 'already_there' => $skipped, 'year' => $year, 'region' => $region,
        'capacity_days_rewritten' => $written,
        'holidays' => array_map('holiday_shape', rows($conn, "SELECT * FROM dbo.public_holidays WHERE workspace_id = ? AND YEAR(day) = ? ORDER BY day", [$wsId, $year]))]);
}

fail('Unknown action', 400);
