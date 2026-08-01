// An unmapped device-type byte has to name itself in the log.
//
// The class is read off the wire and never inferred, so a byte nobody has
// captured routes to "unclassified" by design. The cost of that policy is
// discovery: we learn a new generation exists only when an owner describes
// their screen. 0x18 is the worked example — three units had been answering it
// for weeks, and what surfaced it was somebody saying their capacitor was being
// offered 解除斷電.
//
// The disconnect-time `class-resolve:` line already carried the byte, but it
// renders `class=0x19` exactly like `class=0x17`; telling them apart means
// knowing the mapped set by heart. These tests pin the explicit line instead:
// present for a byte we do not map, absent for every byte we do, and on the
// always-on event path rather than the raw-packet log, which is off by default.
//
// CLEAN-ROOM: expectations derive from this project's own source and captures.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _teleOut = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => _teleOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  String? get connectedDeviceId => 'AA';

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emit(TelemetrySample s) => _teleOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _teleOut.close();
    await super.dispose();
  }
}

/// `_event` inserts are unawaited two-step round trips; a microtask is not
/// enough to see them land.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<AppServices> makeServices(_StubBle ble) async {
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    return AppServices.create(appDatabase: db, ble: ble);
  }

  Future<List<String>> notes(AppServices s) async =>
      (await s.logRepo.queryLog()).map((e) => e.note ?? '').toList();

  Future<List<String>> unrecognisedLines(AppServices s) async =>
      (await notes(s))
          .where((n) => n.startsWith('device-type byte not recognised'))
          .toList();

  /// Connect, reach `ready`, then answer with one device-type byte.
  Future<AppServices> report(int deviceType) async {
    final ble = _StubBle();
    final s = await makeServices(ble);
    ble.emitLink(BleLinkState.connecting);
    ble.emitLink(BleLinkState.ready);
    await settle();
    ble.emit(TelemetrySample(timestamp: DateTime.now(), deviceType: deviceType));
    await settle();
    return s;
  }

  test('an unmapped byte is named in the log, in hex', () async {
    final s = await report(0x19);
    addTearDown(s.dispose);

    final lines = await unrecognisedLines(s);
    expect(lines, hasLength(1));
    expect(lines.single, contains('0x19'));
    // The reader is whoever opens the exported log, so the line has to carry
    // its own context rather than assume the mapped set is memorised.
    expect(lines.single, contains('unclassified'));
  });

  test('every byte this build DOES map stays silent', () async {
    for (final byte in const [
      kSmartBatteryDeviceType,
      kSuperCapacitorDeviceType,
      kSuperCapacitorGen3DeviceType,
      kPowerBankDeviceType,
    ]) {
      final s = await report(byte);
      addTearDown(s.dispose);
      expect(await unrecognisedLines(s), isEmpty,
          reason: 'a recognised 0x${byte.toRadixString(16)} is not news; '
              'a line on every connection would bury the one that is');
    }
  });

  test('0x18 in particular is silent now — it is the reason this exists',
      () async {
    // Before 2026-08-01 this byte WOULD have produced the line. That is the
    // intended lifecycle: unmapped byte → line in the field logs → capture →
    // mapping → silence.
    final s = await report(0x18);
    addTearDown(s.dispose);
    expect(await unrecognisedLines(s), isEmpty);
  });

  test('it fires once per connection, not once per frame', () async {
    // The device-type frame repeats every second; a flood would push the useful
    // lines out of the log's size budget (same reasoning as the unknown
    // capacitor-status line).
    final ble = _StubBle();
    final s = await makeServices(ble);
    addTearDown(s.dispose);

    ble.emitLink(BleLinkState.connecting);
    ble.emitLink(BleLinkState.ready);
    await settle();
    for (var i = 0; i < 5; i++) {
      ble.emit(TelemetrySample(timestamp: DateTime.now(), deviceType: 0x19));
      await settle();
    }

    expect(await unrecognisedLines(s), hasLength(1));
  });

  test('the line is on the event path, so it survives raw-packet-log off',
      () async {
    // Not a redundant assertion: a capture from a real reporter arrived with
    // rawPacketLog off and zero decodable frames. Anything that lives only in
    // the packet log is invisible in that case.
    final s = await report(0x19);
    addTearDown(s.dispose);
    expect(s.settings.settings.rawPacketLog, isFalse,
        reason: 'default is off — the condition this line has to survive');
    expect(await unrecognisedLines(s), hasLength(1));
  });
}
