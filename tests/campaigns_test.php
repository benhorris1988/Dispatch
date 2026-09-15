<?php
// Campaigns: sandbox workspaces alongside the live one (ADM-07).
//   php tests/campaigns_test.php [base=http://localhost:8090]
// Needs the local server (run_local.ps1) and a seeded demo DB (php seed_demo.php).
//
// This suite creates and deletes its own workspaces and leaves the live one untouched, which is
// the whole claim it exists to check: a campaign is a real workspace that cannot reach Live and
// that Live cannot see.
require_once __DIR__ . '/_auth.php';

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$BASE = rtrim($argv[1] ?? 'http://localhost:8090', '/');
$pass = 0; $fail = 0; $token = null;

function api($endpoint, array $body, $expectCode = 200) {
    global $BASE, $token;
    $ch = curl_init("$BASE/api/$endpoint.php");
    $hdr = ['Content-Type: application/json']; if ($token) $hdr[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body), CURLOPT_HTTPHEADER => $hdr, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 300]);
    $raw = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    $j = json_decode($raw, true);
    if ($j === null) { fwrite(STDERR, "Non-JSON from $endpoint/{$body['action']}: " . substr((string)$raw, 0, 400) . "\n"); $j = ['status' => 'error', 'message' => 'non-json']; }
    if ($expectCode !== null) check($code === $expectCode, "$endpoint/{$body['action']} -> HTTP $code (expected $expectCode)" . ($code !== $expectCode ? ' :: ' . ($j['message'] ?? '') : ''));
    return [$code, $j];
}
function check($cond, $label) { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label\n"; } }
function section($t) { echo "\n== $t\n"; }

/** Everything the suite creates, torn down at the end however it exits. */
$created = [];
function cleanup() {
    global $created, $token;
    $token = token_for('delivery_lead');
    foreach (array_unique($created) as $id) {
        $ch = curl_init(rtrim($GLOBALS['BASE'], '/') . '/api/campaigns.php');
        curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode(['action' => 'delete', 'workspace_id' => $id]),
            CURLOPT_HTTPHEADER => ['Content-Type: application/json', "Authorization: Bearer $token"], CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120]);
        curl_exec($ch); curl_close($ch);
    }
}
register_shutdown_function('cleanup');

section('sign in, and what Live looks like before any of this');
$token = token_for('delivery_lead');
check($token !== null, 'a delivery lead token for the live workspace');
[, $L0] = api('campaigns', ['action' => 'list']);
check($L0['current']['kind'] === 'live', 'the seeded workspace is the live one');
check($L0['current']['can_delete'] === false, 'and it cannot be deleted');
check($L0['can_create'] === true, 'a delivery lead may create a campaign');
$livePeople = (int)$L0['current']['people_count'];
$liveItems = (int)$L0['current']['items_count'];
check($livePeople > 0 && $liveItems > 0, "Live has $livePeople people and $liveItems work items");

[, $LIVEWI] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
$liveTitle = $LIVEWI['item']['title'];
$liveId = (int)$LIVEWI['item']['id'];

section('a full copy is the whole shape of the workspace');
[, $C] = api('campaigns', ['action' => 'create', 'name' => 'Suite full copy', 'description' => 'Created by campaigns_test.php', 'mode' => 'full']);
$fullId = (int)$C['workspace']['id'];
$created[] = $fullId;
check($C['workspace']['kind'] === 'campaign', 'it is a campaign, not another live workspace');
check($C['workspace']['seeded_from'] === 'full', 'and it records how it was made');
check($C['workspace']['source_name'] !== null, "with where it came from ({$C['workspace']['source_name']})");
check((int)$C['workspace']['people_count'] === $livePeople, "the same people came across ({$C['workspace']['people_count']})");
check((int)$C['workspace']['items_count'] === $liveItems, "and the same work items ({$C['workspace']['items_count']})");
check(!empty($C['token']), 'the creator gets a token for it straight away');
check($C['user']['role'] === 'admin', 'as an administrator of their own sandbox');

$campaignToken = $C['token'];
$wasToken = $token;
$token = $campaignToken;
[, $ME] = api('auth', ['action' => 'me']);
check((int)$ME['user']['workspace']['id'] === $fullId, 'the token really is for the campaign');
check($ME['user']['workspace']['kind'] === 'campaign', 'and `me` says which universe this is, so the client can say so too');

section('the copy is complete enough to plan with');
[, $CP] = api('people', ['action' => 'list']);
check(count($CP['people']) === $livePeople, 'people');
check(count($CP['teams']) >= 5, 'teams, with the tree intact (' . count($CP['teams']) . ')');
$withTeam = array_filter($CP['people'], fn($p) => $p['team_id'] !== null);
check(count($withTeam) === $livePeople, 'everybody still sits in a team, so the ids were remapped rather than dropped');
$leads = array_filter($CP['teams'], fn($t) => $t['lead_person_id'] !== null);
check(count($leads) >= 3, 'team leads survived the circular reference (' . count($leads) . ' teams have one)');

