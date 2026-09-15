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
  Workspace({
    required this.id,
    required this.name,
    this.timeZone,
    this.workingDays,
    this.hoursPerDay,
    this.currency,
    this.kind = 'live',
    this.description,
    this.seededFrom,
    this.sourceWorkspaceId,
  });

  final int id;
  final String name;
  final String? timeZone;
  final String? workingDays;
  final double? hoursPerDay;
  final String? currency;

  /// live | campaign. A campaign is a sandbox: a real workspace of its own, isolated from the
  /// plan people are working to. The shell says so on every screen, because nobody should have
  /// to remember which universe they are in.
  final String kind;
  final String? description;

  /// full | config | demo — how the campaign was built.
  final String? seededFrom;
  final int? sourceWorkspaceId;

  bool get isCampaign => kind == 'campaign';

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Workspace'),
        timeZone: asStr(j['time_zone']),
        workingDays: asStr(j['working_days']),
        hoursPerDay: asDouble(j['hours_per_day']),
        currency: asStr(j['currency']),
        kind: asStrOr(j['kind'], 'live'),
        description: asStr(j['description']),
        seededFrom: asStr(j['seeded_from']),
        sourceWorkspaceId: asInt(j['source_workspace_id']),
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

/// Signed-in user, as returned by auth.php `me` / `google_login`.
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
    this.authProvider,
  });

  final int id;
  final String email;
  final String displayName;
  final String? shortName;
  final String role;
  final int? personId;
  final UserPerson? person;
  final Workspace? workspace;

  /// Which identity provider this account signs in with: 'google', 'entra',
  /// 'seed' for demo data, 'test' for a minted token.
  final String? authProvider;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: asIntOr(j['id'], 0),
        email: asStrOr(j['email'], ''),
        displayName: asStrOr(j['display_name'], ''),
        shortName: asStr(j['short_name']),
        role: asStrOr(j['role'], 'viewer'),
        personId: asInt(j['person_id']),
        person: j['person'] is Map ? UserPerson.fromJson(asMap(j['person'])) : null,
        workspace: j['workspace'] is Map ? Workspace.fromJson(asMap(j['workspace'])) : null,
        authProvider: asStr(j['auth_provider']),
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

/// Which identity providers this deployment offers, from auth.php `providers`.
/// Asked for before sign-in and without a token, so the screen draws the buttons
/// that actually work rather than a disabled one that never will.
class AuthProviders {
  const AuthProviders({this.googleEnabled = false, this.googleWebClientId, this.googleHostedDomain, this.microsoftEnabled = false});

  final bool googleEnabled;

  /// The web OAuth client id. The browser starts the flow with it; the Android
  /// and iOS apps send it as their *server* client id so the token they get back
  /// is addressed to the audience the API checks.
  final String? googleWebClientId;

  /// Set when the workspace accepts only one Google Workspace domain.
  final String? googleHostedDomain;

  final bool microsoftEnabled;

  bool get any => googleEnabled || microsoftEnabled;

  /// Google is on but no client id came back: the server would answer 501, so
  /// there is nothing useful to draw.
  bool get googleUsable => googleEnabled && (googleWebClientId?.isNotEmpty ?? false);

  factory AuthProviders.fromJson(Map<String, dynamic> j) {
    final g = asMap(j['google']);
    final m = asMap(j['microsoft']);
    return AuthProviders(
      googleEnabled: asBool(g['enabled']),
      googleWebClientId: asStr(g['web_client_id']),
      googleHostedDomain: asStr(g['hosted_domain']),
      microsoftEnabled: asBool(m['enabled']),
    );
  }
}

/// One account in the workspace, from auth.php `list_users` (admin). Settings
/// shows these to assign roles (ADM-02).
class DirectoryUser {
  const DirectoryUser({
    required this.id,
    required this.displayName,
    this.shortName,
    this.email,
    required this.role,
    this.personId,
    this.personName,
    this.roleTitle,
    this.teamName,
    this.initials,
    this.colour,
    this.authProvider,
    this.active = true,
  });

  final int id;
  final String displayName;
  final String? shortName;
  final String? email;
  final String role;
  final int? personId;
  final String? personName;
  final String? roleTitle;
  final String? teamName;
  final String? initials;
  final String? colour;
  final String? authProvider;
  final bool active;

  factory DirectoryUser.fromJson(Map<String, dynamic> j) => DirectoryUser(
        id: asIntOr(j['id'], 0),
        displayName: asStrOr(j['display_name'], ''),
        shortName: asStr(j['short_name']),
        email: asStr(j['email']),
        role: asStrOr(j['role'], 'viewer'),
        personId: asInt(j['person_id']),
        personName: asStr(j['person_name']),
        roleTitle: asStr(j['role_title']),
        teamName: asStr(j['team_name']),
        initials: asStr(j['initials']),
        colour: asStr(j['colour']),
        authProvider: asStr(j['auth_provider']),
        active: asBool(j['active'], fallback: true),
      );

  String get initialsOrDerived => initials ?? User._initials(displayName);

  /// 'Google', 'Microsoft', 'Demo data', 'Test token'.
  String get providerLabel => switch (authProvider) {
        'google' => 'Google',
        'entra' => 'Microsoft',
        'seed' => 'Demo data',
        'test' => 'Test token',
        _ => 'Not signed in yet',
      };
}
