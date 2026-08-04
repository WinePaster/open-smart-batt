/// design 0036 — 復電 always carries auth; cb from the device's own dealer code,
/// pwSum from the built-in default. These are pure, wire-anchored checks.
///
/// The golden bytes come from the 2026-08-04 iOS engineering-app HCI capture:
/// a successful release wrote `b8 23 00 01 00 9a  b8 2a 01 04 00 a8 01 e4 da`
/// (mode-0 frame ++ auth frame), and `0x23` telemetry moved 0x02 → 0x00.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('releaseAuthFromDealerCode — cb uses the wire-confirmed 4-char rule', () {
    test('01680102 → cb 0x00A8 (168), pwSum = default', () {
      final c = releaseAuthFromDealerCode('01680102');
      expect(c, isNotNull);
      expect(c!.cb, 0x00A8);
      expect(c.pwSum, kDefaultCutoffPwSum);
      // NOT the buggy 8-char rule (which would be 1680102).
      expect(c.cb, isNot(1680102));
    });

    test('null / too-short dealer code → null (fall back to manual dialog)', () {
      expect(releaseAuthFromDealerCode(null), isNull);
      expect(releaseAuthFromDealerCode('016'), isNull);
    });

    test('non-numeric leading chars → null, never a bad frame', () {
      expect(releaseAuthFromDealerCode('abcd0102'), isNull);
    });
  });

  test('default pwSum is the captured value', () {
    expect(kDefaultCutoffPwSum, 0x01E4);
  });

  test('release frame == the captured successful-release bytes (golden)', () {
    // conn.releaseCutOff → switchMode(unlock=0, creds).
    final creds = releaseAuthFromDealerCode('01680102')!;
    final bytes = const CommandBuilder().switchMode(ModeArg.unlock, creds);
    expect(_hex(bytes), 'b8230001009ab82a010400a801e4da');
  });

  test('mode read-back frame == the captured eng-app poll (golden)', () {
    // The pairing partner conn.pollMode() sends after each release write
    // (design 0036 §10): B8 23 01 00 <xor=9a> 26.
    expect(_hex(const CommandBuilder().modeReadBack()), 'b82301009a26');
  });
}
