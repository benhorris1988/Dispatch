<?php
// JWT gate. Include AFTER db_connect.php. Exposes $userId, $userName, $wsId, $role, $personId, $userPayload.
require_once __DIR__ . '/jwt_lib.php';
$headers = function_exists('getallheaders') ? getallheaders() : [];
$authHeader = $headers['Authorization'] ?? $headers['authorization'] ?? ($_SERVER['HTTP_AUTHORIZATION'] ?? '');
if (empty($authHeader) && !empty($_GET['token'])) $authHeader = 'Bearer ' . $_GET['token'];
if (!preg_match('/Bearer\s+(\S+)/', $authHeader, $m)) fail('Unauthorized - token not provided', 401);
$userPayload = jwt_verify($m[1], jwt_secret());
if (!$userPayload) fail('Unauthorized - invalid or expired token', 401);
$userId = (int)$userPayload['user_id'];
$wsId = (int)$userPayload['workspace_id'];
$role = $userPayload['role'] ?? 'viewer';
$personId = $userPayload['person_id'] ?? null;
$userName = $userPayload['name'] ?? '';
// Re-check the account is still active (leavers are deactivated - ADM-03). Role changes apply without re-login.
$dpUserRow = row($conn, "SELECT active, role, person_id FROM dbo.users WHERE id = ? AND workspace_id = ?", [$userId, $wsId]);
if (!$dpUserRow || !(int)$dpUserRow['active']) fail('Unauthorized - account inactive', 401);
$role = $dpUserRow['role'];
$personId = $dpUserRow['person_id'] !== null ? (int)$dpUserRow['person_id'] : null;
