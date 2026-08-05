/// OpenSmartBatt — power-bank energy-path row (design 0035).
///
/// One line answers the four questions a power bank's owner actually has: which
/// way energy is moving, through which port, on what protocol, at what voltage
/// and current. It replaces the two-port "USB" card, whose halves permanently
/// said "unknown" (design 0035 §1.2 / §4.1).
///
/// The discipline that makes it honest lives in three rules, each the direct
/// consequence of what the flag byte can and cannot prove:
///
///   * DIRECTION comes from the current sign alone ([powerFlowOf]) — never from
///     b7 bit2/bit3, which are weaker (design 0035 §4.2). Port and direction are
///     read from the SAME sample so they cannot disagree (§4.5 / G3).
///   * The PORT is Type-C (b7 bit1, a cable/CC detection), Type-A **by
///     elimination**, or "path undetermined". There is still no Type-A bit —
///     bit0 was refuted as one in four field readings (§4.3) — but with bit1
///     clear and the bank discharging there is no other path the energy can
///     take, and that holds 29,114/0 over every port-marked capture on three
///     units (2026-08-05, `feedback-analysis/2026.08.04-014.md` §1). The
///     elimination is restricted to discharge: nothing in the corpus charges
///     with bit1 clear, so that case stays undetermined and keeps the
///     lightweight feedback hook (§4.8) that lets the user tag it.
///   * "PD" is a positive-only badge from bit3 (input) / bit5 (output), never
///     crossed and never negated. bit3 is ONE-WAY — a 9.05 V/1.83 A charge
///     reads it clear (16 counter-examples) — so a "non-PD"/"standard" label
///     would be fabrication (§4.4). We show the measured voltage and let it
///     speak for itself.
///
/// Standby is two shapes: b7 == 0x00 **corroborated by an idle current** is the
/// boost rail off ("standby · output off"); an in-band near-zero current with
/// the rail up is "standby · no flow" (§4.6). Before the first `0x4B` arrives
/// (up to ~10 s per connect) the row says "waiting · connected N s" rather than
/// a decoded zero (§4.6). A non-power-bank renders nothing.
///
/// ## Why standby needs corroboration (2026-08-05)
///
/// `b7 == 0x00` on its own is one bit of one sample, and it is not reliable. A
/// 10.5 h capture at 1 Hz — 36,152 complete bursts, the corpus's largest —
/// contains **5 frames where b7 read 0x00 while the unit was demonstrably not
/// idle**: a 2,718 mA discharge with the port voltage held ≥ 5.17 V across
/// ±2 s, a 68 mA discharge, a 4,712 mV charge-side reading. At 1 Hz that
/// surfaces as a visible flicker of "output off" about every two hours.
///
/// So the ladder now requires the SAME BURST to agree with the flag:
///
///   * `b7 == 0x00` AND `powerFlowOf(current) == idle` ⇒ standby · output off.
///     A genuinely rail-off unit reads `0x49` at 36–39 mA and `0x4A` at 0,
///     computing to ≈ −0.039 A — inside the ±0.05 A dead-band, so idle always
///     holds for a real rail-off. Behaviour there is unchanged.
///   * `b7 == 0x00` BUT current is flowing ⇒ the flag contradicts the current.
///     **Claim neither.** Show the direction, the readings, and "path
///     undetermined". Deliberately NOT a fall-through to the normal port
///     ladder: with b7 == 0x00 bit1 is clear, so Type-A-by-elimination would
///     confidently print "Type-A" — and the operator had the 2,718 mA sample
///     marked as Type-C. A contradictory sample must say "I don't know".
///
/// A DEBOUNCE was considered and rejected: it needs state and it costs latency
/// on the genuine transition. Corroboration is stateless, instant, and uses a
/// signal already in the same burst — which is what §4.5 asked for and was
/// recorded as an "acceptable deviation" for not doing. Do not reintroduce one.
///
/// ⚠️ **Status: this is a ROBUSTNESS GUARD, not a protocol claim.** It asserts
/// nothing new about the wire — b7 == 0x00 still means "boost rail off" and the
/// documentation is unchanged on that point. It only stops the UI acting on a
/// single uncorroborated bit. That is why a single-unit observation was allowed
/// to change behaviour at all: the corpus's multi-machine bar governs what we
/// *assert*, and this asserts nothing.
///
/// No register numbers or raw bytes reach the screen (design 0017 string
/// discipline); the raw b7 the feedback hook records rides the diagnostic log,
/// never the UI.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial_card.dart';
import 'power_flow.dart';

