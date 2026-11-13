/// OpenSmartBatt — lay a list of sections into N columns, IN ORDER (design
/// 0105 P3, owner ruling 2026-11-13 Q4 = A「照原順序分欄」).
///
/// The first column holds the first run of sections, the second the next run,
/// and so on — a newspaper, not a masonry grid: reading down column one and
/// then column two meets the sections in exactly the order the user arranged
/// them in the home editor. Where each run ends is chosen from the sections'
/// MEASURED heights so the tallest column is as short as it can be (a linear
/// partition); ties go to the split that keeps the earlier columns fuller.
///
/// Sections are never split or reordered, and each one is laid out at the
/// column's width with unbounded height — exactly how the single-column page
/// lays it out — so nothing inside a section (design 0084's half-width
/// left/right columns included) knows it is in a multi-column page.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// See the library doc.
class FlowColumns extends MultiChildRenderObjectWidget {
  const FlowColumns({
    super.key,
    required this.columns,
    required this.gap,
    super.children,
  }) : assert(columns >= 1);

  /// How many columns. 1 is a plain vertical list.
  final int columns;

  /// Horizontal gap between columns.
  final double gap;

  @override
  RenderFlowColumns createRenderObject(BuildContext context) =>
      RenderFlowColumns(columns: columns, gap: gap);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFlowColumns renderObject,
  ) {
    renderObject
      ..columns = columns
      ..gap = gap;
  }
}

/// Parent data: the offset, plus which column the child landed in (read by
/// tests, which assert the split rather than pixel positions).
class FlowColumnsParentData extends ContainerBoxParentData<RenderBox> {
  int column = 0;
}

/// The render object behind [FlowColumns].
class RenderFlowColumns extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, FlowColumnsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, FlowColumnsParentData> {
  RenderFlowColumns({required this._columns, required this._gap});

  int get columns => _columns;
  int _columns;
  set columns(int v) {
    if (v == _columns) return;
    _columns = v;
    markNeedsLayout();
  }

  double get gap => _gap;
  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! FlowColumnsParentData) {
      child.parentData = FlowColumnsParentData();
    }
  }

  double _columnWidth(double maxWidth) =>
      math.max(0, (maxWidth - (_columns - 1) * _gap) / _columns);

  /// Split [heights] into at most [n] contiguous runs minimising the tallest
  /// run; returns the start index of each run (length [n], non-decreasing).
  ///
  /// Dynamic programming over (columns, prefix) — the section count is the
  /// home grid's tile count, a dozen or two, so O(n·k²) is nothing. On a tie
  /// the LATER cut wins, which leaves earlier columns fuller: a short last
  /// column reads as "the end", a short first column reads as a gap.
  @visibleForTesting
  static List<int> partition(List<double> heights, int n) {
    final k = heights.length;
    final prefix = List<double>.filled(k + 1, 0);
    for (var i = 0; i < k; i++) {
      prefix[i + 1] = prefix[i] + heights[i];
    }
    double run(int from, int to) => prefix[to] - prefix[from];
    // best[c][i]: the tallest column when the first i sections fill c columns.
    final best = List.generate(n + 1, (_) => List<double>.filled(k + 1, 0));
    final cut = List.generate(n + 1, (_) => List<int>.filled(k + 1, 0));
    for (var i = 0; i <= k; i++) {
      best[1][i] = run(0, i);
    }
    for (var c = 2; c <= n; c++) {
      for (var i = 0; i <= k; i++) {
        var bestValue = double.infinity;
        var bestCut = 0;
        for (var j = 0; j <= i; j++) {
          final v = math.max(best[c - 1][j], run(j, i));
          // `<=` (with a tolerance for float sums): ties take the later cut.
          if (v <= bestValue + 1e-6) {
            bestValue = math.min(v, bestValue);
            bestCut = j;
          }
        }
        best[c][i] = bestValue;
        cut[c][i] = bestCut;
      }
    }
    final starts = List<int>.filled(n, 0);
    var end = k;
    for (var c = n; c >= 2; c--) {
      starts[c - 1] = cut[c][end];
      end = starts[c - 1];
    }
    starts[0] = 0;
    return starts;
  }

  @override
  void performLayout() {
    final maxWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : constraints.minWidth;
    final colWidth = _columnWidth(maxWidth);
    final childConstraints = BoxConstraints.tightFor(width: colWidth);
    final children = <RenderBox>[];
    final heights = <double>[];
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      children.add(child);
      heights.add(child.size.height);
      child = childAfter(child);
    }
    final starts = partition(heights, _columns);
    var tallest = 0.0;
    for (var c = 0; c < _columns; c++) {
      final from = starts[c];
      final to = c + 1 < _columns ? starts[c + 1] : children.length;
      var y = 0.0;
      for (var i = from; i < to; i++) {
        final pd = children[i].parentData! as FlowColumnsParentData;
        pd
          ..offset = Offset(c * (colWidth + _gap), y)
          ..column = c;
        y += heights[i];
      }
      tallest = math.max(tallest, y);
    }
    size = constraints.constrain(Size(maxWidth, tallest));
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  double _intrinsicHeight(double width) {
    final colWidth = _columnWidth(width);
    final heights = <double>[];
    var child = firstChild;
    while (child != null) {
      heights.add(child.getMaxIntrinsicHeight(colWidth));
      child = childAfter(child);
    }
    final starts = partition(heights, _columns);
    var tallest = 0.0;
    for (var c = 0; c < _columns; c++) {
      final to = c + 1 < _columns ? starts[c + 1] : heights.length;
      var y = 0.0;
      for (var i = starts[c]; i < to; i++) {
        y += heights[i];
      }
      tallest = math.max(tallest, y);
    }
    return tallest;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final maxWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : constraints.minWidth;
    return constraints.constrain(Size(maxWidth, _intrinsicHeight(maxWidth)));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
