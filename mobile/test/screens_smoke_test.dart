// Renders every screen against the LIVE API and fails on any exception, missing
// content or overflow. `flutter analyze` proves the code compiles; only this proves a
// screen actually draws with real data.
//
//   run_local.ps1 must be serving, and the demo must be seeded:
//     C:\xampp\php\php.exe seed_demo.php
//   then, from mobile/:
//     flutter test test/screens_smoke_test.dart
//
// Flutter's test binding blocks real sockets, so `HttpOverrides.global` is cleared to let
// the app's own HTTP client through. Nothing is mocked: the screens parse exactly what the
// PHP API returns, which is the point.
import 'dart:io';

import 'package:dispatch_app/app_state.dart';
import 'package:dispatch_app/screens/add_work_screen.dart';
import 'package:dispatch_app/screens/benefits_screen.dart';
import 'package:dispatch_app/screens/changes_screen.dart';
import 'package:dispatch_app/screens/estimate_screen.dart';
import 'package:dispatch_app/screens/estimates_screen.dart';
import 'package:dispatch_app/screens/my_week_screen.dart';
import 'package:dispatch_app/screens/notifications_screen.dart';
import 'package:dispatch_app/screens/overview_screen.dart';
import 'package:dispatch_app/screens/person_screen.dart';
import 'package:dispatch_app/screens/pipeline_screen.dart';
import 'package:dispatch_app/screens/plan_versions_screen.dart';
import 'package:dispatch_app/screens/org_chart_screen.dart';
import 'package:dispatch_app/screens/role_family_screen.dart';
import 'package:dispatch_app/screens/reports_screen.dart';
import 'package:dispatch_app/screens/request_detail_screen.dart';
import 'package:dispatch_app/screens/requests_screen.dart';
import 'package:dispatch_app/screens/scenarios_screen.dart';
import 'package:dispatch_app/screens/schedule_screen.dart';
import 'package:dispatch_app/screens/settings_screen.dart';
import 'package:dispatch_app/screens/team_skills_screen.dart';
import 'package:dispatch_app/screens/work_item_screen.dart';
import 'package:dispatch_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop, tablet and phone. Screens must render at all three (NFR-ACC-01, MOB-02).
const _sizes = <String, Size>{
  'desktop': Size(1440, 1000),
  'tablet': Size(900, 1000),
  'phone': Size(390, 844),
};

