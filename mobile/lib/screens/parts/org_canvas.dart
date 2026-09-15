import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/org.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/org_layout.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// The chart itself: a pannable, zoomable canvas of team cards joined by elbow
/// connectors, with drag and drop for reorganising (ORG-01, ORG-03).
///
/// Two gesture systems want the same pointer here. `InteractiveViewer` claims a
/// drag as a pan, and a `Draggable` claims it as a drag, and the viewer wins —
/// so everything draggable is a `LongPressDraggable`: holding still for a moment
/// is unambiguous. While a drag is running the viewer's pan and zoom are turned
/// off, so a wobble mid-drag cannot slide the whole chart out from under the
/// thing being dropped.

/// What is being dragged: a team to re-parent, or a person to move.
sealed class OrgDragPayload {
  const OrgDragPayload();
}

class OrgTeamDrag extends OrgDragPayload {
  const OrgTeamDrag(this.team);
  final OrgTeam team;
}

class OrgPersonDrag extends OrgDragPayload {
  const OrgPersonDrag(this.person);
  final OrgPerson person;
}

/// What the chart can be asked to do. The screen owns the API calls.
class OrgCanvasCallbacks {
  const OrgCanvasCallbacks({
    required this.onSelectTeam,
    required this.onSelectPerson,
    required this.onToggleCollapse,
    required this.onMoveTeam,
    required this.onMovePerson,
    required this.onAddSubTeam,
  });

  final void Function(OrgTeam) onSelectTeam;
  final void Function(OrgPerson) onSelectPerson;
  final void Function(int teamId) onToggleCollapse;
  final void Function(OrgTeam team, int? newParentId) onMoveTeam;
  final void Function(OrgPerson person, int? newTeamId) onMovePerson;
  final void Function(OrgTeam parent) onAddSubTeam;
}

class OrgCanvas extends StatefulWidget {
  const OrgCanvas({
    super.key,
    required this.tree,
    required this.collapsed,
    required this.showPeople,
    required this.callbacks,
    this.roleFamilyFilter,
    this.selectedTeamId,
    this.selectedPersonId,
  });

  final OrgTree tree;
  final Set<int> collapsed;
  final bool showPeople;
  final OrgCanvasCallbacks callbacks;

  /// When set, people outside this discipline fade back so the ones in it read
  /// as a group across the whole chart — which is the point of a role family.
  final int? roleFamilyFilter;

  final int? selectedTeamId;
  final int? selectedPersonId;

  @override
  State<OrgCanvas> createState() => OrgCanvasState();
}

class OrgCanvasState extends State<OrgCanvas> {
  final TransformationController _xform = TransformationController();
  final ValueNotifier<OrgDragPayload?> _dragging = ValueNotifier(null);
  Size _viewport = Size.zero;
  bool _fitted = false;

  static const double _minScale = 0.25;
  static const double _maxScale = 2.0;

  /// A long press is what tells a drag apart from a pan. A mouse can be quicker
  /// about it than a finger, because a mouse does not wobble.
  static Duration get _dragDelay =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux
          ? const Duration(milliseconds: 160)
          : const Duration(milliseconds: 400);

  @override
  void dispose() {
    _xform.dispose();
    _dragging.dispose();
    super.dispose();
  }

  double get _scale => _xform.value.getMaxScaleOnAxis();

  void zoomBy(double factor) {
    final target = (_scale * factor).clamp(_minScale, _maxScale);
    _setScaleAboutCentre(target);
  }

  void _setScaleAboutCentre(double target) {
    if (_viewport == Size.zero) return;
    final current = _scale;
    if ((target - current).abs() < 0.001) return;
    final centre = Offset(_viewport.width / 2, _viewport.height / 2);
    final scene = _xform.toScene(centre);
    final m = Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(target, target, 1, 1)
      ..translateByDouble(-scene.dx, -scene.dy, 0, 1);
    _xform.value = m;
  }

