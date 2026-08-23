/// OpenSmartBatt — the custom date-range picker (design 0083 S3).
///
/// Two dates, one calendar, and an Apply button. That is the whole feature, and
/// the restraint is deliberate on three counts:
///
///  * 🔵 **Dates only, no time of day** (Q4, ruled 2026-08-23). Looking at one
///    RIDE is already served twice over — the landscape chart pinches down to a
///    minute (design 0081 S3) and the list drills into seconds (design 0074) —
///    so a clock here would double the sheet to duplicate what exists.
///    ⛔ Marketing copy must not describe this as "pick a time".
///  * **Bounded by what the unit actually recorded.** `firstData` / `lastData`
///    come from an unscoped `historyStats`, so a day with nothing in it cannot
///    be selected at all. Letting someone pick a guaranteed-empty span and then
///    explaining the emptiness afterwards is a worse conversation than not
///    offering it.
///  * **No `showDateRangePicker`.** Material's is full-screen and carries its
///    own visual language; pinning it back to this app's would mean overriding
///    a `ThemeData` subtree just to make a stock widget stop looking stock.
///    An embedded [CalendarDatePicker] is the piece worth reusing — nobody
///    should hand-roll a calendar grid — and it themes with three colours.
///
/// 🔴 **The half-open conversion is NOT here.** It is `historyCustomRange`, in
/// the shared kernel, and this sheet calls it: the sheet talks in the days a
/// person picked, the kernel turns "up to the 15th" into midnight on the 16th.
/// Doing that arithmetic here would put it one import away from the next entry
/// point that needs it.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../theme/app_theme.dart';
import 'history_query.dart';

/// Ask for a custom span, or null if the user backs out.
///
/// [firstData] / [lastData] bound the calendar — the extremes of what this
/// scope holds. [initial] pre-selects a previous custom choice; a preset
/// selection starts the picker on the last recorded day, which is where someone
/// opening this is most likely to be looking.
Future<HistoryRangeSel?> showCustomRangeSheet(
  BuildContext context, {
  required DateTime firstData,
  required DateTime lastData,
  HistoryRangeSel? initial,
}) {
  return showModalBottomSheet<HistoryRangeSel>(
    context: context,
    backgroundColor: context.colors.panel,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: CustomRangeSheet(
          firstData: firstData,
          lastData: lastData,
          initial: initial,
        ),
      ),
    ),
  );
}

/// The sheet's body. PUBLIC so a widget test can pump it without a route
/// around it — the same reason `MinuteSecondsSheet` is.
class CustomRangeSheet extends StatefulWidget {
  const CustomRangeSheet({
    super.key,
    required this.firstData,
    required this.lastData,
    this.initial,
  });

  final DateTime firstData;
  final DateTime lastData;
  final HistoryRangeSel? initial;

  @override
  State<CustomRangeSheet> createState() => _CustomRangeSheetState();
}

/// Which end the calendar is currently editing.
enum _End { from, to }

class _CustomRangeSheetState extends State<CustomRangeSheet> {
  late DateTime _from;
  late DateTime _to;
  _End _editing = _End.from;

