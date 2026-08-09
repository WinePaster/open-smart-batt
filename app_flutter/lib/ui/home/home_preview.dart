/// OpenSmartBatt — the home EDITOR's fake data (design 0051 §5, owner ruling
/// 2026-08-09: 「請堅持編輯主頁就是假資料 … 只有回到主頁才是真實資料」).
///
/// ## Why this is a bug fix and not decoration
///
/// The editor drew the REAL tile at the real width, which is right. But the app
/// is usually opened with nothing connected, and with nothing connected all
/// eight module tiles degrade to the same compressed "heading + `--`" box. A
/// voltage dial, a trend chart, a numbers grid and a per-cell bar chart — four
/// cards of wildly different heights — were indistinguishable in the one screen
/// whose entire job is arranging them by height.
///
/// 🔴 And two of them were not degraded at all: `speed` and `gForce` read the
/// PHONE, so `_ModuleTile` counted them as live and mounted the real cards,
/// which start the GNSS receiver and the accelerometer from
/// `didChangeDependencies`. Arranging your home page ran your GPS. Dragging a
/// speed tile ran it twice, since the drag ghost is a second live card. That is
/// a hole straight through design 0042's three-condition gate, and it was in
/// the shipped build with no test looking at it.
///
/// ## No "DEMO" watermark
///
/// Ruled explicitly: 「不用放提示文字：示範」. The editor is reached by tapping
/// 編輯主頁 and is titled as such; a label on every card explaining that the
/// editor is an editor is the sentence design 0046 §4.7 forbids.
///
/// ## Why the numbers are ugly
///
/// Every value here is chosen to be the WIDEST or TALLEST plausible rendering,
/// not the prettiest. A preview full of tidy two-digit numbers invites the user
/// to build a layout that just fits, and the first real reading then overflows
/// it — this project already has `narrow_tile_layout_test.dart` (three-digit
/// speed) and `value_text_scaling_test.dart` because that failure has happened.
/// So: a four-significant-figure voltage, a negative three-digit current, an
/// alias long enough to force an ellipsis, the longest of the three SOH labels,
/// the longest relative-time string, and the port/PD combination that draws the
/// most badges.
///
/// ⚠️ Two knowing inconsistencies, recorded so they are not "fixed" into
/// blandness later:
///
///  * the pack's CURRENT READOUT reads −128.4 A while its chart swings −29→+8.
///    The readout is dimensioned for the widest string; the chart is
///    dimensioned for a real shape (the swing is from an actual capture, and it
///    is what makes the zero axis draw). They optimise different things and
///    neither is a claim about a device.
///  * the same for nothing else — the SOC dial, the SOC track, the port row and
///    the energy readings were all reconciled onto ONE sample rather than left
///    to contradict each other on screen.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../dashboard/clock_card.dart';
import '../dashboard/g_force_card.dart';
import '../dashboard/speed_card.dart';
import '../widgets/industrial_card.dart';

/// Everything one editor tile needs in order to draw itself with fake data.
///
/// Passed down through `HomeTileView`; `null` everywhere else, which is what
/// makes "the real home page cannot draw a preview" true by construction.
class HomePreview {
  const HomePreview({
    required this.tele,
    required this.device,
    required this.shellClass,
    required this.live,
    required this.speedUnit,
  });

  /// Fake telemetry, already matched to [shellClass].
  final CardTelemetry tele;

  /// Fake saved device, for the device-summary tile.
  final SavedDevice device;

  /// The class the module cards draw as — taken from the REAL device the tile
  /// is bound to (design 0051 §5.4). A power bank's readouts grid and trend
  /// chart carry different content from a pack's, so previewing everything as a
  /// battery would show the wrong card to exactly the users who most need to
  /// see it.
  final ProductClass shellClass;

  /// Whether the device-summary tile draws its LIVE shape or its cached one.
  ///
  /// One link can be up at a time today, so the editor shows exactly one live
  /// card and the rest cached — the same proportion the real page has. Both
  /// shapes are worth seeing: the cached one is TALLER (it carries an age line)
  /// and the live one carries the LIVE dot.
  final bool live;

  final SpeedUnit speedUnit;
}

/// The alias the fake device carries.
///
/// Long on purpose: it must overflow a half-width tile's name row so the user
/// sees the ellipsis their own long alias will get. Not localized — it is
/// sample DATA, not interface copy, and translating it would be translating a
/// user's device name.
const String kPreviewAlias = '車庫備用電池 #2 (2026)';

/// How stale the cached device tile pretends to be.
///
/// Days rather than minutes: "N 天前" is the longest string [relativeTime]
/// produces, and this row is directly under a 32 px number.
const Duration kPreviewLastSeenAge = Duration(days: 3);

