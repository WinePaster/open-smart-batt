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
///     elimination**, or NOTHING AT ALL. There is still no Type-A bit —
///     bit0 was refuted as one in four field readings (§4.3) — but with bit1
///     clear and the bank discharging there is no other path the energy can
///     take, and that holds 29,114/0 over every port-marked capture on three
///     units (2026-08-05, `feedback-analysis/2026.08.04-014.md` §1). The
///     elimination is restricted to discharge: nothing in the corpus charges
///     with bit1 clear, so that case draws no badge and keeps the lightweight
///     feedback hook (§4.8) that lets the user tag it.
///   * "PD" is a positive-only badge from bit3 (input) / bit5 (output), never
///     crossed and never negated. bit3 is ONE-WAY — a 9.05 V/1.83 A charge
///     reads it clear (16 counter-examples) — so a "non-PD"/"standard" label
///     would be fabrication (§4.4). We show the measured voltage and let it
///     speak for itself.
///
/// Standby is ONE shape: an in-band current reads "standby", whether the boost
/// rail is up or down. Before the first `0x4B` arrives (up to ~10 s per connect)
/// the row says "waiting · connected N s" rather than a decoded zero (§4.6). A
/// non-power-bank renders nothing.
///
/// ## What design 0041 removed, and what it deliberately did not
///
/// Two things left this file on 2026-08-05, both by owner ruling after the
/// diagnosis design 0040 §9 A5 asked for:
///
///  1. **The "path undetermined" badge.** Withholding a claim is now expressed
///     by drawing NO badge instead of by printing a word for it. Same meaning,
///     and an empty slot cannot be misread as a third kind of port. ⚠️ The §4.8
///     hook stays: with the badge gone it is the only place this row still says
///     "I don't know", and it fires on exactly the state the corpus never
///     covered (bit1 clear while charging).
///  2. **The two standby strings.** "standby · output off" (rail down) and
///     "standby · no flow" (rail up, no current) both collapse to the plain
///     "standby" the SOC dial already uses — deliberately the SAME l10n key, per
///     §6's one-derivation-one-rendering rule.
///
/// 🔴 The accepted cost of (2), recorded rather than softened: a user can no
/// longer tell "the bank switched its own output off, press the button" from
/// "the bank is awake with nothing drawing". Those imply different next actions.
/// The owner was told this before ruling (design 0041 R1). If the field asks for
/// the distinction back, the answer is a better single sentence — NOT the two
/// states returning.
///
/// ⚠️ What did NOT go: the `isRailOff` corroboration guard below. It stopped
/// choosing a STRING and now only decides whether b7-derived claims are
/// withheld. Deleting it would let a spurious `0x00` print a confident "Type-A"
/// — see the next section, which is still live.
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
/// So the ladder still requires the SAME BURST to agree with the flag:
///
///   * `b7 == 0x00` AND `powerFlowOf(current) == idle` ⇒ a genuine rail-off.
///     A genuinely rail-off unit reads a charge-side `0x49` residual that
///     varies BY UNIT — 36–39 mA on one, a constant 58–69 mA on another
///     (2026-08-07) — so the ±0.05 A dead-band alone does NOT always compute
///     idle here. What does is [powerFlowOf]'s rail-off veto: it reads the
///     same b7 and refuses a charging verdict on a small residual, so idle
///     still holds for every real rail-off. Since design 0041 this needs no
///     branch of its own: it renders as plain "standby", the same as any other
///     in-band reading, and no port badge (bit1 is clear, and idle eliminates
///     nothing).
///   * `b7 == 0x00` BUT current is flowing ⇒ the flag contradicts the current.
///     **Claim neither.** Show the direction and the readings, and withhold
///     every b7-derived claim. Deliberately NOT a fall-through to the normal
///     port ladder: with b7 == 0x00 bit1 is clear, so Type-A-by-elimination
///     would confidently print "Type-A" — and the operator had the 2,718 mA
///     sample marked as Type-C. A contradictory sample must say nothing.
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
///
/// 🔴 [tele] and [shellClass] arrive as PARAMETERS (design 0051 §5). This was
/// the only module card that fetched its own providers, which made it the only
/// one the home editor's fake-data preview could not reach: `packLabel` there is
/// `unknown`, so the row drew nothing at all and the user judged a layout with
/// an invisible card in it. `dashboardCardFor` has both facts already.
class PowerPathRow extends StatefulWidget {
  const PowerPathRow({
    super.key,
    required this.tele,
    required this.shellClass,
  });

