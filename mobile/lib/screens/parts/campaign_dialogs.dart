/// Switching between workspaces, and making a new campaign.
///
/// A campaign is a sandbox: a real workspace of its own that nothing in the live plan can see and
/// that cannot reach back into it. Switching re-issues the session token for the target workspace
/// rather than widening the one already held, so a campaign token is only ever good for a campaign.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// One workspace as `campaigns.php list` describes it.
class CampaignRow {
  const CampaignRow({
    required this.id,
    required this.name,
    required this.kind,
    this.description,
    this.sourceName,
    this.seededFrom,
    this.createdByEmail,
    this.createdAt,
    this.member = false,
    this.myRole,
    this.peopleCount = 0,
    this.itemsCount = 0,
    this.canReset = false,
    this.canDelete = false,
    this.isCurrent = false,
    this.openToAll = true,
  });

  final int id;
  final String name;
  final String kind;
  final String? description;
  final String? sourceName;
  final String? seededFrom;
  final String? createdByEmail;
  final DateTime? createdAt;
  final bool member;
  final String? myRole;
  final int peopleCount;
  final int itemsCount;
  final bool canReset;
  final bool canDelete;
  final bool isCurrent;
  final bool openToAll;

  bool get isLive => kind == 'live';

  String get madeFrom => switch (seededFrom) {
        'demo' => 'Demo dataset',
        'config' => 'People and settings only',
        'full' => sourceName == null ? 'Full copy' : 'Full copy of $sourceName',
        _ => 'Live workspace',
      };

  factory CampaignRow.fromJson(Map<String, dynamic> j) => CampaignRow(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Workspace'),
        kind: asStrOr(j['kind'], 'live'),
        description: asStr(j['description']),
        sourceName: asStr(j['source_name']),
        seededFrom: asStr(j['seeded_from']),
        createdByEmail: asStr(j['created_by_email']),
        createdAt: asDate(j['created_at']),
        member: asBool(j['member']),
        myRole: asStr(j['my_role']),
        peopleCount: asIntOr(j['people_count'], 0),
        itemsCount: asIntOr(j['items_count'], 0),
        canReset: asBool(j['can_reset']),
        canDelete: asBool(j['can_delete']),
        isCurrent: asBool(j['is_current']),
        openToAll: asBool(j['open_to_all'], fallback: true),
      );
}

/// Fetch the workspaces this person can reach.
Future<({List<CampaignRow> rows, bool canCreate})> loadCampaigns() async {
  final r = await Api.post('campaigns.php', 'list');
  return (
    rows: asList(r['workspaces'], CampaignRow.fromJson),
    canCreate: asBool(r['can_create']),
  );
}

/// The id of the live workspace, for "Back to Live".
Future<int?> liveWorkspaceId(BuildContext context) async {
  try {
    final r = await loadCampaigns();
    for (final w in r.rows) {
      if (w.isLive) return w.id;
    }
  } on ApiException catch (e) {
    if (context.mounted) tmToast(context, e.message, bad: true);
  }
  return null;
}

/// Move the session into [workspaceId]: a new token, a fresh config, fresh counters.
///
/// Everything cached belongs to the workspace being left — the vocabulary, the policy, the badge
/// counts — so it is all thrown away rather than carried across.
Future<bool> switchWorkspace(BuildContext context, int workspaceId) async {
  final session = context.read<Session>();
  final config = context.read<WorkspaceConfig>();
  final shell = context.read<ShellState>();
  try {
    final r = await Api.post('campaigns.php', 'switch', {'workspace_id': workspaceId});
    final token = asStr(r['token']);
    if (token == null || token.isEmpty) return true; // already there
    await session.adopt(token, User.fromJson(asMap(r['user'])));
    config.clear();
    await config.load();
    await shell.refreshCounts();
    if (context.mounted) {
      final name = asStrOr(asMap(r['workspace'])['name'], 'that workspace');
      tmToast(context, 'Now in $name');
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) tmToast(context, e.message, bad: true);
    return false;
  }
}

/// The switcher: where you are, where else you can go, and a way to make a new sandbox.
Future<void> showCampaignSwitcher(BuildContext context) async {
  await showDialog<void>(context: context, builder: (_) => const _CampaignSwitcher());
}

class _CampaignSwitcher extends StatefulWidget {
  const _CampaignSwitcher();

  @override
  State<_CampaignSwitcher> createState() => _CampaignSwitcherState();
}

