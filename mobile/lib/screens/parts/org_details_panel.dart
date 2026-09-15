import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/org.dart';
import '../../services/format.dart';
import '../../shell/nav.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';
import 'org_dialogs.dart';

/// What the chart shows about whatever is selected: a side panel on a wide
/// screen, a bottom sheet on a narrow one. It is also where the things that are
/// awkward to drag happen — setting a manager, restricting a team, deleting one.
class OrgDetailsPanel extends StatelessWidget {
  const OrgDetailsPanel({
    super.key,
    required this.tree,
    this.team,
    this.person,
    required this.onClose,
    required this.onSelectTeam,
    required this.onSelectPerson,
    required this.onEditTeam,
    required this.onAddSubTeam,
    required this.onDeleteTeam,
    required this.onVisibility,
    required this.onSetManager,
    required this.onMovePerson,
    this.sheet = false,
  });

  final OrgTree tree;
  final OrgTeam? team;
  final OrgPerson? person;
  final VoidCallback onClose;
  final void Function(OrgTeam) onSelectTeam;
  final void Function(OrgPerson) onSelectPerson;
  final void Function(OrgTeam) onEditTeam;
  final void Function(OrgTeam) onAddSubTeam;
  final void Function(OrgTeam) onDeleteTeam;
  final void Function(OrgTeam) onVisibility;
  final void Function(OrgPerson, int?) onSetManager;
  final void Function(OrgPerson) onMovePerson;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final body = team != null ? _TeamBody(this) : (person != null ? _PersonBody(this) : const SizedBox.shrink());
    if (sheet) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.md, Sp.lg, Sp.lg),
          child: SingleChildScrollView(child: body),
        ),
      );
    }
    return Container(
      width: 340,
      margin: const EdgeInsets.only(left: Sp.lg),
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(padding: const EdgeInsets.all(Sp.lg), child: body),
    );
  }
}

class _TeamBody extends StatelessWidget {
  const _TeamBody(this.p);
  final OrgDetailsPanel p;

  @override
  Widget build(BuildContext context) {
    final t = p.team!;
    final canEdit = p.tree.canEdit(t.id);
    final path = p.tree.pathOf(t.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(t.name, style: context.text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis)),
        IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: p.onClose, tooltip: 'Close'),
      ]),
      if (path != t.name)
        Text(path, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
      if (t.description != null && t.description!.isNotEmpty) ...[
        const SizedBox(height: Sp.sm),
        Text(t.description!, style: context.text.bodyMedium),
      ],
      const SizedBox(height: Sp.lg),
      TmKeyValue(
        'Lead',
        null,
        valueWidget: t.lead == null
            ? Text('Nobody yet', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                PersonAvatar(t.lead!.initialsOrDerived, colourHex: t.lead!.colourHex, seed: t.lead!.id, size: 22),
                const SizedBox(width: Sp.sm),
                Flexible(child: Text(t.lead!.name, style: context.text.bodyMedium, overflow: TextOverflow.ellipsis)),
              ]),
      ),
      TmKeyValue('People', null, valueWidget: Text(
        t.headcountAll == t.headcount ? '${t.headcount}' : '${t.headcount} here, ${t.headcountAll} including sub-teams',
        style: context.text.bodyMedium,
      )),
      TmKeyValue('Load, next 4 weeks', null, valueWidget: TmLoadBar(t.loadPct.toDouble(), width: 70)),
      TmKeyValue(
        'Visible to',
        null,
        valueWidget: t.isRestricted
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const ToneChip('Restricted', compact: true, icon: Icons.lock_outline_rounded),
                if (t.visibilityReason != null) ...[
                  const SizedBox(height: 4),
                  Text(t.visibilityReason!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                ],
              ])
            : Text('Everyone', style: context.text.bodyMedium),
      ),
      if (t.children.isNotEmpty) ...[
        const SectionLabel('Sub-teams'),
        for (final c in t.children)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(c.restricted ? Icons.lock_outline_rounded : Icons.account_tree_outlined, size: 18, color: context.mutedColor),
            title: Text(c.name, style: context.text.bodyMedium, overflow: TextOverflow.ellipsis),
            subtitle: c.restricted ? null : Text('${c.headcountAll} people', style: context.text.bodySmall),
            onTap: () => p.onSelectTeam(c),
          ),
      ],
      if (t.people.isNotEmpty) ...[
        SectionLabel('People (${t.people.length})'),
        for (final person in t.people)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 26),
            title: Text(person.name, style: context.text.bodyMedium, overflow: TextOverflow.ellipsis),
            subtitle: Text(dotJoin([person.roleTitle, person.roleFamilyName]), style: context.text.bodySmall, overflow: TextOverflow.ellipsis),
            onTap: () => p.onSelectPerson(person),
          ),
      ],
      if (canEdit) ...[
        const SizedBox(height: Sp.lg),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          SecondaryButton('Edit', icon: Icons.edit_outlined, onPressed: () => p.onEditTeam(t)),
          SecondaryButton('Add sub-team', icon: Icons.add_rounded, onPressed: () => p.onAddSubTeam(t)),
          SecondaryButton(t.isRestricted ? 'Visibility' : 'Restrict', icon: Icons.lock_outline_rounded, onPressed: () => p.onVisibility(t)),
          SecondaryButton(
            'Delete',
            icon: Icons.delete_outline_rounded,
            danger: true,
            // The API refuses while anything depends on the team; saying why
            // here beats an error a second after the tap.
            onPressed: t.children.isEmpty && t.people.isEmpty ? () => p.onDeleteTeam(t) : null,
          ),
        ]),
        if (t.children.isNotEmpty || t.people.isNotEmpty) ...[
          const SizedBox(height: Sp.sm),
          Text('Move its people and sub-teams elsewhere before deleting it.',
              style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ],
      ],
    ]);
  }
}

