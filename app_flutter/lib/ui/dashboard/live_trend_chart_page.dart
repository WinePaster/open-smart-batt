/// OpenSmartBatt — the full-screen LANDSCAPE live chart (design 0093).
///
/// The second shell over `live_trend_chart_core.dart`. The first is the card on
/// the dashboard; this one is the same picture with the height budget of a
/// landscape screen behind it.
///
/// ## What this shell is NOT
///
/// 🔴 **It is not a longer window.** [LiveTrendBuffer] holds ~900 samples ≈ 3
/// minutes and is neither persisted nor exported (that is what makes it free).
/// Full screen buys horizontal RESOLUTION — ~1.1 samples per pixel instead of
/// ~2.8 on a card, which is the difference between seeing a cranking transient
/// and seeing the pixel it was averaged into. It buys no history at all.
///
/// 🔴 **It takes no gestures** — owner ruling 2026-09-02, 逐字「Q2 NO」. The
/// history chart's scrub (design 0076) is not portable here: this source
/// advances ~4.8 times a second, so a cursor would first have to decide whether
/// the window freezes under the finger. That question stays open and undesigned.
///
/// 🔴 **It shows no time axis** — 逐字「Q1 NO」. With no pan and no zoom there is
/// nothing inviting a viewer to reach for a window that does not exist, so the
/// only line this page prints is the one about the LINK (§_status).
///
/// ## What was ruled here, in one place (design 0093 §4)
///
///  * **Q3** — the tracks divide the available height, keeping their relative
///    weights ([allocateTrackHeights]); the pack current track stays the tall
///    one because it is the only one crossing zero.
///  * **Q4** — the entry lives on the card, drawn only on
///    [CardSurface.deviceDetail]. The same card is the home grid's 1x1 tile.
///  * **Q5** — a reconnect starts a NEW picture. It never continues the frozen
///    one; `TelemetryController` clears the buffer on a disconnect precisely so
///    that two units never share a stroke.
///  * **Q6** — the track list is recomputed on this page's own tick, so a power
///    bank's 輸入／輸出 legend keeps following the flow.
///  * **Q7 (inherited from design 0081)** — landscape is LOCKED, and the back
///    button is the only way out. The orientation sensor is never read.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'display_modules.dart';
import 'live_trend_chart.dart';

/// Open the landscape live chart for a unit of [shellClass].
///
/// A function rather than a `MaterialPageRoute` at the call site, for the reason
/// `history_chart_page.dart` gives: a second `push` spelled slightly differently
/// is how two entries start behaving differently.
Future<void> showLiveTrendChartPage(
  BuildContext context, {
  required ProductClass shellClass,
  required CardTelemetry tele,
}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LiveTrendChartPage(shellClass: shellClass, tele: tele),
    ));

class LiveTrendChartPage extends StatefulWidget {
  const LiveTrendChartPage({
    super.key,
    required this.shellClass,
    required this.tele,
  });

  /// The same telemetry the card that opened this page is reading.
  ///
  /// 🔑 Handed over rather than looked up. `dashboardCardFor` already holds it,
  /// and it is a [CardTelemetry] there — the narrow "one getter per fact a card
  /// reads" interface — so taking it here keeps this page inside the same
  /// vocabulary instead of reaching past it for the whole controller. It also
  /// means the page never has to know which of the two implementations it got.
  final CardTelemetry tele;

  /// The family whose tracks are drawn — already resolved by the card that
  /// opened this page, exactly as `history_chart_page.dart` takes its own.
  /// Re-deriving it here would be a second resolution of one screen's class
  /// (design 0056 §4).
  final ProductClass shellClass;

  @override
  State<LiveTrendChartPage> createState() => _LiveTrendChartPageState();
}

class _LiveTrendChartPageState extends State<LiveTrendChartPage> {
  static const double _topBarH = 44;

  Timer? _ticker;
  int _seenRevision = -1;

  /// A copy of the live buffer, refreshed on every tick WHILE THE LINK IS UP.
  ///
  /// 🔴 Refreshed here rather than captured when the link drops, and that is not
  /// belt-and-braces. `TelemetryController._onLinkState` calls `trend.clear()`
  /// on a disconnect, so by the time anything can react the points are already
  /// gone — the copy has to exist BEFORE the event. Copying ~25 KB ten times a
  /// second while this page is open is the price of that.
  FrozenTrendSnapshot? _snapshot;

  /// The tracks as they stood when the link dropped, so the legends freeze with
  /// the picture (design 0093 §4 Q6). A power bank that was discharging must not
  /// switch to 輸入 because the flow behind the frozen chart went null.
  List<TrendTrack>? _frozenTracks;

  bool _frozen = false;
  DateTime? _frozenAt;

