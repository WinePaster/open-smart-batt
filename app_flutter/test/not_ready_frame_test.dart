// Not-ready frames — a power bank that reboots mid-session sends ONE telemetry
// group whose registers are not yet populated, inside frames that are otherwise
// perfectly legal.
//
// The wire, from a 2026-08-05 capture that caught three reboots (each confirmed
// independently by `0x3B` rewinding to a checkpoint and `0x34`'s last byte
// incrementing):
//
//   17:00:36.679   0x19=0000  0x37=0000  0x21=00e2     <- reboot, not ready
//   17:00:36.859   0x19=019a  0x37=01fa  0x21=1be2     <- 180 ms later, normal
//
// Note `0x21`'s trailing byte is `0xe2` in BOTH: the framing is intact and the
// XOR checks out. Nothing about the frame says "ignore me" — only the values do.
//
// Rendered as-is that group prints "0.00 V / 0.00 V / 0 °C" on the dashboard,
// which is the failure mode this project rates as worse than a blank: a wrong
// number that looks entirely reasonable.
//
// The guard is PHYSICAL, not statistical — a device whose primary cell reads
// 0 V cannot power the radio that just delivered the frame — which is why these
// tests assert it holds for every product class, and why the secondary voltage
// is guarded only on a power bank (a discharged capacitor really does sit at
// 0 V on its secondary).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inbound(selector, payload)).single;

void main() {
  final at = DateTime.utc(2026, 8, 5, 17, 0, 36);

  /// The reboot frame's own bytes: `0x19 = 0000`, `0x37 = 0000`.
  final pvltZero = decodeOne(0x19, [0x00, 0x00]);
  final svltZero = decodeOne(0x37, [0x00, 0x00]);

  /// The frame 180 ms later, from the same capture.
  final pvltReal = decodeOne(0x19, [0x01, 0x9a]); // 4.10 V
  final svltReal = decodeOne(0x37, [0x01, 0xfa]); // 5.06 V

  TelemetrySample sampleOf(int deviceType) =>
      TelemetrySample.empty().copyWith(deviceType: deviceType);

  group('a zero primary voltage is dropped on every class', () {
    for (final entry in const {
      'power bank': 0x22,
      'smart battery': 0x02,
      'supercapacitor': 0x17,
    }.entries) {
      test(entry.key, () {
        // Start from a sample that already carries a good reading, so the test
        // distinguishes "not written" from "written as null".
        final good = TelemetryDecoder.apply(
            sampleOf(entry.value), pvltReal,
            at: at);
        expect(good.pvlt, closeTo(4.10, 0.001));

        final after = TelemetryDecoder.apply(good, pvltZero, at: at);
        expect(after.pvlt, closeTo(4.10, 0.001),
            reason: 'the not-ready frame must not overwrite a real reading');
      });
    }

    test('and it does not fabricate one from an empty sample', () {
      final s = TelemetryDecoder.apply(sampleOf(0x22), pvltZero, at: at);
      expect(s.pvlt, isNull, reason: 'blank beats 0.00 V');
    });
  });

  group('the secondary voltage guard is power-bank only', () {
    test('power bank: a zero port voltage is dropped', () {
      final good = TelemetryDecoder.apply(sampleOf(0x22), svltReal, at: at);
      expect(good.svlt, closeTo(5.06, 0.001));
      final after = TelemetryDecoder.apply(good, svltZero, at: at);
      expect(after.svlt, closeTo(5.06, 0.001));
    });

    test('capacitor: a zero secondary voltage is a REAL reading and is kept',
        () {
      // The discriminator that makes the pvlt guard safe (a live device cannot
      // be at 0 V) does not transfer here: a discharged supercapacitor really
      // does read 0 V on its secondary. Guarding it class-blind would hide a
      // true measurement, so this test is the boundary marker.
      final good = TelemetryDecoder.apply(sampleOf(0x17), svltReal, at: at);
      expect(good.svlt, closeTo(5.06, 0.001));
      final after = TelemetryDecoder.apply(good, svltZero, at: at);
      expect(after.svlt, 0.0, reason: 'capacitors may legitimately read 0 V');
    });
  });

  test('the frame 180 ms later decodes normally — the guard is not a filter',
      () {
    var s = sampleOf(0x22);
    s = TelemetryDecoder.apply(s, pvltZero, at: at);
    s = TelemetryDecoder.apply(s, svltZero, at: at);
    expect(s.pvlt, isNull);
    expect(s.svlt, isNull);

    s = TelemetryDecoder.apply(s, pvltReal, at: at);
    s = TelemetryDecoder.apply(s, svltReal, at: at);
    expect(s.pvlt, closeTo(4.10, 0.001));
    expect(s.svlt, closeTo(5.06, 0.001));
  });
}