[, $CS] = api('skills', ['action' => 'matrix']);
check(count($CS['skills']) > 0 && count($CS['cells']) > 0, 'skills and the proficiency matrix came across');
[, $CPLAN] = api('plan', ['action' => 'schedule']);
check(count($CPLAN['assignments']) > 0, 'the committed plan came across (' . count($CPLAN['assignments']) . ' assignments)');
check($CPLAN['plan_version']['status'] === 'committed', 'as a committed version');
[, $CV] = api('plan', ['action' => 'versions']);
check(count($CV['versions']) === 1, "only the plan being worked to, not the source's history (" . count($CV['versions']) . ')');

section('what a sandbox must NOT inherit');
[, $CC] = api('changes', ['action' => 'list']);
check(count($CC['proposals'] ?? []) === 0, 'no proposals: the copy starts from the plan, not from somebody else\'s open decisions');
[, $CN] = api('notifications', ['action' => 'list']);
check(count($CN['notifications']) === 0, 'no notifications');
[, $CW] = api('webhooks', ['action' => 'list']);
check(count($CW['subscriptions'] ?? []) === 0, 'no webhook subscriptions: they carry signing secrets, and a sandbox that could post to a real endpoint is not a sandbox');

section('changing the campaign does not touch Live');
[, $CWI] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
$campaignItemId = (int)$CWI['item']['id'];
check($campaignItemId !== $liveId, "the same ref is a different row ($campaignItemId vs $liveId)");
api('work_items', ['action' => 'update', 'id' => $campaignItemId, 'title' => 'Renamed inside the sandbox']);
[, $CWI2] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check($CWI2['item']['title'] === 'Renamed inside the sandbox', 'the campaign sees its own change');

$token = $wasToken;
[, $LWI2] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check($LWI2['item']['title'] === $liveTitle, "Live is untouched: still '{$liveTitle}'");
api('work_items', ['action' => 'get', 'id' => $campaignItemId], 404);
check(true, 'and a live token cannot reach the campaign row at all');
$token = $campaignToken;
api('work_items', ['action' => 'get', 'id' => $liveId], 404);
check(true, 'nor a campaign token the live one');
$token = $wasToken;

section('one identity, one account per workspace');
[, $LU] = api('auth', ['action' => 'list_users']);
$liveEmails = array_map(fn($u) => strtolower($u['email']), $LU['users']);
$token = $campaignToken;
[, $CU] = api('auth', ['action' => 'list_users']);
$campaignEmails = array_map(fn($u) => strtolower($u['email']), $CU['users']);
check(count(array_intersect($liveEmails, $campaignEmails)) > 1, 'the same people exist in both, as separate accounts');
$mine = array_values(array_filter($CU['users'], fn($u) => strtolower($u['email']) === strtolower($ME['user']['email'])));
check($mine && $mine[0]['role'] === 'admin', 'and a role is per workspace: the creator is an admin here, a delivery lead in Live');
$token = $wasToken;

section('switching, and who may');
[, $SW] = api('campaigns', ['action' => 'switch', 'workspace_id' => $fullId]);
check(!empty($SW['token']), 'switch re-issues a token rather than widening the one you hold');
check((int)$SW['workspace']['id'] === $fullId, 'for the workspace asked for');
[, $BACK] = api('campaigns', ['action' => 'switch', 'workspace_id' => (int)$L0['current']['id']]);
check(!empty($BACK['token']) || !empty($BACK['already_here']), 'and back to Live again');

$memberToken = token_for('team_member', true);
if ($memberToken) {
    $token = $memberToken;
    [, $MS] = api('campaigns', ['action' => 'switch', 'workspace_id' => $fullId]);
    check(!empty($MS['token']), 'a team member can join an open campaign');
    check($MS['user']['role'] === 'team_member', 'at the role they hold in Live, not as an administrator');
    api('campaigns', ['action' => 'create', 'name' => 'Not allowed', 'mode' => 'config'], 403);
    check(true, 'but cannot create one');
    $token = $wasToken;
}

section('config-only and demo campaigns');
[, $CFG] = api('campaigns', ['action' => 'create', 'name' => 'Suite config only', 'mode' => 'config']);
$cfgId = (int)$CFG['workspace']['id'];
$created[] = $cfgId;
check((int)$CFG['workspace']['items_count'] === 0, 'a config copy has no work items');
check((int)$CFG['workspace']['people_count'] === $livePeople, 'but all the people, so it is ready to plan into');

