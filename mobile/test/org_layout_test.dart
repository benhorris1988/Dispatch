// The organisation chart's geometry. Pure Dart: no server, no fonts, no pumping,
// so this is the one test in the suite that says something about the chart
// without needing anything running.
//
//   flutter test test/org_layout_test.dart
import 'dart:ui';

import 'package:dispatch_app/widgets/org_layout.dart';
import 'package:flutter_test/flutter_test.dart';

const cfg = OrgLayoutConfig();
OrgLayoutNode n(int id, {double height = 100, List<OrgLayoutNode> children = const []}) =>
    OrgLayoutNode(id: id, height: height, children: children);

void main() {
  test('a single root sits at the padding, and the canvas is just big enough for it', () {
    final r = OrgLayout.layout([n(1, height: 90)]);
    expect(r.rectOf(1), Rect.fromLTWH(cfg.padding, cfg.padding, cfg.nodeWidth, 90));
    expect(r.size.width, cfg.nodeWidth + cfg.padding * 2);
    expect(r.size.height, 90 + cfg.padding * 2);
    expect(r.edges, isEmpty);
  });

  test('no teams at all is an empty canvas rather than a crash', () {
    final r = OrgLayout.layout(const []);
    expect(r.isEmpty, isTrue);
    expect(r.size, Size(cfg.padding * 2, cfg.padding * 2));
  });

  test('three equal children are evenly spaced and the parent is centred over them', () {
    final r = OrgLayout.layout([
      n(1, children: [n(2), n(3), n(4)])
    ]);
    final a = r.rectOf(2)!, b = r.rectOf(3)!, c = r.rectOf(4)!;
    expect(b.left - a.left, cfg.nodeWidth + cfg.hGap);
    expect(c.left - b.left, cfg.nodeWidth + cfg.hGap);
    expect(a.top, b.top);
    expect(b.top, c.top);
    expect(r.rectOf(1)!.center.dx, closeTo((a.center.dx + c.center.dx) / 2, 0.001));
    expect(r.rectOf(1)!.center.dx, closeTo(b.center.dx, 0.001));
  });

  test('an unbalanced tree gives each subtree a band wide enough for itself', () {
    // 1 has A (three children) and B (a leaf). B must clear A's whole subtree,
    // not just A's own box, or the wide branch would run under its sibling.
    final r = OrgLayout.layout([
      n(1, children: [
        n(2, children: [n(4), n(5), n(6)]),
        n(3),
      ])
    ]);
    final a = r.rectOf(2)!, b = r.rectOf(3)!;
    final aSubtreeRight = [2, 4, 5, 6].map((id) => r.rectOf(id)!.right).reduce((x, y) => x > y ? x : y);
    expect(b.left, greaterThanOrEqualTo(aSubtreeRight + cfg.hGap - 0.001));
    expect(r.rectOf(1)!.center.dx, closeTo((a.center.dx + b.center.dx) / 2, 0.001));
    // A sits centred over its three children, B over nothing but itself.
    expect(a.center.dx, closeTo(r.rectOf(5)!.center.dx, 0.001));
    expect(r.rectOf(6)!.right - r.rectOf(4)!.left, closeTo(cfg.nodeWidth * 3 + cfg.hGap * 2, 0.001));
  });

  test('collapsing a node hides its subtree and shrinks the canvas', () {
    final tree = [
      n(1, children: [
        n(2, children: [n(4), n(5), n(6)]),
        n(3),
      ])
    ];
    final open = OrgLayout.layout(tree);
    final shut = OrgLayout.layout(tree, collapsed: {2});
    expect(shut.nodes.keys, unorderedEquals([1, 2, 3]));
    expect(shut.size.width, lessThan(open.size.width));
    expect(shut.rectOf(2)!.width, cfg.nodeWidth);
    expect(shut.edges.map((e) => e.toId), unorderedEquals([2, 3]));
  });

  test('a tall node pushes the whole next row down, cousins included', () {
    // 2 is tall (its people are showing); 3 is short. Their children must still
    // share a row, or a long team would overlap its cousin's children.
    final r = OrgLayout.layout([
      n(1, height: 100, children: [
        n(2, height: 320, children: [n(4)]),
        n(3, height: 100, children: [n(5)]),
      ])
    ]);
    expect(r.rectOf(4)!.top, r.rectOf(5)!.top);
    // Row 0 is 100 tall, row 1 is as tall as the tallest node in it (320).
    expect(r.rectOf(2)!.top, closeTo(cfg.padding + 100 + cfg.vGap, 0.001));
    expect(r.rectOf(4)!.top, closeTo(cfg.padding + 100 + cfg.vGap + 320 + cfg.vGap, 0.001));
    // The short sibling's child clears the tall sibling's box, which is the point.
    expect(r.rectOf(5)!.top, greaterThan(r.rectOf(2)!.bottom));
  });

  test('nothing overlaps anything else, at any shape of tree', () {
    // A deterministic but awkward tree: mixed fan-out, mixed heights, four deep.
    var next = 1;
    OrgLayoutNode build(int depth, int fanout) {
      final id = next++;
      final kids = depth == 0 ? <OrgLayoutNode>[] : [for (var i = 0; i < fanout; i++) build(depth - 1, (fanout + i) % 3 + 1)];
      return n(id, height: 80.0 + (id % 5) * 40, children: kids);
    }

    final r = OrgLayout.layout([build(3, 3), build(2, 2)]);
    expect(r.nodes.length, greaterThan(20));
    final rects = r.nodes.values.toList();
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].rect.overlaps(rects[j].rect), isFalse,
            reason: 'nodes ${rects[i].id} and ${rects[j].id} overlap');
      }
    }
    final canvas = Rect.fromLTWH(0, 0, r.size.width, r.size.height);
    for (final p in rects) {
      expect(canvas.contains(p.rect.topLeft), isTrue, reason: 'node ${p.id} starts outside the canvas');
      expect(canvas.contains(p.rect.bottomRight), isTrue, reason: 'node ${p.id} runs past the canvas');
    }
  });

  test('several roots are laid out left to right in the order given', () {
    final r = OrgLayout.layout([n(1), n(2, children: [n(4), n(5)]), n(3)]);
    expect(r.rectOf(1)!.left, lessThan(r.rectOf(2)!.left));
    expect(r.rectOf(2)!.left, lessThan(r.rectOf(3)!.left));
    expect(r.nodes.values.where((p) => p.depth == 0).length, 3);
    expect(r.nodes[1]!.parentId, isNull);
    expect(r.nodes[4]!.parentId, 2);
  });

  test('every edge runs from the bottom of a parent to the top of a child, with the elbow between', () {
    final r = OrgLayout.layout([
      n(1, children: [n(2), n(3)])
    ]);
    expect(r.edges.length, 2);
    for (final e in r.edges) {
      final from = r.rectOf(e.fromId)!, to = r.rectOf(e.toId)!;
      expect(e.start, from.bottomCenter);
      expect(e.end, to.topCenter);
      expect(e.elbowY, greaterThan(e.start.dy));
      expect(e.elbowY, lessThan(e.end.dy));
    }
  });

  test('a deep chain stays one node wide and one row per level', () {
    var node = n(6);
    for (var id = 5; id >= 1; id--) {
      node = n(id, children: [node]);
    }
    final r = OrgLayout.layout([node]);
    expect(r.nodes.length, 6);
    expect(r.size.width, cfg.nodeWidth + cfg.padding * 2);
    for (var id = 1; id <= 6; id++) {
      expect(r.nodes[id]!.depth, id - 1);
    }
  });

  test('a node claiming itself as a child is drawn once rather than for ever', () {
    // The API cannot produce this; a layout that hung on it would still be a bug.
    final loop = OrgLayoutNode(id: 1, height: 100, children: [OrgLayoutNode(id: 1, height: 100)]);
    final r = OrgLayout.layout([loop]);
    expect(r.nodes.length, 1);
  });
}
