// design 0099 P0 — golden for the device-profile seam.
//
// The seam refactor (P1–P5) must not change one byte this app sends, nor what
// it makes of the bytes it receives. This file pins both, BEFORE the refactor
// starts, against the code as it stands:
//
//   a. the keep-alive schedule, ticks 1–150, power bank and not;
//   b. the TX stream of a demo link over 60 s, including the mode / auth
//      command frames the cut-off flow writes;
//   c. the order of the frames that link receives (values vary with the wall
//      clock, so only selector order and checksum are pinned);
//   d. what the decoder makes of a fixed-clock demo unit's answers;
//   e. that a power-bank device-type flips the schedule to the 5-tick `!#`.
//
// Goldens live in test/goldens/seam_0099/. To regenerate them (only ever on
// purpose, and the diff then has to be read):
//
//   SEAM_GOLDEN_UPDATE=1 flutter test test/seam_golden_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

const _dir = 'test/goldens/seam_0099';
final bool _update = Platform.environment['SEAM_GOLDEN_UPDATE'] == '1';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

/// Compare [lines] with the golden file [name], or rewrite it in update mode.
void _golden(String name, List<String> lines) {
  final file = File('$_dir/$name');
  final text = '${lines.join('\n')}\n';
  if (_update) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return;
  }
  expect(file.existsSync(), isTrue,
      reason: '$name missing — run with SEAM_GOLDEN_UPDATE=1 once');
  final want = file.readAsStringSync().split('\n');
  final got = text.split('\n');
  for (var i = 0; i < want.length || i < got.length; i++) {
    final w = i < want.length ? want[i] : '<end>';
    final g = i < got.length ? got[i] : '<end>';
    expect(g, w, reason: '$name line ${i + 1} differs');
  }
}

/// The schedule as the transport asks for it today.
List<int> _token(int tick, {required bool isPowerBank}) =>
    BleService.keepAliveTokenFor(const CommandBuilder(),
        tick: tick, isPowerBank: isPowerBank);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a. keep-alive schedule, ticks 1-150', () {
    _golden('schedule.txt', [
      for (final pb in [false, true])
        for (var tick = 1; tick <= 150; tick++)
          'pb=$pb tick=$tick ${_hex(_token(tick, isPowerBank: pb))}',
    ]);
  });

  group('b/c. demo link over the real transport', () {
    const channel = MethodChannel('flutter_blue_plus/methods');
    late Duration savedConnect;
    late Duration savedReply;

    setUp(() {
      savedConnect = BleService.demoConnectDelay;
      savedReply = BleService.demoReplyDelay;
      BleService.demoConnectDelay = Duration.zero;
      BleService.demoReplyDelay = Duration.zero;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      BleService.demoConnectDelay = savedConnect;
      BleService.demoReplyDelay = savedReply;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final kind in DemoKind.values) {
      test('${kind.id}: TX bytes and RX frame order', () {
        final tx = <String>[];
        final rxBytes = <int>[];
        fakeAsync((async) {
          final ble = BleService();
          final sub = ble.packets.listen((e) {
            if (e.direction == LogDirection.tx) tx.add(_hex(e.bytes));
            if (e.direction == LogDirection.rx) rxBytes.addAll(e.bytes);
          });
          ble.connect(kind.id);
          async.elapse(const Duration(seconds: 3));
          // The command frames the cut-off / self-check flows write. The
          // values are arbitrary test credentials, not anyone's real ones.
          ble.sendAuth(cb: 0x0168, pwSum: 0x01E4);
          async.elapse(const Duration(milliseconds: 100));
          ble.switchMode(kind == DemoKind.battery
                  ? ModeArg.cutOff
                  : ModeArg.capacitorSelfCheck,
              cb: 0x0168, pwSum: 0x01E4);
          async.elapse(const Duration(milliseconds: 100));
          ble.writeCommand(const CommandBuilder().modeSet(ModeArg.unlock));
          async.elapse(const Duration(milliseconds: 100));
          ble.writeCommand(const CommandBuilder().modeReadBack());
          async.elapse(const Duration(seconds: 57));
          ble.disconnect();
          async.elapse(const Duration(seconds: 2));
          sub.cancel();
          ble.dispose();
          async.flushMicrotasks();
        });
        final frames = FrameReassembler().addBytes(rxBytes);
        _golden('tx_${kind.name}.txt', tx);
        _golden('rx_order_${kind.name}.txt', [
          for (final f in frames)
            'sel=0x${f.selector.toRadixString(16).padLeft(2, '0')} '
                'len=${f.len} crc=${f.checksumOk ? 'ok' : 'BAD'}',
        ]);
        expect(tx.length, greaterThan(55), reason: 'about one write a second');
      });
    }
  });

  group('d. decode of a fixed-clock demo unit', () {
    final t0 = DateTime.utc(2026, 11, 9, 12);
    for (final kind in DemoKind.values) {
      test('${kind.id}: samples for ticks 1-60', () {
        var now = t0;
        final unit = DemoPeripheral(kind, clock: () => now);
        final reassembler = FrameReassembler();
        final decoder = TelemetryDecoder();
        final lines = <String>[];
        for (var tick = 1; tick <= 60; tick++) {
          now = t0.add(Duration(seconds: tick));
          final isPb = decoder.sample.isPowerBank;
          final answer = unit.answer(_token(tick, isPowerBank: isPb));
          for (final f in reassembler.addBytes([for (final a in answer) ...a])) {
            if (!f.checksumOk) continue;
            decoder.ingest(f, at: now);
          }
          final s = decoder.sample;
          lines.add('tick=$tick dt=${s.deviceType} pb=${s.isPowerBank} '
              '${jsonEncode(s.toMap())}');
        }
        _golden('decode_${kind.name}.txt', lines);
      });
    }
  });

  test('e. a power-bank device type switches the schedule', () {
    final decoder = TelemetryDecoder();
    final t = DateTime.utc(2026, 11, 9, 12);
    expect(decoder.sample.isPowerBank, isFalse);
    expect(_token(5, isPowerBank: decoder.sample.isPowerBank),
        const CommandBuilder().keepAlive());
    for (final f in FrameReassembler()
        .addBytes(buildFrame(Selectors.deviceType, const [0x22]))) {
      decoder.ingest(f, at: t);
    }
    expect(decoder.sample.isPowerBank, isTrue);
    expect(_token(5, isPowerBank: decoder.sample.isPowerBank),
        const CommandBuilder().extendedPoll());
    expect(_token(25, isPowerBank: decoder.sample.isPowerBank),
        const CommandBuilder().slowMetadataPoll());
  });
}
