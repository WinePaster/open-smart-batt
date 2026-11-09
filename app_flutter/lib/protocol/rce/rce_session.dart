/// The RCE protocol as a [ProtocolSession] (design 0099 P1).
///
/// Nothing in here is new behaviour. Every line was in `BleService` — the
/// reassembler and decoder that lived on each link, the loop `_onNotify` ran
/// over the frames, and the keep-alive schedule — and moved here verbatim, so
/// the transport no longer has to know which protocol a link speaks.
/// `test/seam_golden_test.dart` pins that the bytes on the wire did not change.
library;

import '../../models/telemetry_sample.dart';
import '../command_builder.dart';
import '../inbound_frame.dart';
import '../metadata_parser.dart';
import '../session/protocol_session.dart';
import '../telemetry_decoder.dart';

/// Pure keep-alive scheduler (PROTOCOL.md §2): which poll token to write on a
/// 1-based [tick], given whether the unit is a power bank (device-type 0x22,
/// from decoded telemetry).
///
/// Order (the metadata poll is checked BEFORE the power-bank extended poll,
/// so a tick that is both %25 and %5 sends `@`):
///   * tick == 1          -> `!#` (0x21 0x23) — every device, once.
///   * %25 == 0            -> `@`  (0x40) — slow metadata (all devices).
///   * power bank & %5==0  -> `!#` — continuous SOC / port refresh.
///   * otherwise           -> `#`  (0x23).
List<int> rceTokenFor(
  CommandBuilder commands, {
  required int tick,
  required bool isPowerBank,
}) {
  if (tick <= 1) return commands.extendedPoll();
  if (tick % 25 == 0) return commands.slowMetadataPoll();
  if (isPowerBank && tick % 5 == 0) return commands.extendedPoll();
  return commands.keepAlive();
}

/// One RCE link's reassembly, decode and poll schedule.
class RceSession implements ProtocolSession {
  RceSession({
    MetadataParser parser = const NoopMetadataParser(),
    this.commands = const CommandBuilder(),
  }) : _decoder = TelemetryDecoder(parser: parser);

  /// Builds the poll tokens.
  final CommandBuilder commands;

  /// One byte stream per link: feeding two units into one buffer splices a
  /// frame boundary from one into a frame from the other.
  final FrameReassembler _reassembler = FrameReassembler();

  /// Folds successive frames into ONE accumulated sample (DVOL needs the
  /// last-seen VADJ).
  final TelemetryDecoder _decoder;

  /// ~1 Hz. The battery streams telemetry as long as it keeps receiving a poll
  /// token; exact cadence is not protocol-critical.
  @override
  Duration get tickInterval => const Duration(seconds: 1);

  /// Several poll periods, so a momentary gap does not flap the indicator.
  @override
  Duration get stallThreshold => const Duration(seconds: 8);

  /// Whether the unit is a power bank is read from THIS link's latest decoded
  /// telemetry; it flips true once the tick-1 `!#` elicits the 0x10 frame,
  /// after which the every-5th `!#` schedule kicks in.
  @override
  List<int> nextPoll(int tick) => rceTokenFor(
    commands,
    tick: tick,
    isPowerBank: _decoder.sample.isPowerBank,
  );

  @override
  bool ingest(List<int> chunk, DateTime at) {
    var changed = false;
    for (final f in _reassembler.addBytes(chunk)) {
      if (!f.checksumOk) continue;
      final before = _decoder.sample;
      final after = _decoder.ingest(f, at: at);
      if (!identical(before, after)) changed = true;
    }
    return changed;
  }

  @override
  void discardPartial() => _reassembler.reset();

  @override
  TelemetrySample get sample => _decoder.sample;

  @override
  DeviceMetadata get metadata => _decoder.deviceMetadata;

  /// RCE writes are unrestricted at this layer: which mode codes may be sent
  /// is gated per class by the controller and UI, as it always was.
  @override
  bool allowsWrite(List<int> bytes) => true;
}
