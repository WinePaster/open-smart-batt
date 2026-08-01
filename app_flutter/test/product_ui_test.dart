// Unit tests for the design-0001 product-class UI architecture (Phase 2–5):
//   * ProductClass mapping (device-type → class) + pack-label inference.
//   * ProductClass storage-key round-trip (SavedDevice persistence).
//   * PackClassResolver settling-window behaviour (cosmetic label only).
//   * BleService keep-alive poll schedule (tick-driven token selection).
//   * The decoder SOC path (selector 0x96 b6 → socPercent, direct percent).
//   * PvltGauge two-mode fraction math (voltage domain vs percent).
//
// CLEAN-ROOM: every expectation is derived only from docs/PROTOCOL.md and the
// project's own design notes. No decompiled/original-app source was consulted.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/pack_class_resolver.dart';
import 'package:open_smart_batt/ui/dashboard/pvlt_gauge.dart';

/// One inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inbound(selector, payload)).single;

void main() {
  // =========================================================================
  // ProductClass mapping + pack-label inference (design 0001 §3.1 / §3.4)
  // =========================================================================
  group('ProductClass.fromDeviceType', () {
    test('0x22 (34) is the ONLY power-bank code; wire byte, not the Smi-tag',
        () {
      expect(ProductClass.fromDeviceType(0x22), ProductClass.powerBank);
      expect(ProductClass.fromDeviceType(0x22).isPowerBank, isTrue);
      // The old buggy 0x44 (Smi-tag of 34) must NOT map to power bank.
      expect(ProductClass.fromDeviceType(0x44), ProductClass.unknown);
      expect(ProductClass.fromDeviceType(null), ProductClass.unknown);
      expect(ProductClass.unknown.isPowerBank, isFalse);
    });

    test('0x17 is the super-capacitor (wire-verified 2026-07-27, design 0007)',
        () {
      expect(ProductClass.fromDeviceType(kSuperCapacitorDeviceType),
          ProductClass.supercapacitor);
      expect(ProductClass.fromDeviceType(0x17), ProductClass.supercapacitor);
      expect(ProductClass.fromDeviceType(0x02), ProductClass.smartBattery);
      // An unrecognised byte stays unknown — the user resolves it; we do not
      // fall back to guessing from telemetry any more.
      expect(ProductClass.fromDeviceType(0x99), ProductClass.unknown);
    });
  });

  group('ProductClass storage key round-trip', () {
    test('every value round-trips via its name', () {
      for (final c in ProductClass.values) {
        expect(ProductClass.fromStorageKey(c.storageKey), c);
      }
    });

    test('unknown / garbage key defaults to unknown (pre-migration rows)', () {
      expect(ProductClass.fromStorageKey(null), ProductClass.unknown);
      expect(ProductClass.fromStorageKey(''), ProductClass.unknown);
      expect(ProductClass.fromStorageKey('nope'), ProductClass.unknown);
    });
  });

  // =========================================================================
  // PackClassResolver — deterministic, no guessing (design 0007)
  // =========================================================================
  group('PackClassResolver', () {
    final t0 = DateTime.utc(2026, 7, 27, 20, 18);

    test('reads the class straight off the device-type byte', () {
      final r = PackClassResolver()..markConnected(t0);
      r.observe(TelemetrySample(timestamp: t0, deviceType: 0x22));
      expect(r.isPowerBank, isTrue);
      expect(r.label, ProductClass.powerBank);

      final b = PackClassResolver()..markConnected(t0);
      b.observe(TelemetrySample(timestamp: t0, deviceType: 0x02));
      expect(b.label, ProductClass.smartBattery);
    });

    test('0x17 is a capacitor even though it streams current (the 07-27 bug)',
        () {
      // The regression in one test: this is exactly what the field unit sends —
      // device-type 0x17 AND a 0x2E current register pinned at 0.0 A. The old
      // fingerprint called it a battery and handed it the battery controls.
      final r = PackClassResolver()..markConnected(t0);
      r.observe(TelemetrySample(
        timestamp: t0,
        deviceType: kSuperCapacitorDeviceType,
        current: 0.0,
      ));
      expect(r.label, ProductClass.supercapacitor);
    });

    test('no telemetry fingerprint remains: current/DVOL never imply a class',
        () {
      final r = PackClassResolver()..markConnected(t0);
      r.observe(TelemetrySample(
        timestamp: t0,
        current: 1.5,
        dvol: const [3.3, 3.3, 3.3, 3.3],
        dvolPending: true,
      ));
      // Registers alone say nothing without a device-type byte.
      expect(r.label, ProductClass.unknown);
    });

    test('a recognised byte overrides the user choice (self-heal)', () {
      // A record saved as smartBattery while the old fingerprint was guessing
      // is seeded as an override on reconnect; the wire byte must win, or the
      // unit stays mislabelled forever.
      final r = PackClassResolver()..markConnected(t0);
      r.setOverride(ProductClass.smartBattery);
      expect(r.label, ProductClass.smartBattery); // before any frame
      r.observe(TelemetrySample(
          timestamp: t0, deviceType: kSuperCapacitorDeviceType));
      expect(r.label, ProductClass.supercapacitor);
    });

    test('the user choice only applies to an unrecognised byte', () {
      final r = PackClassResolver()..markConnected(t0);
      r.observe(TelemetrySample(timestamp: t0, deviceType: 0x99));
      expect(r.label, ProductClass.unknown);
      r.setOverride(ProductClass.supercapacitor);
      expect(r.label, ProductClass.supercapacitor);
    });

    test('reset and reconnect drop both the byte and the choice', () {
      final r = PackClassResolver()..markConnected(t0);
      r.observe(TelemetrySample(timestamp: t0, deviceType: 0x02));
      r.setOverride(ProductClass.supercapacitor);
      r.reset();
      expect(r.override, isNull);
      expect(r.label, ProductClass.unknown);

      r.observe(TelemetrySample(timestamp: t0, deviceType: 0x02));
      r.markConnected(t0);
      expect(r.label, ProductClass.unknown, reason: 'new connection starts clean');
    });
  });

  // =========================================================================
  // BleService keep-alive poll schedule (PROTOCOL.md §2 / design §3.3)
  // =========================================================================
  group('BleService.keepAliveTokenFor', () {
    const cb = CommandBuilder();

    List<int> tokenAt(int tick, {required bool isPowerBank}) =>
        BleService.keepAliveTokenFor(cb, tick: tick, isPowerBank: isPowerBank);

    test('tick 1 sends !# for EVERY device (learns class)', () {
      expect(tokenAt(1, isPowerBank: false), [0x21, 0x23]);
      expect(tokenAt(1, isPowerBank: true), [0x21, 0x23]);
    });

    test('non-power-bank: # each tick, @ every 25th', () {
      expect(tokenAt(2, isPowerBank: false), [0x23]);
      expect(tokenAt(3, isPowerBank: false), [0x23]);
      expect(tokenAt(5, isPowerBank: false), [0x23]); // %5 only for power bank
      expect(tokenAt(24, isPowerBank: false), [0x23]);
      expect(tokenAt(25, isPowerBank: false), [0x40]); // @ metadata
      expect(tokenAt(50, isPowerBank: false), [0x40]);
    });

    test('power bank: extra !# every 5th tick (continuous SOC/port refresh)',
        () {
      expect(tokenAt(5, isPowerBank: true), [0x21, 0x23]);
      expect(tokenAt(10, isPowerBank: true), [0x21, 0x23]);
      expect(tokenAt(20, isPowerBank: true), [0x21, 0x23]);
      expect(tokenAt(2, isPowerBank: true), [0x23]);
      // tick 25 is a %5 AND %25 hit; per PROTOCOL.md §2 the `@` metadata poll is
      // checked BEFORE the power-bank !#, so a power bank still gets `@` at 25/50.
      expect(tokenAt(25, isPowerBank: true), [0x40]);
      expect(tokenAt(50, isPowerBank: true), [0x40]);
    });
  });

  // =========================================================================
  // Decoder SOC path (selector 0x96 b6 → socPercent, DIRECT percent)
  // =========================================================================
  group('decoder SOC path (0x96 b6)', () {
    final at = DateTime.utc(2026, 7, 3);

    test('socPercent reads b6 directly as a 0..100 percentage', () {
      expect(TelemetryDecoder.socPercent(decodeOne(0x96, [0, 0, 84, 0])), 84);
      expect(TelemetryDecoder.socPercent(decodeOne(0x96, [0, 0, 0, 0])), 0);
      expect(TelemetryDecoder.socPercent(decodeOne(0x96, [0, 0, 100, 0])), 100);
    });

    test('out-of-range b6 clamps to 100 (never a voltage→SOC curve)', () {
      expect(TelemetryDecoder.socPercent(decodeOne(0x96, [0, 0, 0xFF, 0])), 100);
    });

    test('apply 0x96 folds socPercent alongside capacityRaw + sohBucket', () {
      final s = TelemetryDecoder.apply(
          TelemetrySample.empty(at), decodeOne(0x96, [0, 0, 84, 0]),
          at: at);
      expect(s.socPercent, 84); // direct
      expect(s.capacityRaw, 84);
      expect(s.sohBucket, (84 - 1) * 10 + 5); // distinct icon bucket
    });

    test('the accumulator surfaces SOC on the folded sample', () {
      final dec = TelemetryDecoder();
      dec.ingest(decodeOne(0x96, [0, 0, 55, 0]), at: at);
      expect(dec.sample.socPercent, 55);
    });
  });

  // =========================================================================
  // PvltGauge two-mode fraction math (design 0001 §3.5)
  // =========================================================================
  group('PvltGauge fraction modes', () {
    test('voltage domain 8..16 V matches the original PVLT behaviour', () {
      expect(PvltGauge.voltageFraction(8.0), 0.0);
      expect(PvltGauge.voltageFraction(12.0), closeTo(0.5, 1e-9));
      expect(PvltGauge.voltageFraction(16.0), 1.0);
      expect(PvltGauge.voltageFraction(20.0), 1.0); // clamp high
      expect(PvltGauge.voltageFraction(4.0), 0.0); // clamp low
      expect(PvltGauge.voltageFraction(null), 0.0);
    });

    test('percent mode maps 0..100 onto 0..1', () {
      expect(PvltGauge.percentFraction(0), 0.0);
      expect(PvltGauge.percentFraction(50), closeTo(0.5, 1e-9));
      expect(PvltGauge.percentFraction(100), 1.0);
      expect(PvltGauge.percentFraction(150), 1.0); // clamp
      expect(PvltGauge.percentFraction(null), 0.0);
    });
  });
}
