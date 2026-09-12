import 'json.dart';

/// Role rank order — mirrors DP_ROLE_RANK in api/lib.php.
const List<String> kRoleOrder = ['viewer', 'requester', 'team_member', 'benefit_owner', 'team_lead', 'delivery_lead', 'admin'];

int roleRank(String? role) {
  final i = kRoleOrder.indexOf(role ?? 'viewer');
  return i < 0 ? 0 : i;
}

/// 'delivery_lead' → 'Delivery lead'
String roleLabel(String? role) {
  if (role == null || role.isEmpty) return 'Viewer';
  final t = role.replaceAll('_', ' ');
  return t[0].toUpperCase() + t.substring(1);
}

/// Workspace summary attached to the signed-in user.
class Workspace {
  Workspace({required this.id, required this.name, this.timeZone, this.workingDays, this.hoursPerDay, this.currency});

  final int id;
  final String name;
  final String? timeZone;
  final String? workingDays;
  final double? hoursPerDay;
  final String? currency;

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Workspace'),
        timeZone: asStr(j['time_zone']),
        workingDays: asStr(j['working_days']),
        hoursPerDay: asDouble(j['hours_per_day']),
        currency: asStr(j['currency']),
      );

  String get currencySymbol => switch (currency) { 'USD' => r'$', 'EUR' => '€', _ => '£' };
}

/// The person record linked to a user (may be null for pure requesters/viewers).
class UserPerson {
  UserPerson({required this.id, required this.name, this.initials, this.colour, this.roleTitle, this.teamId});
  final int id;
  final String name;
  final String? initials;
  final String? colour;
  final String? roleTitle;
  final int? teamId;

  factory UserPerson.fromJson(Map<String, dynamic> j) => UserPerson(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        initials: asStr(j['initials']),
        colour: asStr(j['colour']),
        roleTitle: asStr(j['role_title']),
        teamId: asInt(j['team_id']),
      );
}

/// Signed-in user, as returned by auth.php `me` / `dev_login`.
class User {
  User({
    required this.id,
    required this.email,
    required this.displayName,
    this.shortName,
    required this.role,
    this.personId,
    this.person,
    this.workspace,
  });

  final int id;
  final String email;
  final String displayName;
  final String? shortName;
  final String role;
  final int? personId;
  final UserPerson? person;
  final Workspace? workspace;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: asIntOr(j['id'], 0),
        email: asStrOr(j['email'], ''),
        displayName: asStrOr(j['display_name'], ''),
        shortName: asStr(j['short_name']),
        role: asStrOr(j['role'], 'viewer'),
        personId: asInt(j['person_id']),
        person: j['person'] is Map ? UserPerson.fromJson(asMap(j['person'])) : null,
        workspace: j['workspace'] is Map ? Workspace.fromJson(asMap(j['workspace'])) : null,
      );

  String get initials => person?.initials ?? _initials(displayName);
  String? get colour => person?.colour;
  String get roleTitle => person?.roleTitle ?? roleLabel(role);
  String get firstName => shortName ?? displayName.split(' ').first;

  /// True when this user's role is at least [minRole] in the rank order.
  bool can(String minRole) => roleRank(role) >= roleRank(minRole);

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

/// Entry from auth.php `list_dev_users`.
class DevUser {
  DevUser({
    required this.id,
    required this.displayName,
    this.shortName,
    this.email,
    required this.role,
    this.personId,
    this.roleTitle,
    this.initials,
    this.colour,
    this.workspace,
  });

  final int id;
  final String displayName;
  final String? shortName;
  final String? email;
  final String role;
  final int? personId;
  final String? roleTitle;
  final String? initials;
  final String? colour;
  final String? workspace;

  factory DevUser.fromJson(Map<String, dynamic> j) => DevUser(
        id: asIntOr(j['id'], 0),
        displayName: asStrOr(j['display_name'], ''),
        shortName: asStr(j['short_name']),
        email: asStr(j['email']),
        role: asStrOr(j['role'], 'viewer'),
        personId: asInt(j['person_id']),
        roleTitle: asStr(j['role_title']),
        initials: asStr(j['initials']),
        colour: asStr(j['colour']),
        workspace: asStr(j['workspace']),
      );

  String get initialsOrDerived => initials ?? User._initials(displayName);
}
