import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/dispatch_logo.dart';
import '../widgets/person_avatar.dart';
import 'nav.dart';

/// Dark navy left sidebar. Full width (280) with labels, or a 72px icon rail
/// when [collapsed].
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.location, this.collapsed = false});
  final String location;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final shell = context.watch<ShellState>();
    final width = collapsed ? ShellDims.sidebarRail : ShellDims.sidebarWide;

    return Container(
      width: width,
      color: DispatchColors.sidebar,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(collapsed ? 14 : 20, 22, collapsed ? 14 : 20, 24),
          child: collapsed
              ? const Tooltip(message: 'Dispatch', child: DispatchMark(size: 44))
              : const Align(alignment: Alignment.centerLeft, child: DispatchLogo(size: 44)),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 12 : 16),
            children: [
              for (final group in Nav.sidebar) ...[
                if (group.label != null && group.items.any((i) => session.can(i.minRole)))
                  Padding(
                    padding: EdgeInsets.only(top: 22, bottom: 8, left: collapsed ? 0 : 16),
                    child: collapsed
                        ? Divider(color: Colors.white.withValues(alpha: 0.1))
                        : Text(group.label!, style: DispatchTheme.inter(fontSize: 12, fontWeight: FontWeight.w600, color: DispatchColors.sidebarMuted, letterSpacing: 0.2)),
                  ),
                for (final item in group.items)
                  if (session.can(item.minRole))
                    _SidebarTile(
                      item: item,
                      selected: item.matches(location),
                      collapsed: collapsed,
                      badge: item.badge ? shell.pendingChanges : 0,
                      onTap: () => context.go(item.path),
                    ),
              ],
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(collapsed ? 12 : 16, 0, collapsed ? 12 : 16, 16),
          child: Column(children: [
            Divider(color: Colors.white.withValues(alpha: 0.1)),
            const SizedBox(height: 8),
            _UserMenu(collapsed: collapsed),
          ]),
        ),
      ]),
    );
  }
}

class _SidebarTile extends StatefulWidget {
  const _SidebarTile({required this.item, required this.selected, required this.collapsed, required this.onTap, this.badge = 0});
  final NavItem item;
  final bool selected, collapsed;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final fg = sel ? Colors.white : DispatchColors.sidebarText;
    final bg = sel ? DispatchColors.sidebarActive : (_hover ? Colors.white.withValues(alpha: 0.06) : Colors.transparent);

    final badge = widget.badge > 0
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            constraints: const BoxConstraints(minWidth: 22),
            decoration: BoxDecoration(color: DispatchColors.orange, borderRadius: BorderRadius.circular(999)),
            child: Text('${widget.badge}', textAlign: TextAlign.center, style: DispatchTheme.manrope(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
          )
        : null;

    Widget tile = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.only(bottom: 4),
            height: 48,
            padding: EdgeInsets.symmetric(horizontal: widget.collapsed ? 0 : 14),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(DispatchRadius.card)),
            child: widget.collapsed
                ? Center(
                    child: Stack(clipBehavior: Clip.none, children: [
                      Icon(sel ? widget.item.selectedIcon : widget.item.icon, color: fg, size: 22),
                      if (widget.badge > 0)
                        Positioned(right: -6, top: -6, child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: DispatchColors.orange, shape: BoxShape.circle))),
                    ]),
                  )
                : Row(children: [
                    Icon(sel ? widget.item.selectedIcon : widget.item.icon, color: fg, size: 22),
                    const SizedBox(width: 14),
                    Expanded(child: Text(widget.item.label, style: DispatchTheme.inter(fontSize: 15, fontWeight: sel ? FontWeight.w600 : FontWeight.w500, color: fg))),
                    ?badge,
                  ]),
          ),
          // Orange active marker on the left edge.
          if (sel)
            Positioned(
              left: widget.collapsed ? -12 : -16,
              top: 12,
              child: Container(width: 3, height: 24, decoration: const BoxDecoration(color: DispatchColors.orange, borderRadius: BorderRadius.horizontal(right: Radius.circular(3)))),
            ),
        ]),
      ),
    );
    if (widget.collapsed) tile = Tooltip(message: widget.item.label, waitDuration: const Duration(milliseconds: 300), child: tile);
    return tile;
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu({required this.collapsed});
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    if (user == null) return const SizedBox.shrink();

    final avatar = PersonAvatar(user.initials, colourHex: user.colour, seed: user.id, size: 40);
    return PopupMenuButton<String>(
      tooltip: 'Account',
      position: PopupMenuPosition.over,
      offset: const Offset(0, -8),
      onSelected: (v) async {
        switch (v) {
          case 'profile':
            if (user.personId != null) context.go(Routes.person(user.personId!));
          case 'notifications':
            context.go(Routes.notifications);
          case 'switch':
            await session.signOut();
          case 'signout':
            await session.signOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, child: Text(user.email, style: Theme.of(context).textTheme.bodySmall)),
        const PopupMenuDivider(),
        if (user.personId != null) const PopupMenuItem(value: 'profile', child: ListTile(dense: true, leading: Icon(Icons.person_outline_rounded), title: Text('My profile'))),
        const PopupMenuItem(value: 'notifications', child: ListTile(dense: true, leading: Icon(Icons.notifications_none_rounded), title: Text('Notifications'))),
        const PopupMenuItem(value: 'switch', child: ListTile(dense: true, leading: Icon(Icons.swap_horiz_rounded), title: Text('Switch user'))),
        const PopupMenuItem(value: 'signout', child: ListTile(dense: true, leading: Icon(Icons.logout_rounded), title: Text('Sign out'))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: collapsed
            ? Center(child: avatar)
            : Row(children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(_shortName(user.displayName, user.shortName), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: DispatchTheme.inter(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                    Text(user.roleTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: DispatchTheme.inter(fontSize: 13, color: DispatchColors.sidebarMuted)),
                  ]),
                ),
                const Icon(Icons.unfold_more_rounded, color: DispatchColors.sidebarMuted, size: 20),
              ]),
      ),
    );
  }

  /// 'Ben A.' style: first name + initial of surname.
  static String _shortName(String display, String? short) {
    if (short != null && short.isNotEmpty) return short;
    final parts = display.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return display;
    return '${parts.first} ${parts.last[0]}.';
  }
}
