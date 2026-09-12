import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'breaks.dart';
import 'nav.dart';
import 'sidebar.dart';
import 'top_bar.dart';

/// Responsive chrome around every signed-in route.
///
///   desktop  sidebar (280) + top bar
///   tablet   icon rail (72) + top bar
///   phone    AppBar + bottom tabs (My week, Pipeline, Changes, More)
///
/// Screens are plain widgets: they render their own [PageHeader] and content,
/// and the shell supplies scrolling? No — screens own their scroll view so
/// that tables, boards and lists can scroll independently. Use
/// [PageBody] for the standard padded, width-clamped scroll container.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child, required this.state});
  final Widget child;
  final GoRouterState state;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  void initState() {
    super.initState();
    // Kick off shell counters once we have a session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ShellState>().refreshCounts();
      final cfg = context.read<WorkspaceConfig>();
      if (!cfg.loaded && !cfg.loading) cfg.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.state.uri.path;
    final pane = Breaks.of(context);

    if (pane == Pane.phone) return _PhoneShell(location: location, child: widget.child);

    return Scaffold(
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Sidebar(location: location, collapsed: pane == Pane.tablet),
        Expanded(
          child: Column(children: [
            TopBar(location: location),
            Expanded(child: widget.child),
          ]),
        ),
      ]),
    );
  }
}

class _PhoneShell extends StatelessWidget {
  const _PhoneShell({required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellState>();
    final title = shell.pageTitle ?? Nav.titleFor(location);
    final tab = Nav.phoneTabIndex(location);
    final isTabRoot = Nav.phoneTabs.any((t) => t.path == location);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: isTabRoot
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => context.canPop() ? context.pop() : context.go(Nav.phoneTabs[tab].path),
              ),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => context.push(Routes.notifications),
            icon: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.notifications_none_rounded),
              if (shell.unreadNotifications > 0)
                Positioned(right: -1, top: -1, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: DispatchColors.orange, shape: BoxShape.circle, border: Border.all(color: context.panelColor, width: 1.5)))),
            ]),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: context.borderColor))),
        child: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => context.go(Nav.phoneTabs[i].path),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final t in Nav.phoneTabs)
              NavigationDestination(
                icon: t.badge && shell.pendingChanges > 0
                    ? Badge.count(count: shell.pendingChanges, backgroundColor: DispatchColors.orange, child: Icon(t.icon))
                    : Icon(t.icon),
                selectedIcon: t.badge && shell.pendingChanges > 0
                    ? Badge.count(count: shell.pendingChanges, backgroundColor: DispatchColors.orange, child: Icon(t.selectedIcon))
                    : Icon(t.selectedIcon),
                label: t.label,
              ),
          ],
        ),
      ),
    );
  }
}

/// Standard scrolling page container: gutter padding by breakpoint, content
/// width clamped to [Breaks.maxContent], optional pull-to-refresh.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.onRefresh, this.maxWidth = Breaks.maxContent, this.padding});
  final Widget child;
  final Future<void> Function()? onRefresh;
  final double maxWidth;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final g = Breaks.gutter(context);
    Widget scroll = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding ?? EdgeInsets.fromLTRB(g, Breaks.isPhone(context) ? Sp.lg : Sp.xl, g, Sp.xxl),
      child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child)),
    );
    if (onRefresh != null) scroll = RefreshIndicator(onRefresh: onRefresh!, color: DispatchColors.orange, child: scroll);
    return scroll;
  }
}
