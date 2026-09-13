import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/models.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/widgets.dart';

/// Bulk actions on the pipeline (PIP-10): `work_items.php bulk` with
/// `retype`, `resize`, `tag`, `cancel` and `assign_owner`.

/// The five operations, in menu order. Cancel is destructive and sits last.
const wcBulkOps = <String, ({String menu, String title, IconData icon, bool destructive})>{
  'retype': (menu: 'Change the work type', title: 'Change the work type', icon: Icons.category_outlined, destructive: false),
  'resize': (menu: 'Change the size', title: 'Change the size', icon: Icons.crop_square_rounded, destructive: false),
  'tag': (menu: 'Add a tag', title: 'Add a tag', icon: Icons.sell_outlined, destructive: false),
  'assign_owner': (menu: 'Assign an owner', title: 'Assign an owner', icon: Icons.person_outline_rounded, destructive: false),
  'cancel': (menu: 'Cancel these items', title: 'Cancel these items', icon: Icons.block_rounded, destructive: true),
};

/// The bar that appears once anything is selected: how many, a way back out and
/// the action menu. Wraps on a phone rather than overflowing.
class WcBulkBar extends StatelessWidget {
  const WcBulkBar({
    super.key,
    required this.count,
    required this.total,
    required this.onClear,
    required this.onSelectAll,
    required this.onAction,
  });

