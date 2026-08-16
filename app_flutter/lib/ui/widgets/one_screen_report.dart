/// OpenSmartBatt — the "one full screen of report, optionally with more below"
/// shell (design 0065 §3.4.0).
///
/// ## Why this exists
///
/// Three screens render the same thing: a status report that fills exactly one
/// screen and sits vertically centred in it — the detail page's offline body
/// (`device_detail_page.dart`), the unidentified-unit view
/// (`unidentified_view.dart`) and the class-pending view
/// (`class_pending_view.dart`). Until design 0065 they were three VERBATIM
/// copies of the same six-widget tree, down to the padding values.
///
/// `_OfflineBody`'s own class comment says why that mattered: its layout
/// "mirrors the dashboard's own disconnected state **on purpose** … a second
/// visual language for one state is how two screens start disagreeing".
/// Design 0065 has to change that layout — it appends this unit's history
/// below the report — and changing three verbatim copies separately is how
/// they stop being copies.
///
/// ## The one thing this widget actually does
///
/// 🔴 **It moves `minHeight: constraints.maxHeight` off the whole column and
/// onto the REPORT HALF only.**
///
/// That constraint plus `MainAxisAlignment.center` is the layout language of a
/// full-page failure report: the report fills the screen and is centred in it.
/// Append anything to that same centred column and the centring divides the
/// space between the report and the appendix — the pulsing glyph gets shoved
/// upward and the page reads as broken rather than as "the report, and then
/// something else". So the report keeps its own one-screen box, and [below]
/// goes underneath it, reachable by scrolling (design 0065 §6 R1).
///
/// ⚠️ **With [below] null this emits the pre-0065 tree, node for node.** Not
/// "an equivalent tree" — the same one. Three shipped screens are pinned by
/// existing tests (`waiting_states_test.dart`,
/// `connection_failure_visibility_test.dart`) that were written against those
/// exact widgets, and a shell that quietly restructured them would change what
/// those assertions mean without changing whether they pass. That is what
/// `T65-6` exists to hold.
library;

import 'package:flutter/material.dart';

/// Padding around the report half. Was written out at all three call sites;
/// the values are unchanged.
const EdgeInsets _kReportPadding = EdgeInsets.fromLTRB(24, 24, 24, 30);

class OneScreenReport extends StatelessWidget {
  const OneScreenReport({super.key, required this.report, this.below});

  /// The centred report's children — what used to be the `Column`'s children
  /// at each of the three call sites.
  final List<Widget> report;

  /// Appended UNDER the one-screen report, scrolled to rather than shown.
  ///
  /// Null means "nothing appended", and that case is contractually identical to
  /// the pre-0065 layout — see the library comment.
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final centred = ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
            minWidth: constraints.maxWidth,
          ),
          child: Padding(
            padding: _kReportPadding,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: report,
            ),
          ),
        );
        final appendix = below;
        // 🔴 A branch rather than an always-wrapping Column, deliberately. An
        // outer Column would change how the cross axis is sized (the
        // `minWidth` box no longer drives the width on its own) and would need
        // a `mainAxisSize` of its own inside an unbounded scroll view. Both are
        // invisible in a screenshot and both are real. The null case is the one
        // three shipped screens already depend on, so it gets the untouched
        // tree and the new case gets the new one.
        return SingleChildScrollView(
          child: appendix == null
              ? centred
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [centred, appendix],
                ),
        );
      },
    );
  }
}
