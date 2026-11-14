/// design 0106 Phase 1 — one unit's live values, whichever link carries them.
///
/// Until Phase 1 the device page could only show the PRIMARY link: its live
/// test was `conn.isOnline && conn.connectedDeviceId == deviceId`, so a unit
/// live on a secondary link (design 0103) read as offline, and opening its
/// page auto-connected it as the primary — releasing the secondary first and
/// dropping both links for 2.9–4.1 s on iOS (2026.11.13/009, /011) and
/// 1.1–3.5 s on Android (/016).
///
/// 🔑 What changed is WHERE the page reads, not what the primary path does.
/// The page publishes a [DeviceLiveSource] through `DeviceLiveScope` only for
/// a unit live on a secondary link; every dashboard widget reads the scope
/// when there is one and otherwise reads the two controllers exactly as it
/// always did. A single-link user never has a scope, so their path is the
/// pre-Phase-1 code, byte for byte.
///
/// Values only, no I/O — the same membership rule as [CardTelemetry]: a
/// secondary link's history rows and alert evaluation are already written,
/// per device, by `TelemetryController.recordExtraSample`. A second
/// `TelemetryController` for it would write them twice (the FB-41 shape).
library;

import 'package:flutter/foundation.dart' show VoidCallback;

import '../models/models.dart';
import 'card_telemetry.dart';
import 'live_trend_buffer.dart';
import 'telemetry_health.dart';

/// The pack readings the protection bodies judge (run mode, dealer code for
/// the cut-off generation gate, the two quantities the threshold comparator
/// reads). [TelemetryController] already had every one of these getters; the
/// interface only names them so a secondary link can supply them too.
abstract class PackReadings {
  int? get mode;
  String? get dealerCode;
  String? get serial;
  String? get fullSerial;
  int? get temperatureC;
  double? get pvlt;
}

/// One unit's live link as the device page sees it (design 0106 §2.3).
abstract class DeviceLiveSource
    implements CardTelemetry, TelemetryHealth, PackReadings {
  /// The unit these values belong to.
  String get deviceId;

  /// The link is `ready`.
  bool get isOnline;

  /// Whether controls may write on this link as it is. False for a secondary:
  /// writes go through the primary only (one physical link per unit on iOS,
  /// 2026.11.12/001 §3.1), so a control first hands the unit over.
  bool get isPrimary;

  /// Polling paused — demoted for slow writes, or held by a power bank on the
  /// primary (design 0103 D1/D5). The values are the last ones received
  /// (ruling T3: show them with 「暫停中」).
  bool get paused;

  /// A control asked for this unit to become the primary and the hand-over is
  /// in flight: the values are frozen at the moment it began (§2.5 —
  /// 「切換中」, never the offline page).
  bool get handingOff;

  /// Age of the newest frame, or null before the first one.
  Duration? get telemetryAge;

  /// Time since the link came up.
  Duration? get onlineFor;

  /// The class the dashboard draws with.
  ProductClass get packLabel;

  /// Which dashboard body to build.
  RoutingDecision get routing;

  /// Which controls the class offers.
  DeviceCapabilities get capabilities;

  /// The unit's own `0x38` address once this link has reported it.
  String? get liveMac;
}

/// [RoutingDecision] and [DeviceCapabilities] for a class known from the saved
/// record — the same two pure rules `ConnectionController.routing` /
/// `.capabilities` apply to the class it resolved from the wire.
RoutingDecision routingForClass(ProductClass cls) => RoutingDecision.from(
      resolved: cls,
      sawDeviceType: cls != ProductClass.unknown,
    );

DeviceCapabilities capabilitiesForClass(ProductClass cls) =>
    cls == ProductClass.unknown
        ? DeviceCapabilities.unknown
        : DeviceCapabilities.fromClass(cls);

/// The source a control froze when it asked for the hand-over (§2.5): the last
/// values the secondary link showed, held still while the primary connects.
///
/// Static on purpose — the secondary link is being released and the primary
/// has not reached `ready`, so there is no live value to follow. The page
/// draws these with 「切換中」 instead of flashing the offline body for the
/// 2–4 s the hand-over takes.
class HandoffLiveSource implements DeviceLiveSource {
  HandoffLiveSource.freeze(DeviceLiveSource from)
      : deviceId = from.deviceId,
        sample = from.sample,
        trend = from.trend,
        packLabel = from.packLabel,
        routing = from.routing,
        capabilities = from.capabilities,
        liveMac = from.liveMac,
        temperatureDisplay = from.temperatureDisplay,
        temperatureUnitLabel = from.temperatureUnitLabel,
        _lastAt = from.lastTelemetryAt,
        _hasTelemetry = from.hasTelemetry;

  @override
  final String deviceId;
  @override
  final TelemetrySample sample;
  @override
  final LiveTrendBuffer trend;
  @override
  final ProductClass packLabel;
  @override
  final RoutingDecision routing;
  @override
  final DeviceCapabilities capabilities;
  @override
  final String? liveMac;
  @override
  final double? temperatureDisplay;
  @override
  final String temperatureUnitLabel;
  final DateTime? _lastAt;
  final bool _hasTelemetry;

  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool get isOnline => true;
  @override
  bool get isPrimary => false;
  @override
  bool get paused => false;
  @override
  bool get handingOff => true;
  @override
  bool get hasTelemetry => _hasTelemetry;
  // Not "stalled": the silence is ours (the hand-over), and the 「切換中」
  // line already says so.
  @override
  bool get telemetryStalled => false;
  @override
  DateTime? get lastTelemetryAt => _lastAt;
  @override
  Duration? get telemetryAge =>
      _lastAt == null ? null : DateTime.now().difference(_lastAt);
  @override
  Duration? get onlineFor => null;

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
  UsbPort? get usbPort => sample.usbPort;
  @override
  bool? get isRailOff => sample.isRailOff;
  @override
  bool? get isPdIn => sample.isPdIn;
  @override
  bool? get isPdOut => sample.isPdOut;
  @override
  int? get portFlagsRaw => sample.portFlagsRaw;
  @override
  int? get mode => sample.mode;
  @override
  String? get dealerCode => sample.dealerCode;
  @override
  String? get serial => sample.serial;
  @override
  String? get fullSerial => sample.fullSerial;
  @override
  int? get temperatureC => sample.temperatureC;
}
