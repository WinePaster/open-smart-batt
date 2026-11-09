// design 0099 P1 — RceSession on its own, without a transport.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

void main() {
  const cmd = CommandBuilder();
  final t = DateTime.utc(2026, 11, 9, 12);

  test('schedule matches the transport static it replaced', () {
    final s = RceSession();
    for (var tick = 1; tick <= 150; tick++) {
      expect(
          s.nextPoll(tick),
          BleScheduleReference.tokenFor(tick, isPowerBank: false),
          reason: 'tick $tick');
    }
  });

  test('a power-bank 0x10 switches this session to the 5-tick schedule', () {
    final s = RceSession();
    expect(s.nextPoll(5), cmd.keepAlive());
    expect(s.ingest(buildFrame(Selectors.deviceType, const [0x22]), t), isTrue);
    expect(s.nextPoll(5), cmd.extendedPoll());
    expect(s.nextPoll(25), cmd.slowMetadataPoll());
  });

  test('a frame split across chunks is decoded once, when complete', () {
    final s = RceSession();
    final f = buildFrame(Selectors.deviceType, const [0x02]);
    expect(s.ingest(f.sublist(0, 3), t), isFalse);
    expect(s.sample.deviceType, isNull);
    expect(s.ingest(f.sublist(3), t), isTrue);
    expect(s.sample.deviceType, 0x02);
  });

  test('a frame with a bad checksum changes nothing', () {
    final s = RceSession();
    final f = buildFrame(Selectors.deviceType, const [0x02]).toList();
    f[f.length - 1] ^= 0xFF;
    final before = s.sample;
    expect(s.ingest(f, t), isFalse);
    expect(identical(s.sample, before), isTrue);
  });

  test('discardPartial drops half a frame but keeps the sample', () {
    final s = RceSession();
    s.ingest(buildFrame(Selectors.deviceType, const [0x17]), t);
    final f = buildFrame(Selectors.deviceType, const [0x02]);
    s.ingest(f.sublist(0, 3), t);
    s.discardPartial();
    // The tail alone cannot complete a frame any more.
    expect(s.ingest(f.sublist(3), t), isFalse);
    expect(s.sample.deviceType, 0x17);
  });

  test('RCE allows every write and ticks at 1 Hz with an 8 s stall', () {
    final s = RceSession();
    expect(s.allowsWrite(cmd.switchMode(0x00,
        const AuthCredentials(cb: 0, pwSum: 0))), isTrue);
    expect(s.tickInterval, const Duration(seconds: 1));
    expect(s.stallThreshold, const Duration(seconds: 8));
  });
}

/// The schedule exactly as `BleService.keepAliveTokenFor` stated it before
/// design 0099 moved it, written out independently so this test does not
/// compare the function with itself.
class BleScheduleReference {
  static List<int> tokenFor(int tick, {required bool isPowerBank}) {
    const cmd = CommandBuilder();
    if (tick <= 1) return cmd.extendedPoll();
    if (tick % 25 == 0) return cmd.slowMetadataPoll();
    if (isPowerBank && tick % 5 == 0) return cmd.extendedPoll();
    return cmd.keepAlive();
  }
}
