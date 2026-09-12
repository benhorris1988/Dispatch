import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/team_widgets.dart';
import '../widgets/widgets.dart';

/// Notifications (NOT-01..03): newest first, with per-kind delivery
/// preferences underneath.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _loading = true;
  String? _error;
  List<AppNotification> _items = const [];
  List<_Pref> _prefs = const [];
  int _unread = 0;
  bool _showPrefs = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        Api.post('notifications.php', 'list'),
        Api.post('notifications.php', 'prefs'),
      ]);
      if (!mounted) return;
      setState(() {
        _items = listOf(results[0]['notifications'], AppNotification.fromJson);
        _unread = asIntOr(results[0]['unread'], 0);
        _prefs = asList(results[1]['prefs'], _Pref.fromJson);
        _loading = false;
      });
      if (mounted) context.read<ShellState>().setUnreadNotifications(_unread);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _markAllRead() async {
    try {
      await Api.post('notifications.php', 'mark_read', {'all': true});
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _open(AppNotification n) async {
    if (!n.isRead) {
      try {
        await Api.post('notifications.php', 'mark_read', {'id': n.id});
      } on ApiException {
        // Opening matters more than the read receipt; the list refreshes anyway.
      }
    }
    if (!mounted) return;
    if (n.link != null && n.link!.startsWith('/')) {
      context.go(n.link!);
    } else {
      await _load();
    }
  }

  Future<void> _savePref(_Pref p, Map<String, dynamic> changes) async {
    try {
      final r = await Api.post('notifications.php', 'save_prefs', {'kind': p.kind, ...changes});
      if (!mounted) return;
      setState(() => _prefs = asList(r['prefs'], _Pref.fromJson));
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageBody(
      onRefresh: _load,
      maxWidth: 980,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Notifications',
          subtitle: _loading ? null : (_unread == 0 ? 'Nothing unread' : '$_unread unread'),
          actions: [
            SecondaryButton(
              _showPrefs ? 'Hide preferences' : 'Preferences',
              icon: Icons.tune_rounded,
              onPressed: () => setState(() => _showPrefs = !_showPrefs),
            ),
            PrimaryButton('Mark all read', icon: Icons.done_all_rounded, onPressed: _unread == 0 ? null : _markAllRead),
          ],
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const SkeletonPanel(rows: 6)
        else if (_error != null)
          ErrorState(title: 'We could not load your notifications', message: _error, onRetry: _load)
        else ...[
          Panel(
            padding: EdgeInsets.zero,
            child: _items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(Sp.xl),
                    child: EmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: 'You are up to date',
                      message: 'Changes to your plan, approvals and assignments will appear here.',
                      compact: true,
                    ),
                  )
                : Column(children: [
                    for (var i = 0; i < _items.length; i++) ...[
                      if (i > 0) Divider(height: 1, thickness: 1, color: context.borderColor),
                      _NotificationTile(notification: _items[i], onTap: () => _open(_items[i])),
                    ],
                  ]),
          ),
          if (_showPrefs) ...[
            const SizedBox(height: Sp.lg),
            _PrefsPanel(prefs: _prefs, onChange: _savePref),
          ],
        ],
      ]),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});
  final AppNotification notification;
  final VoidCallback onTap;

  static IconData iconFor(String kind) => switch (kind) {
        'change_proposed' => Icons.alt_route_rounded,
        'change_committed' => Icons.event_available_rounded,
        'approval_requested' => Icons.how_to_reg_rounded,
        'item_assigned' => Icons.assignment_ind_outlined,
        'estimate_requested' => Icons.straighten_rounded,
        'realisation_due' => Icons.savings_outlined,
        'watch_list' => Icons.visibility_outlined,
        _ => Icons.notifications_none_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final colour = n.urgent ? DispatchColors.red : DispatchColors.typeBlue;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Sp.lg),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: DispatchColors.tint(colour, opacity: context.isDark ? 0.22 : 0.1), borderRadius: DispatchRadius.cardR),
            child: Icon(iconFor(n.kind), size: 18, color: colour),
          ),
          const SizedBox(width: Sp.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(
                  child: Text(
                    n.title,
                    style: n.isRead ? context.text.titleSmall : context.text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (n.urgent) ...[const SizedBox(width: Sp.sm), const ToneChip('Urgent', tone: 'bad', compact: true)],
                if (!n.isRead) ...[
                  const SizedBox(width: Sp.sm),
                  Tooltip(
                    message: 'Unread',
                    child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: DispatchColors.orange, shape: BoxShape.circle)),
                  ),
                ],
              ]),
              if (n.body != null && n.body!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(n.body ?? '', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              ],
              const SizedBox(height: 4),
              Text(dotJoin([humanise(n.kind), _relative(n.createdAt)]), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ]),
          ),
          if (n.link != null) Icon(Icons.chevron_right_rounded, size: 20, color: context.mutedColor),
        ]),
      ),
    );
  }

  static String _relative(DateTime? d) {
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} ${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    if (diff.inDays < 7) return '${diff.inDays} ${diff.inDays == 1 ? 'day' : 'days'} ago';
    return fmtShortDate(d);
  }
}

