import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/json.dart';
import '../models/user.dart';

/// Thrown for any non-ok response: transport failure, non-JSON body, HTTP
/// error status or `{status:"error"}`. [code] is the HTTP status (0 for
/// transport failures).
class ApiException implements Exception {
  ApiException(this.message, [this.code = 0]);
  final String message;
  final int code;
  bool get isAuth => code == 401;
  bool get isNotImplemented => code == 501;
  @override
  String toString() => message;
}

/// Static HTTP client for the PHP API.
///
/// Every resource is one PHP file under [base]; calls are POSTs with a JSON
/// body `{action, ...}` and a Bearer token. Responses are JSON
/// `{status:"ok", ...}` or `{status:"error", message}`.
///
///   final r = await Api.post('work_items.php', 'list', {'status': 'ready'});
///   final items = (r['items'] as List).map(WorkItem.fromJson).toList();
///
/// On 401 the session is cleared via [onUnauthorised] (wired by [Session]) and
/// the router redirects to /sign-in.
class Api {
  Api._();

  /// API base, from `--dart-define=API_BASE=...`. Defaults to the local dev box.
  static String get base {
    const override = String.fromEnvironment('API_BASE');
    if (override.isNotEmpty) return override;
    return 'http://localhost:8090/api';
  }

  static const Duration timeout = Duration(seconds: 20);
  static const String _tokenKey = 'dispatch.token';

  static String? _token;
  static String? get token => _token;

  /// Called on a 401 so the session can clear itself. Set by [Session].
  static void Function()? onUnauthorised;

  static final http.Client _client = http.Client();

  static Future<void> setToken(String? t) async {
    _token = t;
    final prefs = await SharedPreferences.getInstance();
    if (t == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, t);
    }
  }

  static Future<String?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    return _token;
  }

  static Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  /// POST `{action, ...body}` to [endpoint] (e.g. 'work_items.php').
  static Future<Map<String, dynamic>> post(String endpoint, String action, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$base/$endpoint');
    final payload = <String, dynamic>{'action': action, ...?body};
    http.Response res;
    try {
      res = await _client.post(uri, headers: _headers(), body: jsonEncode(payload)).timeout(timeout);
    } on TimeoutException {
      throw ApiException('The server took too long to respond. Please try again.');
    } catch (e) {
      throw ApiException('Could not reach the Dispatch server.');
    }
    return _handle(res, '$endpoint#$action');
  }

  /// GET [endpoint] with [query] params (action goes in the query string).
  static Future<Map<String, dynamic>> get(String endpoint, [Map<String, String>? query]) async {
    final uri = Uri.parse('$base/$endpoint').replace(queryParameters: query);
    http.Response res;
    try {
      res = await _client.get(uri, headers: _headers(json: false)).timeout(timeout);
    } on TimeoutException {
      throw ApiException('The server took too long to respond. Please try again.');
    } catch (e) {
      throw ApiException('Could not reach the Dispatch server.');
    }
    return _handle(res, endpoint);
  }

  static Map<String, dynamic> _handle(http.Response res, String label) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}

    if (res.statusCode == 401) {
      debugPrint('[api] 401 on $label — clearing session');
      onUnauthorised?.call();
      throw ApiException(json?['message']?.toString() ?? 'Your session has expired. Please sign in again.', 401);
    }
    if (json == null) {
      throw ApiException('Unexpected reply from the server (HTTP ${res.statusCode}).', res.statusCode);
    }
    if (json['status'] != 'ok' || res.statusCode >= 400) {
      throw ApiException(json['message']?.toString() ?? 'Something went wrong.', res.statusCode);
    }
    return json;
  }

  // ─── Auth convenience ──────────────────────────────────────────────────

  /// Which identity providers this deployment offers. Needs no token — it is
  /// the first thing the sign-in screen asks, and doubles as "is the API there".
  static Future<AuthProviders> providers() async {
    final r = await post('auth.php', 'providers');
    return AuthProviders.fromJson(r);
  }

  /// Exchange a verified Google ID token for a Dispatch token and user.
  /// Returns (token, user); the caller stores the token via [Session].
  static Future<(String, User)> googleLogin(String idToken) async {
    final r = await post('auth.php', 'google_login', {'id_token': idToken});
    return (r['token'] as String, User.fromJson(asMap(r['user'])));
  }

  static Future<User> me() async {
    final r = await post('auth.php', 'me');
    return User.fromJson(r['user'] as Map<String, dynamic>);
  }

  /// The workspace's accounts, for Settings (admin only).
  static Future<List<DirectoryUser>> listUsers() async {
    final r = await post('auth.php', 'list_users');
    return listOf(r['users'], DirectoryUser.fromJson);
  }

  static Future<User> setRole(int userId, String role, {String? reason}) async {
    final r = await post('auth.php', 'set_role', {'user_id': userId, 'role': role, 'reason': ?reason});
    return User.fromJson(asMap(r['user']));
  }
}

/// Map a JSON list (or null) through [fromJson], skipping non-map entries.
List<T> listOf<T>(dynamic raw, T Function(Map<String, dynamic>) fromJson) {
  if (raw is! List) return const [];
  return raw.whereType<Map<String, dynamic>>().map(fromJson).toList();
}