/// The energy-path row, as a standalone card (design 0035 Q3).
class PowerPathRow extends StatefulWidget {
  const PowerPathRow({super.key});

  @override
  State<PowerPathRow> createState() => _PowerPathRowState();
}

class _PowerPathRowState extends State<PowerPathRow> {
  /// Whether the §4.8 hook has been answered or dismissed for this connection.
  /// The State outlives rebuilds but not a reconnect (the view is torn down and
  /// rebuilt), which is exactly "once per connection" — non-nagging (§4.8).
  bool _hookHandled = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = context.watch<TelemetryController>();
    final conn = context.watch<ConnectionController>();

    // T10: only a power bank has an energy path. Not "draw an empty card" —
    // render nothing (design 0034 §4.3: an unavailable module is not offered).
    if (conn.packLabel != ProductClass.powerBank) {
      return const SizedBox.shrink();
    }

    final b7 = tele.portFlagsRaw;

    final Widget body;
    if (b7 == null) {
      // 0x4B has not arrived yet. "connected N s" must read differently from a
      // decoded reading of zero — the difference between "not yet" and "--"
      // (design 0035 §4.6, 0017 §3.5).
      final seconds = (conn.onlineFor ?? Duration.zero).inSeconds;
      body = Text(
        l10n.powerPathWaiting(seconds),
        style: TextStyle(fontSize: 12.5, color: context.colors.muted),
      );
    } else if (tele.isRailOff == true &&
        powerFlowOf(tele.current) == PowerFlow.idle) {
      // b7 == 0x00 AND the same burst's current is in the dead-band — the two
      // corroborate, so this is a genuine rail-off. The standby test still
      // comes FIRST in the ladder (§3.3 / §4.3); it just no longer fires on
      // the flag alone (see the "why standby needs corroboration" note above).
      body = _railOff(context, l10n);
    } else if (tele.isRailOff == true) {
      // b7 == 0x00 while current is flowing: the flag and the current disagree
      // inside one burst. Claim NEITHER — not standby, and not a port either.
      body = _path(context, l10n, tele, flagsContradicted: true);
    } else {
      body = _path(context, l10n, tele);
    }

