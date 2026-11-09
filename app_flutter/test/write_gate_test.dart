// design 0099 P3 — every write passes one gate, and the gate can say no.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/log_entry.dart' show LogDirection;
import 'package:open_smart_batt/models/telemetry_sample.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

/// A session that polls with [poll] and allows only [allowed] payloads.
class _ListSession implements ProtocolSession {
  _ListSession({required this.poll, required this.allowed});
  final List<int> poll;
  final List<List<int>> allowed;
  final TelemetrySample _sample = TelemetrySample.empty();

  @override
  Duration get tickInterval => const Duration(seconds: 1);
  @override
  Duration get stallThreshold => const Duration(seconds: 8);
  @override
  List<int>? nextPoll(int tick) => poll;
  @override
  bool ingest(List<int> chunk, DateTime at) => false;
  @override
  TelemetrySample get sample => _sample;
  @override
  DeviceMetadata get metadata => const EmptyDeviceMetadata();
  @override
  void discardPartial() {}
  @override
  bool allowsWrite(List<int> bytes) => allowed.any(
    (a) =>
        a.length == bytes.length &&
        Iterable<int>.generate(a.length).every((i) => a[i] == bytes[i]),
  );
}

class _SilentPeer implements SimulatedPeer {
  final written = <List<int>>[];
  @override
  List<List<int>> answer(List<int> w) {
    written.add(List<int>.of(w));
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_blue_plus/methods');

  setUp(() {
    BleService.demoConnectDelay = Duration.zero;
    BleService.demoReplyDelay = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a read-only session: polls go out, anything else is refused', () async {
    const poll = [0x5A, 0x01];
    final peer = _SilentPeer();
    final ble = BleService();
    final events = <BlePacketEvent>[];
    final sub = ble.packets.listen(events.add);

    await ble.connectSimulated(
      'SIM-1',
      session: _ListSession(poll: poll, allowed: const [poll]),
      peer: peer,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(peer.written, [poll], reason: 'the first tick goes out');

    // Every RCE command path, and a raw write, is refused at the gate.
    await expectLater(
      ble.writeCommand(const [0x01, 0x02, 0x03]),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await expectLater(
      ble.switchMode(ModeArg.unlock, cb: 1, pwSum: 2),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await expectLater(
      ble.sendAuth(cb: 1, pwSum: 2),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await expectLater(
      ble.modeSet(ModeArg.unlock),
      throwsA(isA<ProfileWriteRefused>()),
    );
    await expectLater(ble.modeReadBack(), throwsA(isA<ProfileWriteRefused>()));
    expect(peer.written, [poll], reason: 'nothing refused reached the peer');

    final refusals = events
        .where((e) => e.note?.contains('write refused') ?? false)
        .toList();
    expect(refusals, hasLength(5));
    for (final r in refusals) {
      expect(r.bytes, isEmpty, reason: 'a refusal must not log the payload');
      expect(r.note, isNot(contains('01 02 03')));
    }
    expect(
      events.where((e) => e.direction == LogDirection.tx).map((e) => e.bytes),
      everyElement(poll),
      reason: 'only allowed bytes are logged as sent',
    );

    await sub.cancel();
    await ble.disconnect();
    await ble.dispose();
  });

  test('a session that refuses its own poll writes nothing at all', () async {
    final peer = _SilentPeer();
    final ble = BleService();
    await ble.connectSimulated(
      'SIM-2',
      session: _ListSession(poll: const [0x5A], allowed: const []),
      peer: peer,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(peer.written, isEmpty);
    expect(
      ble.keepAliveWriteFailed,
      isTrue,
      reason: 'a refused poll is reported like any failed keep-alive',
    );
    await ble.disconnect();
    await ble.dispose();
  });

  test('RCE (demo) still writes everything it wrote before', () async {
    final ble = BleService();
    await ble.connect(DemoKind.battery.id);
    await ble.switchMode(ModeArg.cutOff, cb: 0x0168, pwSum: 0x01E4);
    await ble.modeSet(ModeArg.unlock);
    await ble.modeReadBack();
    await ble.disconnect();
    await ble.dispose();
  });

  test('lib/state no longer builds wire commands itself', () {
    final hits = <String>[];
    for (final f in Directory('lib/state').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//')) continue;
        if (l.contains('CommandBuilder')) hits.add('${f.path}:${i + 1}');
      }
    }
    expect(
      hits,
      isEmpty,
      reason: 'writes go through BleService and its gate (design 0099 P3)',
    );
  });
}
