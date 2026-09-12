import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'router.dart';
import 'theme/app_theme.dart';
import 'widgets/dispatch_logo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_GB');
  final session = Session();
  final themePrefs = ThemePrefs();
  await themePrefs.load();
  // Restore the stored token in the background; the router shows a splash
  // until it settles.
  session.restore();
  runApp(DispatchApp(session: session, themePrefs: themePrefs));
}

class DispatchApp extends StatefulWidget {
  const DispatchApp({super.key, required this.session, required this.themePrefs});
  final Session session;
  final ThemePrefs themePrefs;

  @override
  State<DispatchApp> createState() => _DispatchAppState();
}

class _DispatchAppState extends State<DispatchApp> {
  late final GoRouter _router = buildRouter(widget.session);
  final _config = WorkspaceConfig();
  final _shell = ShellState();

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
  }

  void _onSession() {
    if (!widget.session.signedIn) _config.clear();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.session),
        ChangeNotifierProvider.value(value: widget.themePrefs),
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
          builder: (context, child) => session.restoring ? const _Splash() : (child ?? const SizedBox.shrink()),
        ),
      ),
    );
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
