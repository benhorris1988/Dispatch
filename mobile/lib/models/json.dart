/// Null-tolerant JSON readers shared by every model. The PHP API returns
/// numbers as ints, decimals as doubles or strings, bits as 0/1 or bool, and
/// dates as 'YYYY-MM-DD' / ISO strings — these accept all of those.
library;

int? asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is bool) return v ? 1 : 0;
  return int.tryParse(v.toString()) ?? double.tryParse(v.toString())?.round();
}

int asIntOr(dynamic v, int fallback) => asInt(v) ?? fallback;

double? asDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  return double.tryParse(v.toString());
}

double asDoubleOr(dynamic v, double fallback) => asDouble(v) ?? fallback;

bool asBool(dynamic v, {bool fallback = false}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().toLowerCase();
  if (s == '1' || s == 'true' || s == 'yes') return true;
  if (s == '0' || s == 'false' || s == 'no' || s.isEmpty) return false;
  return fallback;
}

String? asStr(dynamic v) => v?.toString();
String asStrOr(dynamic v, String fallback) => v == null ? fallback : v.toString();

DateTime? asDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  // SQL Server DATETIME2 via PHP may arrive as 'YYYY-MM-DD HH:MM:SS.ffffff'.
  return DateTime.tryParse(s) ?? DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

/// Comma-separated ids ('3,5,7') or a JSON list → list of int.
List<int> asIntList(dynamic v) {
  if (v == null) return const [];
  if (v is List) return v.map(asInt).whereType<int>().toList();
  return v.toString().split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
}

/// Comma-separated strings or a JSON list → list of String.
List<String> asStrList(dynamic v) {
  if (v == null) return const [];
  if (v is List) return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  return v.toString().split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

Map<String, dynamic> asMap(dynamic v) => v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : const {});

List<T> asList<T>(dynamic v, T Function(Map<String, dynamic>) fromJson) {
  if (v is! List) return const [];
  return v.map((e) => e is Map ? fromJson(Map<String, dynamic>.from(e)) : null).whereType<T>().toList();
}
