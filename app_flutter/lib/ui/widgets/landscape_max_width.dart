/// OpenSmartBatt — a centred maximum width that exists only in landscape
/// (design 0105 P5).
///
/// The devices list, Settings and History were the three pages with no
/// `maxWidth` at all (0105 §3.2 #5 / #7 / #9): on a 1280-wide head unit every
/// row stretched edge to edge, the name at the far left and its button at the
/// far right. In a landscape window this centres the page in a column at most
/// [maxWidth] wide — the same 560 every other page already uses.
///
/// 🔴 In portrait it lays its child out with EXACTLY the constraints it was
/// given, at the same position, so the page renders as before. It is one
/// render object in both orientations (never "wrap in portrait, unwrap in
/// landscape"), so a rotation re-lays the page out instead of rebuilding it
/// — the list's scroll offset, the devices page's tab and its listeners all
/// survive.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../util/wide_layout.dart';

/// See the library doc.
class LandscapeMaxWidth extends StatelessWidget {
  const LandscapeMaxWidth({
    super.key,
    this.maxWidth = WideLayout.columnMaxWidth,
    required this.child,
  });

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final landscape = WideLayout.isLandscape(MediaQuery.sizeOf(context));
    return _CentredMaxWidth(
      maxWidth: landscape ? maxWidth : double.infinity,
      child: child,
    );
  }
}

class _CentredMaxWidth extends SingleChildRenderObjectWidget {
  const _CentredMaxWidth({required this.maxWidth, super.child});

  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCentredMaxWidth(maxWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCentredMaxWidth renderObject,
  ) {
    renderObject.maxWidth = maxWidth;
  }
}

class _RenderCentredMaxWidth extends RenderShiftedBox {
  _RenderCentredMaxWidth(this._maxWidth) : super(null);

  double get maxWidth => _maxWidth;
  double _maxWidth;
  set maxWidth(double v) {
    if (v == _maxWidth) return;
    _maxWidth = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    if (constraints.maxWidth <= _maxWidth) {
      // Portrait, or a window narrower than the cap: pass straight through.
      c.layout(constraints, parentUsesSize: true);
      size = c.size;
      (c.parentData! as BoxParentData).offset = Offset.zero;
      return;
    }
    // Wider than the cap: the child gets the cap (and the full height
    // constraints); this box keeps the full width and centres it.
    final inner = constraints.copyWith(
      minWidth: math.min(constraints.minWidth, _maxWidth),
      maxWidth: _maxWidth,
    );
    c.layout(inner, parentUsesSize: true);
    size = constraints.constrain(Size(constraints.maxWidth, c.size.height));
    (c.parentData! as BoxParentData).offset = Offset(
      (size.width - c.size.width) / 2,
      0,
    );
  }
}