  /// Set once the link comes back. The page says so for as long as it is open:
  /// what is on screen after a reconnect is a NEW recording, and the three
  /// minutes before the drop are gone from everywhere (§Q5).
  bool _restarted = false;

  @override
  void initState() {
    super.initState();
    // Inherited from design 0081 Q7 = A. Restored in [dispose] and NOT in the
    // close button's callback: the system back gesture never reaches that
    // callback, and an app left locked to landscape is the worst outcome this
    // file can produce.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _ticker = Timer.periodic(LiveTrendChart.frameInterval, (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  /// One beat: refresh the snapshot, notice a disconnect, repaint if either
  /// moved.
  ///
  /// 🔑 Everything this page reads is read HERE, at the chart's own capped rate,
  /// and never by listening to the controller. It notifies at ~4.8 Hz;
  /// following it would rebuild this page — and re-derive its track list — on
  /// every decoded sample, which is exactly the cost the 100 ms ceiling exists
  /// to cap.
  ///
  /// 🔑 **The disconnect is detected as the buffer EMPTYING, not by asking a
  /// connection controller.** `LiveTrendBuffer.clear()` has exactly one caller —
  /// `TelemetryController._onLinkState` on `disconnected` — and it is a no-op on
  /// an already-empty buffer, so "was holding points, now holds none" is the
  /// link dropping and nothing else. Reading it from the buffer also removes the
  /// race: by the time this page sees the empty buffer it is already holding the
  /// copy taken on the previous beat, whereas a page reacting to a link event
  /// might be scheduled after the clear and find nothing left to freeze.
  void _tick() {
    if (!mounted) return;
    final tele = widget.tele;
    final buf = tele.trend;

    if (_frozen) {
      // Q5 = 換新. Anything new means a NEW recording: the frozen copy is
      // discarded, never extended. Continuing it is what the unconditional
      // clear in `TelemetryController` exists to prevent — two units joined by
      // a stroke neither of them produced.
      if (buf.length == 0) return;
      setState(() {
        _frozen = false;
        _frozenAt = null;
        _frozenTracks = null;
        _snapshot = null;
        _seenRevision = -1;
        _restarted = true;
      });
      return;
    }

    final rev = buf.revision;
    if (rev == _seenRevision) return;
    _seenRevision = rev;

    if (buf.length > 0) {
      setState(() => _snapshot = FrozenTrendSnapshot.from(buf));
      return;
    }
    // Empty after having held something: the link is gone. Freeze what the last
    // beat copied and say so; a frozen picture with no caption is a picture that
    // reads as still updating.
    if (_snapshot == null) return;
    setState(() {
      _frozen = true;
      final lastMs = _snapshot!.lastMs;
      _frozenAt = lastMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMs.round());
      _frozenTracks = _tracksFor(tele);
    });
  }

  List<TrendTrack> _tracksFor(CardTelemetry tele) {
    final modules = DisplayModules.forClass(widget.shellClass) ??
        DisplayModules.packFallback;
    return chartTracksFor(
      context,
      modules: modules,
      isPowerBank: widget.shellClass == ProductClass.powerBank,
      tele: tele,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tele = widget.tele;
    // Frozen: the local copy and the legends that went with it. Live: the buffer
    // itself, and legends re-derived from the sample that is on screen.
    final TrendSource? source = _frozen ? _snapshot : tele.trend;
    final tracks = _frozen ? (_frozenTracks ?? const <TrendTrack>[]) : _tracksFor(tele);
    final status = _statusLine(l10n);

    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: _topBarH,
              child: Row(
                children: [
                  IconButton(
                    // Q7a = A1: this and the system back are the only ways out.
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.fullscreen_exit, size: 20),
                    tooltip: l10n.fullscreenExit,
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                  ),
                  Expanded(
                    child: Text(
                      l10n.dashboardChartHeading,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
                child: source == null
                    ? Center(
                        child: Text(l10n.dashboardChartWaiting,
                            style: AppTextStyles.label(context)))
                    : LiveTrendChart(
                        buffer: source,
                        tracks: tracks,
                        fillHeight: true,
                        emptyLabel: l10n.dashboardChartWaiting,
                      ),
              ),
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.label(context).copyWith(
                    color: _frozen
                        ? AppSemantics.warn
                        : context.colors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The one line this page prints about itself, and only when there is
  /// something true to say.
  ///
  /// 🔵 Q1 = NO: no time range, no bucket note, nothing about the window. What
  /// remains is a statement about the LINK, and it is not decoration — a frozen
  /// chart with no caption is a chart that looks like it is still updating.
  String? _statusLine(AppLocalizations l10n) {
    if (_frozen) {
      final at = _frozenAt;
      return l10n.liveChartFrozen(
          at == null ? '--' : DateFormat('HH:mm:ss').format(at));
    }
    return _restarted ? l10n.liveChartRestarted : null;
  }
}