/// Build the preview data for one tile.
///
/// [now] is passed in rather than read, so a test pins a relative-time string
/// instead of racing the clock.
HomePreview buildHomePreview({
  required ProductClass shellClass,
  required bool live,
  required TempUnit tempUnit,
  required SpeedUnit speedUnit,
  required DateTime now,
  LiveTrendBuffer? trend,
}) {
  final isBank = shellClass == ProductClass.powerBank;
  final sample = isBank ? previewPowerBankSample(now) : previewPackSample(now);
  return HomePreview(
    tele: StaticCardTelemetry(
      sample: sample,
      trend: trend ?? buildPreviewTrend(shellClass, now),
      tempUnit: tempUnit,
    ),
    device: SavedDevice(
      id: 'preview',
      alias: kPreviewAlias,
      // 8.05 V — the bottom of the 8–16 V gauge range, so the cached number is
      // the one a user is most likely to misread as live if it were undated.
      lastValue: 8.05,
      lastSeen: now.subtract(kPreviewLastSeenAge),
      productClass: shellClass,
    ),
    shellClass: shellClass,
    live: live,
    speedUnit: speedUnit,
  );
}

/// The pack (battery / capacitor / unclassified) sample.
///
///  * `pvlt` 13.87 — four significant figures, which is what fills the 32 px
///    device-tile number and the dial's centre;
///  * `sohBucket` 45 — lands in the "degraded" bucket, the longest of the three
///    health labels;
///  * `temperatureC` 41 — 106 °F, a three-digit reading for anyone on
///    Fahrenheit;
///  * `current` −128.4 — sign + three digits + a decimal, the widest number the
///    grid can be asked to print;
///  * `dvol` deliberately RAGGED: two cells near the top of the band, one low
///    (2.55) and one high (3.65). A flat set of four equal bars does not show
///    what the card is for, and the two extremes are what exercise the clamps.
TelemetrySample previewPackSample(DateTime now) => TelemetrySample(
      timestamp: now,
      pvlt: 13.87,
      svlt: 13.9,
      temperatureC: 41,
      current: -128.4,
      sohBucket: 45,
      dvol: const [3.31, 3.28, 2.55, 3.65],
    );

/// The power-bank sample.
///
///  * `socPercent` 100 — three digits, the widest the ring can show;
///  * `current` +2.72 → DISCHARGING (positive is discharge, `power_flow.dart`),
///    which is also the longer of the two direction words;
///  * `portFlagsRaw` 0x22 = bit1 (Type-C cable) + bit5 (PD **output**), so the
///    energy-path row draws its widest branch: a filled Type-C badge, a PD
///    badge, the direction and both readings.
///
/// 🔴 0x22 rather than the 0x0A (Type-C + PD-**in**) first sketched: PD-in is
/// only badged while CHARGING, and a charging flag beside a discharging current
/// would have printed a Type-C badge with no PD badge — the narrower branch,
/// and a self-contradictory preview. It also stays clear of `b7 == 0x00`, which
/// would trip `flagsContradicted` and suppress every badge on the row.
TelemetrySample previewPowerBankSample(DateTime now) => TelemetrySample(
      timestamp: now,
      svlt: 9.05,
      current: 2.72,
      temperatureC: 41,
      socPercent: 100,
      designCapacityMah: 20000,
      portFlagsRaw: 0x22,
    );

/// ~180 points of fake trend — enough to fill the chart's width.
///
/// Pack: current −29 → +8 (an actual field swing; it CROSSES ZERO, which is the
/// only way to see the chart's zero axis), `pvlt`/`svlt` flat within ±0.02 V so
/// the anti-noise floor (`minSpan`) is exercised rather than a wide ramp, and
/// temperature 28 → 41.
///
/// Power bank: the same zero-crossing current, `svlt` 9.05 ±0.1 and SOC moving
/// only 97 → 100 — three points of travel, which is under the SOC track's
/// `minSpan` of 5 and therefore the case that proves the floor works.
LiveTrendBuffer buildPreviewTrend(ProductClass cls, DateTime now) {
  const n = 180;
  final buf = LiveTrendBuffer();
  final isBank = cls == ProductClass.powerBank;
  final start = now.subtract(const Duration(seconds: n));
  for (var i = 0; i < n; i++) {
    final f = i / (n - 1);
    // A slow wobble rather than random noise: a preview that changed shape on
    // every rebuild would be read as live data.
    final wobble = math.sin(f * 2 * math.pi * 3);
    buf.add(TelemetrySample(
      timestamp: start.add(Duration(seconds: i)),
      pvlt: isBank ? null : 13.87 + 0.02 * wobble,
      svlt: isBank ? 9.05 + 0.1 * wobble : 13.9 + 0.02 * wobble,
      current: -29 + 37 * f,
      temperatureC: (28 + 13 * f).round(),
      socPercent: isBank ? (97 + 3 * f).round() : null,
    ));
  }
  return buf;
}