    return IndustrialCard(
      heading: l10n.powerPathHeading,
      headingIcon: Icons.bolt,
      child: body,
    );
  }

  /// b7 == 0x00 corroborated by an idle current: the rail really is off.
  ///
  /// No direction word: this branch is only reached when the flow is idle, so
  /// there is no direction to name. (It used to print one, because the branch
  /// used to be reached with a live current too — that combination is now the
  /// contradiction case and never lands here.)
  Widget _railOff(BuildContext context, AppLocalizations l10n) {
    return Text(
      l10n.powerPathStandbyOutputOff,
      style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: context.colors.text),
    );
  }

  /// The full row: direction → port → protocol → readings.
  ///
  /// [flagsContradicted] is the spurious-`0x00` case: b7 says the rail is off
  /// while the same burst's current says energy is moving. The direction and
  /// the readings still stand — they come from `0x49`/`0x4A`, not from b7 — but
  /// EVERY b7-derived claim is withheld: no port (not even the derived Type-A,
  /// which bit1-clear would otherwise hand us), no PD badge, and no §4.8 hook
  /// (we do not ask the user to label a burst we do not trust).
  Widget _path(
      BuildContext context, AppLocalizations l10n, TelemetryController tele,
      {bool flagsContradicted = false}) {
    final colors = context.colors;
    final flow = powerFlowOf(tele.current);
    final active = flow == PowerFlow.charging || flow == PowerFlow.discharging;
    final isTypeC = !flagsContradicted && tele.usbPort == UsbPort.typeC;

    // PD badge: bit3 while charging (input), bit5 while discharging (output).
    // NEVER crossed, and never shown for idle/unknown. A CLEAR bit is not a
    // "non-PD" claim — 16 charging counter-examples read bit3 clear (§4.4), so
    // there is no negative label here, ever. Do not "helpfully" add one.
    final showPd = !flagsContradicted &&
        ((flow == PowerFlow.charging && tele.isPdIn == true) ||
            (flow == PowerFlow.discharging && tele.isPdOut == true));

    final row = <Widget>[];

    // ---- segment 1: direction (or the in-band standby label) ---------------
    if (flow == PowerFlow.idle) {
      // Rail up but current in the dead-band: "standby · no flow" (§4.6). This
      // is the correct face of bit1's "first 11 seconds" — a Type-C cable that
      // is inserted but not yet supplying reads here, and must NOT read as
      // "Type-C supplying" (§4.5). No debounce: this sample decides the frame.
      row.add(Text(
        l10n.powerPathStandbyNoFlow,
        style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, color: colors.text),
      ));
    } else {
      final word = _directionWord(l10n, flow);
      final color = powerFlowColor(context, flow);
      row
        ..add(_flowIcon(flow, color))
        ..add(Text(word ?? '--',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: color)));
    }

    // ---- segment 2: port badge --------------------------------------------
    row
      ..add(_dot(context))
      ..add(flagsContradicted
          ? _undeterminedBadge(context, l10n)
          : _portBadge(context, l10n, isTypeC, active, flow));
    if (showPd) row.add(_pdBadge(context, l10n));

    // ---- segment 3: readings ----------------------------------------------
    row
      ..add(_dot(context))
      ..add(_reading(context, _fmt2(tele.svlt), 'V'))
      ..add(_reading(context, _fmt2Abs(tele.current), 'A'));

    final rowWrap = Wrap(
      spacing: 7,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: row,
    );

    // ---- §4.8 feedback hook: only when we genuinely do not know the port ---
    // "path undetermined" AND actually moving (not standby). Type-C is known,
    // so it is never hooked (avoid nagging). The hook records data only; it
    // changes NO display decision — bit0 stays out of every field above.
    //
    // Narrowed 2026-08-05: discharge with bit1 clear is now DERIVED as Type-A,
    // so hooking it would be asking a question we can already answer — and it
    // is the commonest state a bank sits in, which is how a non-nagging hook
    // becomes a nagging one. What is left genuinely unknown is CHARGING with no
    // Type-C cable, which no capture in the corpus contains; if a user is in
    // that state we want to hear about it. (The one field use of this hook so
    // far, in the 2026-08-04 controlled capture, tagged `a` at b7=0x05 while
    // discharging 473 mA — the derivation would have printed Type-A unasked.)
    //
    // Never hooked on a contradicted burst either: the answer would be filed
    // against a b7 we have just decided not to believe.
    final showHook = !flagsContradicted &&
        !isTypeC &&
        flow == PowerFlow.charging &&
        !_hookHandled;
    if (!showHook) return rowWrap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        rowWrap,
        const SizedBox(height: 8),
        _hook(context, l10n),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // §4.8 feedback hook
  // -------------------------------------------------------------------------

  Widget _hook(BuildContext context, AppLocalizations l10n) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => _openTagChooser(context, l10n),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.help_outline, size: 13, color: colors.muted),
                const SizedBox(width: 5),
                Text(
                  l10n.powerPathAskWhichPort,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.muted,
                    decoration: TextDecoration.underline,
                    decorationColor: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Dismiss without answering — the hook must be closable, not a nag
        // (§4.8). Handled the same way as an answer: gone for this connection.
        InkWell(
          onTap: () => setState(() => _hookHandled = true),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 13, color: colors.muted),
          ),
        ),
      ],
    );
  }

  Future<void> _openTagChooser(
      BuildContext context, AppLocalizations l10n) async {
    // (code, label) — the code is a stable ASCII token tooling matches on, the
    // label follows the locale (mirrors CaptureMark.code vs its label).
    final options = <(String, String)>[
      ('c', l10n.usbPortTypeC),
      ('a', l10n.usbPortTypeA),
      ('other', l10n.powerPathTagOther),
    ];
    final chosen = await showModalBottomSheet<(String, String)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l10n.powerPathAskWhichPort,
                    style: Theme.of(ctx).textTheme.titleSmall),
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.$2),
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    // Use the State's own context after the async gap (guarded by [mounted]).
    _recordTag(l10n, chosen.$1, chosen.$2);
  }

  /// Record the user's tag + the current raw b7 + time as one local report,
  /// through the design 0029 no-telemetry pathway (the always-on event channel
  /// [CaptureMark] already uses, so it lands even with raw packet logging off —
  /// this is passive collection, not a capture session). Nothing auto-uploads;
  /// it joins the user-exportable feedback. The raw byte is diagnostic log
  /// content, never shown on screen.
  void _recordTag(AppLocalizations l10n, String code, String label) {
    final conn = context.read<ConnectionController>();
    final b7 = context.read<TelemetryController>().portFlagsRaw;
    final hex =
        b7 == null ? 'null' : '0x${b7.toRadixString(16).padLeft(2, '0')}';
    conn.markCaptureState(CaptureMark.note, 'port-tag',
        note: 'port-tag=$code b7=$hex');
    setState(() => _hookHandled = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1600),
      content: Text(l10n.powerPathTagSaved(label)),
    ));
  }

  // -------------------------------------------------------------------------
  // Pieces
  // -------------------------------------------------------------------------

  String? _directionWord(AppLocalizations l10n, PowerFlow flow) => switch (flow) {
        PowerFlow.charging => l10n.powerBankDirectionCharging,
        PowerFlow.discharging => l10n.powerBankDirectionDischarging,
        PowerFlow.idle || PowerFlow.unknown => null,
      };

  /// Charging draws energy IN (arrow toward the device); discharging sends it
  /// OUT. Idle/unknown draw no arrow — no direction to point.
  Widget _flowIcon(PowerFlow flow, Color color) {
    final icon = switch (flow) {
      PowerFlow.charging => Icons.arrow_back,
      PowerFlow.discharging => Icons.arrow_forward,
      PowerFlow.idle || PowerFlow.unknown => Icons.remove,
    };
    return Icon(icon, size: 15, color: color);
  }

  /// Which port the energy is using.
  ///
  /// Still NOT read off any Type-A bit — there is none, and bit0 is refuted
  /// (§4.3). Type-A is reached by ELIMINATION instead: with no Type-C cable
  /// present (bit1 clear) and the bank discharging, there is no other path the
  /// energy can be taking. Corpus check over every port-marked power-bank
  /// capture, excluding the `b7 == 0x00` frames the ladder short-circuits
  /// above: **29,114 agree / 0 disagree**, across three physical units
  /// (2026-08-05 corpus-wide sweep, the derivation section) — so this one
  /// clears the multi-unit bar that bit0 never did.
  ///
  /// ⚠️ Restricted to DISCHARGE on purpose. The corpus check paired `0x4A`, so
  /// it says nothing about charging with bit1 clear, and no capture shows that
  /// combination at all. Charging stays "undetermined" until one does.
  ///
  /// 🔲 The Type-C branch is the weaker one, and now says so. bit1 is CABLE
  /// PRESENT, not "the C port is carrying this" — a C cable sitting idle while
  /// the load is on Type-A reads Type-C here. That is not hypothetical: 46
  /// frames in `2026.07.31/001` are exactly it (the operator later confirmed
  /// the C cable was never unplugged). Settling it needs a bit we do not have.
  Widget _portBadge(BuildContext context, AppLocalizations l10n, bool isTypeC,
      bool active, PowerFlow flow) {
    final colors = context.colors;
    if (!isTypeC) {
      if (flow == PowerFlow.discharging) {
        return _badge(
          context,
          l10n.usbPortTypeA,
          fill: AppColors.amber,
          border: AppColors.amber,
          textColor: AppColors.onAmber,
        );
      }
      // Idle, charging, or no reading: nothing to eliminate from.
      return _undeterminedBadge(context, l10n);
    }
    // Type-C present. Filled amber while actually supplying/charging, outline
    // otherwise ("cable inserted" is not "cable in use", §3.2 / §4.1).
    return _badge(
      context,
      l10n.usbPortTypeC,
      fill: active ? AppColors.amber : null,
      border: active ? AppColors.amber : colors.line,
      textColor: active ? AppColors.onAmber : colors.text,
    );
  }

  /// "Path undetermined" — the honest badge. Used both when there is nothing to
  /// eliminate from and when b7 contradicts the current (the spurious-`0x00`
  /// guard), so the two cases cannot drift into different wording.
  Widget _undeterminedBadge(BuildContext context, AppLocalizations l10n) {
    final colors = context.colors;
    return _badge(
      context,
      l10n.powerPathPortUndetermined,
      fill: null,
      border: colors.line,
      textColor: colors.muted,
    );
  }

  Widget _pdBadge(BuildContext context, AppLocalizations l10n) => _badge(
        context,
        l10n.powerPathPd,
        fill: AppColors.cyan.withValues(alpha: 0.18),
        border: AppColors.cyan,
        textColor: AppColors.cyan,
      );

  Widget _badge(BuildContext context, String label,
      {required Color? fill, required Color border, required Color textColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w700, color: textColor),
      ),
    );
  }

  Widget _reading(BuildContext context, String value, String unit) {
    // One plain Text (tabular figures) rather than styled spans: the value and
    // its unit read as one number, and a single string is what the tests pin.
    return Text(
      '$value $unit',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: context.colors.text,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _dot(BuildContext context) => Text('·',
      style: TextStyle(fontSize: 13, color: context.colors.muted));

  static String _fmt2(double? v) => v == null ? '--' : v.toStringAsFixed(2);
  static String _fmt2Abs(double? v) =>
      v == null ? '--' : v.abs().toStringAsFixed(2);
}
