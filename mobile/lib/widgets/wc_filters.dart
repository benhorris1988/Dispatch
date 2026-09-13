import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'chips.dart';

/// The bordered filter dropdown the Pipeline toolbar is built from, lifted into
/// a shared widget so the Benefits register can wear the same control (BEN-05).
///
/// [icon] is drawn beside the selected value, never inside the menu, so a long
/// option name still reads properly when the menu is open.
class WcFilterDropdown<T> extends StatelessWidget {
  const WcFilterDropdown({
    super.key,
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
    this.icon,
    this.tooltip,
    this.maxWidth,
  });

  final T? value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final IconData? icon;
  final String? tooltip;

  /// Caps the control so a long option cannot stretch the toolbar; the value
  /// ellipsises instead. Null sizes it to its widest option, as a toolbar of
  /// short options wants.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final field = Container(
      height: 38,
      constraints: maxWidth == null ? null : BoxConstraints(maxWidth: maxWidth!),
      padding: const EdgeInsets.symmetric(horizontal: Sp.md),
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.buttonR,
        border: Border.all(color: context.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: maxWidth != null,
          hint: Text(hint, style: context.text.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
          icon: const Icon(Icons.expand_more_rounded, size: 18),
          borderRadius: DispatchRadius.cardR,
          style: context.text.labelLarge?.copyWith(color: context.inkColor),
          dropdownColor: context.panelColor,
          items: items,
          onChanged: onChanged,
          selectedItemBuilder: (context) => [
            for (final i in items)
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: context.mutedColor),
                  const SizedBox(width: Sp.sm),
                ],
                Flexible(
                  child: DefaultTextStyle(
                    style: context.text.labelLarge ?? const TextStyle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: i.child,
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
    return tooltip == null ? field : Tooltip(message: tooltip!, child: field);
  }
}

/// 'Filtered · 2 filters' with a clear action, for a filter row that can be
/// scrolled away from. Renders nothing when [count] is zero.
class WcActiveFilters extends StatelessWidget {
  const WcActiveFilters({super.key, required this.count, required this.onClear, this.label = 'filter'});

  final int count;
  final VoidCallback onClear;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ToneChip('$count $label${count == 1 ? '' : 's'} on', tone: 'accent', icon: Icons.filter_alt_rounded, compact: true),
      TextButton(onPressed: onClear, child: const Text('Clear', maxLines: 1)),
    ]);
  }
}
