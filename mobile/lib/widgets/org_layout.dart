/// Laying out an organisation chart.
///
/// Pure geometry: no Flutter widgets, no measuring, no BuildContext — which is
/// what lets `test/org_layout_test.dart` check it without a server or a font,
/// and what makes the chart look the same under `flutter test` as in a browser.
/// Node widths are fixed and the text inside them ellipsises, so the em-square
/// font the test binding uses cannot change a single position.
///
/// The algorithm is Reingold–Tilford without the contour threading: each
/// subtree owns a horizontal band as wide as its children need, and the node
/// sits centred over that band. Sibling bands never overlap, so nothing has to
/// be pushed apart afterwards. Each depth gets one row, as tall as the tallest
/// node in it, so a team showing eight people pushes the whole next row down
/// rather than colliding with a cousin's children.
library;

import 'dart:ui';

/// A team as the layout needs it: an identity, a height, and its children.
class OrgLayoutNode {
  const OrgLayoutNode({required this.id, required this.height, this.children = const []});
  final int id;
  final double height;
  final List<OrgLayoutNode> children;
}

class OrgLayoutConfig {
  const OrgLayoutConfig({this.nodeWidth = 248, this.hGap = 28, this.vGap = 56, this.padding = 40});

  /// Every node is this wide. Text ellipsises inside it.
  final double nodeWidth;

  /// Between sibling bands, and between the roots.
  final double hGap;

  /// Between one depth row and the next.
  final double vGap;

  /// Around the whole drawing, so nothing touches the edge of the canvas.
  final double padding;
}

class OrgPlacedNode {
  const OrgPlacedNode({required this.id, required this.parentId, required this.depth, required this.rect});
  final int id;
  final int? parentId;
  final int depth;
  final Rect rect;
}

/// A connector, drawn as three segments: down out of the parent, across at
/// [elbowY], then down into the child.
class OrgEdge {
  const OrgEdge({required this.fromId, required this.toId, required this.start, required this.end, required this.elbowY});
  final int fromId;
  final int toId;
  final Offset start;
  final Offset end;
  final double elbowY;
}

class OrgLayoutResult {
  const OrgLayoutResult({required this.nodes, required this.edges, required this.size});
  final Map<int, OrgPlacedNode> nodes;
  final List<OrgEdge> edges;
  final Size size;

  Rect? rectOf(int id) => nodes[id]?.rect;
  bool get isEmpty => nodes.isEmpty;
}

class OrgLayout {
  const OrgLayout._();

  static OrgLayoutResult layout(
    List<OrgLayoutNode> roots, {
    Set<int> collapsed = const {},
    OrgLayoutConfig config = const OrgLayoutConfig(),
  }) {
    if (roots.isEmpty) {
      return OrgLayoutResult(nodes: const {}, edges: const [], size: Size(config.padding * 2, config.padding * 2));
    }

    // A node that is collapsed, or that we have already drawn, contributes no
    // children. The `seen` set is belt and braces: the API cannot produce a
    // cycle, but a layout that looped would hang the app rather than draw badly.
    final seen = <int>{};
    List<OrgLayoutNode> kidsOf(OrgLayoutNode n) =>
        collapsed.contains(n.id) ? const [] : n.children.where((c) => !seen.contains(c.id)).toList();

    // 1. Subtree widths, post-order. A node is at least as wide as itself.
    final widths = <int, double>{};
    double width(OrgLayoutNode n) {
      if (widths.containsKey(n.id)) return widths[n.id]!;
      widths[n.id] = config.nodeWidth; // provisional, so a cycle cannot recurse forever
      final kids = kidsOf(n);
      double w = config.nodeWidth;
      if (kids.isNotEmpty) {
        double sum = 0;
        for (final k in kids) {
          sum += width(k);
        }
        sum += config.hGap * (kids.length - 1);
        if (sum > w) w = sum;
      }
      widths[n.id] = w;
      return w;
    }

    // 2. Row heights: one row per depth, as tall as the tallest node in it.
    final rowHeight = <int, double>{};
    void measure(OrgLayoutNode n, int depth) {
      if (!seen.add(n.id)) return;
      final h = n.height;
      if (h > (rowHeight[depth] ?? 0)) rowHeight[depth] = h;
      for (final k in kidsOf(n)) {
        measure(k, depth + 1);
      }
    }

    seen.clear();
    for (final r in roots) {
      measure(r, 0);
    }
    final maxDepth = rowHeight.keys.isEmpty ? 0 : rowHeight.keys.reduce((a, b) => a > b ? a : b);
    final rowTop = <int, double>{0: config.padding};
    for (var d = 1; d <= maxDepth; d++) {
      rowTop[d] = rowTop[d - 1]! + rowHeight[d - 1]! + config.vGap;
    }

    // 3. Place. Each subtree gets a band [bandX, bandX + width) that no sibling
    //    band overlaps, so the only question left is where in its band each node
    //    sits. Children are placed first and the parent is then centred over the
    //    midpoint of its first and last child — not over the middle of its band,
    //    which drifts visibly when one branch is much wider than another. The
    //    parent can never leave its band that way, because each child is itself
    //    at least half a node from the band's edges.
    final nodes = <int, OrgPlacedNode>{};
    final edges = <OrgEdge>[];
    seen.clear();

    void place(OrgLayoutNode n, int depth, double bandX, int? parentId) {
      if (!seen.add(n.id)) return;
      final w = widths[n.id] ?? config.nodeWidth;
      final kids = kidsOf(n);

      final placedKids = <int>[];
      if (kids.isNotEmpty) {
        double kidsWidth = 0;
        for (final k in kids) {
          kidsWidth += widths[k.id] ?? config.nodeWidth;
        }
        kidsWidth += config.hGap * (kids.length - 1);
        var childX = bandX + (w - kidsWidth) / 2;
        for (final k in kids) {
          place(k, depth + 1, childX, n.id);
          if (nodes.containsKey(k.id)) placedKids.add(k.id);
          childX += (widths[k.id] ?? config.nodeWidth) + config.hGap;
        }
      }

      final double left;
      if (placedKids.isEmpty) {
        left = bandX + (w - config.nodeWidth) / 2;
      } else {
        final first = nodes[placedKids.first]!.rect, last = nodes[placedKids.last]!.rect;
        left = (first.center.dx + last.center.dx) / 2 - config.nodeWidth / 2;
      }
      final rect = Rect.fromLTWH(left, rowTop[depth]!, config.nodeWidth, n.height);
      nodes[n.id] = OrgPlacedNode(id: n.id, parentId: parentId, depth: depth, rect: rect);

      for (final kid in placedKids) {
        final kr = nodes[kid]!.rect;
        edges.add(OrgEdge(
          fromId: n.id,
          toId: kid,
          start: rect.bottomCenter,
          end: kr.topCenter,
          elbowY: rect.bottom + (kr.top - rect.bottom) / 2,
        ));
      }
    }

    // Widths first for every root, so the roots can be laid side by side.
    seen.clear();
    for (final r in roots) {
      width(r);
    }
    seen.clear();

    var x = config.padding;
    for (final r in roots) {
      place(r, 0, x, null);
      x += (widths[r.id] ?? config.nodeWidth) + config.hGap;
    }

    final right = x - config.hGap + config.padding;
    final bottom = rowTop[maxDepth]! + (rowHeight[maxDepth] ?? 0) + config.padding;
    return OrgLayoutResult(nodes: nodes, edges: edges, size: Size(right, bottom));
  }
}
