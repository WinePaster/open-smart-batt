// design 0099 P5 — a protocol that is not RCE, through the seam.
//
// The protocol is invented (see test/support/fake_query_protocol.dart). What
// is being proven is the seam: a second protocol rides the same transport —
// connect, keep-alive, write gate, teardown — by supplying a profile and a
// session, with no protocol branch in BleService.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/models/log_entry.dart' show LogDirection;
import 'package:open_smart_batt/models/telemetry_sample.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

import 'support/fake_query_protocol.dart';

const _rceTokens = [
  [0x23],
  [0x21, 0x23],
  [0x40],
];

bool _isRceToken(List<int> b) => _rceTokens.any(
  (t) =>
      t.length == b.length &&
      Iterable<int>.generate(t.length).every((i) => t[i] == b[i]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_blue_plus/methods');

  setUp(() {
    BleService.demoReplyDelay = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Run a simulated link for [seconds] and report what crossed it.
  ({
    List<List<int>> tx,
    List<TelemetrySample> samples,
    List<String> notes,
    FakeQuerySession session,
    FakeQueryPeer peer,
  })
  run({FqFault fault = FqFault.none, int seconds = 5}) {
    final tx = <List<int>>[];
    final samples = <TelemetrySample>[];
    final notes = <String>[];
    final session = FakeQuerySession();
    final peer = FakeQueryPeer(fault: fault);
    fakeAsync((async) {
      final ble = BleService();
      final subs = [
        ble.packets.listen((e) {
          if (e.direction == LogDirection.tx) tx.add(e.bytes);
          if (e.note != null) notes.add(e.note!);
        }),
        ble.telemetry.listen(samples.add),
      ];
      ble.connectSimulated('FQ-0001', session: session, peer: peer);
      async.elapse(Duration(seconds: seconds));
      ble.disconnect();
      async.elapse(const Duration(seconds: 1));
      for (final s in subs) {
        s.cancel();
      }
      ble.dispose();
      async.flushMicrotasks();
    });
    return (
      tx: tx,
      samples: samples,
      notes: notes,
      session: session,
      peer: peer,
    );
  }

  test('polls at the session cadence, decodes, and never speaks RCE', () {
    final r = run();
    // 500 ms ticks over 5 s, answered at once: about ten requests.
    expect(r.tx.length, inInclusiveRange(9, 12));
    expect(
      r.tx.where(_isRceToken),
      isEmpty,
      reason: 'no RCE keep-alive token on a non-RCE link',
    );
    expect(r.tx.every((b) => r.session.allowsWrite(b)), isTrue);
    expect(r.samples, isNotEmpty);
    final last = r.samples.last;
    expect(last.deviceId, 'FQ-0001', reason: 'identity stamped by transport');
    expect(last.dvol, hasLength(16));
    expect(last.dvol!.first, 3.328);
    expect(last.pvlt, closeTo(16 * 3.328 + 0.120, 1e-9));
    expect(last.temperatureC, 25);
    expect(last.socPercent, 87);
  });

  test('one request outstanding: a silent unit is not flooded', () {
    final r = run(fault: FqFault.silent, seconds: 5);
    // Ten ticks; with a 3-tick timeout at most four requests go out.
    expect(r.tx.length, lessThanOrEqualTo(4));
    expect(r.samples, isEmpty);
  });

  test('a truncated answer is dropped whole, never half-decoded', () {
    final r = run(fault: FqFault.truncateCells);
    expect(r.session.dropped, greaterThan(0));
    for (final s in r.samples) {
      expect(s.dvol, isNull, reason: 'no cells from a damaged frame');
    }
    expect(r.samples.last.socPercent, 87, reason: 'good frames still decode');
  });

  test('two answers glued into one notification both decode', () {
    final r = run(fault: FqFault.glueAnswers, seconds: 6);
    expect(r.session.dropped, 0);
    expect(r.samples.last.dvol, hasLength(16));
    expect(r.samples.last.socPercent, 87);
  });

  test('writes outside the read list are refused at the gate', () async {
    final ble = BleService();
    await ble.connectSimulated(
      'FQ-0002',
      session: FakeQuerySession(),
      peer: FakeQueryPeer(),
    );
    await expectLater(
      ble.writeCommand(const [0x23]),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await expectLater(
      ble.switchMode(ModeArg.unlock, cb: 1, pwSum: 2),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await ble.disconnect();
    await ble.dispose();
  });

  group('GATT: generic UUIDs alone are only a candidate', () {
    GattSnapshot table({required bool signature}) => GattSnapshot([
      GattServiceInfo(kFqService, [
        const GattCharacteristicInfo(kFqWrite, write: true),
        const GattCharacteristicInfo(kFqNotify, notify: true),
        if (signature) const GattCharacteristicInfo(kFqSignature),
      ]),
    ]);
    const profiles = <DeviceProfile>[RceProfile(), FakeQueryProfile()];

    test('without the signature nothing resolves, so nothing is written', () {
      final c = resolveProfile(profiles, table(signature: false));
      expect(c.resolution, ProfileResolution.candidatesOnly);
      expect(c.profile, isNull);
      expect(c.candidates, ['fake-query']);
    });

    test('with the signature it resolves to the fake protocol', () {
      final c = resolveProfile(profiles, table(signature: true));
      expect(c.resolution, ProfileResolution.resolved);
      expect(c.profile, isA<FakeQueryProfile>());
      expect(c.profile!.openSession(), isA<FakeQuerySession>());
    });

    test('an RCE table still resolves to RCE with both profiles present', () {
      final rce = GattSnapshot([
        GattServiceInfo(normaliseUuid(Gatt.serviceUuid), [
          GattCharacteristicInfo(normaliseUuid(Gatt.writeCharUuid)),
          GattCharacteristicInfo(normaliseUuid(Gatt.notifyCharUuid)),
        ]),
      ]);
      expect(resolveProfile(profiles, rce).profile, isA<RceProfile>());
    });
  });
}