class _CampaignSwitcherState extends State<_CampaignSwitcher> {
  List<CampaignRow> _rows = const [];
  bool _canCreate = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await loadCampaigns();
      if (!mounted) return;
      setState(() {
        _rows = r.rows;
        _canCreate = r.canCreate;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _switch(CampaignRow w) async {
    setState(() => _busy = true);
    final ok = await switchWorkspace(context, w.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _create() async {
    final made = await showCampaignCreate(context);
    if (made && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Workspaces'),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(height: 120, child: LoadingState())
            : _error != null
                ? SizedBox(height: 120, child: ErrorState(message: _error, onRetry: _load, compact: true))
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('A campaign is a sandbox: a workspace of its own, with its own plan. '
                          'Nothing you do in one reaches the live plan.',
                          style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                      const SizedBox(height: Sp.md),
                      for (final w in _rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Sp.sm),
                          child: _WorkspaceTile(row: w, busy: _busy, onSwitch: () => _switch(w)),
                        ),
                    ]),
                  ),
      ),
      actions: [
        if (_canCreate) SecondaryButton('New campaign…', icon: Icons.add_rounded, onPressed: _busy ? null : _create),
        PrimaryButton('Close', navy: true, onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }
}

class _WorkspaceTile extends StatelessWidget {
  const _WorkspaceTile({required this.row, required this.busy, required this.onSwitch});
  final CampaignRow row;
  final bool busy;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(
        color: row.isCurrent ? DispatchColors.tint(DispatchColors.orange, opacity: context.isDark ? 0.16 : 0.08) : null,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: context.borderColor),
      ),
      child: Row(children: [
        Icon(row.isLive ? Icons.public_rounded : Icons.science_outlined, size: 20,
            color: row.isLive ? DispatchColors.green : DispatchColors.amber),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: Sp.sm, runSpacing: Sp.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(row.name, style: context.text.titleSmall),
              ToneChip(row.isLive ? 'Live' : 'Campaign', tone: row.isLive ? 'ok' : 'warn', compact: true),
              if (row.isCurrent) const ToneChip('You are here', tone: 'info', compact: true),
            ]),
            Text(
              dotJoin([
                row.description,
                if (!row.isLive) row.madeFrom,
                '${row.peopleCount} people',
                '${row.itemsCount} items',
                row.myRole == null ? 'not joined yet' : humanise(row.myRole),
              ]),
              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        const SizedBox(width: Sp.sm),
        if (!row.isCurrent) SecondaryButton(row.member ? 'Switch' : 'Join', onPressed: busy ? null : onSwitch),
      ]),
    );
  }
}

/// Make a new campaign. Returns true when one was created and the session moved into it.
Future<bool> showCampaignCreate(BuildContext context) async {
  final made = await showDialog<bool>(context: context, builder: (_) => const _CampaignCreate());
  return made ?? false;
}

class _CampaignCreate extends StatefulWidget {
  const _CampaignCreate();

  @override
  State<_CampaignCreate> createState() => _CampaignCreateState();
}

class _CampaignCreateState extends State<_CampaignCreate> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _mode = 'full';
  bool _openToAll = true;
  bool _busy = false;
  String? _error;

  static const _modes = [
    ('full', 'A copy of this workspace', 'The people, the pipeline and the plan being worked to. The closest thing to trying something for real.'),
    ('config', 'The people and settings only', 'Work types, sizes, policy, skills, teams and people — but no work and no plan. Start a pipeline from nothing.'),
    ('demo', 'The demo dataset', 'The same worked example the documentation is written around. Good for showing somebody the app.'),
  ];

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.post('campaigns.php', 'create', {
        'name': _name.text.trim(),
        if (_description.text.trim().isNotEmpty) 'description': _description.text.trim(),
        'mode': _mode,
        'open_to_all': _openToAll,
      });
      if (!mounted) return;
      // Creating one puts you in it: the reply carries a token for the new workspace.
      final token = asStr(r['token']);
      if (token != null && token.isNotEmpty) {
        await context.read<Session>().adopt(token, User.fromJson(asMap(r['user'])));
        if (!mounted) return;
        final config = context.read<WorkspaceConfig>();
        config.clear();
        await config.load();
        if (!mounted) return;
        await context.read<ShellState>().refreshCounts();
      }
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
    return AlertDialog(
      title: const Text('New campaign'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(
              label: 'Name',
              hint: 'What this sandbox is for, e.g. "Reorg trial" or "Q3 intake".',
              child: TextField(controller: _name, autofocus: true, onChanged: (_) => setState(() {})),
            ),
            const SizedBox(height: Sp.md),
            TmField(label: 'Description (optional)', child: TextField(controller: _description, minLines: 2, maxLines: 3)),
            const SizedBox(height: Sp.md),
            Text('What it starts with', style: context.text.labelLarge?.copyWith(color: context.mutedColor)),
            const SizedBox(height: 6),
            for (final (value, title, blurb) in _modes)
              RadioListTile<String>(
                value: value,
                // ignore: deprecated_member_use
                groupValue: _mode,
                // ignore: deprecated_member_use
                onChanged: _busy ? null : (v) => setState(() => _mode = v ?? _mode),
                contentPadding: EdgeInsets.zero,
                title: Text(title, style: context.text.bodyMedium),
                subtitle: Text(blurb, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ),
            const SizedBox(height: Sp.sm),
            TmSwitchRow(
              label: 'Anyone here can join it',
              value: _openToAll,
              onChanged: _busy ? null : (v) => setState(() => _openToAll = v),
            ),
            const SizedBox(height: Sp.md),
            const TmInfoBox(
              'Secrets and outbound integrations are never copied: no webhook subscriptions, no intake sources, '
              'no device registrations. A campaign cannot post to anything real, and it is never included in the weekly digest.',
            ),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
        PrimaryButton('Create and open', navy: true, busy: _busy, onPressed: _name.text.trim().isEmpty || _busy ? null : _create),
      ],
    );
  }
}
