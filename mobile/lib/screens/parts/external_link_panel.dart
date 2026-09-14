import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/json.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// External record (REQ-05): the ticket or page a work item came from.
///
/// Shows the system label, the reference, an "Open" button and the server's
/// badge. **The badge is only ever what the server says it is.** `live: true`
/// (an item `intake.php` raised from a ticket system — Dispatch's own record of
/// what the caller posted, never the ticket's state at source) renders as a
/// coloured status chip with "seen N times · last (date)"; `link_only` is a
/// neutral chip with the server's note underneath. Nothing here invents a
/// status. Team leads and above can link, edit and remove.
class ExternalLinkPanel extends StatelessWidget {
  const ExternalLinkPanel({super.key, required this.item, required this.canEdit, required this.onChanged});

  /// The `work_items.php get` item map (reads `id`, `ref`, `external_link`).
  final Map<String, dynamic> item;
  final bool canEdit;

  /// Called after a successful link / edit / remove so the screen reloads.
  final Future<void> Function() onChanged;

  Map<String, dynamic> get _link => asMap(item['external_link']);
  bool get _linked => _link.isNotEmpty && asStr(_link['url']) != null;

  Future<void> _open(BuildContext context) async {
    final raw = asStr(_link['url']);
    final uri = raw == null ? null : Uri.tryParse(raw);
    var ok = false;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && context.mounted) tmToast(context, 'The link could not be opened on this device.', bad: true);
  }

  Future<void> _edit(BuildContext context) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _LinkDialog(itemId: asIntOr(item['id'], 0), initialUrl: asStr(_link['url']), initialRef: asStr(_link['ref'])),
    );
    if (saved == true) await onChanged();
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await showTmConfirm(
      context,
      title: 'Remove the external link?',
      message: 'The link and reference are cleared from ${asStrOr(item['ref'], 'this item')}. The record itself is untouched, and the change is audited.',
      confirmLabel: 'Remove',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.post('work_items.php', 'clear_external_link', {'id': asIntOr(item['id'], 0)});
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    final badge = asMap(link['badge']);
    return Panel(
      title: 'External record',
      subtitle: _linked ? asStr(link['system_label']) : 'The ticket or page this work came from',
      trailing: canEdit && _linked
          ? Wrap(spacing: Sp.xs, children: [
              IconButton(tooltip: 'Edit the link', icon: const Icon(Icons.edit_outlined, size: 18), visualDensity: VisualDensity.compact, onPressed: () => _edit(context)),
              IconButton(tooltip: 'Remove the link', icon: const Icon(Icons.link_off_rounded, size: 18), visualDensity: VisualDensity.compact, onPressed: () => _remove(context)),
            ])
          : null,
      child: !_linked
          ? EmptyState(
              icon: Icons.link_rounded,
              title: 'Not linked to an external record',
              message: canEdit ? 'Link the Jira, ServiceNow, SharePoint or Azure DevOps record this work came from.' : 'A team lead can link the record this work came from.',
              compact: true,
              action: canEdit ? SecondaryButton('Link a record', icon: Icons.add_link_rounded, onPressed: () => _edit(context)) : null,
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: Sp.sm, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                ToneChip(asStrOr(link['system_label'], humanise(asStr(link['system']))), icon: _systemIcon(asStr(link['system'])), compact: true),
                if (asStr(link['ref']) != null) Text(asStr(link['ref'])!, style: DispatchTheme.numeric(size: 14, weight: FontWeight.w800, color: context.inkColor)),
                _BadgeChip(badge),
              ]),
              const SizedBox(height: Sp.sm),
              Text(asStrOr(link['url'], ''), style: context.text.bodySmall?.copyWith(color: context.mutedColor), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (asBool(badge['live']) && (badge['times_seen'] != null || badge['last_seen_at'] != null)) ...[
                const SizedBox(height: Sp.xs),
                Text(_seenLine(badge), style: context.text.bodySmall),
              ],
              if (asStr(badge['note']) != null) ...[
                const SizedBox(height: Sp.xs),
                Text(asStr(badge['note'])!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ],
              const SizedBox(height: Sp.md),
              Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                SecondaryButton('Open', icon: Icons.open_in_new_rounded, onPressed: () => _open(context)),
              ]),
            ]),
    );
  }

  /// "seen 3 times · last Tue 8 Sep" — only for a live badge, and only from
  /// what the server sent.
  static String _seenLine(Map<String, dynamic> badge) {
    final times = asInt(badge['times_seen']);
    final last = asDate(badge['last_seen_at']);
    return dotJoin([
      times == null ? null : 'seen $times ${times == 1 ? 'time' : 'times'}',
      last == null ? null : 'last ${fmtShortDate(last)}',
      asStr(badge['source_name']) == null ? null : 'via ${asStr(badge['source_name'])}',
    ]);
  }

  static IconData _systemIcon(String? system) => switch (system) {
        'jira' => Icons.bug_report_outlined,
        'servicenow' => Icons.support_agent_rounded,
        'sharepoint' => Icons.folder_shared_outlined,
        'azure_devops' => Icons.merge_type_rounded,
        _ => Icons.link_rounded,
      };
}

/// The badge chip. A live state gets a colour by what it *is* (raised → ok,
/// duplicate_seen → warn, anything else the server may add → info); a
/// `link_only` badge is a plain neutral chip that says just that.
class _BadgeChip extends StatelessWidget {
  const _BadgeChip(this.badge);
  final Map<String, dynamic> badge;

  @override
  Widget build(BuildContext context) {
    final state = asStrOr(badge['state'], 'link_only');
    final live = asBool(badge['live']);
    final label = asStrOr(badge['label'], humanise(state));
    if (!live) return ToneChip(label.isEmpty ? 'Link only' : label, icon: Icons.link_rounded, compact: true);
    final tone = switch (state) {
      'raised' => 'ok',
      'duplicate_seen' => 'warn',
      _ => 'info',
    };
    return ToneChip(label, tone: tone, icon: Icons.sensors_rounded, compact: true);
  }
}

/// Link or edit: URL and optional reference. The system is inferred server-side
/// from the host and shows after save, so the form does not ask for it.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.itemId, this.initialUrl, this.initialRef});
  final int itemId;
  final String? initialUrl;
  final String? initialRef;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _url = TextEditingController(text: widget.initialUrl ?? '');
  late final TextEditingController _ref = TextEditingController(text: widget.initialRef ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('work_items.php', 'set_external_link', {
        'id': widget.itemId,
        'url': _url.text.trim(),
        if (_ref.text.trim().isNotEmpty) 'external_ref': _ref.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initialUrl == null;
    return AlertDialog(
      title: Text(isNew ? 'Link an external record' : 'Edit the external link'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmField(
            label: 'URL',
            hint: 'A full http(s) address. The system — Jira, ServiceNow, SharePoint, Azure DevOps — is recognised from it.',
            child: TextField(controller: _url, keyboardType: TextInputType.url, autofocus: true, onChanged: (_) => setState(() {})),
          ),
          const SizedBox(height: Sp.md),
          TmField(
            label: 'Reference (optional)',
            hint: 'The ticket or page key as people quote it, for example INC0012345 or DP-88.',
            child: TextField(controller: _ref),
          ),
          if (_error != null) TmInlineError(_error!),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _url.text.trim().isEmpty ? null : _save),
      ],
    );
  }
}