  /// Fit the whole chart in view. Called once when it first loads, and by the
  /// toolbar — a chart you have to hunt around for is no use.
  void fit({required Size content}) {
    if (_viewport == Size.zero || content.width <= 0 || content.height <= 0) return;
    final s = math.min(
      math.min((_viewport.width - 32) / content.width, (_viewport.height - 32) / content.height),
      1.0,
    ).clamp(_minScale, _maxScale);
    final dx = (_viewport.width - content.width * s) / 2;
    final dy = math.max(0.0, (_viewport.height - content.height * s) / 2);
    _xform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  /// How tall a team card is. Arithmetic, never measured, so the layout is the
  /// same under `flutter test` as in a browser.
  double _nodeHeight(OrgTeam t) {
    if (t.restricted) return 76;
    var h = 104.0;
    if (t.isRestricted) h += 24;
    if (widget.showPeople && t.people.isNotEmpty) {
      h += 10 + math.min(t.people.length, _maxRows) * 30;
      if (t.people.length > _maxRows) h += 26;
    }
    return h;
  }

  static const int _maxRows = 8;

  OrgLayoutNode _toLayout(OrgTeam t) =>
      OrgLayoutNode(id: t.id, height: _nodeHeight(t), children: [for (final c in t.children) _toLayout(c)]);

  @override
  Widget build(BuildContext context) {
    final roots = [for (final r in widget.tree.roots) _toLayout(r)];
    final layout = OrgLayout.layout(roots, collapsed: widget.collapsed);

    return LayoutBuilder(builder: (context, c) {
      final viewport = Size(c.maxWidth, c.maxHeight);
      if (viewport != _viewport) {
        _viewport = viewport;
        if (!_fitted && !layout.isEmpty) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) fit(content: layout.size);
          });
        }
      }
      return Stack(children: [
        Positioned.fill(
          child: ValueListenableBuilder<OrgDragPayload?>(
            valueListenable: _dragging,
            builder: (context, drag, _) => InteractiveViewer(
              transformationController: _xform,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(400),
              minScale: _minScale,
              maxScale: _maxScale,
              panEnabled: drag == null,
              scaleEnabled: drag == null,
              child: SizedBox(
                width: layout.size.width,
                height: layout.size.height,
                child: Stack(children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _OrgEdgePainter(
                        edges: layout.edges,
                        colour: context.borderColor,
                        highlight: widget.selectedTeamId,
                      ),
                    ),
                  ),
                  for (final placed in layout.nodes.values)
                    if (widget.tree.team(placed.id) != null)
                      Positioned.fromRect(
                        rect: placed.rect,
                        child: _TeamNode(
                          team: widget.tree.team(placed.id)!,
                          tree: widget.tree,
                          collapsed: widget.collapsed.contains(placed.id),
                          showPeople: widget.showPeople,
                          roleFamilyFilter: widget.roleFamilyFilter,
                          selected: widget.selectedTeamId == placed.id,
                          selectedPersonId: widget.selectedPersonId,
                          dragging: _dragging,
                          dragDelay: _dragDelay,
                          scale: _scale,
                          callbacks: widget.callbacks,
                          maxRows: _maxRows,
                        ),
                      ),
                ]),
              ),
            ),
          ),
        ),
        // The two places a drag can go that are not a team card.
        Positioned(
          left: Sp.lg,
          top: Sp.lg,
          child: ValueListenableBuilder<OrgDragPayload?>(
            valueListenable: _dragging,
            builder: (context, drag, _) {
              final show = drag is OrgTeamDrag && drag.team.parentTeamId != null && widget.tree.canEditAll;
              if (!show) return const SizedBox.shrink();
              return _DropZone(
                label: 'Top of the organisation',
                icon: Icons.vertical_align_top_rounded,
                onAccept: (p) => widget.callbacks.onMoveTeam((p as OrgTeamDrag).team, null),
                accepts: (p) => p is OrgTeamDrag,
              );
            },
          ),
        ),
        if (widget.tree.unassigned.isNotEmpty || widget.tree.canEditAnything)
          Positioned(
            left: Sp.lg,
            bottom: Sp.lg,
            child: ValueListenableBuilder<OrgDragPayload?>(
              valueListenable: _dragging,
              builder: (context, drag, _) {
                final dragging = drag is OrgPersonDrag;
                if (!dragging && widget.tree.unassigned.isEmpty) return const SizedBox.shrink();
                return _UnassignedBucket(
                  people: widget.tree.unassigned,
                  onAccept: (p) => widget.callbacks.onMovePerson((p as OrgPersonDrag).person, null),
                  onTapPerson: widget.callbacks.onSelectPerson,
                  canDrop: widget.tree.canEditAnything,
                );
              },
            ),
          ),
        Positioned(
          right: Sp.lg,
          bottom: Sp.lg,
          child: _CanvasToolbar(
            onZoomIn: () => zoomBy(1.25),
            onZoomOut: () => zoomBy(0.8),
            onFit: () => fit(content: layout.size),
          ),
        ),
      ]);
    });
  }
}

