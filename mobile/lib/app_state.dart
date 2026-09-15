import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/models.dart';
import 'services/api.dart';
import 'services/google_auth.dart';
import 'theme/tokens.dart';

/// Signed-in state: token + user. Restored on launch from shared_preferences
/// and verified with `auth.php me`.
///
///   final s = context.watch&lt;Session&gt;();
///   if (s.can('team_lead')) { ... }
class Session extends ChangeNotifier {
  Session() {
    Api.onUnauthorised = () => signOut(silent: true);
  }

  User? _user;
  bool _restoring = true;
  bool _interactive = false;
  bool _signingOut = false;

  User? get user => _user;
  bool get signedIn => _user != null;

  /// True until [restore] has finished checking the stored token.
  bool get restoring => _restoring;

  /// True when the current session came from a sign-in the person just performed, false
  /// when it was restored from storage. The biometric lock (MOB-05) treats a fresh sign-in
  /// as proof of identity and a restored one as something still to be confirmed.
  bool get signedInInteractively => _interactive;

  /// Run, and awaited, before the token is cleared on an interactive sign-out — the push
  /// registrar uses this to unregister the device while it still can (MOB-04). Not run on a
  /// silent sign-out (a 401), when the token is already dead.
  final List<Future<void> Function()> beforeSignOut = [];

  String get role => _user?.role ?? 'viewer';

  /// True when the current user's role is at least [minRole] in the rank order
  /// viewer < requester < team_member < benefit_owner < team_lead < delivery_lead < admin.
  bool can(String minRole) => _user?.can(minRole) ?? false;

  bool get isAdmin => can('admin');
  bool get isDeliveryLead => can('delivery_lead');
  bool get isTeamLead => can('team_lead');

  Future<void> restore() async {
    try {
      final token = await Api.loadToken();
      if (token != null && token.isNotEmpty) {
        _user = await Api.me();
        _interactive = false;
      }
    } on ApiException catch (e) {
      debugPrint('[session] restore failed: $e');
      if (e.isAuth) await Api.setToken(null);
      _user = null;
    } catch (e) {
      debugPrint('[session] restore failed: $e');
      _user = null;
    }
    _restoring = false;
    notifyListeners();
  }

  /// Exchange a verified Google ID token for a session (ADM-01). The Google
  /// token is used once and never stored; what we keep is our own.
  Future<void> signInWithGoogle(String idToken) async {
    final (token, user) = await Api.googleLogin(idToken);
    await adopt(token, user);
  }

  /// Adopt an already-issued Dispatch token. The sign-in flows end here, and so
  /// does the smoke test, which is handed a token minted by tests/mint_token.php
  /// because it cannot perform a Google sign-in.
  Future<void> signInWithToken(String token) async {
    await Api.setToken(token);
    _user = await Api.me();
    _interactive = true;
    notifyListeners();
  }

  /// Store an already-issued token and the user it belongs to.
  Future<void> adopt(String token, User user) async {
    await Api.setToken(token);
    _user = user;
    _interactive = true;
    notifyListeners();
  }

  Future<void> refreshUser() async {
    if (!signedIn) return;
    try {
      _user = await Api.me();
      notifyListeners();
    } catch (e) {
      debugPrint('[session] refresh failed: $e');
    }
  }

  Future<void> signOut({bool silent = false}) async {
    // A hook's own request can 401 and call back in here; once is enough.
    if (_signingOut) return;
    _signingOut = true;
    try {
      final was = _user != null;
      final wasGoogle = _user?.authProvider == 'google';
      if (was && !silent) {
        for (final hook in List.of(beforeSignOut)) {
          try {
            await hook();
          } catch (e) {
            debugPrint('[session] sign-out hook failed: $e');
          }
        }
        // Sign out of Google too, so the next sign-in offers the account chooser
        // rather than silently returning the person who just left.
        if (wasGoogle) await GoogleAuth.instance.signOut();
      }
      _user = null;
      _interactive = false;
      await Api.setToken(null);
      if (was || !silent) notifyListeners();
    } finally {
      _signingOut = false;
    }
  }
}

/// Cached workspace configuration: work types, size classes, policy.
/// Loaded via `workspace_config.php get`; failure is logged and the config stays empty
/// so the shell still runs.
class WorkspaceConfig extends ChangeNotifier {
  List<WorkType> _workTypes = const [];
  List<SizeClass> _sizeClasses = const [];
  Policy _policy = Policy();
  Workspace? _workspace;
  bool _loaded = false;
  bool _loading = false;
  String? _error;

  List<WorkType> get workTypes => _workTypes;
  List<SizeClass> get sizeClasses => _sizeClasses;
  Policy get policy => _policy;
  Workspace? get workspace => _workspace;
  bool get loaded => _loaded;
  bool get loading => _loading;
  String? get error => _error;