late final Session _session;
late final WorkspaceConfig _config;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // let the app talk to the real server
  SharedPreferences.setMockInitialValues({});
  await initializeDateFormatting('en_GB');

  setUpAll(() async {
    // Sign-in is Google (ADM-01), which a test cannot perform, so the suite is handed a
    // token minted straight from the database instead:
    //   flutter test test/screens_smoke_test.dart --dart-define=TEST_TOKEN=<token>
    //   (C:\\xampp\\php\\php.exe tests\\mint_token.php delivery_lead prints one)
    const token = String.fromEnvironment('TEST_TOKEN');
    expect(token, isNotEmpty, reason: 'run with --dart-define=TEST_TOKEN=<jwt>, minted by: php tests/mint_token.php delivery_lead');
    _session = Session();
    await _session.signInWithToken(token).timeout(const Duration(seconds: 20));
    expect(_session.signedIn, isTrue, reason: 'the token was refused — stale, or the demo reseeded since?');
    expect(_session.isDeliveryLead, isTrue, reason: 'the TEST_TOKEN account must be a delivery lead or an administrator');
    _config = WorkspaceConfig();
    await _config.load();
    expect(_config.workTypes, isNotEmpty, reason: 'workspace config did not load');
  });

  /// Pumps [child] at [size] against the real API and fails on any framework exception.
  ///
  /// testWidgets runs inside FakeAsync, so a real HTTP response never arrives while only
  /// tester.pump() is driving the clock. tester.runAsync() steps outside that fake zone,
  /// which is the only way to let the screens' own requests complete.
  Future<void> render(WidgetTester tester, Widget child, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = MultiProvider(
      providers: [
        ChangeNotifierProvider<Session>.value(value: _session),
        ChangeNotifierProvider<WorkspaceConfig>.value(value: _config),
        ChangeNotifierProvider<ShellState>(create: (_) => ShellState()),
        ChangeNotifierProvider<ThemePrefs>(create: (_) => ThemePrefs()),
      ],
      child: MaterialApp(theme: DispatchTheme.light(), home: Scaffold(body: child)),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      // Real time, so the screen's requests resolve; pump between waits so each arriving
      // response gets a frame to render into.
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 120));
      }
    });
    await tester.pump(const Duration(milliseconds: 200));

    final error = tester.takeException();
    expect(error, isNull, reason: 'threw while rendering: $error');
  }

  /// Every screen must reach real content: never stuck loading, never an error state.
  void expectLoaded(WidgetTester tester, String screen) {
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    expect(text, isNotEmpty, reason: '$screen rendered no text at all');
    final failed = text.where((s) =>
        s.contains('Something went wrong') ||
        s.contains('Could not load') ||
        s.contains('Unauthorized') ||
        s.startsWith('Database error'));
    expect(failed, isEmpty, reason: '$screen showed an error state: ${failed.join(" | ")}');
  }

  final screens = <String, Widget>{
    'Overview': const OverviewScreen(),
    'Pipeline': const PipelineScreen(),
    'Schedule': const ScheduleScreen(),
    'Plan versions': const PlanVersionsScreen(),
    'Scenarios': const ScenariosScreen(),
    'Changes': const ChangesScreen(),
    'Requests': const RequestsScreen(),
    'Request': const RequestDetailScreen(id: '1'),
    'Team & skills': const TeamSkillsScreen(),
    'Person': const PersonScreen(id: '1'),
    'Organisation': const OrgChartScreen(),
    'Role family': const RoleFamilyScreen(id: '1'),
    'Work item': const WorkItemScreen(ref: 'WI-1042'),
    'Estimate': const EstimateScreen(ref: 'WI-1042'),
    'Estimates': const EstimatesScreen(),
    'Benefits': const BenefitsScreen(),
    'Reports': const ReportsScreen(),
    'Settings': const SettingsScreen(),
    'Notifications': const NotificationsScreen(),
    'My week': const MyWeekScreen(),
    'Add work': const AddWorkScreen(),
  };

  // Every screen at every width. Restricting the responsive pass to a handful of screens
  // was a real hole: three separate sweeps found overflows on screens the bar was happy
  // with, because it only ever drew them at 1440px. A layout that breaks on a phone is
  // broken whether or not anyone happened to test that screen there.
  for (final entry in screens.entries) {
    for (final size in _sizes.keys) {
      testWidgets('${entry.key} renders on $size', (tester) async {
        await render(tester, entry.value, _sizes[size]!);
        expectLoaded(tester, '${entry.key} ($size)');
      });
    }
  }


  // Settings hides thirteen sections behind a side nav, and the screens map only
  // ever draws the first one. A layout fault in a later section is a blank panel
  // that every check above is perfectly happy with — which is exactly how one got
  // through. Open each section and look at it.
  const settingsSections = [
    'General', 'Work types', 'Size classes', 'Day rates', 'Scheduling & stability',
    'Priority & objective', 'Skills catalogue', 'Teams & roles', 'Integrations',
    'Notifications', 'Audit log', 'Calendar & leave', 'Campaigns',
  ];
  for (final section in settingsSections) {
    testWidgets('Settings: $section', (tester) async {
      await render(tester, const SettingsScreen(), _sizes['desktop']!);
      final tab = find.text(section);
      expect(tab, findsWidgets, reason: 'no "$section" entry in the Settings nav');
      await tester.runAsync(() async {
        await tester.tap(tab.first, warnIfMissed: false);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await tester.pump(const Duration(milliseconds: 120));
        }
      });
      expect(tester.takeException(), isNull, reason: 'Settings → $section threw');
      expectLoaded(tester, 'Settings → $section');
    });
  }

  testWidgets('screens render in dark theme', (tester) async {
    for (final name in ['Overview', 'Schedule', 'Benefits']) {
      tester.view.physicalSize = _sizes['desktop']!;
      tester.view.devicePixelRatio = 1.0;
      final app = MultiProvider(
        providers: [
          ChangeNotifierProvider<Session>.value(value: _session),
          ChangeNotifierProvider<WorkspaceConfig>.value(value: _config),
          ChangeNotifierProvider<ShellState>(create: (_) => ShellState()),
          ChangeNotifierProvider<ThemePrefs>(create: (_) => ThemePrefs()),
        ],
        child: MaterialApp(
          theme: DispatchTheme.dark(),
          darkTheme: DispatchTheme.dark(),
          themeMode: ThemeMode.dark,
          home: Scaffold(body: screens[name]!),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(app);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await tester.pump(const Duration(milliseconds: 120));
        }
      });
      expect(tester.takeException(), isNull, reason: '$name threw in dark theme');
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
