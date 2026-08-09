/// OpenSmartBatt — the clock card (design 0052).
///
/// ## 🔴 THE FIRST CARD IN THIS APP THAT CAN ALWAYS DRAW
///
/// Every other card in `dashboard_cards.dart` is downstream of something that
/// can be missing: a BLE link, a decoded frame, a GNSS fix, a mount
/// calibration, a product class. So the codebase's shared assumptions — "a card
/// with nothing to say shows `--`" (`HomeWaitingTile`), "offline is the common
/// case", "availability is a runtime state" — are all statements about cards
/// with an upstream. This one has none:
///
///  * it is **never** [HomeWaitingTile]. There is no waiting state, no `--`,
///    and no path that produces one. `_ModuleTile`'s offline branch is
///    unreachable for it, because a clock tile carries no `deviceId`.
///  * it is **not** `dataGated` — nothing arrives for it to gate on.
///  * it has **no availability condition**. [phoneModuleAvailable] answers a
///    literal `true` for it, written out rather than inherited from a wildcard
///    (design 0052 §3.5), so "the clock has no gate" is a DECLARATION in the
///    source and not an accident of a `_ =>` arm.
///
/// Anyone reasoning about "what does the home page look like with nothing
/// connected" must therefore treat this card as an exception to the whole of
/// that reasoning. That is the point of it — design 0052 §2: a home page whose
/// every tile can be empty at once has nothing to say on the screen it is most
/// often opened on.
///
/// ## Why it lives beside the dashboard cards
///
/// It is a home-only module (design 0051 A: phone modules are not on any
/// watchface), and so are `speed` and `gForce`, which are in this directory
/// already. `dashboardCardFor` is the single module → card map both surfaces
/// go through; splitting the map's targets across two directories by which
/// surface currently places them would be a filing decision that goes stale the
/// next time a ruling moves a module.
///
/// ## The three seams (design 0052 §3)
///
///  1. [ClockView] — an exhaustive `switch` with no `default`. V1 has exactly
///     one member, and the structure is here anyway so that adding `analog`
///     (ruled to be a CONTENT VARIANT of this one card, not a second module) is
///     an added `case` rather than a rewrite.
///  2. [ClockCard.now] — the time source is injectable, the same seam
///     `relativeTime` uses. It is what lets a test state a time instead of
///     waiting for one.
///  3. The ticker is a separate object ([AlignedTicker]) and the PERIOD is
///     declared by the view ([ClockView.tickPeriod]), so a variant that shows
///     seconds changes one expression rather than the scheduling code.
///
/// ## No in-card style switch
///
/// Design 0040 §3.4 retired the readouts card's numbers/chart toggle: a
/// per-card view control is a second, weaker mechanism for a question the
/// layout already answers. When the analog variant lands, it is chosen where
/// the card is placed — never by a button on the card.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../util/aligned_ticker.dart';
import '../widgets/industrial_card.dart';

/// How the clock card draws itself.
///
/// One member today. It is an enum rather than a bare widget because design
/// 0052 §3 seam ① wants the branch point to EXIST before there is a second
/// branch: the alternative — writing V1 as the only possible rendering and
/// adding an `if` when `analog` arrives — is how a variant ends up as a copy of
/// the card instead of a case of it.
enum ClockView {
  /// V1, ruled by the owner from four mockup variants: hours and minutes, no
  /// seconds, no date, no weekday (`design/mockups/0052-clock-card.html`).
  digital;

  /// How often this view has to be redrawn.
  ///
  /// 🔑 The VIEW declares it, not the card. `digital` shows no seconds, so a
  /// per-second rebuild would repaint an identical string 59 times out of 60;
  /// a future `analog` with a sweep hand, or a variant carrying seconds, says
  /// something different here and nothing else changes.
  ///
  /// Exhaustive, no `default` — see the library comment.
  Duration get tickPeriod => switch (this) {
        ClockView.digital => const Duration(minutes: 1),
      };
}

/// The clock, ticking.
///
/// 🔴 Mounting this ARMS A TIMER, which is why the home editor must not build
/// one — `previewCardFor` mounts [ClockCardBody] with a fixed time instead.
/// That is the same rule, and the same shape, as `SpeedCard` / `GForceCard`
/// opening the GNSS receiver and the accelerometer from
/// `didChangeDependencies` (design 0051 §5). The consequence here is a wasted
/// rebuild rather than a privacy leak, so it is stated plainly rather than in
/// red: an editor tile that re-rendered every minute would still be a screen
/// doing work nobody asked for while a drag is in progress.
class ClockCard extends StatefulWidget {
  const ClockCard({super.key, this.view = ClockView.digital, this.now});

  final ClockView view;

  /// The time source. Null means the real clock.
  final DateTime Function()? now;

  @override
  State<ClockCard> createState() => _ClockCardState();
}

class _ClockCardState extends State<ClockCard> {
  late AlignedTicker _ticker;
  late DateTime _time;