  final int count;
  final int total;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;
  final void Function(String op) onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.md),
      child: DispatchCard(
        tint: DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.18 : 0.08),
        accent: DispatchColors.typeBlue,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
        child: Wrap(
          spacing: Sp.md,
          runSpacing: Sp.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.checklist_rounded, size: 18, color: DispatchColors.typeBlue),
              const SizedBox(width: Sp.sm),
              Text(
                '$count of $total selected',
                style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: context.inkColor),
              ),
            ]),
            if (count < total) TextButton(onPressed: onSelectAll, child: Text('Select all $total', maxLines: 1)),
            TextButton(onPressed: onClear, child: const Text('Clear selection', maxLines: 1)),
            PopupMenuButton<String>(
              tooltip: 'Choose a bulk action',
              onSelected: onAction,
              itemBuilder: (context) => [
                for (final e in wcBulkOps.entries)
                  PopupMenuItem(
                    value: e.key,
                    child: Row(children: [
                      Icon(e.value.icon, size: 18, color: e.value.destructive ? DispatchColors.red : context.mutedColor),
                      const SizedBox(width: Sp.sm),
                      Flexible(
                        child: Text(
                          e.value.menu,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: e.value.destructive ? const TextStyle(color: DispatchColors.red) : null,
                        ),
                      ),
                    ]),
                  ),
              ],
              child: IgnorePointer(
                child: PrimaryButton('Bulk actions', icon: Icons.playlist_add_check_rounded, navy: true, onPressed: () {}),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Runs one bulk operation over [ids]. Returns the number of items the API
/// actually changed, or null if the user backed out.
Future<int?> showWcBulkDialog(BuildContext context, {required String op, required List<int> ids}) {
  return showDialog<int>(context: context, builder: (_) => _WcBulkDialog(op: op, ids: ids));
}

class _WcBulkDialog extends StatefulWidget {
  const _WcBulkDialog({required this.op, required this.ids});
  final String op;
  final List<int> ids;

  @override
  State<_WcBulkDialog> createState() => _WcBulkDialogState();
}

class _WcBulkDialogState extends State<_WcBulkDialog> {
  final _tags = TextEditingController();
  final _reason = TextEditingController();

  int? _typeId;
  String? _stamp;
  int? _personId;
  List<Person> _people = const [];
  bool _loadingPeople = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.op == 'assign_owner') _loadPeople();
    WidgetsBinding.instance.addPostFrameCallback((_) => _primeDefaults());
  }

  void _primeDefaults() {
    if (!mounted) return;
    final cfg = context.read<WorkspaceConfig>();
    setState(() {
      _typeId ??= cfg.activeWorkTypes.isEmpty ? null : cfg.activeWorkTypes.first.id;
      _stamp ??= cfg.defaultSizeClasses.where((s) => !s.isCustom).firstOrNull?.stamp;
    });
  }

  Future<void> _loadPeople() async {
    setState(() => _loadingPeople = true);
    try {
      final r = await Api.post('people.php', 'list');
      if (!mounted) return;
      setState(() {
        _people = asList(r['people'], Person.fromJson).where((p) => p.active).toList()..sort((a, b) => a.name.compareTo(b.name));
        _personId ??= _people.isEmpty ? null : _people.first.id;
        _loadingPeople = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loadingPeople = false;
      });
    }
  }

  @override
  void dispose() {
    _tags.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// The `value` the API expects for this op, or null when it needs none.
  Object? get _value => switch (widget.op) {
        'retype' => _typeId,
        'resize' => _stamp,
        'tag' => _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
        'assign_owner' => _personId,
        _ => null,
      };

  bool get _ready => switch (widget.op) {
        'retype' => _typeId != null,
        'resize' => _stamp != null,
        'tag' => _tags.text.trim().isNotEmpty,
        'assign_owner' => _personId != null,
        _ => true,
      };

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.post('work_items.php', 'bulk', {
        'ids': widget.ids,
        'op': widget.op,
        if (_value != null) 'value': _value,
        if (widget.op == 'cancel' && _reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(asIntOr(r['updated'], widget.ids.length));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<WorkspaceConfig>();
    final spec = wcBulkOps[widget.op]!;
    final n = widget.ids.length;
    final noun = '$n ${n == 1 ? 'item' : 'items'}';

    return AlertDialog(
      title: Text(spec.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              switch (widget.op) {
                'retype' => '$noun will move to the type you choose. References keep the prefix they were given.',
                'resize' => '$noun will take the size band you choose. Estimates already recorded are left alone.',
                'tag' => 'The tag is added to $noun. Tags already carried are kept.',
                'assign_owner' => '$noun will take the owner you choose. It does not change who is scheduled on the work.',
                _ => 'Cancelling stops $noun being planned. Anything already delivered or cancelled is skipped, and every change is recorded in its history.',
              },
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: Sp.lg),
            if (widget.op == 'retype')
              DropdownButtonFormField<int>(
                initialValue: _typeId,
                decoration: const InputDecoration(labelText: 'Work type'),
                items: [for (final t in cfg.activeWorkTypes) DropdownMenuItem(value: t.id, child: Text(t.name))],
                onChanged: (v) => setState(() => _typeId = v),
              )
            else if (widget.op == 'resize')
              DropdownButtonFormField<String>(
                initialValue: _stamp,
                decoration: const InputDecoration(labelText: 'Size'),
                items: [
                  for (final s in cfg.defaultSizeClasses.where((s) => !s.isCustom))
                    DropdownMenuItem(value: s.stamp, child: Text('${s.stamp} · ${s.name}')),
                ],
                onChanged: (v) => setState(() => _stamp = v),
              )
            else if (widget.op == 'tag')
              TextField(
                controller: _tags,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Tags', hintText: 'Comma separated, for example finance, regulatory'),
              )
            else if (widget.op == 'assign_owner')
              _loadingPeople
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: Sp.md), child: LoadingState(message: 'Loading the team'))
                  : DropdownButtonFormField<int>(
                      initialValue: _personId,
                      decoration: const InputDecoration(labelText: 'Owner'),
                      items: [for (final p in _people) DropdownMenuItem(value: p.id, child: Text(p.name))],
                      onChanged: (v) => setState(() => _personId = v),
                    )
            else
              TextField(
                controller: _reason,
                decoration: const InputDecoration(labelText: 'Reason (optional)', hintText: 'Recorded against every item'),
              ),
            if (_error != null) ...[
              const SizedBox(height: Sp.md),
              ErrorState(title: 'Nothing was changed', message: _error, compact: true),
            ],
          ]),
        ),
      ),
      actions: [
        SecondaryButton(spec.destructive ? 'Keep them' : 'Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop()),
        PrimaryButton(
          switch (widget.op) {
            'retype' => 'Re-type $noun',
            'resize' => 'Re-size $noun',
            'tag' => 'Tag $noun',
            'assign_owner' => 'Assign $noun',
            _ => 'Cancel $noun',
          },
          busy: _busy,
          onPressed: _ready ? _apply : null,
        ),
      ],
    );
  }
}
