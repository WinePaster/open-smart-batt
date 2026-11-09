/// OpenSmartBatt — the past a demo unit arrives with (design 0097 §2.3).
///
/// A reviewer opens History seconds after connecting; with only live rows
/// there would be nothing to see. So a demo link starts by writing the last
/// [demoHistorySpan] as one row per minute.
///
/// Each row is made the way a live one is: the unit's frames for that minute
/// are run through the real [TelemetryDecoder], so the seeded past and the
/// live present cannot disagree about what the unit reports.
///
/// 🔴 These rows are the one place demo data is allowed into the database.
/// They are kept out of every export by `kNotDemoRowSql` and deleted when the
/// demo ends and again at startup (`HistoryRepo.purgeDemoRows`).
library;

import '../data/history_repo.dart' show HistoryWrite;
import '../protocol/protocol.dart';
import 'demo_device.dart';
import 'demo_peripheral.dart';

/// How far back the seeded history reaches.
const Duration demoHistorySpan = Duration(hours: 24);

/// One row per whole minute of the [demoHistorySpan] before [now], oldest
/// first, ending at the last whole minute before [now] so it never overlaps
/// the live rows that follow.
List<HistoryWrite> demoHistorySeed(
  DemoKind kind,
  DateTime now, {
  String? appBuild,
}) {
  final end = DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch ~/ 60000 * 60000);
  final minutes = demoHistorySpan.inMinutes;
  const poll = CommandBuilder();
  return [
    for (var i = minutes; i >= 1; i--)
      _row(kind, end.subtract(Duration(minutes: i)), poll, appBuild),
  ];
}

HistoryWrite _row(
    DemoKind kind, DateTime at, CommandBuilder poll, String? appBuild) {
  final decoder = TelemetryDecoder();
  final reassembler = FrameReassembler();
  final unit = DemoPeripheral(kind, clock: () => at);
  for (final frame in unit.answer(poll.keepAlive())) {
    for (final f in reassembler.addBytes(frame)) {
      decoder.ingest(f, at: at);
    }
  }
  return HistoryWrite(
    sample: decoder.sample.copyWith(timestamp: at, deviceId: kind.id),
    deviceId: kind.id,
    samples: 60,
    appBuild: appBuild,
    bucketS: 60,
  );
}