class _PrefsPanel extends StatelessWidget {
  const _PrefsPanel({required this.prefs, required this.onChange});
  final List<_Pref> prefs;
  final void Function(_Pref, Map<String, dynamic>) onChange;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'Preferences',
      subtitle: 'How each kind of notification reaches you',
      child: prefs.isEmpty
          ? const EmptyState(icon: Icons.tune_rounded, title: 'No preferences', message: 'Defaults apply until you change something.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < prefs.length; i++) ...[
                if (i > 0) const Divider(height: Sp.xl),
                _PrefRow(pref: prefs[i], onChange: onChange),
              ],
            ]),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({required this.pref, required this.onChange});
  final _Pref pref;
  final void Function(_Pref, Map<String, dynamic>) onChange;

  @override
  Widget build(BuildContext context) {
    final p = pref;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(p.label, style: context.text.titleSmall)),
        if (p.isDefault) const ToneChip('Default', compact: true),
        if (p.urgentBypassesDigest) ...[
          const SizedBox(width: Sp.sm),
          const ToneChip('Urgent bypasses the digest', tone: 'warn', compact: true),
        ],
      ]),
      const SizedBox(height: Sp.sm),
      Wrap(spacing: Sp.xl, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _Toggle(label: 'In app', value: p.inApp, onChanged: (v) => onChange(p, {'in_app': v})),
        _Toggle(label: 'Push', value: p.push, onChanged: (v) => onChange(p, {'push': v})),
        _Toggle(label: 'Email digest', value: p.emailDigest, onChanged: (v) => onChange(p, {'email_digest': v})),
        _Toggle(label: 'Teams', value: p.teams, onChanged: (v) => onChange(p, {'teams': v})),
        SizedBox(
          width: 190,
          child: TmField(
            label: 'Digest cadence',
            child: DropdownButtonFormField<String>(
              initialValue: p.digest,
              isDense: true,
              items: const [
                DropdownMenuItem(value: 'immediate', child: Text('Immediate')),
                DropdownMenuItem(value: 'daily', child: Text('Daily')),
                DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                DropdownMenuItem(value: 'off', child: Text('Off')),
              ],
              onChanged: (v) => v == null ? null : onChange(p, {'digest': v}),
            ),
          ),
        ),
      ]),
    ]);
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Switch(value: value, onChanged: onChanged),
      const SizedBox(width: 6),
      Text(label, style: context.text.bodyMedium),
    ]);
  }
}

// ─── Parsing (notifications.php prefs) ────────────────────────────────────

class _Pref {
  const _Pref({
    required this.kind,
    required this.label,
    this.inApp = true,
    this.push = true,
    this.emailDigest = false,
    this.teams = false,
    this.digest = 'daily',
    this.urgentBypassesDigest = false,
    this.isDefault = true,
  });

  final String kind;
  final String label;
  final bool inApp;
  final bool push;
  final bool emailDigest;
  final bool teams;
  final String digest;
  final bool urgentBypassesDigest;
  final bool isDefault;

  factory _Pref.fromJson(Map<String, dynamic> j) => _Pref(
        kind: asStrOr(j['kind'], ''),
        label: asStrOr(j['label'], ''),
        inApp: asBool(j['in_app'], fallback: true),
        push: asBool(j['push'], fallback: true),
        emailDigest: asBool(j['email_digest']),
        teams: asBool(j['teams']),
        digest: asStrOr(j['digest'], 'daily'),
        urgentBypassesDigest: asBool(j['urgent_bypasses_digest']),
        isDefault: asBool(j['is_default'], fallback: true),
      );
}