  /// What to read. A real link's controller, or the editor's static preview.
  final CardTelemetry tele;

  /// The class the page is drawing as. Only a power bank has an energy path.
  final ProductClass shellClass;

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
    final tele = widget.tele;

    // T10: only a power bank has an energy path. Not "draw an empty card" —
    // render nothing (design 0034 §4.3: an unavailable module is not offered).
    // Read off the parameter since design 0051, not off `packLabel`: same
    // question, one source, and the home editor can answer it too.
    if (widget.shellClass != ProductClass.powerBank) {
      return const SizedBox.shrink();
    }

    final b7 = tele.portFlagsRaw;

    final Widget body;
    if (b7 == null) {
      // 0x4B has not arrived yet. "connected N s" must read differently from a
      // decoded reading of zero — the difference between "not yet" and "--"
      // (design 0035 §4.6, 0017 §3.5).
      //
      // The ONE thing still read from a provider here, and only on this branch:
      // "how long has this link been up" is a fact about the link, not about
      // the sample. The editor's preview never reaches it — its fake b7 is set.
      final seconds =
          (context.watch<ConnectionController>().onlineFor ?? Duration.zero)
              .inSeconds;
      body = Text(
        l10n.powerPathWaiting(seconds),
        style: TextStyle(fontSize: 12.5, color: context.colors.muted),
      );
    } else {
      // Two branches, not four (design 0041 §3.4). The rail-off case no longer
      // gets a rendering of its own — an idle current prints "standby" whether
      // the rail is up or down — so all `isRailOff` decides now is whether b7
      // is trustworthy enough to make claims from.
      //
      // 🔒 That test must NOT be simplified away with the strings it used to
      // pick. b7 == 0x00 while current flows means bit1 is clear, and a
      // discharge would then be printed as a confident "Type-A" by elimination
      // — on the very sample (2,718 mA) whose operator recorded Type-C.
      body = _path(
        context,
        l10n,
        tele,
        flagsContradicted: tele.isRailOff == true &&
            powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw) !=
                PowerFlow.idle,
      );
    }

    return IndustrialCard(
      heading: l10n.powerPathHeading,
      headingIcon: Icons.bolt,
      child: body,
    );
  }

  /// The full row: port → protocol → direction → readings.
  ///
  /// [flagsContradicted] is the spurious-`0x00` case: b7 says the rail is off
  /// while the same burst's current says energy is moving. The direction and
  /// the readings still stand — they come from `0x49`/`0x4A`, not from b7 — but
  /// EVERY b7-derived claim is withheld: no port (not even the derived Type-A,
  /// which bit1-clear would otherwise hand us), no PD badge, and no §4.8 hook
  /// (we do not ask the user to label a burst we do not trust). Since design
  /// 0041 "withheld" means the badge is absent, not that it says so in words.
  Widget _path(
      BuildContext context, AppLocalizations l10n, CardTelemetry tele,
      {bool flagsContradicted = false}) {
    final flow = powerFlowOf(tele.current, portFlagsRaw: tele.portFlagsRaw);
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

    // ---- segment 1: port badge, or NOTHING ---------------------------------
    //
    // Since design 0041 an unknown port draws no badge instead of a "path
    // undetermined" one. A contradicted burst is the same case reached a
    // different way, which is why both go through this single null.
    final badge = flagsContradicted
        ? null
        : _portBadge(context, l10n, isTypeC, active, flow);
    if (badge != null) row.add(badge);
    if (showPd) row.add(_pdBadge(context, l10n));

    // ---- segment 2: direction, placed to READ AS the readings' label -------
    //
    // The direction sits immediately before the numbers on purpose (2026-08-05).
    // It used to lead the row, which left "9.04 V  0.68 A" bare at the far end
    // with two separators and two badges between them and the only word saying
    // which way the energy goes. A reporter on 0.6.14 put it plainly: "no
    // charging voltage shown". He was right, and the fix is adjacency —
    // "CHARGING 9.04 V 0.68 A" reads as one clause.
    //
    // ⚠️ Deliberately NOT a per-reading label ("input voltage" / "output
    // voltage"), even though both strings still sit unused in the .arb from
    // design 0037. A label is a SECOND surface that has to stay in agreement
    // with [PowerFlow], and a label saying the wrong thing is precisely FB-47:
    // a 9.15 V PD charge printed under "Output Voltage", which the owner read
    // as his device being broken. One derivation, one rendering (§6) —
    // adjacency cannot disagree with the word it is adjacent to. Do not
    // "improve" this by reintroducing the labels.
    //
    // Losing the leading slot costs nothing since v0.7.3: the SOC dial above
    // carries the direction as its own sub-line, so the glanceable copy lives
    // there and this row is free to spend the slot on precision.
    // The separator parts the badges from the direction, so it only belongs
    // there when a badge actually preceded it (design 0041 §3.3): with the
    // "undetermined" badge gone, an unconditional dot would sit at the head of
    // the row as an orphan.
    if (row.isNotEmpty) row.add(_dot(context));
    // ONE branch for every flow, standby included (design 0041 §3.4). Standby
    // is drawn exactly like a direction because it IS the answer to the same
    // question — and in the same muted colour the SOC dial's sub-line gives it,
    // from the shared [powerFlowColor] table, so the two cannot disagree.
    //
    // This is also the correct face of bit1's "first 11 seconds": a Type-C
    // cable inserted but not yet supplying lands here and reads "Type-C ·
    // standby", never "Type-C supplying" (§4.5). No debounce: this sample
    // decides this frame.
    final word = _directionWord(l10n, flow);
    final color = powerFlowColor(context, flow);
    row
      ..add(_flowIcon(flow, color))
      ..add(Text(word ?? '--',
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: color)));

    // ---- segment 3: readings, no separator — they belong to the word above --
    row
      ..add(_reading(context, _fmt2(tele.svlt), 'V'))
      ..add(_reading(context, _fmt2Abs(tele.current), 'A'));

    final rowWrap = Wrap(
      spacing: 7,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: row,
    );

    // ---- §4.8 feedback hook: only when we genuinely do not know the port ---
    // No badge drawn AND actually moving (not standby). Type-C is known, so it
    // is never hooked (avoid nagging). The hook records data only; it changes
    // NO display decision — bit0 stays out of every field above.
    //
    // ⚠️ Load-bearing since design 0041 removed the "path undetermined" badge:
    // this line is now the ONLY place the row admits it does not know. Deleting
    // it would leave the unknown-port case rendering as a bare direction, with
    // nothing distinguishing "we chose not to claim" from "there is no port".
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
    final b7 = widget.tele.portFlagsRaw;
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

  /// The word for [flow]. `null` only for [PowerFlow.unknown] — the ABSENCE of
  /// a current reading, which the caller renders as `--`.
  ///
  /// [PowerFlow.idle] is a word now, and deliberately the SAME key the SOC
  /// dial's sub-line uses (design 0041 §3.4): one state, one string, on one
  /// screen. It replaced two — "standby · output off" and "standby · no flow" —
  /// whose difference (boost rail down vs merely nothing flowing) the owner
  /// ruled was internal detail. Do not reintroduce a second standby string
  /// here without reading design 0041 R1 first; the distinction was given up
  /// knowingly, not overlooked.
  String? _directionWord(AppLocalizations l10n, PowerFlow flow) => switch (flow) {
        PowerFlow.charging => l10n.powerBankDirectionCharging,
        PowerFlow.discharging => l10n.powerBankDirectionDischarging,
        PowerFlow.idle => l10n.powerBankDirectionIdle,
        PowerFlow.unknown => null,
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
  /// combination at all. Charging draws no badge until one does.
  ///
  /// 🔲 The Type-C branch is the weaker one, and now says so. bit1 is CABLE
  /// PRESENT, not "the C port is carrying this" — a C cable sitting idle while
  /// the load is on Type-A reads Type-C here. That is not hypothetical: 46
  /// frames in `2026.07.31/001` are exactly it (the operator later confirmed
  /// the C cable was never unplugged). Settling it needs a bit we do not have.
  ///
  /// Returns `null` when there is nothing to claim. Design 0041 Q3 removed the
  /// "path undetermined" badge that used to fill that slot: an empty slot says
  /// the same thing, and cannot be misread as a third kind of port.
  Widget? _portBadge(BuildContext context, AppLocalizations l10n, bool isTypeC,
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
      // Idle, charging, or no reading: nothing to eliminate from. Draw nothing
      // — and, while charging, let the §4.8 hook do the asking instead.
      return null;
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
