import 'package:flutter/material.dart';

import '../../models/org.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// The dialogs the organisation chart opens (ORG-01..05). Each one returns true
/// when something was changed, so the caller reloads.

/// Add or rename a team, set its lead and where it sits.
Future<bool> showOrgTeamDialog(BuildContext context, {required OrgTree tree, OrgTeam? team, int? parentId}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => _TeamDialog(tree: tree, team: team, parentId: parentId),
  );
  return r ?? false;
}

class _TeamDialog extends StatefulWidget {
  const _TeamDialog({required this.tree, this.team, this.parentId});
  final OrgTree tree;
  final OrgTeam? team;
  final int? parentId;

  @override
  State<_TeamDialog> createState() => _TeamDialogState();
}

class _TeamDialogState extends State<_TeamDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.team?.name ?? '');
  late final TextEditingController _description = TextEditingController(text: widget.team?.description ?? '');
  late int? _parent = widget.team?.parentTeamId ?? widget.parentId;
  late int? _lead = widget.team?.leadPersonId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'A team needs a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('org.php', 'save_team', {
        if (widget.team != null) 'id': widget.team!.id,
        'name': _name.text.trim(),
        'parent_team_id': _parent,
        'lead_person_id': _lead,
        'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.team != null;
    // A team cannot be moved inside itself or its own sub-tree; offering those
    // options and then showing a 409 would be a worse way to say so.
    final forbidden = editing ? widget.tree.descendantsOf(widget.team!.id) : <int>{};
    final options = widget.tree.flat.where((t) => !forbidden.contains(t.id) && widget.tree.canEdit(t.id)).toList();
    final people = _peopleOf(widget.tree);
    return AlertDialog(
      title: Text(editing ? 'Edit ${widget.team!.name}' : 'Add a team'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(label: 'Name', child: TextField(controller: _name, autofocus: !editing, decoration: const InputDecoration(hintText: 'Platform engineering'))),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Sits under',
              hint: widget.tree.canEditAll ? 'Leave empty for a team at the top of the organisation.' : null,
              child: DropdownButtonFormField<int?>(
                initialValue: options.any((t) => t.id == _parent) ? _parent : null,
                isExpanded: true,
                items: [
                  if (widget.tree.canEditAll) const DropdownMenuItem<int?>(value: null, child: Text('Top of the organisation')),
                  for (final t in options)
                    DropdownMenuItem<int?>(
                      value: t.id,
                      child: Padding(
                        padding: EdgeInsets.only(left: 12.0 * widget.tree.depthOf(t.id)),
                        child: Text(t.name, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                ],
                selectedItemBuilder: (context) => [
                  if (widget.tree.canEditAll) const Text('Top of the organisation'),
                  for (final t in options) Text(t.name, overflow: TextOverflow.ellipsis),
                ],
                onChanged: (v) => setState(() => _parent = v),
              ),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Lead',
              child: DropdownButtonFormField<int?>(
                initialValue: people.any((p) => p.id == _lead) ? _lead : null,
                isExpanded: true,
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('No lead yet')),
                  for (final p in people)
                    DropdownMenuItem<int?>(
                      value: p.id,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        PersonAvatar(p.initialsOrDerived, colourHex: p.colourHex, seed: p.id, size: 20),
                        const SizedBox(width: Sp.sm),
                        Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ],
                selectedItemBuilder: (context) => [
                  const Text('No lead yet'),
                  for (final p in people) Text(p.name, overflow: TextOverflow.ellipsis),
                ],
                onChanged: (v) => setState(() => _lead = v),
              ),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'What it does',
              child: TextField(controller: _description, minLines: 2, maxLines: 3, decoration: const InputDecoration(hintText: 'Optional. One line is plenty.')),
            ),
            if (_error != null) ...[const SizedBox(height: Sp.md), TmInlineError(_error!)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton(editing ? 'Save' : 'Add team', busy: _busy, onPressed: _busy ? null : _save),
      ],
    );
  }
}

/// Restrict a team, or lift a restriction (ORG-04). Restricting needs a reason,
/// and the reason is about the work — never about a person (ADM-05).
Future<bool> showOrgVisibilityDialog(BuildContext context, OrgTeam team) async {
  final r = await showDialog<bool>(context: context, builder: (_) => _VisibilityDialog(team: team));
  return r ?? false;
}

class _VisibilityDialog extends StatefulWidget {
  const _VisibilityDialog({required this.team});
  final OrgTeam team;