[, $DEMO] = api('campaigns', ['action' => 'create', 'name' => 'Suite demo', 'mode' => 'demo']);
$demoId = (int)$DEMO['workspace']['id'];
$created[] = $demoId;
check($DEMO['workspace']['seeded_from'] === 'demo', 'a demo campaign is built from the seed, not copied');
check((int)$DEMO['workspace']['items_count'] > 0, 'and has the demo pipeline (' . $DEMO['workspace']['items_count'] . ' items)');
$token = $DEMO['token'];
[, $DWI] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check(($DWI['item']['title'] ?? '') === $liveTitle, 'including the work item the documentation is written around');
$token = $wasToken;

section('reset puts it back');
[, $RS] = api('campaigns', ['action' => 'reset', 'workspace_id' => $fullId]);
check((int)$RS['workspace']['id'] === $fullId, 'reset keeps the same id, so tokens and links stay good');
// The accounts inside were rebuilt with it, so the token issued before the reset is spent: the
// reply carries a fresh one, and anything still holding the old one has to sign in again.
check(!empty($RS['token']), 'and hands back a token for the rebuilt workspace');
$campaignToken = $RS['token'] ?: $campaignToken;
$token = $campaignToken;
[, $RWI] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check($RWI['item']['title'] === $liveTitle, 'and the sandbox change is gone');
$token = $wasToken;

section('deleting, and what cannot be deleted');
api('campaigns', ['action' => 'delete', 'workspace_id' => (int)$L0['current']['id']], 409);
check(true, 'the live workspace cannot be deleted');
api('campaigns', ['action' => 'reset', 'workspace_id' => (int)$L0['current']['id']], 409);
check(true, 'nor reset');

[, $DEL] = api('campaigns', ['action' => 'delete', 'workspace_id' => $cfgId]);
check($DEL['deleted'] === true, 'a campaign can be deleted');
$created = array_values(array_diff($created, [$cfgId]));
[, $L2] = api('campaigns', ['action' => 'list']);
$stillThere = array_filter($L2['workspaces'], fn($w) => (int)$w['id'] === $cfgId);
check(!$stillThere, 'and is gone from the list');

section('the weekly digest never goes out about a sandbox');
// Asking for the digest in both places, so the check is not vacuous: whoever turns it on in Live
// gets one and the same person turns it on in the campaign and does not.
$token = $wasToken;
api('notifications', ['action' => 'save_prefs', 'kind' => 'change_committed', 'email_digest' => true, 'digest' => 'weekly']);
[, $LIVEME] = api('auth', ['action' => 'me']);
$liveUserId = (int)$LIVEME['user']['id'];
$token = $campaignToken;
api('notifications', ['action' => 'save_prefs', 'kind' => 'change_committed', 'email_digest' => true, 'digest' => 'weekly']);
[, $CAMPME] = api('auth', ['action' => 'me']);
$campaignUserId = (int)$CAMPME['user']['id'];
check($campaignUserId !== $liveUserId, 'the same person is a different account in each workspace');

$token = token_for('admin');
[, $DG] = api('digest', ['action' => 'send']);
$sentTo = array_map(fn($r) => (int)$r['user_id'], $DG['results'] ?? []);
check(in_array($liveUserId, $sentTo, true), 'the live account, which asked for a digest, is a recipient');
check(!in_array($campaignUserId, $sentTo, true), 'the campaign account, which asked for one too, is not');

// Skipped by the scheduled run, not broken: somebody inside the campaign can still send one,
// because `send` works on the workspace the caller's own token names.
$token = $campaignToken;
[, $DG2] = api('digest', ['action' => 'send']);
$named = array_map(fn($r) => (int)$r['user_id'], $DG2['results'] ?? []);
check(in_array($campaignUserId, $named, true), 'though an administrator inside the campaign can still send one there');
check((int)$DG2['recipients'] >= 1, 'so the digest itself stays testable inside a sandbox');

$token = $wasToken;
api('notifications', ['action' => 'save_prefs', 'kind' => 'change_committed', 'email_digest' => false, 'digest' => 'daily']);

section('Live is exactly as it was');
$token = $wasToken;
[, $LFINAL] = api('campaigns', ['action' => 'list']);
check((int)$LFINAL['current']['people_count'] === $livePeople, 'same people');
check((int)$LFINAL['current']['items_count'] === $liveItems, 'same work items');
[, $LWI3] = api('work_items', ['action' => 'get', 'ref' => 'WI-1042']);
check($LWI3['item']['title'] === $liveTitle, 'same WI-1042');

echo "\n" . str_repeat('-', 60) . "\n";
echo "campaigns: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);
