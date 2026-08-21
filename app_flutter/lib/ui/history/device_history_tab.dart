/// OpenSmartBatt — the "History" half of a device's detail page (design 0079).
///
/// ## What changed, and why it is not a new feature
///
/// Until design 0079 this unit's history was a BLOCK appended to the bottom of
/// whatever the detail page happened to be showing — five different hosts, four
/// dashboard routes plus the offline failure report (design 0065 §3.3). It
/// worked, and it shipped in `v0.7.21`. What it could not do was grow: the
/// per-minute list was removed on 2026-08-16 because a thousand rows inside one
/// child of somebody else's `ListView` inflate ~3,030 elements, and by 2026-08-20
/// the History TAB had gained a drill-down (FB-90 / design 0074) that the detail
/// page had no list to hang off. The detail page had become strictly weaker than
/// the surface the dealer complained about having to go to.
///
/// So the block became a TAB. This file is its host.
///
/// 🔑 **Design 0065 §0.8.2 licensed exactly this move**, in as many words: its
/// argument against slivers is scoped to "this component, on these five hosts",
/// and it ends "the next person doing a full-screen list page — its own scroll
/// container, no parasite problem — none of the above applies". Dismantling the
/// five hosts is what makes that true, and it is S1's whole job.
///
/// ## S1 is deliberately EQUIVALENT
///
/// This host renders [DeviceHistorySection] unchanged: range row, chart, stats
/// strip, refresh, export — the same widget, the same queries, the same pixels,
/// reachable by one tap instead of a scroll. **The list and the drill-down
/// arrive in S2**, and they arrive as slivers, which is the point of the move.
///
/// Splitting it this way is not ceremony. S1 moves five mount points and the
/// page's whole body structure at once; if it also changed what is drawn, a
/// regression would have two candidate causes and no way to tell them apart.
library;

import 'package:flutter/material.dart';

import 'device_history_section.dart';

/// The history tab's body.
///
/// 🔴 [deviceId] comes from the page, never from a controller — design 0065's
/// first red line, and it survives the container change intact. "The unit being
/// looked at" and "the unit on the link" are different questions; FB-41 / FB-42
/// are what answering the first with the second costs.
class DeviceHistoryTab extends StatelessWidget {
  const DeviceHistoryTab({
    super.key,
    required this.deviceId,
    required this.live,
    this.activationEpoch = 0,
  });

  /// The unit whose page this is.
  final String deviceId;

  /// Whether [deviceId] is the unit currently on the link — computed by the
  /// page (`isOnline && connectedDeviceId == deviceId`) and passed in.
  ///
  /// 🔵 **It gates the warning thresholds, and the owner ruled on 2026-08-21
  /// that it stays** ("警告用的 ov uv ot 要留之後要做"). Since 2026-08-16 it has
  /// had no visible effect — the filter that used it was removed — so it reads
  /// as dead weight, and the design proposed deleting it. It is not dead: S2
  /// classifies every list row through `historyClassifyRow(ov:, uv:, ot:)`, and
  /// those thresholds come from the CONNECTED unit. On a page showing unit A
  /// while the phone holds unit B, ungated, they would judge A's stored rows
  /// against B's limits — FB-41's shape in a third column. See design 0079 §0.3.
  final bool live;

  /// Bumped by the page every time this tab becomes the selected one.
  ///
  /// 🔴 **This is what closes FB-84**, and it is worth being precise about what
  /// FB-84 actually was. The complaint was "opening a device page does not
  /// refresh its history"; the section did query on mount, but behind a 30 s
  /// cache, and never again afterwards. Both halves were real and they have
  /// different fixes. Under tabs the second one dissolves — you arrive at this
  /// surface by an explicit tap, so "on arrival" is a moment that exists — and
  /// the epoch turns each arrival into a forced re-query.
  ///
  /// ⚠️ An `int` rather than a `GlobalKey` or a listener: it goes through
  /// `didUpdateWidget` like any other prop, so a test can drive it without
  /// reaching into anybody's State.
  final int activationEpoch;

  @override
  Widget build(BuildContext context) {
    // The same frame the dashboard routes give their content — `pack_view.dart`
    // and `power_bank_view.dart` both centre a 560-wide column and pad it
    // (15, 3, 15, 14). Matching it is what makes S1 equivalent to look at:
    // the block does not shift sideways or change width when it moves here.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(15, 3, 15, 14),
          children: [
            DeviceHistorySection(
              deviceId: deviceId,
              live: live,
              activationEpoch: activationEpoch,
            ),
          ],
        ),
      ),
    );
  }
}
