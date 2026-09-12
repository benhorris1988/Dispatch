import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../shell/app_shell.dart';
import '../services/my_week_cache.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';

/// Phone 'More' tab: the rest of the navigation plus profile and sign out.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final prefs = context.watch<ThemePrefs>();
    final shell = context.watch<ShellState>();
    final user = session.user;

    return PageBody(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (user != null)
          DispatchCard(
            onTap: user.personId == null ? null : () => context.push(Routes.person(user.personId!)),
            child: Row(children: [
              PersonAvatar(user.initials, colourHex: user.colour, seed: user.id, size: 48),
              const SizedBox(width: Sp.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(user.displayName, style: context.text.titleMedium),
                  Text(user.roleTitle, style: context.text.bodySmall),
                ]),
              ),
              if (user.personId != null) Icon(Icons.chevron_right_rounded, color: context.mutedColor),
            ]),
          ),
        const SizedBox(height: Sp.lg),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(children: [
            if (user?.personId != null) _Row(icon: Icons.person_outline_rounded, label: 'My profile', onTap: () => context.push(Routes.person(user!.personId!))),
            for (final item in Nav.moreItems)
              if (session.can(item.minRole))
                _Row(
                  icon: item.icon,
                  label: item == Nav.schedule ? 'Schedule (read-only)' : item.label,
                  badge: item == Nav.notifications ? shell.unreadNotifications : 0,
                  onTap: () => context.push(item.path),
                ),
          ]),
        ),
        const SizedBox(height: Sp.lg),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.dark_mode_outlined, color: context.mutedColor),
              title: const Text('Appearance'),
              trailing: SegmentedTabs(
                compact: true,
                labels: const ['Auto', 'Light', 'Dark'],
                selected: switch (prefs.mode) { ThemeMode.system => 0, ThemeMode.light => 1, ThemeMode.dark => 2 },
                onChanged: (i) => prefs.set([ThemeMode.system, ThemeMode.light, ThemeMode.dark][i]),
              ),
            ),
            const Divider(),
            _Row(
              icon: Icons.logout_rounded,
              label: 'Sign out',
              onTap: () async {
                await MyWeekCache.clear();
                await session.signOut();
              },
              last: true,
            ),
          ]),
        ),
        const SizedBox(height: Sp.lg),
        Panel(
          padding: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(Icons.info_outline_rounded, color: context.mutedColor),
            title: const Text('About'),
            subtitle: const Text('Dispatch · Delivery planning'),
            trailing: Text(_version, style: context.text.bodySmall),
          ),
        ),
      ]),
    );
  }
}

/// App version, shown on the About row. Kept in step with pubspec.yaml.
const String _version = 'Version 0.1.0';

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.onTap, this.last = false, this.badge = 0});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool last;

  /// Unread count shown as a pill on the right (notifications).
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      ListTile(
        leading: Icon(icon, color: context.mutedColor),
        title: Text(label),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (badge > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: DispatchColors.orange, borderRadius: BorderRadius.circular(999)),
              child: Text(
                badge > 99 ? '99+' : '$badge',
                style: DispatchTheme.numeric(size: 12, color: Colors.white),
              ),
            ),
            const SizedBox(width: Sp.sm),
          ],
          Icon(Icons.chevron_right_rounded, color: context.mutedColor),
        ]),
        onTap: onTap,
      ),
      if (!last) const Divider(),
    ]);
  }
}