/// One team, and the people in it.
class _TeamNode extends StatelessWidget {
  const _TeamNode({
    required this.team,
    required this.tree,
    required this.collapsed,
    required this.showPeople,
    required this.roleFamilyFilter,
    required this.selected,
    required this.selectedPersonId,
    required this.dragging,
    required this.dragDelay,
    required this.scale,
    required this.callbacks,
    required this.maxRows,
  });

  final OrgTeam team;
  final OrgTree tree;
  final bool collapsed;
  final bool showPeople;
  final int? roleFamilyFilter;
  final bool selected;
  final int? selectedPersonId;
  final ValueNotifier<OrgDragPayload?> dragging;
  final Duration dragDelay;
  final double scale;
  final OrgCanvasCallbacks callbacks;
  final int maxRows;

  bool _accepts(OrgDragPayload? p) {
    if (p == null) return false;
    if (!tree.canEdit(team.id)) return false;
    return switch (p) {
      OrgTeamDrag(:final team) =>
        tree.canEdit(team.id) && team.id != this.team.id && team.parentTeamId != this.team.id && !tree.descendantsOf(team.id).contains(this.team.id),
      OrgPersonDrag(:final person) => tree.canEdit(person.teamId) && person.teamId != team.id,
    };
  }

  void _drop(OrgDragPayload p) {
    switch (p) {
      case OrgTeamDrag(:final team):
        callbacks.onMoveTeam(team, this.team.id);
      case OrgPersonDrag(:final person):
        callbacks.onMovePerson(person, team.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (team.restricted) return _RestrictedNode(team: team);

    final card = DragTarget<OrgDragPayload>(
      onWillAcceptWithDetails: (d) => _accepts(d.data),
      onAcceptWithDetails: (d) => _drop(d.data),
      builder: (context, accepted, rejected) {
        final tint = accepted.isNotEmpty
            ? DispatchColors.tint(DispatchColors.orange, opacity: 0.16)
            : rejected.isNotEmpty
                ? DispatchColors.tint(DispatchColors.red, opacity: 0.12)
                : null;
        return _TeamCard(
          team: team,
          tree: tree,
          collapsed: collapsed,
          showPeople: showPeople,
          roleFamilyFilter: roleFamilyFilter,
          selected: selected,
          selectedPersonId: selectedPersonId,
          tint: tint,
          dragging: dragging,
          dragDelay: dragDelay,
          scale: scale,
          callbacks: callbacks,
          maxRows: maxRows,
        );
      },
    );

    if (!tree.canEdit(team.id)) return card;
    return LongPressDraggable<OrgDragPayload>(
      data: OrgTeamDrag(team),
      delay: dragDelay,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        dragging.value = OrgTeamDrag(team);
        HapticFeedback.selectionClick();
      },
      onDragEnd: (_) => dragging.value = null,
      onDraggableCanceled: (_, _) => dragging.value = null,
      feedback: _Ghost(scale: scale, label: team.name, subtitle: '${team.headcountAll} people', icon: Icons.account_tree_rounded),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.team,
    required this.tree,
    required this.collapsed,
    required this.showPeople,
    required this.roleFamilyFilter,
    required this.selected,
    required this.selectedPersonId,
    required this.tint,
    required this.dragging,
    required this.dragDelay,
    required this.scale,
    required this.callbacks,
    required this.maxRows,
  });

  final OrgTeam team;
  final OrgTree tree;
  final bool collapsed;
  final bool showPeople;
  final int? roleFamilyFilter;
  final bool selected;
  final int? selectedPersonId;
  final Color? tint;
  final ValueNotifier<OrgDragPayload?> dragging;
  final Duration dragDelay;
  final double scale;
  final OrgCanvasCallbacks callbacks;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final shown = team.people.take(maxRows).toList();
    final more = team.people.length - shown.length;
    return DispatchCard(
      onTap: () => callbacks.onSelectTeam(team),
      accent: selected ? DispatchColors.orange : null,
      tint: tint,
      padding: const EdgeInsets.fromLTRB(Sp.md, Sp.md, Sp.sm, Sp.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(team.name, style: context.text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (team.lead != null) ...[
            const SizedBox(width: Sp.xs),
            PersonAvatar(team.lead!.initialsOrDerived, colourHex: team.lead!.colourHex, seed: team.lead!.id, size: 24, tooltip: '${team.lead!.name} leads this team'),
          ],
          if (team.children.isNotEmpty)
            IconButton(
              tooltip: collapsed ? 'Show sub-teams' : 'Hide sub-teams',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded, size: 20, color: context.mutedColor),
              onPressed: () => callbacks.onToggleCollapse(team.id),
            ),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Icon(Icons.groups_outlined, size: 14, color: context.mutedColor),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              team.headcountAll == team.headcount
                  ? '${team.headcount} ${team.headcount == 1 ? 'person' : 'people'}'
                  : '${team.headcount} here · ${team.headcountAll} in all',
              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TmLoadBar(team.loadPct.toDouble(), width: 40),
        ]),
        if (team.isRestricted) ...[
          const SizedBox(height: Sp.xs),
          const ToneChip('Restricted', compact: true, icon: Icons.lock_outline_rounded),
        ],
        if (showPeople && team.people.isNotEmpty) ...[
          const SizedBox(height: Sp.xs),
          Divider(height: 9, color: context.borderColor),
          for (final p in shown)
            _PersonRow(
              person: p,
              tree: tree,
              faded: roleFamilyFilter != null && p.roleFamilyId != roleFamilyFilter,
              highlighted: roleFamilyFilter != null && p.roleFamilyId == roleFamilyFilter,
              selected: selectedPersonId == p.id,
              dragging: dragging,
              dragDelay: dragDelay,
              scale: scale,
              onTap: () => callbacks.onSelectPerson(p),
            ),
          if (more > 0)
            SizedBox(
              height: 26,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: () => callbacks.onSelectTeam(team),
                  child: Text('and $more more', style: context.text.labelMedium),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}

/// A team this viewer may not look inside (ORG-04): where it sits, and no more.
class _RestrictedNode extends StatelessWidget {
  const _RestrictedNode({required this.team});
  final OrgTeam team;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'This team has been restricted. You can see that it exists and where it sits, but not who is in it.',
      child: DashedBox(
        child: Padding(
          padding: const EdgeInsets.all(Sp.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Text(team.name, style: context.text.titleMedium?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Icon(Icons.lock_outline_rounded, size: 16, color: context.mutedColor),
            ]),
            const SizedBox(height: 4),
            Text('Restricted', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          ]),
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.person,
    required this.tree,
    required this.faded,
    required this.highlighted,
    required this.selected,
    required this.dragging,
    required this.dragDelay,
    required this.scale,
    required this.onTap,
  });

  final OrgPerson person;
  final OrgTree tree;
  final bool faded;
  final bool highlighted;
  final bool selected;
  final ValueNotifier<OrgDragPayload?> dragging;
  final Duration dragDelay;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: selected
              ? DispatchColors.tint(DispatchColors.orange, opacity: 0.18)
              : highlighted
                  ? DispatchColors.tint(DispatchColors.orange, opacity: 0.08)
                  : null,
          borderRadius: DispatchRadius.chipR,
        ),
        child: Row(children: [
          PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 20),
          const SizedBox(width: Sp.sm),
          Expanded(child: Text(person.name, style: context.text.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (person.onLoanTo != null)
            Tooltip(
              message: 'On loan to ${person.onLoanTo!.toTeamName}',
              child: Icon(Icons.swap_horiz_rounded, size: 14, color: DispatchColors.amber),
            ),
          if (person.isLead) Icon(Icons.star_rounded, size: 13, color: context.mutedColor),
        ]),
      ),
    );
    final shown = faded ? Opacity(opacity: 0.32, child: row) : row;
    if (!tree.canEdit(person.teamId)) return shown;
    return LongPressDraggable<OrgDragPayload>(
      data: OrgPersonDrag(person),
      delay: dragDelay,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        dragging.value = OrgPersonDrag(person);
        HapticFeedback.selectionClick();
      },
      onDragEnd: (_) => dragging.value = null,
      onDraggableCanceled: (_, _) => dragging.value = null,
      feedback: _Ghost(scale: scale, label: person.name, subtitle: person.roleTitle ?? 'Move to another team', icon: Icons.person_outline_rounded),
      childWhenDragging: Opacity(opacity: 0.3, child: shown),
      child: shown,
    );
  }
}

