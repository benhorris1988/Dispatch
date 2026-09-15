import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/parts/campaign_dialogs.dart';
import '../services/format.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';

/// A strip across the top of every screen while the session is in a campaign.
///
/// The whole risk of sandboxes is somebody making a decision in one and thinking it landed in the
/// plan, so this is deliberately hard to miss and present on every screen rather than only on the
/// one where you switched. In the live workspace it renders nothing at all.
class CampaignBanner extends StatelessWidget {
  const CampaignBanner({super.key, this.compact = false});

  /// Phone layout: one line, no description.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<Session>().user?.workspace;
    if (ws == null || !ws.isCampaign) return const SizedBox.shrink();

    final source = switch (ws.seededFrom) {
      'demo' => 'built from the demo dataset',
      'config' => 'set up with the people and settings only',
      _ => 'copied from the live workspace',
    };
    final text = 'Campaign · ${ws.name}';
    final sub = compact ? null : '$source. Nothing you do here changes the live plan.';

    return Material(
      color: DispatchColors.amber.withValues(alpha: context.isDark ? 0.18 : 0.14),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: compact ? Sp.md : Sp.lg, vertical: compact ? 6 : Sp.sm),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: DispatchColors.amber.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          const Icon(Icons.science_outlined, size: 18, color: DispatchColors.amber),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(dotJoin([text, if (compact) 'sandbox']), style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (sub != null)
                Text(sub, style: context.text.bodySmall?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: Sp.sm),
          SecondaryButton('Back to Live', icon: Icons.logout_rounded, onPressed: () => _backToLive(context)),
        ]),
      ),
    );
  }

  static Future<void> _backToLive(BuildContext context) async {
    final target = await liveWorkspaceId(context);
    if (target == null || !context.mounted) return;
    final ok = await switchWorkspace(context, target);
    if (ok && context.mounted) context.go('/');
  }
}
