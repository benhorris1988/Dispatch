import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A My week payload read back from the device cache, with the time it was
/// stored so the screen can say how fresh it is.
class CachedWeek {
  const CachedWeek(this.data, this.savedAt);
  final Map<String, dynamic> data;
  final DateTime? savedAt;
}

/// Offline cache for the My week payload (MOB-03).
///
/// The last successful `overview.php my_week` response is written to
/// `shared_preferences` keyed by person and week, so a network failure can
/// still render the week the person last saw. Nothing here is personal beyond
/// what the API already returned; [clear] is called on sign out.
class MyWeekCache {
  MyWeekCache._();

  static const String _prefix = 'dispatch.myWeek.';

  static String _key(int? personId, String weekStart) => '$_prefix${personId ?? 'me'}.$weekStart';

  /// Store [data] for [weekStart] ('YYYY-MM-DD'). Failures are swallowed: a
  /// cache that cannot be written must never break the screen.
  static Future<void> save(int? personId, String weekStart, Map<String, dynamic> data) async {
    if (weekStart.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(personId, weekStart),
        jsonEncode({'saved_at': DateTime.now().toIso8601String(), 'payload': data}),
      );
    } catch (e) {
      debugPrint('[my_week_cache] save failed: $e');
    }
  }

  /// The cached week for [weekStart], or null when nothing is stored.
  static Future<CachedWeek?> read(int? personId, String weekStart) async {
    if (weekStart.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(personId, weekStart));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      if (payload is! Map) return null;
      return CachedWeek(Map<String, dynamic>.from(payload), DateTime.tryParse(decoded['saved_at']?.toString() ?? ''));
    } catch (e) {
      debugPrint('[my_week_cache] read failed: $e');
      return null;
    }
  }

  /// The most recently saved week for [personId], whichever week that is —
  /// used when the very first load of a session fails offline.
  static Future<CachedWeek?> readAny(int? personId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mine = '$_prefix${personId ?? 'me'}.';
      CachedWeek? best;
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(mine)) continue;
        final week = await read(personId, key.substring(mine.length));
        if (week == null) continue;
        if (best == null || (week.savedAt?.isAfter(best.savedAt ?? DateTime(1970)) ?? false)) best = week;
      }
      return best;
    } catch (e) {
      debugPrint('[my_week_cache] readAny failed: $e');
      return null;
    }
  }

  /// Drop every cached week (sign out, or a deliberate refresh).
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('[my_week_cache] clear failed: $e');
    }
  }
}
