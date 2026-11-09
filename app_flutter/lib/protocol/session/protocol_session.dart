/// The per-link half of the device-profile seam (design 0099 §3.2).
///
/// PURE Dart: no Flutter, no plugin types, no timers, no device handle. The
/// transport ([BleService]) owns everything with a lifecycle — connect, retry,
/// epochs, teardown, the keep-alive timer, the write path — and asks a session
/// only protocol questions: "what do I write on this tick?", "here are some
/// bytes, did anything change?", "may I write these bytes?".
///
/// Keeping lifecycle out of this interface is the point, not an omission:
/// every field fix FB-23 / FB-39 / FB-51 / FB-53 / FB-88 made lives in the
/// transport, and a protocol that held its own timer or handle could route
/// around them.
library;

import '../../models/telemetry_sample.dart';
import '../metadata_parser.dart';

/// One link's protocol state machine.
abstract interface class ProtocolSession {
  /// How often the transport should tick [nextPoll].
  Duration get tickInterval;

  /// How long without a sample change before telemetry counts as stalled.
  ///
  /// Not wired yet: `TelemetryController` still reads the transport constant,
  /// which equals the RCE value. A protocol that polls slower than 1 Hz is
  /// what will need it.
  Duration get stallThreshold;

  /// The bytes to write on this 1-based [tick], or null to write nothing.
  ///
  /// The transport counts ticks; the session only decides what each one says.
  List<int>? nextPoll(int tick);

  /// Feed one notification chunk received at [at]. Returns true when [sample]
  /// changed (a new instance), which is when the transport publishes it.
  bool ingest(List<int> chunk, DateTime at);

  /// The accumulated telemetry. Replaced, never mutated, so `identical` tells
  /// "changed" from "not changed".
  TelemetrySample get sample;

  /// The accumulated device metadata (empty on the open build). Same
  /// replace-don't-mutate rule as [sample].
  DeviceMetadata get metadata;

  /// Drop any half-received bytes. Called by the transport's teardown so the
  /// next link cannot complete a frame out of this one's leftovers. The
  /// accumulated [sample] and [metadata] are kept: the screen keeps showing
  /// the last values after a drop.
  void discardPartial();

  /// The single write gate (design 0099 §3.5): the transport asks this before
  /// every write on the link, keep-alive and command alike, and refuses the
  /// write when it says no.
  bool allowsWrite(List<int> bytes);
}
