import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_state.dart';
import 'screens/add_work_screen.dart';
import 'screens/benefits_screen.dart';
import 'screens/change_detail_screen.dart';
import 'screens/changes_screen.dart';
import 'screens/estimate_screen.dart';
import 'screens/estimates_screen.dart';
import 'screens/more_screen.dart';
import 'screens/my_week_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/person_screen.dart';
import 'screens/pipeline_screen.dart';
import 'screens/plan_versions_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/scenarios_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/team_skills_screen.dart';
import 'screens/work_item_screen.dart';
import 'shell/app_shell.dart';
import 'shell/breaks.dart';
import 'shell/nav.dart';

/// Default landing route after sign-in: Overview on desktop/tablet, My week on phone.
String homeFor(BuildContext context) => Breaks.isPhone(context) ? Routes.myWeek : Routes.overview;

GoRouter buildRouter(Session session) {
  return GoRouter(
    initialLocation: Routes.overview,
    refreshListenable: session,
    debugLogDiagnostics: false,
    redirect: (context, state) {
      final loc = state.uri.path;
      if (session.restoring) return null; // splash shows until restore completes
      final atSignIn = loc == Routes.signIn;
      if (!session.signedIn) {
        if (atSignIn) return null;
        final from = state.uri.toString();
        return Uri(path: Routes.signIn, queryParameters: from == '/' || from == Routes.overview ? null : {'from': from}).toString();
      }
      if (atSignIn || loc == '/') {
        final from = state.uri.queryParameters['from'];
        if (from != null && from.isNotEmpty && from != Routes.signIn) return from;
        return homeFor(context);
      }
      // Phone users landing on /overview go to My week instead.
      if (loc == Routes.overview && Breaks.isPhone(context)) return Routes.myWeek;
      return null;
    },
    routes: [
      GoRoute(path: Routes.signIn, builder: (c, s) => const SignInScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(state: state, child: child),
        routes: [
          _page(Routes.overview, (s) => const OverviewScreen()),
          _page(Routes.pipeline, (s) => PipelineScreen(query: s.uri.queryParameters['q'])),
          _page('/items/:ref', (s) => WorkItemScreen(ref: s.pathParameters['ref']!)),
          _page('/items/:ref/estimate', (s) => EstimateScreen(ref: s.pathParameters['ref']!)),
          _page(Routes.schedule, (s) => const ScheduleScreen()),
          // Plan version history and what-if scenarios hang off the schedule,
          // so the sidebar keeps Schedule highlighted while they are open.
          _page(PlanVersionsScreen.route, (s) => PlanVersionsScreen(versionId: int.tryParse(s.uri.queryParameters['v'] ?? ''))),
          _page(ScenariosScreen.route, (s) => const ScenariosScreen()),
          _page(Routes.changes, (s) => const ChangesScreen()),
          _page('/changes/:id', (s) => ChangeDetailScreen(id: s.pathParameters['id']!)),
          _page(Routes.team, (s) => const TeamSkillsScreen()),
          _page('/people/:id', (s) => PersonScreen(id: s.pathParameters['id']!)),
          _page(Routes.estimates, (s) => const EstimatesScreen()),
          _page(Routes.benefits, (s) => const BenefitsScreen()),
          _page(Routes.reports, (s) => const ReportsScreen()),
          _page(Routes.settings, (s) => const SettingsScreen()),
          _page(Routes.myWeek, (s) => const MyWeekScreen()),
          _page(Routes.addWork, (s) => const AddWorkScreen()),
          _page(Routes.notifications, (s) => const NotificationsScreen()),
          _page(Routes.more, (s) => const MoreScreen()),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Page not found', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(state.uri.toString(), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.go(homeFor(context)), child: const Text('Back to Dispatch')),
        ]),
      ),
    ),
  );
}

GoRoute _page(String path, Widget Function(GoRouterState) builder) => GoRoute(
      path: path,
      pageBuilder: (context, state) => NoTransitionPage(key: state.pageKey, child: builder(state)),
    );
