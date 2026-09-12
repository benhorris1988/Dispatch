import 'package:intl/intl.dart';

/// Formatting helpers. British English, GBP by default.

/// 'Friday 18 September 2026'
String fmtDate(DateTime? d) => d == null ? '—' : DateFormat('EEEE d MMMM yyyy', 'en_GB').format(d);

/// 'Fri 18 Sep'
String fmtShortDate(DateTime? d) => d == null ? '—' : DateFormat('EEE d MMM', 'en_GB').format(d);

/// '18 Sep'
String fmtDayMonth(DateTime? d) => d == null ? '—' : DateFormat('d MMM', 'en_GB').format(d);

/// 'Mon 7 – Fri 11 Sep' (same month) / 'Mon 28 Sep – Fri 2 Oct'
String fmtDateRange(DateTime? a, DateTime? b) {
  if (a == null && b == null) return '—';
  if (a == null) return 'to ${fmtShortDate(b)}';
  if (b == null) return 'from ${fmtShortDate(a)}';
  if (a.month == b.month && a.year == b.year) {
    return '${DateFormat('EEE d', 'en_GB').format(a)} – ${fmtShortDate(b)}';
  }
  return '${fmtShortDate(a)} – ${fmtShortDate(b)}';
}

/// 'w/c 7 Sep' — week commencing (Monday of that week).
String fmtWeekCommencing(DateTime d) {
  final monday = d.subtract(Duration(days: d.weekday - DateTime.monday));
  return 'w/c ${fmtDayMonth(monday)}';
}

/// 'Today', 'Tomorrow', 'Yesterday', otherwise short date.
String fmtRelativeDay(DateTime? d, {DateTime? now}) {
  if (d == null) return '—';
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return fmtShortDate(d);
}

/// '02:00'
String fmtTime(DateTime? d) => d == null ? '—' : DateFormat('HH:mm').format(d);

/// '£210k', '£1.2m', '£850' — compact money.
String fmtMoneyK(num? v, {String symbol = '£'}) {
  if (v == null) return '—';
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1000000) {
    final m = a / 1000000;
    return '$sign$symbol${m >= 10 ? m.round().toString() : m.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}m';
  }
  if (a >= 1000) return '$sign$symbol${(a / 1000).round()}k';
  return '$sign$symbol${a.round()}';
}

/// '£210,000'
String fmtMoney(num? v, {String symbol = '£'}) => v == null ? '—' : '$symbol${NumberFormat('#,##0', 'en_GB').format(v)}';

/// '84%' (0 decimals by default). Pass a fraction with [fraction]=true.
String fmtPct(num? v, {int decimals = 0, bool fraction = false}) {
  if (v == null) return '—';
  final p = fraction ? v * 100 : v;
  return '${p.toStringAsFixed(decimals)}%';
}

/// '3.5 days', '1 day', '0.5 day'
String fmtDays(num? d, {String unit = 'day'}) {
  if (d == null) return '—';
  final s = d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  return '$s $unit${d == 1 ? '' : 's'}';
}

/// '+4 pts', '-2 pts'
String fmtDelta(num? v, {String unit = 'pts', int decimals = 0}) {
  if (v == null) return '—';
  final s = v.toStringAsFixed(decimals);
  return '${v > 0 ? '+' : ''}$s $unit';
}

/// Parse ISO dates from the API; tolerates null, empty and 'YYYY-MM-DD'.
DateTime? parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// 'WI-1042 · Project · 60% today' — join non-empty parts with a middle dot.
String dotJoin(Iterable<String?> parts) => parts.where((p) => p != null && p.isNotEmpty).join(' · ');

/// Initials from a name: 'Priya Kaur' → 'PK'.
String initialsOf(String? name) {
  if (name == null || name.trim().isEmpty) return '?';
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// 'in_progress' → 'In progress'
String humanise(String? s) {
  if (s == null || s.isEmpty) return '';
  final t = s.replaceAll('_', ' ').trim();
  return t[0].toUpperCase() + t.substring(1);
}
