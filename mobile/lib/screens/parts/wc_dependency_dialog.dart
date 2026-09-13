import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/widgets.dart';
import '../../widgets/work_widgets.dart';

/// Add a dependency to a work item (PIP-05).
///
/// `work_items.php add_dependency{from_id, to_id, type}` reads "to_id depends on
/// from_id", so the direction control decides which end this item takes:
/// *needs* puts this item at `to_id`, *unblocks* puts it at `from_id`.
/// Cycle detection answers 409, which is shown inline against the picker
/// rather than thrown away in a snackbar.
Future<bool?> showWcAddDependencyDialog(
  BuildContext context, {
  required int itemId,
  required String itemRef,
  Set<int> linkedIds = const {},
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _WcAddDependencyDialog(itemId: itemId, itemRef: itemRef, linkedIds: linkedIds),
  );
}

/// Small confirmation used before removing a dependency.
Future<bool?> showWcConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Keep it',
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 420, child: Text(message, style: dialogContext.text.bodyMedium)),
      actions: [
        SecondaryButton(cancelLabel, onPressed: () => Navigator.of(dialogContext).pop(false)),
        PrimaryButton(confirmLabel, onPressed: () => Navigator.of(dialogContext).pop(true)),
      ],
    ),
  );
}

class _WcAddDependencyDialog extends StatefulWidget {
  const _WcAddDependencyDialog({required this.itemId, required this.itemRef, required this.linkedIds});
  final int itemId;
  final String itemRef;
  final Set<int> linkedIds;

  @override
  State<_WcAddDependencyDialog> createState() => _WcAddDependencyDialogState();
}

class _WcAddDependencyDialogState extends State<_WcAddDependencyDialog> {
  final _search = TextEditingController();
  Timer? _debounce;

  /// 0 = this item needs the other; 1 = this item unblocks the other.
  int _direction = 0;
  String _type = 'finish_start';

  bool _searching = false;
  bool _searched = false;
  bool _busy = false;
  String? _error;
  String? _searchError;
  List<WorkRow> _results = const [];
  WorkRow? _chosen;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _results = const [];
        _searched = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(q.trim()));
  }

  Future<void> _run(String q) async {
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await Api.post('work_items.php', 'list', {'q': q, 'limit': 10});
      if (!mounted) return;
      final rows = (r['items'] as List?)?.whereType<Map>().map((e) => WorkRow(Map<String, dynamic>.from(e))).toList() ?? const <WorkRow>[];
      setState(() {
        _results = rows.where((w) => w.id != widget.itemId && !widget.linkedIds.contains(w.id)).toList();
        _searching = false;
        _searched = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.message;
        _searching = false;
        _searched = true;
      });
    }
  }

  Future<void> _add() async {
    final other = _chosen;
    if (other == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('work_items.php', 'add_dependency', {
        'from_id': _direction == 0 ? other.id : widget.itemId,
        'to_id': _direction == 0 ? widget.itemId : other.id,
        'type': _type,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  String get _directionNote => _direction == 0
      ? '${widget.itemRef} cannot start until the item you choose has finished.'
      : 'The item you choose cannot start until ${widget.itemRef} has finished.';

  String get _typeNote => _type == 'finish_start'
      ? 'Finish to start is a hard constraint: the scheduler will not overlap them.'
      : 'Soft is a preference. The scheduler keeps the order where it can and says so when it cannot.';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add a dependency to ${widget.itemRef}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Direction', style: context.text.titleSmall),
            const SizedBox(height: Sp.sm),
            SegmentedTabs(
              labels: const ['Needs', 'Unblocks'],
              selected: _direction,
              compact: true,
              onChanged: (i) => setState(() {
                _direction = i;
                _error = null;
              }),
            ),
            const SizedBox(height: Sp.xs),
            Text(_directionNote, style: context.text.bodySmall),
            const SizedBox(height: Sp.lg),
            Text('Kind', style: context.text.titleSmall),
            const SizedBox(height: Sp.sm),
            SegmentedTabs(
              labels: const ['Finish to start', 'Soft'],
              selected: _type == 'finish_start' ? 0 : 1,
              compact: true,
              onChanged: (i) => setState(() => _type = i == 0 ? 'finish_start' : 'soft'),
            ),
            const SizedBox(height: Sp.xs),
            Text(_typeNote, style: context.text.bodySmall),
            const SizedBox(height: Sp.lg),
            Text('The other item', style: context.text.titleSmall),
            const SizedBox(height: Sp.sm),
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search by reference or title',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : (_search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear the search',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _search.clear();
                              _onChanged('');
                            },
                          )),
              ),
            ),
            if (_chosen != null)
              Padding(
                padding: const EdgeInsets.only(top: Sp.sm),
                child: Row(children: [
                  const Icon(Icons.check_circle_rounded, size: 16, color: DispatchColors.green),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_chosen!.ref} ${_chosen!.title}',
                      style: context.text.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _chosen = null;
                      _error = null;
                    }),
                    child: const Text('Change'),
                  ),
                ]),
              ),
            if (_chosen == null && _searchError != null)
              Padding(
                padding: const EdgeInsets.only(top: Sp.sm),
                child: ErrorState(title: 'The search failed', message: _searchError, compact: true),
              )
            else if (_chosen == null && _searched && _results.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Sp.sm),
                child: Text('Nothing matches that. Try a reference such as ${widget.itemRef}, or a word from the title.',
                    style: context.text.bodySmall),
              )
            else if (_chosen == null && _results.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: Sp.sm),
                constraints: const BoxConstraints(maxHeight: 190),
                decoration: BoxDecoration(borderRadius: DispatchRadius.cardR, border: Border.all(color: context.borderColor)),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final w in _results)
                      ListTile(
                        dense: true,
                        title: Text('${w.ref} ${w.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium),
                        subtitle: Text(
                          dotJoin([w.typeName, humanise(w.displayStatus), w.neededBy == null ? null : 'due ${fmtShortDate(w.neededBy)}']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall,
                        ),
                        onTap: () => setState(() {
                          _chosen = w;
                          _results = const [];
                          _error = null;
                        }),
                      ),
                  ],
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: Sp.md),
              ErrorState(title: 'That dependency was not added', message: _error, compact: true),
            ],
          ]),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
        PrimaryButton('Add dependency', busy: _busy, onPressed: _chosen == null ? null : _add),
      ],
    );
  }
}