  DateTime get _firstDay => _dayOf(widget.firstData);
  DateTime get _lastDay => _dayOf(widget.lastData);

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    final prev = widget.initial;
    // 🔴 The stored upper end is EXCLUSIVE (midnight after the last day), so
    // re-opening a saved span has to step back one day to show the day the user
    // actually picked. Skipping this is the off-by-one that would make every
    // re-open silently extend the range by a day.
    final prevTo = prev?.to;
    _from = _clamp(prev?.from == null ? _lastDay : _dayOf(prev!.from!));
    _to = _clamp(
      prevTo == null
          ? _lastDay
          : _dayOf(prevTo.subtract(const Duration(days: 1))),
    );
  }

  DateTime _clamp(DateTime d) =>
      d.isBefore(_firstDay) ? _firstDay : (d.isAfter(_lastDay) ? _lastDay : d);

  /// 🔑 The only invalid combination the sheet can produce, and it is blocked
  /// rather than corrected: silently swapping the two ends would mean the
  /// screen disagreed with the taps that built it.
  bool get _valid => !_from.isAfter(_to);

  void _pick(DateTime day) {
    setState(() {
      if (_editing == _End.from) {
        _from = day;
        // Picking a start after the current end moves the end with it and
        // hands the user the second field — which is what they are about to
        // want anyway. It never produces an inverted range.
        if (_from.isAfter(_to)) _to = _from;
        _editing = _End.to;
      } else {
        _to = day;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final accent = context.accent;
    final fmt = DateFormat('yyyy/MM/dd');

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              l10n.historyCustomRangeTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _EndField(
                  label: l10n.historyCustomRangeFrom,
                  value: fmt.format(_from),
                  selected: _editing == _End.from,
                  onTap: () => setState(() => _editing = _End.from),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _EndField(
                  label: l10n.historyCustomRangeTo,
                  value: fmt.format(_to),
                  selected: _editing == _End.to,
                  onTap: () => setState(() => _editing = _End.to),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Flexible(
            child: SingleChildScrollView(
              // Three colours, no `ThemeData` surgery — see the library note.
              child: Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: Theme.of(context).colorScheme.copyWith(
                    primary: accent.accent,
                    onPrimary: accent.onAccent,
                    surface: colors.panel,
                  ),
                ),
                child: CalendarDatePicker(
                  key: ValueKey(_editing),
                  initialDate: _editing == _End.from ? _from : _to,
                  firstDate: _firstDay,
                  lastDate: _lastDay,
                  onDateChanged: _pick,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 42,
            child: FilledButton(
              onPressed: _valid
                  ? () => Navigator.of(
                      context,
                    ).pop(historyCustomRange(_from, _to))
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: accent.accent,
                foregroundColor: accent.onAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: Text(l10n.historyCustomRangeApply),
            ),
          ),
        ],
      ),
    );
  }
}

class _EndField extends StatelessWidget {
  const _EndField({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = context.accent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: colors.panel2,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: selected ? accent.accent : colors.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: colors.muted)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 🔵 **`HistoryCustomRangeButton` was DELETED here on 2026-08-24.**
//
// design 0083 Q1 was re-ruled from 案 C to 案 A (owner: 「今天/近7天/全部的右邊
// 放一個自訂」), so the calendar `IconButton` this file used to publish is now
// the segmented control's fourth segment. Its two responsibilities moved with
// it and neither was dropped:
//
//   * `active` — saying a custom range is in force — is now the fourth segment
//     being the SELECTED one, which is what the old doc comment said it wanted
//     and could not have ("there is no fourth segment to light up").
//   * `enabled: false` over an empty database is `SegmentedControl.disabled`,
//     added in the same change for exactly this.
//
// Kept as a note rather than removed silently: `device_history_toolbar_test.dart`
// T10b asserted at SOURCE level that both surfaces mount this widget, and a
// reader who finds that test in the history needs to know the widget went away
// on purpose.

/// The selected span, on its own line — or nothing at all for a preset.
///
/// 🔴 **A SEPARATE line, never appended to the bucket-width note.** That note
/// sits in a fixed three-column row (`SizedBox(40)` · `Expanded(Text)` ·
/// `SizedBox(40)`) whose own comment records it overflowing by 20 px the moment
/// the English string could not wrap — a `Row` gives a `Text` no width to break
/// in. Adding words to it is re-running that.
///
/// 🔑 Returns a zero-size box for the presets rather than an empty line, so the
/// three existing ranges keep exactly the layout height they had.
///
/// ⚠️ Shows the days the USER picked — the stored upper end is exclusive
/// (midnight after the last day), and printing that would read as an
/// off-by-one to everyone who did not write it.
class HistoryCustomRangeLine extends StatelessWidget {
  const HistoryCustomRangeLine({super.key, required this.sel});

  final HistoryRangeSel sel;

  @override
  Widget build(BuildContext context) {
    final from = sel.from, to = sel.to;
    if (!sel.isCustom || from == null || to == null) {
      return const SizedBox.shrink();
    }
    final fmt = DateFormat('yyyy/MM/dd');
    final lastDay = to.subtract(const Duration(days: 1));
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        AppLocalizations.of(
          context,
        ).historyCustomRangeLabel(fmt.format(from), fmt.format(lastDay)),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: context.accent.accent,
        ),
      ),
    );
  }
}
