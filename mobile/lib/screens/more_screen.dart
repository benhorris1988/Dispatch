import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'parts/campaign_dialogs.dart';

import '../app_state.dart';
import '../models/json.dart';
import '../services/api.dart';
import '../services/app_lock.dart';
import '../services/my_week_cache.dart';
import '../services/push_service.dart';
import '../shell/app_shell.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';
import 'lock_screen.dart' show idleLabel;

/// Phone 'More' tab: the rest of the navigation plus profile, security, notifications on
/// this device, appearance and sign out.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final prefs = context.watch<ThemePrefs>();
    final shell = context.watch<ShellState>();
    final lock = context.watch<AppLock>();
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
        // MOB-05: only where the device can do it. Web and desktop never see this panel.
        if (lock.supported) ...[
          const SizedBox(height: Sp.lg),
          const SectionLabel('Security'),
          const SizedBox(height: Sp.sm),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              SwitchListTile(
                secondary: Icon(Icons.fingerprint_rounded, color: context.mutedColor),
                title: const Text('Unlock with fingerprint or face'),
                subtitle: Text(lock.enabled
                    ? (lock.idleMinutes == 0
                        ? 'Asked every time you open or return to Dispatch.'
                        : 'Asked when you open Dispatch, or return after ${idleLabel(lock.idleMinutes).toLowerCase()} away.')
                    : 'Guard the app on this device with biometrics or your device PIN. Your sign-in is unchanged.'),
                value: lock.enabled,
                onChanged: lock.authenticating
                    ? null
                    : (on) async {
                        if (!on) {
                          await lock.disable();
                          return;
                        }
                        final ok = await lock.enable();
                        if (!ok && context.mounted && lock.error != null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lock.error!)));
                        }
                      },
              ),
              if (lock.enabled) ...[
                const Divider(),
                ListTile(
                  leading: Icon(Icons.timer_outlined, color: context.mutedColor),
                  title: const Text('Lock after'),
                  trailing: DropdownButton<int>(
                    value: AppLock.idleChoices.contains(lock.idleMinutes) ? lock.idleMinutes : AppLock.defaultIdleMinutes,
                    underline: const SizedBox.shrink(),
                    items: [for (final m in AppLock.idleChoices) DropdownMenuItem(value: m, child: Text(idleLabel(m)))],
                    onChanged: (m) => m == null ? null : lock.setIdleMinutes(m),
                  ),
                ),
                const Divider(),
                _Row(icon: Icons.lock_outline_rounded, label: 'Lock now', onTap: lock.lockNow, last: true),
              ],
            ]),
          ),
        ],
        const SizedBox(height: Sp.lg),
        const SectionLabel('Notifications on this device'),
        const SizedBox(height: Sp.sm),
        const Panel(padding: EdgeInsets.zero, child: _PushRow()),
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
            // ADM-07: which universe this is, and the way to another one.
            _Row(
              icon: Icons.swap_horiz_rounded,
              label: session.user?.workspace?.isCampaign == true
                  ? 'Campaign: ${session.user!.workspace!.name}'
                  : 'Workspaces',
              onTap: () => showCampaignSwitcher(context),
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

/// Push state for this device (MOB-04). Says plainly when the build has no push sender, and
/// when it has one, shows the registration and offers a test notification.
class _PushRow extends StatefulWidget {
  const _PushRow();
  @override
  State<_PushRow> createState() => _PushRowState();
}

class _PushRowState extends State<_PushRow> {
  Future<Map<String, dynamic>>? _list;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    if (PushService.instance.configured) _list = Api.post('devices.php', 'list');
  }

  Future<void> _sendTest() async {
    setState(() => _testing = true);
    String message;
    try {
      final r = await Api.post('devices.php', 'test_push');
      final result = asMap(r['result']);
      final sent = asIntOr(result['sent'], 0);
      final unconfigured = asIntOr(result['unconfigured'], 0);
      message = sent > 0
          ? 'Test notification sent to $sent device${sent == 1 ? '' : 's'}.'
          : unconfigured > 0
              ? 'Queued, but the server has no push sender configured, so nothing was sent.'
              : 'Queued; the server will send it shortly.';
    } on ApiException catch (e) {
      message = e.message;
    } finally {
      if (mounted) setState(() => _testing = false);
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final push = PushService.instance;
    if (!push.configured) {
      return ListTile(
        leading: Icon(Icons.notifications_off_outlined, color: context.mutedColor),
        title: const Text('Push notifications'),
        subtitle: const Text('Not available in this build: it has no push sender. Notifications still appear under Notifications.'),
        isThreeLine: true,
      );
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: _list,
      builder: (context, snap) {
        final devices = snap.hasData ? asList(snap.data!['devices'], (m) => m) : const <Map<String, dynamic>>[];
        final active = devices.where((d) => asBool(d['active'])).length;
        final serverPush = snap.hasData ? asMap(snap.data!['push']) : const <String, dynamic>{};
        final serverConfigured = asBool(serverPush['configured']);
        return Column(children: [
          ListTile(
            leading: Icon(Icons.notifications_active_outlined, color: context.mutedColor),
            title: const Text('Push notifications'),
            subtitle: Text(!snap.hasData
                ? 'Checking this device…'
                : !serverConfigured
                    ? 'This device is registered, but the server has no push sender configured yet.'
                    : 'Registered as ${push.deviceLabel}. $active active device${active == 1 ? '' : 's'} on your account.'),
            isThreeLine: true,
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.send_outlined, color: context.mutedColor),
            title: const Text('Send a test notification'),
            trailing: _testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.chevron_right_rounded, color: context.mutedColor),
            onTap: _testing ? null : _sendTest,
          ),
        ]);
      },
    );
  }
}

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
