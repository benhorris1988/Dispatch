import 'package:flutter/material.dart';

/// Route paths, in one place.
class Routes {
  Routes._();
  static const signIn = '/sign-in';
  static const overview = '/overview';
  static const pipeline = '/pipeline';
  static const schedule = '/schedule';
  static const changes = '/changes';
  static const team = '/team';
  static const org = '/org';
  static const estimates = '/estimates';
  static const benefits = '/benefits';
  static const reports = '/reports';
  static const settings = '/settings';
  static const myWeek = '/my-week';
  static const addWork = '/add-work';
  static const notifications = '/notifications';
  static const more = '/more';

  static String item(String ref) => '/items/$ref';
  static String estimate(String ref) => '/items/$ref/estimate';
  static String change(Object id) => '/changes/$id';
  static String person(Object id) => '/people/$id';
}

/// One sidebar / tab entry.
class NavItem {
  const NavItem({required this.label, required this.icon, required this.selectedIcon, required this.path, this.minRole = 'viewer', this.badge = false});
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
  /// Hidden from users below this role.
  final String minRole;
  /// Show the pending-changes count.
  final bool badge;

  bool matches(String location) => location == path || location.startsWith('$path/');
}

/// A labelled group of items ('Value', 'Admin'); [label] null = ungrouped.
class NavGroup {
  const NavGroup({this.label, required this.items});
  final String? label;
  final List<NavItem> items;
}

class Nav {
  Nav._();

  static const overview = NavItem(label: 'Overview', icon: Icons.grid_view_outlined, selectedIcon: Icons.grid_view_rounded, path: Routes.overview);
  static const pipeline = NavItem(label: 'Pipeline', icon: Icons.format_list_numbered_rounded, selectedIcon: Icons.format_list_numbered_rounded, path: Routes.pipeline);
  static const schedule = NavItem(label: 'Schedule', icon: Icons.calendar_month_outlined, selectedIcon: Icons.calendar_month_rounded, path: Routes.schedule);
  static const changes = NavItem(label: 'Changes', icon: Icons.swap_calls_rounded, selectedIcon: Icons.swap_calls_rounded, path: Routes.changes, badge: true);
  static const team = NavItem(label: 'Team & skills', icon: Icons.people_alt_outlined, selectedIcon: Icons.people_alt_rounded, path: Routes.team);
  static const org = NavItem(label: 'Organisation', icon: Icons.account_tree_outlined, selectedIcon: Icons.account_tree_rounded, path: Routes.org);
  static const estimates = NavItem(label: 'Estimates', icon: Icons.balance_rounded, selectedIcon: Icons.balance_rounded, path: Routes.estimates);
  static const benefits = NavItem(label: 'Benefits', icon: Icons.trending_up_rounded, selectedIcon: Icons.trending_up_rounded, path: Routes.benefits);
  static const reports = NavItem(label: 'Reports', icon: Icons.bar_chart_rounded, selectedIcon: Icons.bar_chart_rounded, path: Routes.reports);
  static const settings = NavItem(label: 'Settings', icon: Icons.tune_rounded, selectedIcon: Icons.tune_rounded, path: Routes.settings, minRole: 'team_lead');
  static const myWeek = NavItem(label: 'My week', icon: Icons.calendar_today_outlined, selectedIcon: Icons.calendar_today_rounded, path: Routes.myWeek);
  static const notifications = NavItem(label: 'Notifications', icon: Icons.notifications_none_rounded, selectedIcon: Icons.notifications_rounded, path: Routes.notifications);
  static const more = NavItem(label: 'More', icon: Icons.menu_rounded, selectedIcon: Icons.menu_rounded, path: Routes.more);

  /// Desktop / tablet sidebar.
  static const List<NavGroup> sidebar = [
    NavGroup(items: [overview, pipeline, schedule, changes, team, org]),
    NavGroup(label: 'Value', items: [estimates, benefits, reports]),
    NavGroup(label: 'Admin', items: [settings]),
  ];

  /// Phone bottom tabs.
  static const List<NavItem> phoneTabs = [myWeek, pipeline, changes, more];

  /// Entries listed on the phone 'More' page (Sign out is appended by the screen).
  static const List<NavItem> moreItems = [schedule, team, org, benefits, estimates, reports, settings, notifications];

  /// Human title for a location, for the top bar / AppBar.
  static String titleFor(String location) {
    if (location.startsWith('/items/') && location.endsWith('/estimate')) return 'Estimate';
    if (location.startsWith('/items/')) return 'Work item';
    if (location.startsWith('/people/')) return 'Person';
    if (location.startsWith('/changes/')) return 'Change';
    for (final g in sidebar) {
      for (final i in g.items) {
        if (i.matches(location)) return i.label;
      }
    }
    for (final i in [myWeek, notifications, more]) {
      if (i.matches(location)) return i.label;
    }
    if (location.startsWith(Routes.addWork)) return 'Add work';
    return 'Dispatch';
  }

  /// Which bottom tab a location belongs to (phone). Anything not covered by
  /// the first three tabs lands on More.
  static int phoneTabIndex(String location) {
    for (var i = 0; i < 3; i++) {
      if (phoneTabs[i].matches(location)) return i;
    }
    if (location.startsWith('/items/')) return 1;
    return 3;
  }
}