/// What follows the pointer during a drag. It lives in the overlay, outside the
/// canvas transform, so it has to be scaled by hand or it looks wrong at any
/// zoom but 100%.
class _Ghost extends StatelessWidget {
  const _Ghost({required this.scale, required this.label, required this.subtitle, required this.icon});
  final double scale;
  final String label;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale.clamp(0.5, 1.5),
      alignment: Alignment.topLeft,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 240,
          padding: const EdgeInsets.all(Sp.md),
          decoration: BoxDecoration(
            color: context.panelColor,
            borderRadius: DispatchRadius.cardR,
            border: Border.all(color: DispatchColors.orange, width: 1.5),
            boxShadow: DispatchShadow.floating,
          ),
          child: Row(children: [
            Icon(icon, size: 18, color: DispatchColors.orange),
            const SizedBox(width: Sp.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(subtitle, style: context.text.bodySmall?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A place to drop something that is not a team card.
class _DropZone extends StatelessWidget {
  const _DropZone({required this.label, required this.icon, required this.onAccept, required this.accepts});
  final String label;
  final IconData icon;
  final void Function(OrgDragPayload) onAccept;
  final bool Function(OrgDragPayload) accepts;

  @override
  Widget build(BuildContext context) {
    return DragTarget<OrgDragPayload>(
      onWillAcceptWithDetails: (d) => accepts(d.data),
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, accepted, rejected) => DashedBox(
        color: accepted.isNotEmpty ? DispatchColors.orange : DispatchColors.border,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
          decoration: BoxDecoration(
            color: accepted.isNotEmpty ? DispatchColors.tint(DispatchColors.orange, opacity: 0.16) : context.panelColor,
            borderRadius: DispatchRadius.cardR,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: context.mutedColor),
            const SizedBox(width: Sp.sm),
            Text(label, style: context.text.labelLarge),
          ]),
        ),
      ),
    );
  }
}

/// People with no team. They exist whether or not the chart admits it.
class _UnassignedBucket extends StatelessWidget {
  const _UnassignedBucket({required this.people, required this.onAccept, required this.onTapPerson, required this.canDrop});
  final List<OrgPerson> people;
  final void Function(OrgDragPayload) onAccept;
  final void Function(OrgPerson) onTapPerson;
  final bool canDrop;

