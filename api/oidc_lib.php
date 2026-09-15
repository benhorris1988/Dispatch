<?php
// OpenID Connect ID-token verification, one provider-agnostic implementation (ADM-01).
//
// Everything a provider differs by is a parameter: which issuers it claims, where its keys live and
// which audiences (client ids) an ID token may be addressed to. Google and Entra ID then differ only
// in the array handed to oidc_verify().
//
// Two shapes of key have to be understood. Entra publishes X.509 certificates (x5c) and Google
// publishes bare RSA moduli (n/e), so oidc_public_key() builds a PEM from either. Getting this wrong
// is the classic way a "working" verifier silently accepts nothing.
//
// This verifies an ID token that a client has already obtained. It is not an authorisation-code
// flow: there is no client secret here, nothing to keep, and nonce/PKCE belong to the SDK on the
// device that fetched the token.
require_once __DIR__ . '/lib.php';

/**
 * @param string $jwt
 * @param array $opts ['issuers' => string[], 'jwks_url' => string, 'audiences' => string[],
 *                     'jwks_override' => array|null (tests: a JWKS document, no network)]
 * @return array|null  the claims, or null if anything at all does not check out
 */
function oidc_verify($jwt, array $opts) {
    $parts = explode('.', (string)$jwt);
    if (count($parts) !== 3) return null;
    $hdr = oidc_b64json($parts[0]);
    $claims = oidc_b64json($parts[1]);
    if (!$hdr || !$claims) return null;
    if (($hdr['alg'] ?? '') !== 'RS256') return null;          // never trust the token's own 'none'
    if (($claims['exp'] ?? 0) < time()) return null;
    if (isset($claims['nbf']) && (int)$claims['nbf'] > time() + 60) return null;

    $issuers = array_map('strval', $opts['issuers'] ?? []);
    if (!$issuers || !in_array((string)($claims['iss'] ?? ''), $issuers, true)) return null;

    // aud is a string for most providers and an array for some; either way one of ours must be in it.
    $aud = $claims['aud'] ?? null;
    $audList = array_map('strval', is_array($aud) ? $aud : [$aud]);
    $want = array_values(array_filter(array_map('strval', $opts['audiences'] ?? [])));
    if (!$want || !array_intersect($audList, $want)) return null;

    $kid = (string)($hdr['kid'] ?? '');
    $signed = $parts[0] . '.' . $parts[1];
    $sig = oidc_b64d($parts[2]);
    foreach ([false, true] as $bypassCache) {
        $jwks = isset($opts['jwks_override']) ? $opts['jwks_override'] : oidc_jwks($opts['jwks_url'] ?? '', $bypassCache);
        foreach ($jwks['keys'] ?? [] as $k) {
            if ($kid !== '' && ($k['kid'] ?? '') !== $kid) continue;
            $pub = oidc_public_key($k);
            if (!$pub) continue;
            if (openssl_verify($signed, $sig, $pub, OPENSSL_ALGO_SHA256) === 1) return $claims;
        }
        // A kid we have never seen usually means the provider rotated its keys since we cached them,
        // so one uncached retry is worth a round trip. Anything else fails on the second pass too.
        if (isset($opts['jwks_override'])) break;
    }
    return null;
}

function oidc_b64d($s) { return base64_decode(strtr((string)$s, '-_', '+/')); }
function oidc_b64json($s) { $d = json_decode(oidc_b64d($s), true); return is_array($d) ? $d : null; }

/**
 * The provider's signing keys, cached in the system temp directory for an hour. A cache that cannot
 * be written is not an error worth failing a sign-in over: the fetch still happens, it is just not
 * remembered.
 */
function oidc_jwks($url, $bypassCache = false) {
    if (!$url) return [];
    $file = sys_get_temp_dir() . '/dispatch_jwks_' . md5($url) . '.json';
    if (!$bypassCache && is_readable($file) && time() - (int)@filemtime($file) < 3600) {
        $cached = json_decode((string)@file_get_contents($file), true);
        if (is_array($cached) && !empty($cached['keys'])) return $cached;
    }
    $raw = @file_get_contents($url, false, stream_context_create(['http' => ['timeout' => 8, 'ignore_errors' => true]]));
    $doc = json_decode((string)$raw, true);
    if (!is_array($doc) || empty($doc['keys'])) return [];
    @file_put_contents($file, json_encode($doc));
    return $doc;
}

