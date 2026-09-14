import 'package:flutter/material.dart';

import '../models/json.dart';
import '../services/format.dart';
import '../theme/app_theme.dart';
import 'chips.dart';

/// How a benefit's worth is shown (BEN-02). A financial benefit reads as money;
/// a non-financial one reads as its qualitative scale label — the server's
/// label, never a client-side list — with "≈ £50k proxy" when a proxy value
/// stands in for it in the priority score. Money and proxy never mix.
class BenefitValueLabel extends StatelessWidget {
  const BenefitValueLabel({
    super.key,
    required this.isFinancial,
    required this.annualValue,
    this.qualitativeLabel,
    this.qualitativeScale,
    this.proxyValue,
    this.perYear = false,
    this.size = 13.5,
  });

  /// Reads the fields straight off a `Benefit` row from the API.
  BenefitValueLabel.fromJson(Map<String, dynamic> b, {super.key, this.perYear = false, this.size = 13.5})
      : isFinancial = asBool(b['is_financial'], fallback: true),
        annualValue = asDoubleOr(b['annual_value'], 0),
        qualitativeLabel = asStr(b['qualitative_label']),
        qualitativeScale = asInt(b['qualitative_scale']),
        proxyValue = asDouble(b['proxy_value']);

  final bool isFinancial;
  final double annualValue;
  final String? qualitativeLabel;
  final int? qualitativeScale;
  final double? proxyValue;
  final bool perYear;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (isFinancial) {
      return Text('${fmtMoneyK(annualValue)}${perYear ? '/yr' : ''}', style: DispatchTheme.numeric(size: size, weight: FontWeight.w800, color: context.inkColor));
    }
    // The label is the server's; fall back to the bare scale number only when
    // an older row has no label at all, and say nothing when it has no scale.
    final label = qualitativeLabel ?? (qualitativeScale == null ? 'Non-financial' : 'Scale $qualitativeScale of 5');
    return Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      ToneChip(label, tone: 'info', icon: Icons.auto_awesome_outlined, compact: true),
      if (proxyValue != null && proxyValue! > 0)
        Text('≈ ${fmtMoneyK(proxyValue)} proxy', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
    ]);
  }
}

/// "+ 2 non-financial (≈ £75k proxy)" — the register's secondary figure beside
/// a financial total. Empty when there are none.
String nonFinancialNote(int count, num proxyTotal) {
  if (count <= 0) return '';
  final proxy = proxyTotal > 0 ? ' (≈ ${fmtMoneyK(proxyTotal)} proxy)' : '';
  return '+ $count non-financial$proxy';
}
