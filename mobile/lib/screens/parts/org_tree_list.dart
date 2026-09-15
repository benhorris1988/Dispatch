import 'package:flutter/material.dart';

import '../../models/org.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// The chart as an indented list: the phone view, and an alternative on a wide
/// screen for anybody who would rather read than pan.
///
/// Nothing is dragged here. Dragging a card around a 390-pixel screen is a poor
/// way to reorganise anything, so each row carries a menu instead and the moves
/// go through a team picker — the same API calls either way.
class OrgTreeList extends StatelessWidget {
  const OrgTreeList({
    super.key,
    required this.tree,
    required this.collapsed,
    required this.showPeople,
    required this.onToggleCollapse,
    required this.onSelectTeam,
    required this.onSelectPerson,
    required this.onEditTeam,
    required this.onAddSubTeam,
    required this.onDeleteTeam,
    required this.onVisibility,
    required this.onMoveTeamTo,
    required this.onMovePersonTo,
    required this.onSetManagerFor,
    this.roleFamilyFilter,
    this.selectedTeamId,
    this.selectedPersonId,
  });

  final OrgTree tree;
  final Set<int> collapsed;
  final bool showPeople;
  final void Function(int teamId) onToggleCollapse;
  final void Function(OrgTeam) onSelectTeam;
  final void Function(OrgPerson) onSelectPerson;
  final void Function(OrgTeam) onEditTeam;
  final void Function(OrgTeam) onAddSubTeam;
  final void Function(OrgTeam) onDeleteTeam;
  final void Function(OrgTeam) onVisibility;
  final void Function(OrgTeam) onMoveTeamTo;
  final void Function(OrgPerson) onMovePersonTo;
  final void Function(OrgPerson) onSetManagerFor;
  final int? roleFamilyFilter;
  final int? selectedTeamId;
  final int? selectedPersonId;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void walk(OrgTeam t, int depth) {
      rows.add(Padding(
        padding: EdgeInsets.only(left: 16.0 * depth, bottom: Sp.sm),
        child: _TeamRow(
          team: t,
          tree: tree,
          depth: depth,
          collapsed: collapsed.contains(t.id),
          selected: selectedTeamId == t.id,
          onToggleCollapse: () => onToggleCollapse(t.id),
          onTap: () => onSelectTeam(t),
          onEdit: () => onEditTeam(t),
          onAddSubTeam: () => onAddSubTeam(t),
          onDelete: () => onDeleteTeam(t),
          onVisibility: () => onVisibility(t),
          onMove: () => onMoveTeamTo(t),
        ),
      ));
      if (collapsed.contains(t.id)) return;
      if (showPeople) {
        for (final p in t.people) {
          rows.add(Padding(
            padding: EdgeInsets.only(left: 16.0 * depth + 20, bottom: 4),
            child: _PersonRow(
              person: p,
              tree: tree,
              faded: roleFamilyFilter != null && p.roleFamilyId != roleFamilyFilter,
              selected: selectedPersonId == p.id,
              onTap: () => onSelectPerson(p),
              onMove: () => onMovePersonTo(p),
              onSetManager: () => onSetManagerFor(p),
            ),
          ));
        }
      }
      for (final c in t.children) {
        walk(c, depth + 1);
      }
    }

