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
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
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
    _to = _clamp(prevTo == null
        ? _lastDay
        : _dayOf(prevTo.subtract(const Duration(days: 1))));
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
                  ? () => Navigator.of(context)
                      .pop(historyCustomRange(_from, _to))
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
            Text(label,
                style: TextStyle(fontSize: 10, color: colors.muted)),
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

/// The calendar button — 🔵 **one widget, both surfaces** (design 0083 §3.3).
///
/// The History tab's range row and the device page's differ in what else is on
/// them (design 0081 §1.4), which is exactly why the button itself must not:
/// a user who learns it in one place has to recognise it in the other.
///
/// 🔴 **[active] is how the screen says "a custom range is in force".** The
/// segmented control shows nothing selected in that state — there is no fourth
/// segment to light up (§4.1 case A: it does not fit) — so this button IS the
/// indicator. Without it the three segments would all look unselected for no
/// visible reason.
///
/// 🔴 **[enabled] false when the unit has no rows at all** (§3.3.4). Offering a
/// picker over an empty database lets someone choose a span that cannot
/// contain anything, and then explains the emptiness afterwards.
class HistoryCustomRangeButton extends StatelessWidget {
  const HistoryCustomRangeButton({
    super.key,
    required this.active,
    required this.enabled,
    required this.onPressed,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = context.accent;
    return IconButton(
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        Icons.event_outlined,
        size: 18,
        color: active ? accent.accent : null,
      ),
      tooltip:
          enabled ? l10n.historyRangeCustom : l10n.historyCustomRangeNoData,
      // 40 dp floor, named rather than inherited — see FB-70.
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      // 🔴 **`shrinkWrap` and the 40 dp floor together, and both are needed.**
      // Material's default `padded` tap target lays an IconButton out at 48
      // even with zero padding and a 40 dp constraint — measured 2026-08-23,
      // and it is why the detail row's real budget for the segmented control
      // was 188.5 px rather than the 204 design 0083 §1.4 computed from the
      // nominal 40s. `shrinkWrap` lets `constraints` decide, which gives back
      // ~15 px and is what makes the English labels fit at 1.15× text scale.
      // ⛔ Removing `constraints` along with this would drop the button to the
      // 14 dp hit box FB-70 was about.
      style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    );
  }
}

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
        AppLocalizations.of(context).historyCustomRangeLabel(
            fmt.format(from), fmt.format(lastDay)),
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
