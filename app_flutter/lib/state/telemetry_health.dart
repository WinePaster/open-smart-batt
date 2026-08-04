/// OpenSmartBatt — "is this link actually delivering?", as a narrow interface.
///
/// One judgement, two presentations: the dashboard's stale banner and the
/// ongoing notification must never disagree about whether the readings on
/// screen are live. [TelemetryController] is the single implementation; this
/// interface exists so [ConnectionController] can consume the answer without
/// depending on the whole controller, and so tests can flip the state in a
/// microsecond instead of waiting out `BleService.telemetryStallThreshold`.
///
/// See design 0038 §5.3.
library;

import 'package:flutter/foundation.dart';

/// Freshness of the telemetry on the link currently being recorded.
abstract class TelemetryHealth implements Listenable {
  /// Whether this connection has produced at least one decoded frame.
  ///
  /// NOT derivable from a timestamp: see [lastTelemetryAt].
  bool get hasTelemetry;

  /// True once nothing has arrived for `BleService.telemetryStallThreshold`
  /// while the link still reports ready — the readouts are stale.
  bool get telemetryStalled;

  /// When the newest frame landed.
  ///
  /// ⚠️ SEEDED at `ready` to give the first frame a grace period, so it is
  /// non-null from the moment a link opens whether or not the unit has said a
  /// word. Only meaningful once [hasTelemetry] is true — that conflation is
  /// what let FB-20 be misread, and it is why callers must test
  /// [hasTelemetry] BEFORE [telemetryStalled] rather than reading a time here.
  DateTime? get lastTelemetryAt;
}