  @override
  Widget build(BuildContext context) {
    return DragTarget<OrgDragPayload>(
      onWillAcceptWithDetails: (d) => canDrop && d.data is OrgPersonDrag && (d.data as OrgPersonDrag).person.teamId != null,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, accepted, rejected) => Container(
        width: 220,
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(
          color: accepted.isNotEmpty ? DispatchColors.tint(DispatchColors.orange, opacity: 0.16) : context.panelColor,
          borderRadius: DispatchRadius.cardR,
          border: Border.all(color: accepted.isNotEmpty ? DispatchColors.orange : context.borderColor),
          boxShadow: DispatchShadow.floating,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('No team', style: context.text.titleSmall),
          const SizedBox(height: 2),
          Text(
            people.isEmpty ? 'Drop somebody here to take them out of their team.' : '${people.length} ${people.length == 1 ? 'person' : 'people'}',
            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
          ),
          if (people.isNotEmpty) ...[
            const SizedBox(height: Sp.sm),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final p in people.take(8))
                  Tooltip(
                    message: p.name,
                    child: InkWell(
                      onTap: () => onTapPerson(p),
                      child: PersonAvatar(p.initialsOrDerived, colourHex: p.colourHex, seed: p.id, size: 22),
                    ),
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

class _CanvasToolbar extends StatelessWidget {
  const _CanvasToolbar({required this.onZoomIn, required this.onZoomOut, required this.onFit});
  final VoidCallback onZoomIn, onZoomOut, onFit;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          icon: Icon(icon, size: 18),
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
        );
    return Container(
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.buttonR,
        border: Border.all(color: context.borderColor),
        boxShadow: DispatchShadow.floating,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        button(Icons.remove_rounded, 'Zoom out', onZoomOut),
        button(Icons.add_rounded, 'Zoom in', onZoomIn),
        button(Icons.fit_screen_outlined, 'Fit the whole chart', onFit),
      ]),
    );
  }
}

/// The connectors. Three segments each: down out of the parent, across, down
/// into the child — an org chart's own convention, and easier to follow across
/// a wide row than a curve.
class _OrgEdgePainter extends CustomPainter {
  const _OrgEdgePainter({required this.edges, required this.colour, this.highlight});
  final List<OrgEdge> edges;
  final Color colour;
  final int? highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final plain = Paint()
      ..color = colour
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final lit = Paint()
      ..color = DispatchColors.orange
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final e in edges) {
      final p = Path()
        ..moveTo(e.start.dx, e.start.dy)
        ..lineTo(e.start.dx, e.elbowY)
        ..lineTo(e.end.dx, e.elbowY)
        ..lineTo(e.end.dx, e.end.dy);
      canvas.drawPath(p, highlight != null && (e.fromId == highlight || e.toId == highlight) ? lit : plain);
    }
  }

  @override
  bool shouldRepaint(_OrgEdgePainter old) => old.edges != edges || old.colour != colour || old.highlight != highlight;
}