  /// Active (non-retired) types in sort order.
  List<WorkType> get activeWorkTypes => _workTypes.where((t) => !t.retired).toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// Workspace-default size classes (no type override).
  List<SizeClass> get defaultSizeClasses => _sizeClasses.where((s) => s.workTypeId == null).toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  WorkType? workType(int? id) => id == null ? null : _workTypes.where((t) => t.id == id).firstOrNull;
  WorkType? workTypeNamed(String? name) => name == null ? null : _workTypes.where((t) => t.name.toLowerCase() == name.toLowerCase()).firstOrNull;
  SizeClass? sizeClass(int? id) => id == null ? null : _sizeClasses.where((s) => s.id == id).firstOrNull;

  /// Colour for a work type by id, falling back to name, then a default.
  Color typeColour({int? id, String? name, String? hex}) {
    if (hex != null && hex.isNotEmpty) return DispatchColors.parseHex(hex);
    return workType(id)?.colour ?? workTypeNamed(name)?.colour ?? DispatchColors.typeBlue;
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await Api.post('workspace_config.php', 'get');
      _workTypes = asList(r['work_types'], WorkType.fromJson);
      _sizeClasses = asList(r['size_classes'], SizeClass.fromJson);
      _policy = r['policy'] is Map ? Policy.fromJson(asMap(r['policy'])) : Policy();
      _workspace = r['workspace'] is Map ? Workspace.fromJson(asMap(r['workspace'])) : null;
      _loaded = true;
    } catch (e) {
      debugPrint('[config] load failed (shell continues with empty config): $e');
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void clear() {
    _workTypes = const [];
    _sizeClasses = const [];
    _policy = Policy();
    _workspace = null;
    _loaded = false;
    notifyListeners();
  }
}

/// Page-level state the shell chrome displays: plan-status pill text, pending
/// change count (Changes badge), unread notifications, and the page title.
/// Screens set these; the shell renders them.
///
///   context.read&lt;ShellState&gt;().setPlanStatus('Plan committed to Fri 18 Sep', committed: true);
class ShellState extends ChangeNotifier {
  String _planStatusText = 'No committed plan';
  bool _planCommitted = false;
  int _pendingChanges = 0;
  int _unreadNotifications = 0;
  String? _pageTitle;
  List<String> _breadcrumb = const [];

  String get planStatusText => _planStatusText;
  bool get planCommitted => _planCommitted;
  int get pendingChanges => _pendingChanges;
  int get unreadNotifications => _unreadNotifications;
  String? get pageTitle => _pageTitle;
  List<String> get breadcrumb => _breadcrumb;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Screens hand the title back from a post-frame callback and set the
  /// counters from replies that arrive on their own schedule, so an update can
  /// land after the shell itself has gone. Notifying a disposed
  /// [ChangeNotifier] throws, and by then there is nothing left to tell.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void setPlanStatus(String text, {bool committed = true}) {
    if (text == _planStatusText && committed == _planCommitted) return;
    _planStatusText = text;
    _planCommitted = committed;
    _notify();
  }

  void setPendingChanges(int n) {
    if (n == _pendingChanges) return;
    _pendingChanges = n;
    _notify();
  }

  void setUnreadNotifications(int n) {
    if (n == _unreadNotifications) return;
    _unreadNotifications = n;
    _notify();
  }

  /// Override the top-bar title/breadcrumb for the current page. Pass null to
  /// fall back to the route's default title.
  void setPageTitle(String? title, {List<String> breadcrumb = const []}) {
    if (title == _pageTitle && listEquals(breadcrumb, _breadcrumb)) return;
    _pageTitle = title;
    _breadcrumb = breadcrumb;
    _notify();
  }

  /// Pull the shell counters from the API. Endpoints are being written
  /// concurrently; each call fails independently and quietly.
  Future<void> refreshCounts() async {
    try {
      final r = await Api.post('changes.php', 'current');
      final counts = asMap(r['counts']);
      setPendingChanges(asIntOr(counts['pending'], 0));
    } catch (e) {
      debugPrint('[shell] changes count unavailable: $e');
    }
    try {
      final r = await Api.post('notifications.php', 'list');
      setUnreadNotifications(asIntOr(r['unread'], 0));
    } catch (e) {
      debugPrint('[shell] unread count unavailable: $e');
    }
    try {
      final r = await Api.post('overview.php', 'get');
      final text = asStr(r['plan_pill']);
      if (text != null && text.isNotEmpty) setPlanStatus(text, committed: true);
    } catch (e) {
      debugPrint('[shell] plan status unavailable: $e');
    }
  }
}

/// Light / dark / system preference, persisted.
class ThemePrefs extends ChangeNotifier {
  static const _key = 'dispatch.themeMode';
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_key);
    _mode = switch (v) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
    notifyListeners();
  }

  Future<void> set(ThemeMode m) async {
    _mode = m;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, m.name);
  }
}
