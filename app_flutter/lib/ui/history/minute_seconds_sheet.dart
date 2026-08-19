/// OpenSmartBatt — the History list's per-minute drill-down (design 0074).
///
/// One list row is a MINUTE window over per-second storage (design 0061 T3a);
/// this is what opens when the user taps it. Every second inside that minute,
/// as a row of the same shape, classified by the same rule, aggregated by the
/// same query.
///
/// 🔑 **Nothing here computes a number.** The seconds come back from
/// [TelemetryController.historySecondsInWindow], which is
/// `queryListBuckets(bucketMs: 1000)` — the same `samples`-weighted means, the
/// same `MAX(mode)`, the same MIN/MAX extremes as the row above. FB-74 was two
/// surfaces disagreeing about one minute; this sheet and that row would be the
/// same defect with both halves on screen at once (design 0074 §3.1).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../data/history_repo.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'history_screen.dart';

/// Open the drill-down for [row].
///
/// [ov] / [uv] / [ot] are the thresholds the CALLER classifies with — passed
/// through unchanged so the seconds are judged exactly as the minute above them
/// was (design 0065 §3.2.2's rule: whoever knows whether the thresholds apply
/// is the caller, not the widget).
Future<void> showMinuteSecondsSheet(
  BuildContext context, {
  required HistoryListRow row,
  required TempUnit tempUnit,
  required ProductClass deviceClass,
  double? ov,
  double? uv,
  double? ot,
}) {
  final colors = context.colors;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.panel,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: MinuteSecondsSheet(
          row: row,
          tempUnit: tempUnit,
          deviceClass: deviceClass,
          ov: ov,
          uv: uv,
          ot: ot,
        ),
      ),
    ),
  );
}

/// The sheet's body. PUBLIC so a widget test can pump it without a bottom
/// sheet route around it.
class MinuteSecondsSheet extends StatefulWidget {
  const MinuteSecondsSheet({
    super.key,
    required this.row,
    required this.tempUnit,
    required this.deviceClass,
    this.ov,
    this.uv,
    this.ot,
  });

  final HistoryListRow row;
  final TempUnit tempUnit;
  final ProductClass deviceClass;
  final double? ov, uv, ot;

  @override
  State<MinuteSecondsSheet> createState() => _MinuteSecondsSheetState();
}

class _MinuteSecondsSheetState extends State<MinuteSecondsSheet> {
  late final Future<List<HistoryListRow>> _future;

  DateTime get _start => widget.row.sample.timestamp;
  DateTime get _end =>
      _start.add(Duration(milliseconds: widget.row.bucketMs));

  @override
  void initState() {
    super.initState();
    // Read once, in initState: a `FutureBuilder` fed from `build` re-queries on
    // every rebuild, and a sheet rebuilds whenever the keyboard, the theme or
    // an inherited widget moves.
    _future = context.read<TelemetryController>().historySecondsInWindow(
          from: _start,
          windowMs: widget.row.bucketMs,
          deviceId: widget.row.deviceId,
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    return FutureBuilder<List<HistoryListRow>>(
      future: _future,
      builder: (context, snap) {
        final seconds = snap.data ?? const <HistoryListRow>[];
        // Only the rows that ARE seconds count. A minute holding one legacy
        // row and forty stored seconds says "40", not "41" — the legacy row is
        // an average of the whole minute, not a 41st second of it.
        final real = seconds.where((r) => r.hasStoredSeconds).toList();
        final samples = seconds.fold<int>(
            0, (a, r) => a + (r.samples ?? 0));
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.historySecondsSheetTitle(
                    DateFormat('HH:mm').format(_start)),
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: colors.text),
              ),
              const SizedBox(height: 6),
              if (snap.connectionState == ConnectionState.waiting)
                _pending()
              else ...[
                // 🔴 The count is the NUMERATOR only — never "40/60". Nothing
                // in the data says how many seconds this minute SHOULD hold:
                // recording needs a live link and the auto-log setting, and
                // neither leaves a "should have been here" row behind. A
                // denominator would invent a completeness we cannot measure
                // (design 0074 R2).
                Text(
                  [
                    l10n.historySecondsCount(real.length),
                    if (samples > 0) l10n.historySecondsSamples(samples),
                  ].join(' · '),
                  style: TextStyle(fontSize: 11.5, color: colors.muted),
                ),
                if (_end.isAfter(DateTime.now())) ...[
                  const SizedBox(height: 4),
                  Text(l10n.historySecondsInProgress,
                      style:
                          TextStyle(fontSize: 11.5, color: colors.muted)),
                ],
                const SizedBox(height: 14),
                ..._body(l10n, seconds, real),
              ],
            ],
          ),
        );
      },
    );
  }

  List<Widget> _body(
    AppLocalizations l10n,
    List<HistoryListRow> seconds,
    List<HistoryListRow> real,
  ) {
    if (seconds.isEmpty) return [_note(l10n.historySecondsEmpty)];
    // Every row is a minute average ⇒ there is nothing to expand, and saying
    // so is the whole job. ⛔ The 60 seconds are NOT invented from it (design
    // 0061 §3.2.3 E3), and the sheet does NOT come up blank (design 0074 R3):
    // blank reads as data loss, and no data was lost — that version simply did
    // not record seconds.
    if (real.isEmpty) return [_note(l10n.historySecondsLegacyOnly)];
    return [
      for (final r in seconds)
        if (r.hasStoredSeconds)
          HistoryRow(
            row: r,
            tempUnit: widget.tempUnit,
            status: historyClassifyRow(r,
                ov: widget.ov, uv: widget.uv, ot: widget.ot),
            deviceClass: widget.deviceClass,
            showSeconds: true,
          )
        else ...[
          // The upgrade minute holds both kinds. This row is SHOWN, labelled,
          // and stamped `HH:mm` rather than `HH:mm:ss` — it is the average of
          // the whole minute and its `:00` names no second. Dropping it to keep
          // the list uniform would be silent data loss (design 0074 §3.2).
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l10n.historySecondsLegacyRow,
                style: TextStyle(
                    fontSize: 10.5, color: context.colors.muted)),
          ),
          HistoryRow(
            row: r,
            tempUnit: widget.tempUnit,
            status: historyClassifyRow(r,
                ov: widget.ov, uv: widget.uv, ot: widget.ot),
            deviceClass: widget.deviceClass,
          ),
        ],
    ];
  }

  Widget _pending() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 34),
        child: Center(
          child: CircularProgressIndicator(color: context.accent.accent),
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, height: 1.75, color: context.colors.muted)),
      );
}