  DateTime Function() get _now => widget.now ?? DateTime.now;

  @override
  void initState() {
    super.initState();
    _time = _now();
    _startTicker();
  }

  @override
  void didUpdateWidget(ClockCard old) {
    super.didUpdateWidget(old);
    // The period is a property of the view, so a view change is a schedule
    // change. Rebuilding the ticker rather than mutating it keeps "one armed
    // timer per mounted card" true through the swap.
    if (old.view.tickPeriod != widget.view.tickPeriod || old.now != widget.now) {
      _ticker.stop();
      _time = _now();
      _startTicker();
    }
  }

  void _startTicker() {
    _ticker = AlignedTicker(
      period: widget.view.tickPeriod,
      now: _now,
      onTick: () {
        if (!mounted) return;
        setState(() => _time = _now());
      },
    )..start();
  }

  @override
  void dispose() {
    // 🔴 Not optional. See [AlignedTicker.stop].
    _ticker.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ClockCardBody(time: _time, view: widget.view);
}

/// The clock's pixels, with no timer behind them.
///
/// Extracted for the same reason `SpeedCardBody` and `GForceCardBody` are: the
/// home editor draws sample data and must mount NO side effect (design 0051
/// §5). It is also what makes every rendering test below a pure function of an
/// argument.
class ClockCardBody extends StatelessWidget {
  const ClockCardBody({
    super.key,
    required this.time,
    this.view = ClockView.digital,
  });

  final DateTime time;
  final ClockView view;

  @override
  Widget build(BuildContext context) {
    // Exhaustive, no `default` (design 0052 §3 seam ①). A new [ClockView] is a
    // compile error here — which is the entire reason the enum exists while
    // there is only one of them.
    switch (view) {
      case ClockView.digital:
        return _DigitalClock(time: time);
    }
  }
}

/// V1: `19:50`, or `7:50 PM` where the system says 12-hour.
class _DigitalClock extends StatelessWidget {
  const _DigitalClock({required this.time});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 🔴 The system's answer, not the app's (design 0052 §5).
    //
    // `alwaysUse24HourFormat` is what the OS reports for this device. Making it
    // an app setting would mean an `AppSettings` field, a schema v13 → v14
    // migration, a settings row and two ARB keys — four owned artefacts for a
    // question the platform has already asked the user once, and whose answer
    // every other clock on their phone already obeys.
    final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
    final material = MaterialLocalizations.of(context);
    // The day period comes from the FRAMEWORK's localizations, not from
    // `app_en.arb`. "AM"/"上午" is a locale fact Flutter already ships in every
    // supported locale; restating it in our own ARB would be re-translating the
    // framework and would drift from the rest of the phone.
    final period = use24
        ? null
        : (time.hour < 12
            ? material.anteMeridiemAbbreviation
            : material.postMeridiemAbbreviation);

    return IndustrialCard(
      heading: l10n.homeModuleClock,
      headingIcon: Icons.schedule,
      child: Row(
        children: [
          // The `_BigValue` shape from `home_tiles.dart`, deliberately: 32 px
          // mono w700 at `height: 1`, a 4 px gap, a 13 px qualifier — and the
          // whole thing inside `FittedBox(scaleDown)` so a wide rendering
          // shrinks instead of overflowing.
          //
          // Scaling matters more here than it looks. `19:50` fits a 148 px 1x1
          // slot with room to spare, but a 12-hour locale adds a day-period
          // word that is two full-width glyphs in Chinese (下午), and a user
          // who has enlarged their system font multiplies both. Every one of
          // those is a real phone.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    clockDigits(time, use24Hour: use24),
                    maxLines: 1,
                    softWrap: false,
                    style: AppTextStyles.mono(context).copyWith(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      letterSpacing: -0.5,
                      color: context.colors.text,
                    ),
                  ),
                  if (period != null) ...[
                    const SizedBox(width: 4),
                    // Muted, not amber. Amber marks a UNIT (`_BigValue`); the
                    // day period is part of the reading itself, demoted so the
                    // digits stay the thing you read.
                    Text(
                      period,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.colors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `19:50` (24-hour) or `7:50` (12-hour). NEVER carries the day period — that
/// is typeset separately, at a different size.
///
/// Hand-formatted rather than `MaterialLocalizations.formatTimeOfDay`, on
/// purpose: that helper returns ONE string with the period already inside it,
/// which would put `下午` into the 32 px tabular-figure run and make the number
/// jump between locales. The digits themselves are the same in every locale
/// this app supports.
///
/// 12-hour hours are NOT zero-padded (`7:50`, not `07:50`) and 24-hour hours
/// are (`07:50`), which is what both conventions look like everywhere else on
/// the phone. Midnight and noon read `12`, not `0`.
String clockDigits(DateTime t, {required bool use24Hour}) {
  final mm = t.minute.toString().padLeft(2, '0');
  if (use24Hour) return '${t.hour.toString().padLeft(2, '0')}:$mm';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:$mm';
}
