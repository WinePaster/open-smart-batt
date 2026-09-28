/// FB 2026.09.27/003 — 復電 leads with cb 0x00A8 and only then falls back to
/// the cb derived from the device's own dealer code (owner's ruling
/// 2026-09-29: "先送 A8，0x23 沒動且失敗三次就改送 0x27 推導值重試").
///
/// The shape these tests pin: on a `01690102` pack our app wrote the derived
/// `cb = 0x00A9` 32 times while the pack sat in cut-off, and `0x23` never
/// moved. 0x00A8 is the only cb ever seen on a release that moved `0x23`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Runs [runReleasePlan] where [changesOn] is the 1-based write that moves
/// `0x23` (null = never). Returns the result and the cb of every write sent.
Future<({ModeWatch result, int writes, List<int> sent})> _run(
  List<AuthCredentials> plan, {
  int? changesOn,
  int? linkLostOn,
}) async {
  final sent = <int>[];
  final run = await runReleasePlan(
    plan,
    attempt: (c) async => sent.add(c.cb),
    watch: () async {
      if (sent.length == linkLostOn) return ModeWatch.linkLost;
      if (sent.length == changesOn) return ModeWatch.changed;
      return ModeWatch.unchanged;
    },
  );
  return (result: run.result, writes: run.writes, sent: sent);
}

void main() {
  group('releaseAuthPlan', () {
    test('0168 pack → one entry, 0x00A8 (behaves exactly as before)', () {
      final p = releaseAuthPlan('01680102')!;
      expect(p.map((c) => c.cb), [0x00A8]);
      expect(p.single.pwSum, kDefaultCutoffPwSum);
    });

    test('0169 pack → 0x00A8 FIRST, derived 0x00A9 second', () {
      final p = releaseAuthPlan('01690102')!;
      expect(p.map((c) => c.cb), [0x00A8, 0x00A9]);
      expect(p.every((c) => c.pwSum == kDefaultCutoffPwSum), isTrue);
    });

    test('dealer code not on the wire → null (manual dialog fallback)', () {
      expect(releaseAuthPlan(null), isNull);
      expect(releaseAuthPlan('016'), isNull);
      expect(releaseAuthPlan('abcd0102'), isNull);
    });

    test('first frame on a 0169 pack is the A8 release bytes, not A9', () {
      final first = releaseAuthPlan('01690102')!.first;
      expect(_hex(const CommandBuilder().switchMode(ModeArg.unlock, first)),
          'b8230001009ab82a010400a801e4da');
    });
  });

  group('runReleasePlan', () {
    final plan0169 = releaseAuthPlan('01690102')!;

    test('A8 works on the first write → 1 write, no fallback', () async {
      final r = await _run(plan0169, changesOn: 1);
      expect(r.result, ModeWatch.changed);
      expect(r.sent, [0x00A8]);
    });

    test('A8 unchanged three times → falls back to derived, which works',
        () async {
      final r = await _run(plan0169, changesOn: 5);
      expect(r.result, ModeWatch.changed);
      expect(r.sent, [0xA8, 0xA8, 0xA8, 0xA9, 0xA9]);
    });

    test('never moves → 3 × A8 then 3 × derived, reports 6 writes', () async {
      final r = await _run(plan0169);
      expect(r.result, ModeWatch.unchanged);
      expect(r.writes, 6);
      expect(r.sent, [0xA8, 0xA8, 0xA8, 0xA9, 0xA9, 0xA9]);
    });

    test('0168 pack never moves → 3 writes, no second credential', () async {
      final r = await _run(releaseAuthPlan('01680102')!);
      expect(r.result, ModeWatch.unchanged);
      expect(r.writes, 3);
    });

    test('link lost stops the plan — no write into a dead link', () async {
      final r = await _run(plan0169, linkLostOn: 2);
      expect(r.result, ModeWatch.linkLost);
      expect(r.sent, [0xA8, 0xA8]);
    });
  });
}