class _PersonBody extends StatelessWidget {
  const _PersonBody(this.p);
  final OrgDetailsPanel p;

  @override
  Widget build(BuildContext context) {
    final person = p.person!;
    final home = p.tree.homeTeamOf(person.id);
    final canEdit = p.tree.canEdit(person.teamId);
    final candidates = orgPeopleOf(p.tree).where((x) => x.id != person.id).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 44),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(person.name, style: context.text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (person.roleTitle != null) Text(person.roleTitle!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: p.onClose, tooltip: 'Close'),
      ]),
      const SizedBox(height: Sp.lg),
      TmKeyValue('Team', null, valueWidget: Text(home?.name ?? 'No team', style: context.text.bodyMedium)),
      TmKeyValue(
        'Role family',
        null,
        valueWidget: person.roleFamilyName == null
            ? Text('None', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
            : ToneChip(person.roleFamilyName!, compact: true, tone: 'info'),
      ),
      TmKeyValue('Load, next 4 weeks', null, valueWidget: TmLoadBar(person.loadPct.toDouble(), width: 70)),
      if (person.onLoanTo != null)
        TmKeyValue('On loan to', null, valueWidget: Text('${person.onLoanTo!.toTeamName} · ${person.onLoanTo!.allocationPct}%', style: context.text.bodyMedium)),
      const SizedBox(height: Sp.md),
      TmField(
        label: 'Reports to',
        child: canEdit
            ? DropdownButtonFormField<int?>(
                initialValue: candidates.any((c) => c.id == person.managerPersonId) ? person.managerPersonId : null,
                isExpanded: true,
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Nobody')),
                  for (final c in candidates)
                    DropdownMenuItem<int?>(
                      value: c.id,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        PersonAvatar(c.initialsOrDerived, colourHex: c.colourHex, seed: c.id, size: 20),
                        const SizedBox(width: Sp.sm),
                        Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ],
                selectedItemBuilder: (context) => [
                  const Text('Nobody'),
                  for (final c in candidates) Text(c.name, overflow: TextOverflow.ellipsis),
                ],
                onChanged: (v) => p.onSetManager(person, v),
              )
            : Text(person.managerName ?? 'Nobody', style: context.text.bodyMedium),
      ),
      const SizedBox(height: Sp.lg),
      Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
        SecondaryButton(
          'Open profile',
          icon: Icons.open_in_new_rounded,
          onPressed: () => context.go(Routes.person(person.id)),
        ),
        if (canEdit) SecondaryButton('Move to…', icon: Icons.drive_file_move_outlined, onPressed: () => p.onMovePerson(person)),
      ]),
    ]);
  }
}