/** A JWK as an OpenSSL public key: an X.509 certificate (x5c, Entra) or a bare RSA key (n/e, Google). */
function oidc_public_key(array $jwk) {
    if (!empty($jwk['x5c'][0])) {
        $pem = "-----BEGIN CERTIFICATE-----\n" . chunk_split($jwk['x5c'][0], 64, "\n") . "-----END CERTIFICATE-----\n";
        return openssl_pkey_get_public($pem) ?: null;
    }
    if (($jwk['kty'] ?? '') !== 'RSA' || empty($jwk['n']) || empty($jwk['e'])) return null;
    $pem = oidc_rsa_pem(oidc_b64d($jwk['n']), oidc_b64d($jwk['e']));
    return $pem ? (openssl_pkey_get_public($pem) ?: null) : null;
}

/**
 * A SubjectPublicKeyInfo PEM built from a raw RSA modulus and exponent. Hand-rolled DER, because
 * PHP has no JWK reader and pulling in a JOSE library for thirty lines of ASN.1 is a poor trade.
 */
function oidc_rsa_pem($modulus, $exponent) {
    if ($modulus === false || $exponent === false || $modulus === '' || $exponent === '') return null;
    $der = oidc_der_seq(oidc_der_int($modulus) . oidc_der_int($exponent));                 // RSAPublicKey
    $algo = oidc_der_seq("\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01" . "\x05\x00");      // rsaEncryption, NULL
    $spki = oidc_der_seq($algo . oidc_der_tlv("\x03", "\x00" . $der));                      // BIT STRING wrapper
    return "-----BEGIN PUBLIC KEY-----\n" . chunk_split(base64_encode($spki), 64, "\n") . "-----END PUBLIC KEY-----\n";
}
function oidc_der_len($n) {
    if ($n < 0x80) return chr($n);
    $b = ''; while ($n > 0) { $b = chr($n & 0xff) . $b; $n >>= 8; }
    return chr(0x80 | strlen($b)) . $b;
}
function oidc_der_tlv($tag, $body) { return $tag . oidc_der_len(strlen($body)) . $body; }
function oidc_der_seq($body) { return oidc_der_tlv("\x30", $body); }
function oidc_der_int($bytes) {
    $bytes = ltrim($bytes, "\x00");
    if ($bytes === '') $bytes = "\x00";
    if (ord($bytes[0]) > 0x7f) $bytes = "\x00" . $bytes;    // DER integers are signed; keep it positive
    return oidc_der_tlv("\x02", $bytes);
}

/** Verification options for Google ID tokens, from the 'google' block of config.php. */
function google_oidc_opts(array $g) {
    return ['issuers' => ['https://accounts.google.com', 'accounts.google.com'],
        'jwks_url' => 'https://www.googleapis.com/oauth2/v3/certs',
        'audiences' => array_values(array_filter((array)($g['client_ids'] ?? [])))];
}

/** Verification options for Entra ID tokens, from the 'entra' block of config.php. */
function entra_oidc_opts(array $e) {
    $tenant = (string)($e['tenant_id'] ?? '');
    return ['issuers' => ["https://login.microsoftonline.com/$tenant/v2.0", "https://sts.windows.net/$tenant/"],
        'jwks_url' => "https://login.microsoftonline.com/$tenant/discovery/v2.0/keys",
        'audiences' => [(string)($e['client_id'] ?? '')]];
}

/**
 * The checks that are about the account rather than the signature: Google must say the address was
 * verified, and a workspace that pins a hosted domain must see that domain. Returns null when the
 * claims are acceptable, or the message to fail with.
 */
function google_claims_problem(array $claims, array $g) {
    $verified = $claims['email_verified'] ?? false;
    if ($verified !== true && $verified !== 'true' && $verified !== 1 && $verified !== '1') return 'That Google account has no verified email address.';
    if (empty($claims['email'])) return 'That Google account did not share an email address.';
    $hd = trim((string)($g['hosted_domain'] ?? ''));
    if ($hd !== '' && strcasecmp((string)($claims['hd'] ?? ''), $hd) !== 0) return "Sign in with your $hd account.";
    return null;
}
