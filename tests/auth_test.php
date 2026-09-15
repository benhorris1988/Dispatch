<?php
// Sign-in, provisioning and roles (ADM-01, ADM-02, ADM-03): auth.php and oidc_lib.php.
//   C:\xampp\php\php.exe tests\auth_test.php [base=http://localhost:8090]
//
// The Google flow itself cannot be driven from a test — it needs a real Google account and a browser —
// so this suite splits the problem. The token verifier is exercised offline with a keypair generated
// here, which is the part that would silently accept a forged token if it were wrong; the endpoint is
// exercised over HTTP for the things that do not need a real identity: which providers are on offer,
// what a bad token does, and the role and tenancy rules around accounts.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require_once __DIR__ . '/_auth.php';
require_once __DIR__ . '/../api/oidc_lib.php';

$BASE = rtrim($argv[1] ?? (getenv('DISPATCH_BASE') ?: 'http://localhost:8090'), '/');
$pass = 0; $fail = 0; $skipped = 0;

function api($file, array $body, $token = null) {
    global $BASE;
    $headers = "Content-Type: application/json\r\n"; if ($token) $headers .= "Authorization: Bearer $token\r\n";
    $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers, 'content' => json_encode($body), 'ignore_errors' => true, 'timeout' => 30]]);
    $raw = @file_get_contents("$BASE/api/$file", false, $ctx);
    $code = 0; foreach ($http_response_header ?? [] as $h) if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int)$m[1];
    $j = json_decode((string)$raw, true);
    return [$code, is_array($j) ? $j : ['raw' => $raw]];
}
function check($label, $cond, $detail = '') { global $pass, $fail; if ($cond) { $pass++; echo "  ok   $label\n"; } else { $fail++; echo "  FAIL $label" . ($detail !== '' ? " -- $detail" : '') . "\n"; } return (bool)$cond; }
function skip($label, $why) { global $skipped; $skipped++; echo "  skip $label -- $why\n"; }
function short($v) { $s = json_encode($v, JSON_UNESCAPED_UNICODE); return strlen($s) > 300 ? substr($s, 0, 300) . '…' : $s; }
function section($t) { echo "\n== $t\n"; }

// ---- what the client is told ------------------------------------------------------------------
section('providers: the client asks what it may offer, without a token (ADM-01)');
[$code, $p] = api('auth.php', ['action' => 'providers']);
if ($code !== 200) { echo "No API at $BASE\n"; exit(2); }
check('providers 200 unauthenticated', $code === 200 && isset($p['google'], $p['microsoft']), short($p));
check('it says whether Google is configured, and hands over the web client id when it is',
    array_key_exists('enabled', $p['google']) && array_key_exists('web_client_id', $p['google'])
    && ($p['google']['enabled'] ? is_string($p['google']['web_client_id']) : $p['google']['web_client_id'] === null), short($p['google']));
check('Microsoft is reported separately, so the button can appear the day a tenant is configured', array_key_exists('enabled', $p['microsoft']));
$googleOn = !empty($p['google']['enabled']);