/// The clock the editor shows.
///
/// 🔴 FIXED, and it does not run. Owner ruling 2026-08-09:「請堅持編輯主頁就是
/// 假資料」— the clock is not exempt from that just because it happens to be the
/// one card whose real value is always available. A live clock in the editor
/// would be the single tile in that screen telling the truth, which makes the
/// other eight look broken rather than sampled.
///
/// No「示範」label on it either, for the same reason nothing else in the editor
/// carries one (design 0046 §4.7, re-ruled 2026-08-09:「不用放提示文字：示範」).
///
/// The value is the mockup's own 19:50 (`design/mockups/0052-clock-card.html`),
/// so the shipped editor and the approved picture read the same. It is also a
/// deliberately WIDE rendering in both formats — two digits before the colon in
/// 24-hour, and 12-hour turns it into `7:50 PM` / `7:50 下午`, which is the
/// widest thing this card can be asked to draw. Same principle as every other
/// number in this file.
/// (`final`, not `const` — [DateTime] has no const constructor.)
final DateTime kPreviewClockTime = DateTime(2026, 8, 9, 19, 50);

/// A phone module's card, WITHOUT its sensor.
///
/// 🔑 The one place the editor cannot simply hand fake data to the real card.
/// `SpeedCard` and `GForceCard` open the GNSS gate and the accelerometer in
/// `didChangeDependencies`, and `ClockCard` arms a one-minute timer in
/// `initState` — the side effect happens on MOUNT, so no value you pass can
/// prevent it. The editor mounts the extracted bodies instead, which are the
/// same pixels with no controller behind them.
///
/// An exhaustive switch with no `default`, deliberately: this is the exact
/// shape `display_module.dart` argues for, and a new module added to the enum
/// becomes a compile error here rather than a silent live card in the editor.
Widget previewCardFor(DisplayModule m, HomePreview p) {
  switch (m) {
    case DisplayModule.speed:
      return IndustrialCard(
        child: SpeedCardBody(
          permission: SpeedPermissionState.granted,
          estimate: previewSpeedEstimate(p.speedUnit),
          accel: previewAccelEstimate(p.speedUnit),
          unit: p.speedUnit,
        ),
      );
    case DisplayModule.gForce:
      return GForceCardBody(
        reading: kPreviewGForce,
        trail: kPreviewGTrail,
      );
    case DisplayModule.clock:
      // No `now:` seam used here at all — the BODY takes an instant, so there
      // is nothing to inject and nothing to forget to inject. The timer lives
      // in `ClockCard`, which this branch does not build.
      return ClockCardBody(time: kPreviewClockTime);
    // Device modules draw through `dashboardCardFor` with `p.tele`; this
    // function is only asked about phone modules.
    case DisplayModule.gaugeVoltage:
    case DisplayModule.gaugeSoc:
    case DisplayModule.readouts:
    case DisplayModule.chart:
    case DisplayModule.cells:
    case DisplayModule.energyPath:
      throw ArgumentError('$m is a device module — use dashboardCardFor');
  }
}

/// 128 in whatever unit the user picked, ±2.4, `live`, good signal.
///
/// The target is the DISPLAYED number, not a fixed m/s: three digits is the
/// known overflow point of the 52 px readout (`narrow_tile_layout_test.dart`),
/// and pinning m/s instead would show 80 to anyone on mph — the exact reading
/// that fits, on the exact users who need to see that it does not.
///
/// `live` rather than `holding` or `lost` because it is the state with the most
/// fields: number, unit, quality pill, acceleration row and the ± line.
SpeedEstimate previewSpeedEstimate(SpeedUnit unit) => SpeedEstimate(
      t: DateTime(2026, 8, 9, 19, 50),
      vSmoothMps: 128 / (unit == SpeedUnit.mph ? 2.2369362920544 : 3.6),
      state: SpeedState.live,
      quality: SpeedSignalQuality.good,
      speedAccuracyMps: 2.4 / (unit == SpeedUnit.mph ? 2.2369362920544 : 3.6),
    );

/// +1.8 in the user's unit per second — above `AccelEstimatorConfig.aDeadMps2`
/// so the row is actually drawn, and signed so the sign column is exercised.
AccelEstimate previewAccelEstimate(SpeedUnit unit) => AccelEstimate(
      t: DateTime(2026, 8, 9, 19, 50),
      aMps2: 1.8 / (unit == SpeedUnit.mph ? 2.2369362920544 : 3.6),
    );

/// −1.24 long / +0.87 lat / 1.31 peak.
///
/// Both axes NON-ZERO on purpose: `_GReadout` drops its direction word when a
/// value is exactly zero, so a zeroed preview would render a narrower row than
/// any real reading. −1.24 also puts the dot outside the 1.0 g ring, which is
/// where the painter's clamp shows.
const GForceReading kPreviewGForce = GForceReading(
  longG: -1.24,
  latG: 0.87,
  peakLongG: 1.24,
  peakLatG: 0.87,
  peakG: 1.31,
);

/// A short static trail, so the ball reads as a G meter rather than a target.
const List<Offset> kPreviewGTrail = [
  Offset(-0.30, 0.40),
  Offset(-0.52, 0.72),
  Offset(-0.70, 1.02),
  Offset(-0.87, 1.24),
];
