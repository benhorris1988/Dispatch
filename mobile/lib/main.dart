import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'router.dart';
import 'screens/lock_screen.dart';
import 'services/app_lock.dart';
import 'services/deep_links.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';
import 'widgets/dispatch_logo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_GB');
  final session = Session();
  final themePrefs = ThemePrefs();
  final lock = AppLock();
  // The lock preference must be known before the first frame: if it is on, the first frame
  // is the lock view, never data.
  await Future.wait([themePrefs.load(), lock.load()]);
  lock.attach();
  // Restore the stored token in the background; the router shows a splash
  // until it settles.
  session.restore();
  runApp(DispatchApp(session: session, themePrefs: themePrefs, lock: lock));
}

class DispatchApp extends StatefulWidget {
  const DispatchApp({super.key, required this.session, required this.themePrefs, required this.lock});
  final Session session;
  final ThemePrefs themePrefs;
  final AppLock lock;

  @override
  State<DispatchApp> createState() => _DispatchAppState();
}

class _DispatchAppState extends State<DispatchApp> {
  late final GoRouter _router = buildRouter(widget.session);
  final _config = WorkspaceConfig();
  final _shell = ShellState();
  final _registrar = DeviceRegistrar();
  late bool _wasSignedIn = widget.session.signedIn;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    widget.session.beforeSignOut.add(_registrar.unregister);
    PushService.instance.init(onLink: _openLink);
  }

  /// A tapped notification lands on the screen its `link` names (MOB-04).
  void _openLink(String link) {
    final route = DeepLinks.toRoute(Uri.parse(link));
    if (route != null) _router.go(route);
  }

  void _onSession() {
    final now = widget.session.signedIn;
    if (!now) _config.clear();
    if (now && !_wasSignedIn) {
      // A fresh sign-in proves identity, so it unlocks and may offer the lock; a session
      // restored from storage leaves the lock exactly as load() set it.
      if (widget.session.signedInInteractively) widget.lock.onSignedIn();
      _registrar.register();
    } else if (!now && _wasSignedIn) {
      widget.lock.onSignedOut();
    }
    _wasSignedIn = now;
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    widget.session.beforeSignOut.remove(_registrar.unregister);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.session),
        ChangeNotifierProvider.value(value: widget.themePrefs),
        ChangeNotifierProvider.value(value: widget.lock),
        ChangeNotifierProvider.value(value: _config),
        ChangeNotifierProvider.value(value: _shell),
      ],
      child: Consumer2<ThemePrefs, Session>(
        builder: (context, prefs, session, _) => MaterialApp.router(
          title: 'Dispatch',
          debugShowCheckedModeBanner: false,
          theme: DispatchTheme.light(),
          darkTheme: DispatchTheme.dark(),
          themeMode: prefs.mode,
          routerConfig: _router,
          builder: (context, child) {
            if (session.restoring) return const _Splash();
            final content = child ?? const SizedBox.shrink();
            if (!session.signedIn) return content;
            final lock = context.watch<AppLock>();
            if (lock.locked) return _Covered(content: content, cover: const LockScreen());
            if (lock.offerPending) return _Covered(content: content, cover: const LockOfferScreen());
            return content;
          },
        ),
      ),
    );
  }
}

/// The app with a full-screen view over it. The router and its screens stay mounted, so
/// nothing is lost on unlock, but they are neither visible, tappable nor read by a screen
/// reader while covered.
class _Covered extends StatelessWidget {
  const _Covered({required this.content, required this.cover});
  final Widget content, cover;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      ExcludeSemantics(child: ExcludeFocus(child: IgnorePointer(child: content))),
      cover,
    ]);
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DispatchLogo(size: 56, onDark: context.isDark),
          const SizedBox(height: 28),
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
    );
  }
}