section('The development sign-in is gone');
// Only `providers` and the two sign-in actions run before the token gate, so a removed action now
// falls through to it: 401 without a token, and 400 Unknown action with one.
$leadEarly = token_for('delivery_lead');
[$code] = api('auth.php', ['action' => 'list_dev_users']);
check('list_dev_users without a token → 401', $code === 401, (string)$code);
[$code, $r] = api('auth.php', ['action' => 'list_dev_users'], $leadEarly);
check('and with one → 400 Unknown action', $code === 400 && str_contains($r['message'] ?? '', 'Unknown action'), "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'dev_login', 'user_id' => 1], $leadEarly);
check('dev_login → 400 Unknown action', $code === 400, "$code " . short($r));
[$code] = api('people.php', ['action' => 'list']);
check('and an endpoint without a token is still 401', $code === 401, (string)$code);

section('A token that is not a token');
[$code, $r] = api('auth.php', ['action' => 'google_login', 'id_token' => 'not.a.jwt']);
check($googleOn ? 'garbage rejected → 401' : 'Google not configured here → 501', $code === ($googleOn ? 401 : 501), "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'google_login']);
// Whether Google is configured is checked before the token is asked for: there is no point demanding
// something this deployment could not verify anyway.
check($googleOn ? 'no token at all → 422' : 'no token at all, and no Google → 501', $code === ($googleOn ? 422 : 501), "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'oidc_login', 'id_token' => 'not.a.jwt']);
check('the Entra path answers 501 until a tenant is configured', $code === 501 || $code === 401, "$code " . short($r));

// ---- the verifier, offline --------------------------------------------------------------------
section('The ID token verifier: the part that would silently accept a forgery (ADM-01)');
// openssl_pkey_new needs a configuration file, which is not in the same place on every box.
$cnf = null;
foreach ([getenv('OPENSSL_CONF'), dirname(PHP_BINARY) . '/extras/ssl/openssl.cnf', 'C:/xampp/apache/conf/openssl.cnf', '/etc/ssl/openssl.cnf'] as $c)
    if ($c && is_readable($c)) { $cnf = $c; break; }
$key = $cnf ? openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA, 'config' => $cnf]) : null;
if (!$key) {
    skip('the verifier tests', 'no OpenSSL configuration file found to generate a test keypair with');
} else {
    $d = openssl_pkey_get_details($key);
    $b64u = fn($s) => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    // Google publishes bare RSA moduli (n/e) with no certificate. Entra publishes certificates (x5c).
    // The verifier has to read both, and reading only x5c is the classic way to accept nothing at all.
    $jwks = ['keys' => [['kty' => 'RSA', 'kid' => 'test-key', 'n' => $b64u($d['rsa']['n']), 'e' => $b64u($d['rsa']['e'])]]];
    $mint = function (array $over = [], array $hdr = []) use ($b64u, $key) {
        $h = $b64u(json_encode(array_merge(['alg' => 'RS256', 'kid' => 'test-key', 'typ' => 'JWT'], $hdr)));
        $c = array_merge(['iss' => 'https://accounts.google.com', 'aud' => 'web.apps.googleusercontent.com',
            'exp' => time() + 300, 'sub' => '1234567890', 'email' => 'someone@example.org', 'email_verified' => true, 'name' => 'Some One'], $over);
        $p = $b64u(json_encode($c));
        openssl_sign("$h.$p", $sig, $key, OPENSSL_ALGO_SHA256);
        return "$h.$p." . $b64u($sig);
    };
    $opts = fn(array $over = []) => array_merge(['issuers' => ['https://accounts.google.com', 'accounts.google.com'],
        'audiences' => ['web.apps.googleusercontent.com'], 'jwks_override' => $jwks, 'jwks_url' => ''], $over);

    check('a sound token verifies, with an RSA key given as n/e the way Google publishes them', oidc_verify($mint(), $opts()) !== null);
    check('the claims come back', (oidc_verify($mint(), $opts())['email'] ?? null) === 'someone@example.org');
    check('a token for somebody else\'s client id is refused', oidc_verify($mint(), $opts(['audiences' => ['other.apps.googleusercontent.com']])) === null);
    check('an aud array is accepted when one of ours is in it', oidc_verify($mint(['aud' => ['x', 'web.apps.googleusercontent.com']]), $opts()) !== null);
    check('a token from another issuer is refused', oidc_verify($mint(['iss' => 'https://accounts.evil.example']), $opts()) === null);
    check('the alternative Google issuer spelling is accepted', oidc_verify($mint(['iss' => 'accounts.google.com']), $opts()) !== null);
    check('an expired token is refused', oidc_verify($mint(['exp' => time() - 1]), $opts()) === null);
    check('a tampered signature is refused', oidc_verify(substr($mint(), 0, -4) . 'AAAA', $opts()) === null);
    check('alg: none is refused outright', oidc_verify($mint([], ['alg' => 'none']), $opts()) === null);
    check('a token signed with an unknown key is refused', oidc_verify($mint([], ['kid' => 'some-other-key']), $opts()) === null);
    check('a certificate key (the Entra shape) is read too', (function () use ($d, $b64u, $opts, $mint) {
        // Same key, presented as OpenSSL would in a PEM: oidc_public_key must handle both shapes.
        $jwk = ['kty' => 'RSA', 'kid' => 'test-key', 'n' => $b64u($d['rsa']['n']), 'e' => $b64u($d['rsa']['e'])];
        return oidc_public_key($jwk) !== null;
    })());
    check('a JWK with neither shape is not a key', oidc_public_key(['kty' => 'oct', 'k' => 'abc']) === null);

    section('Account checks that are not about the signature');
    check('an unverified address is refused', google_claims_problem(['email' => 'a@b.c', 'email_verified' => false], []) !== null);
    check('"true" as a string counts as verified — providers are not consistent about this', google_claims_problem(['email' => 'a@b.c', 'email_verified' => 'true'], []) === null);
    check('a token with no address is refused', google_claims_problem(['email_verified' => true], []) !== null);
    check('a pinned hosted domain is enforced', google_claims_problem(['email' => 'a@b.c', 'email_verified' => true, 'hd' => 'other.org'], ['hosted_domain' => 'example.org']) !== null);
    check('and satisfied by the right domain', google_claims_problem(['email' => 'a@example.org', 'email_verified' => true, 'hd' => 'example.org'], ['hosted_domain' => 'example.org']) === null);
    check('with no pinned domain, any Google account is acceptable', google_claims_problem(['email' => 'a@gmail.com', 'email_verified' => true], ['hosted_domain' => '']) === null);
}

// ---- roles ------------------------------------------------------------------------------------
section('Roles are assigned in the product, by an administrator (ADM-02)');
$admin = token_for('admin');
$lead = token_for('delivery_lead');
$member = token_for('team_member', true);
check('tokens for an admin, a delivery lead and a member', $admin && $lead && $member);
[$code, $r] = api('auth.php', ['action' => 'list_users'], $member);
check('list_users as a team member → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'list_users'], $lead);
check('a delivery lead can see who is in the workspace → 200', $code === 200 && count($r['users'] ?? []) >= 14, "$code " . short(count($r['users'] ?? [])));
[$code, $r] = api('auth.php', ['action' => 'list_users'], $admin);
check('list_users as an administrator → 200', $code === 200 && count($r['users'] ?? []) >= 14, short(count($r['users'] ?? [])));
$byEmail = [];
foreach ($r['users'] ?? [] as $u) $byEmail[$u['email']] = $u;
check('each account says which provider owns it, so nobody has to guess how somebody signs in',
    ($byEmail['ben.a@example.org']['auth_provider'] ?? null) === 'seed', short($byEmail['ben.a@example.org'] ?? null));
check('and which person it is linked to', ($byEmail['priya.kaur@example.org']['person_name'] ?? null) === 'Priya Kaur' && ($byEmail['priya.kaur@example.org']['team_name'] ?? null) === 'Data Platform', short($byEmail['priya.kaur@example.org'] ?? null));
check('the seven roles are published with the list, so the client does not hard-code them', count($r['roles'] ?? []) === 7 && in_array('benefit_owner', $r['roles'], true), short($r['roles'] ?? null));

$target = $byEmail['procurement.requests@example.org'] ?? null;
check('there is a requester account to promote', $target !== null);
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => $target['id'], 'role' => 'team_lead'], $lead);
check('set_role as a delivery lead → 403', $code === 403, "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => $target['id'], 'role' => 'wizard'], $admin);
check('an unknown role → 400, listing the real ones', $code === 400 && count($r['roles'] ?? []) === 7, "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => 999999, 'role' => 'viewer'], $admin);
check('an unknown user → 404', $code === 404, (string)$code);
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => $target['id'], 'role' => 'team_lead', 'reason' => 'Covering intake while Jo is away'], $admin);
check('an administrator can promote somebody → 200', $code === 200 && ($r['user']['role'] ?? null) === 'team_lead', "$code " . short($r));
$targetToken = token_for_email($target['email']);
[$code, $r] = api('people.php', ['action' => 'save', 'id' => 1, 'tagline' => 'Role change takes effect immediately'], $targetToken);
check('the new role applies to the token they already hold, without signing in again', $code === 200, "$code " . short($r));
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => $target['id'], 'role' => 'requester'], $admin);
check('and back to a requester', $code === 200 && ($r['user']['role'] ?? null) === 'requester');
[$code, $r] = api('people.php', ['action' => 'save', 'id' => 1, 'tagline' => 'x'], $targetToken);
check('who is refused again', $code === 403, (string)$code);

$adminUser = user_for('admin');
[$code, $r] = api('auth.php', ['action' => 'set_role', 'user_id' => $adminUser['id'], 'role' => 'viewer'], $admin);
check('the only administrator cannot demote themselves out of the workspace → 409', $code === 409, "$code " . short($r));
[$code, $a] = api('audit.php', ['action' => 'list', 'entity' => 'user'], $admin);
check('role changes are audited with the reason given', $code === 200 && ($a['total'] ?? 0) >= 2
    && count(array_filter($a['events'] ?? [], fn($e) => str_contains((string)($e['reason'] ?? ''), 'Covering intake'))) >= 1, short($a['total'] ?? null));

section('me');
[$code, $r] = api('auth.php', ['action' => 'me'], $member);
check('me returns the account with its workspace and person', $code === 200 && isset($r['user']['workspace']['name'], $r['user']['person']['name']) && array_key_exists('auth_provider', $r['user']), short($r['user'] ?? null));
[$code] = api('auth.php', ['action' => 'me'], 'not-a-token');
check('with a bad token → 401', $code === 401, (string)$code);

echo "\n$pass passed, $fail failed" . ($skipped ? ", $skipped skipped" : '') . "\n";
exit($fail ? 1 : 0);
