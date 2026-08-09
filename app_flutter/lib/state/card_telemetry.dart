/// OpenSmartBatt — "what a dashboard card needs to read", as a narrow interface
/// (design 0051 §5).
///
/// Every card in `ui/dashboard/` used to reach a `TelemetryController` out of
/// the provider tree by itself. That is correct on the two surfaces where the
/// numbers are real — the device dashboard and the home grid — and it is
/// exactly wrong on the third, the home EDITOR, where the numbers must be fake
/// so that the user can judge a layout while nothing is connected.
///
/// ## Why an interface and NOT a `previewMode` flag
///
/// A boolean would be one new decision point per card, and this project has
/// shipped the same caller-side defect at least four times — see
/// `display_module.dart`'s note ("a hardcoded list lets the next member slip
/// past; that has happened four times"), design 0042 §3.9, design 0045 Q3 and
/// `main.dart`'s tab-flag comment. The failure mode of a flag is also the worse
/// one: forget to CLEAR it and the real dashboard starts drawing plausible fake
/// voltages, which is FB-43 with none of FB-43's tells (the numbers look right).
///
/// Passing the data in has no such mode. A real render path hands over a real
/// controller; there is no value it can pass that produces a fake reading, and
/// no value the editor can pass that reaches a device.
///
/// The shape is borrowed rather than invented: `telemetry_health.dart` already
/// does exactly this for `ConnectionController` ("one judgement, two
/// presentations"). [TelemetryController] implements both.
///
/// ## Membership rule
///
/// One getter per fact a CARD reads, and nothing else. History, log I/O,
/// export, the session and the BLE plumbing are all absent on purpose: a
/// preview implementation must be a value holder, and it can only stay one
/// while this interface asks for values.
library;

import '../models/models.dart';
import 'live_trend_buffer.dart';

/// The telemetry a [dashboardCardFor] card is allowed to see.
abstract class CardTelemetry {
  /// The whole snapshot, for the two readouts that have no derived getter of
  /// their own (`designCapacityMah` today).
  TelemetrySample get sample;

  /// The live chart's ring buffer.
  LiveTrendBuffer get trend;

  /// Primary voltage PVLT (V).
  double? get pvlt;

  /// Secondary voltage SVLT (V) — the port rail on a power bank.
  double? get svlt;

  /// Main current (A), signed.
  double? get current;

  /// Per-cell DVOL voltages (V), or null until decoded.
  List<double>? get dvol;

  /// DVOL frames arriving but VADJ not yet known.
  bool get dvolPending;

  /// Capacity / SOH bucket.
  int? get sohBucket;

  /// Device-reported state of charge (0..100).
  int? get socPercent;

  /// Temperature already converted to the user's chosen unit.
  double? get temperatureDisplay;

  /// `°C` / `°F`, matching [temperatureDisplay].
  String get temperatureUnitLabel;

  // ---- power-bank 0x4B b7 (design 0035) ---------------------------------

  /// Type-C cable / CC detect. Never Type-A — see [UsbPort].
  UsbPort? get usbPort;

  /// Boost rail off (b7 == 0x00).
  bool? get isRailOff;

  /// PD input negotiated (b7 bit3, one-way).
  bool? get isPdIn;

  /// PD output (b7 bit5).
  bool? get isPdOut;

  /// The raw flag byte, for the design 0035 §4.8 hook. Never shown.
  int? get portFlagsRaw;
}

/// Temperature in [unit]. The ONE conversion, so the live controller and any
/// value-holder implementation of [CardTelemetry] cannot disagree about what
/// 41 °C reads as in Fahrenheit (106, three digits — which is a layout fact,
/// not only an arithmetic one).
double? displayTemperature(int? celsius, TempUnit unit) {
  if (celsius == null) return null;
  return unit == TempUnit.fahrenheit
      ? celsius * 9 / 5 + 32
      : celsius.toDouble();
}

/// The suffix that goes with [displayTemperature]. Not localized: `°C` and `°F`
/// are the same symbols in both of this app's languages.
String temperatureUnitLabelOf(TempUnit unit) =>
    unit == TempUnit.fahrenheit ? '°F' : '°C';

/// A [CardTelemetry] that holds values instead of listening to a link.
///
/// 🔴 Its ONLY caller is the home editor's preview (`home_preview.dart`). It is
/// deliberately NOT a `ChangeNotifier` and deliberately has no setters: a
/// preview that could change is a preview that could be mistaken for a reading.
class StaticCardTelemetry implements CardTelemetry {
  const StaticCardTelemetry({
    required this.sample,
    required this.trend,
    required this.tempUnit,
  });

  @override
  final TelemetrySample sample;

  @override
  final LiveTrendBuffer trend;

  /// Followed rather than hardcoded, so the preview shows the same three-digit
  /// Fahrenheit reading the real card would.
  final TempUnit tempUnit;

  @override
  double? get pvlt => sample.pvlt;

  @override
  double? get svlt => sample.svlt;

  @override
  double? get current => sample.current;

  @override
  List<double>? get dvol => sample.dvol;

  @override
  bool get dvolPending => sample.dvolPending;

  @override
  int? get sohBucket => sample.sohBucket;

  @override
  int? get socPercent => sample.socPercent;

  @override
  double? get temperatureDisplay =>
      displayTemperature(sample.temperatureC, tempUnit);

  @override
  String get temperatureUnitLabel => temperatureUnitLabelOf(tempUnit);

  @override
  UsbPort? get usbPort => sample.usbPort;

  @override
  bool? get isRailOff => sample.isRailOff;

  @override
  bool? get isPdIn => sample.isPdIn;

  @override
  bool? get isPdOut => sample.isPdOut;

  @override
  int? get portFlagsRaw => sample.portFlagsRaw;
}