  @override
  State<_VisibilityDialog> createState() => _VisibilityDialogState();
}

class _VisibilityDialogState extends State<_VisibilityDialog> {
  late String _visibility = widget.team.visibility;
  late final TextEditingController _reason = TextEditingController(text: widget.team.visibilityReason ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('org.php', 'set_visibility', {
        'team_id': widget.team.id,
        'visibility': _visibility,
        'reason': _reason.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Who can see ${widget.team.name}?'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          RadioGroup<String>(
            groupValue: _visibility,
            onChanged: (v) => setState(() => _visibility = v ?? 'everyone'),
            child: const Column(mainAxisSize: MainAxisSize.min, children: [
              RadioListTile<String>(
                value: 'everyone',
                title: Text('Everyone'),
                subtitle: Text('Anybody signed in can see the team and who is in it.'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'restricted',
                title: Text('Restricted'),
                subtitle: Text('Everyone still sees that the team exists and where it sits. Only its leads and the people inside it see its members.'),
                contentPadding: EdgeInsets.zero,
              ),
            ]),
          ),
          if (_visibility == 'restricted') ...[
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Why',
              hint: 'A reason about the work — a reorganisation not yet announced, say. Never about a person.',
              child: TextField(controller: _reason, autofocus: true, minLines: 2, maxLines: 3),
            ),
          ],
          if (_error != null) ...[const SizedBox(height: Sp.md), TmInlineError(_error!)],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _busy ? null : _save),
      ],
    );
  }
}

/// Moving somebody changes which team's capacity they count towards, which is a
/// planning decision and not a tidy-up. Say so before doing it.
Future<bool> confirmOrgMovePerson(BuildContext context, {required OrgPerson person, String? from, required String to}) {
  return showTmConfirm(
    context,
    title: 'Move ${person.name} to $to?',
    message: '${person.firstName} leaves ${from ?? 'no team'} and joins $to. Committed work stays with them, '
        'but from now on their time counts towards $to, so both teams\' load figures change. Any loan stays as it is.',
    confirmLabel: 'Move',
  );
}

/// A team can only go when nothing depends on it.
Future<bool> confirmOrgDeleteTeam(BuildContext context, OrgTeam team) {
  return showTmConfirm(
    context,
    title: 'Delete ${team.name}?',
    message: 'The team is removed from the organisation. Its people and any sub-teams have to be moved somewhere else first.',
    confirmLabel: 'Delete',
    danger: true,
  );
}

/// Pick a team, for the list view where there is nothing to drag onto.
Future<OrgTeamPick?> showOrgTeamPicker(
  BuildContext context, {
  required OrgTree tree,
  required String title,
  Set<int> exclude = const {},
  bool allowNone = false,
  String noneLabel = 'No team',
}) {
  final options = tree.flat.where((t) => !exclude.contains(t.id) && tree.canEdit(t.id)).toList();
  return showDialog<OrgTeamPick>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        if (allowNone)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(const OrgTeamPick(null, 'no team')),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(noneLabel, style: context.text.bodyLarge)),
          ),
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.all(Sp.lg),
            child: Text('There is nowhere you can move this to.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
          ),
        for (final t in options)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(OrgTeamPick(t.id, t.name)),
            child: Padding(
              padding: EdgeInsets.only(left: 16.0 * tree.depthOf(t.id), top: 6, bottom: 6),
              child: Row(children: [
                Icon(Icons.groups_outlined, size: 16, color: context.mutedColor),
                const SizedBox(width: Sp.sm),
                Flexible(child: Text(t.name, style: context.text.bodyLarge, overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
      ],
    ),
  );
}

/// What [showOrgTeamPicker] returns: the id chosen, and its name for the message.
class OrgTeamPick {
  const OrgTeamPick(this.id, this.name);
  final int? id;
  final String name;
}

/// Everybody on the chart, in name order — for the lead and manager dropdowns.
List<OrgPerson> _peopleOf(OrgTree tree) {
  final out = <OrgPerson>[];
  void walk(OrgTeam t) {
    out.addAll(t.people);
    for (final c in t.children) {
      walk(c);
    }
  }

  for (final r in tree.roots) {
    walk(r);
  }
  out.addAll(tree.unassigned);
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// Shared by the details panel's manager dropdown and the list view's menu.
List<OrgPerson> orgPeopleOf(OrgTree tree) => _peopleOf(tree);