    for (final r in tree.roots) {
      walk(r, 0);
    }
    if (tree.unassigned.isNotEmpty) {
      rows.add(const SectionLabel('Nobody\'s team'));
      for (final p in tree.unassigned) {
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _PersonRow(
            person: p,
            tree: tree,
            faded: roleFamilyFilter != null && p.roleFamilyId != roleFamilyFilter,
            selected: selectedPersonId == p.id,
            onTap: () => onSelectPerson(p),
            onMove: () => onMovePersonTo(p),
            onSetManager: () => onSetManagerFor(p),
          ),
        ));
      }
    }
    return ListView(padding: const EdgeInsets.only(bottom: Sp.xxl), children: rows);
  }
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({
    required this.team,
    required this.tree,
    required this.depth,
    required this.collapsed,
    required this.selected,
    required this.onToggleCollapse,
    required this.onTap,
    required this.onEdit,
    required this.onAddSubTeam,
    required this.onDelete,
    required this.onVisibility,
    required this.onMove,
  });

  final OrgTeam team;
  final OrgTree tree;
  final int depth;
  final bool collapsed;
  final bool selected;
  final VoidCallback onToggleCollapse, onTap, onEdit, onAddSubTeam, onDelete, onVisibility, onMove;

  @override
  Widget build(BuildContext context) {
    if (team.restricted) {
      return DashedBox(
        child: Padding(
          padding: const EdgeInsets.all(Sp.md),
          child: Row(children: [
            Icon(Icons.lock_outline_rounded, size: 16, color: context.mutedColor),
            const SizedBox(width: Sp.sm),
            Expanded(child: Text(team.name, style: context.text.titleSmall?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis)),
            Text('Restricted', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          ]),
        ),
      );
    }
    final canEdit = tree.canEdit(team.id);
    return DispatchCard(
      onTap: onTap,
      accent: selected ? DispatchColors.orange : null,
      padding: const EdgeInsets.fromLTRB(Sp.sm, Sp.sm, Sp.xs, Sp.sm),
      child: Row(children: [
        SizedBox(
          width: 28,
          child: team.children.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded, size: 20, color: context.mutedColor),
                  tooltip: collapsed ? 'Show sub-teams' : 'Hide sub-teams',
                  onPressed: onToggleCollapse,
                ),
        ),
        if (team.lead != null) ...[
          PersonAvatar(team.lead!.initialsOrDerived, colourHex: team.lead!.colourHex, seed: team.lead!.id, size: 24, tooltip: '${team.lead!.name} leads this team'),
          const SizedBox(width: Sp.sm),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Flexible(child: Text(team.name, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (team.isRestricted) ...[
                const SizedBox(width: Sp.xs),
                Icon(Icons.lock_outline_rounded, size: 13, color: context.mutedColor),
              ],
            ]),
            Text(
              team.headcountAll == team.headcount ? '${team.headcount} people' : '${team.headcount} here · ${team.headcountAll} in all',
              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        TmLoadBar(team.loadPct.toDouble(), width: 34),
        if (canEdit)
          PopupMenuButton<String>(
            tooltip: 'Team actions',
            icon: Icon(Icons.more_vert_rounded, size: 18, color: context.mutedColor),
            onSelected: (v) => switch (v) {
              'edit' => onEdit(),
              'add' => onAddSubTeam(),
              'move' => onMove(),
              'visibility' => onVisibility(),
              'delete' => onDelete(),
              _ => null,
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'add', child: Text('Add sub-team')),
              const PopupMenuItem(value: 'move', child: Text('Move…')),
              PopupMenuItem(value: 'visibility', child: Text(team.isRestricted ? 'Visibility…' : 'Restrict…')),
              PopupMenuItem(
                value: 'delete',
                enabled: team.children.isEmpty && team.people.isEmpty,
                child: const Text('Delete'),
              ),
            ],
          ),
      ]),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.person,
    required this.tree,
    required this.faded,
    required this.selected,
    required this.onTap,
    required this.onMove,
    required this.onSetManager,
  });

  final OrgPerson person;
  final OrgTree tree;
  final bool faded;
  final bool selected;
  final VoidCallback onTap, onMove, onSetManager;

  @override
  Widget build(BuildContext context) {
    final canEdit = tree.canEdit(person.teamId);
    final row = InkWell(
      onTap: onTap,
      borderRadius: DispatchRadius.chipR,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.sm, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? DispatchColors.tint(DispatchColors.orange, opacity: 0.14) : null,
          borderRadius: DispatchRadius.chipR,
        ),
        child: Row(children: [
          PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 22),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(person.name, style: context.text.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(dotJoin([person.roleTitle, person.roleFamilyName]), style: context.text.bodySmall?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (person.onLoanTo != null)
            Tooltip(message: 'On loan to ${person.onLoanTo!.toTeamName}', child: Icon(Icons.swap_horiz_rounded, size: 14, color: DispatchColors.amber)),
          if (canEdit)
            PopupMenuButton<String>(
              tooltip: 'Person actions',
              icon: Icon(Icons.more_vert_rounded, size: 16, color: context.mutedColor),
              onSelected: (v) => switch (v) {
                'move' => onMove(),
                'manager' => onSetManager(),
                _ => null,
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'move', child: Text('Move to another team…')),
                PopupMenuItem(value: 'manager', child: Text('Set who they report to…')),
              ],
            ),
        ]),
      ),
    );
    return faded ? Opacity(opacity: 0.4, child: row) : row;
  }
}
