import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import 'nav.dart';

/// Desktop/tablet top bar: page title or breadcrumb, search field, plan-status
/// pill and the notification bell.
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.location});
  final String location;

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellState>();
    final title = shell.pageTitle ?? Nav.titleFor(location);
    final crumbs = shell.breadcrumb;
    final narrow = MediaQuery.sizeOf(context).width < 1300;

    return Container(
      height: ShellDims.topBar,
      padding: const EdgeInsets.symmetric(horizontal: Sp.xl),
      decoration: BoxDecoration(color: context.panelColor, border: Border(bottom: BorderSide(color: context.borderColor))),
      child: Row(children: [
        Expanded(
          child: Row(children: [
            for (final c in crumbs) ...[
              Text(c, style: context.text.titleMedium?.copyWith(color: context.mutedColor, fontWeight: FontWeight.w600)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.chevron_right_rounded, size: 18, color: context.mutedColor)),
            ],
            Flexible(child: Text(title, style: context.text.titleMedium, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        const SizedBox(width: Sp.lg),
        SizedBox(width: narrow ? 260 : 380, child: const ShellSearchField()),
        const SizedBox(width: Sp.md),
        InfoPill(shell.planStatusText, dot: shell.planCommitted ? DispatchColors.green : DispatchColors.amber, onTap: () => context.go(Routes.schedule)),
        const SizedBox(width: Sp.md),
        IconBox(Icons.notifications_none_rounded, tooltip: 'Notifications', badge: shell.unreadNotifications > 0, onPressed: () => context.go(Routes.notifications)),
      ]),
    );
  }
}

/// Search field placeholder. Submitting navigates to the pipeline with a `q`
/// query parameter; the Pipeline screen may read it later.
class ShellSearchField extends StatelessWidget {
  const ShellSearchField({super.key});

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        hintText: 'Search work, people, skills',
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: context.mutedColor),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        fillColor: context.isDark ? DispatchColors.darkBg : DispatchColors.surface,
      ),
      textInputAction: TextInputAction.search,
      onSubmitted: (q) {
        final t = q.trim();
        if (t.isEmpty) return;
        context.go(Uri(path: Routes.pipeline, queryParameters: {'q': t}).toString());
      },
    );
  }
}
