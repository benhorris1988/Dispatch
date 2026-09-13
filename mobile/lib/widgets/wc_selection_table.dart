import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'work_widgets.dart';

/// A [DispatchTable] with a leading checkbox column and a select-all checkbox
/// in the header, for bulk actions on the pipeline (PIP-10).
///
/// It deliberately mirrors DispatchTable's chrome — same header tint, same row
/// padding and dividers, same horizontal-scroll fallback below [minWidth] — so
/// a selectable table and a plain one look identical apart from the column.
class WcSelectionTable extends StatelessWidget {
  const WcSelectionTable({
    super.key,
    required this.columns,
    required this.rows,
    required this.isSelected,
    required this.onSelect,
    required this.onSelectAll,
    this.onRowTap,
    this.rowSemantics,
    this.rowLabel,
    this.minWidth = 720,
  });

  final List<TableCol> columns;
  final List<List<Widget>> rows;

  /// Selection state by row index.
  final bool Function(int index) isSelected;
  final void Function(int index, bool selected) onSelect;

  /// Null when the header checkbox is in its indeterminate state.
  final void Function(bool selectAll) onSelectAll;

  final void Function(int index)? onRowTap;
  final String Function(int index)? rowSemantics;

  /// Accessible name for one row's checkbox, e.g. 'WI-1042 Fleet telemetry'.
  final String Function(int index)? rowLabel;

  final double minWidth;

  static const double _checkWidth = 44;

  bool get _allSelected => rows.isNotEmpty && List.generate(rows.length, isSelected).every((s) => s);
  bool get _noneSelected => !List.generate(rows.length, isSelected).any((s) => s);

  Widget _cell(BuildContext context, TableCol c, Widget child) {
    final aligned = Align(alignment: c.alignRight ? Alignment.centerRight : Alignment.centerLeft, child: child);
    return c.width != null ? SizedBox(width: c.width, child: aligned) : Expanded(flex: c.flex, child: aligned);
  }

  @override
  Widget build(BuildContext context) {
    final header = Container(
      color: context.scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
      child: Row(children: [
        SizedBox(
          width: _checkWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Checkbox(
              value: _noneSelected ? false : (_allSelected ? true : null),
              tristate: true,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              semanticLabel: _allSelected ? 'Clear the selection' : 'Select every row',
              onChanged: rows.isEmpty ? null : (_) => onSelectAll(!_allSelected),
            ),
          ),
        ),
        for (final c in columns)
          _cell(context, c, Text(c.label, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
      ]),
    );

    final body = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final cells = rows[i];
      final index = i;
      final selected = isSelected(index);
      Widget row = Container(
        color: selected ? DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.18 : 0.07) : null,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.md),
        child: Row(children: [
          SizedBox(
            width: _checkWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Checkbox(
                value: selected,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                semanticLabel: rowLabel?.call(index),
                onChanged: (v) => onSelect(index, v ?? false),
              ),
            ),
          ),
          for (var c = 0; c < columns.length; c++)
            _cell(context, columns[c], c < cells.length ? cells[c] : const SizedBox.shrink()),
        ]),
      );
      if (onRowTap != null) {
        row = InkWell(onTap: () => onRowTap!(index), child: row);
        row = Semantics(button: true, label: rowSemantics?.call(index), child: row);
      }
      body.add(row);
      if (i < rows.length - 1) body.add(Divider(height: 1, color: context.borderColor));
    }

    final table = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...body]);

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= minWidth) return table;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: minWidth, child: table),
      );
    });
  }
}
