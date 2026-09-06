// Power-bank 0x4B byte b7 → port / protocol flag decode (design 0035 Phase 0).
//
// b7 is the port/protocol flag byte. This phase decodes it into the raw byte
// [TelemetrySample.portFlagsRaw] plus derived fields, WITHOUT changing any
// on-screen pixels (no view reads them yet). The bit map (design 0035 §3.2):
//   bit1 = Type-C cable / CC   → usbPort == UsbPort.typeC (else unknown)
//   bit2 = output active       → isOutputActive
//   bit3 = PD input (one-way)  → isPdIn
//   bit5 = non-5 V output contract → isPdOut  (narrowed from "PD output"
//                                    2026-09-04: the protocol was never
//                                    observed, only the voltage)
//   b7 == 0x00                 → isRailOff  (boost rail off)
//   bit0 and bit4              → decoded to NOTHING
//
// The three ground-truth vectors are the ones the owner's own capture produced
// (design 0035 §3.3), anchored to what the owner said was happening:
//   * b7 = 0x0a (bit1+bit3): "使用 type c 充電"      → Type-C + PD input
//   * b7 = 0x05 (bit0+bit2): output active, bit0 set  → port UNKNOWN, not Type-A
//   * b7 = 0x00            : boost rail off
//
// CLEAN-ROOM: bit positions and their meanings come from docs/protocol
// power-bank.md plus our own captures; no raw byte is ever shown to a user.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

/// One inbound frame `[0xB8, selector, flag, LEN, payload..., XOR]`.
List<int> inbound(int selector, List<int> payload, {int flag = 0x01}) {
  final body = <int>[0xB8, selector, flag, payload.length, ...payload];
  return <int>[...body, xorFold(body)];
}

InboundFrame decodeOne(int selector, List<int> payload) =>
    FrameReassembler().addBytes(inbound(selector, payload)).single;

void main() {
  final at = DateTime.utc(2026, 8, 4, 12, 0);

  /// A sample that already knows it is a power bank (0x10 = 0x22) — the real
  /// burst order, since 0x4B is class-gated.
  final pb = TelemetrySample.empty().copyWith(deviceType: 0x22);

  /// Decode a 0x4B frame whose b7 is [b7], keeping SOC (b6=0x62=98) and design
  /// capacity (b4b5=0x2710=10000) fixed so only the flag byte varies.
  TelemetrySample withB7(int b7) => TelemetryDecoder.apply(
        pb,
        decodeOne(0x4B, [0x27, 0x10, 0x62, b7]),
        at: at,
      );

  group('the three §3.3 ground-truth vectors', () {
    test('0x0a → Type-C + PD input, rail on, not outputting', () {
      final s = withB7(0x0a);
      expect(s.portFlagsRaw, 0x0a);
      expect(s.usbPort, UsbPort.typeC); // bit1
      expect(s.isPdIn, isTrue); // bit3
      expect(s.isPdOut, isFalse); // bit5 clear
      expect(s.isOutputActive, isFalse); // bit2 clear (charging)
      expect(s.isRailOff, isFalse);
      // SOC + capacity still decode as before — b7 is additive.
      expect(s.socPercent, 98);
      expect(s.designCapacityMah, 10000);
    });

    test('0x05 → output active, port UNKNOWN (bit0 must NOT show Type-A)', () {
      final s = withB7(0x05); // bit0 + bit2
      expect(s.portFlagsRaw, 0x05);
      expect(s.usbPort, UsbPort.unknown,
          reason: 'bit1 clear ⇒ unknown; bit0 is refuted, never Type-A');
      expect(s.isOutputActive, isTrue); // bit2
      expect(s.isPdIn, isFalse);
      expect(s.isPdOut, isFalse);
      expect(s.isRailOff, isFalse);
    });

    test('0x00 → boost rail off, everything else clear', () {
      final s = withB7(0x00);
      expect(s.portFlagsRaw, 0x00);
      expect(s.isRailOff, isTrue);
      expect(s.usbPort, UsbPort.unknown);
      expect(s.isOutputActive, isFalse);
      expect(s.isPdIn, isFalse);
      expect(s.isPdOut, isFalse);
    });
  });

  group('bit0 and bit4 are decoded to NOTHING', () {
    test('bit0 alone (0x01) never yields Type-C and is not rail-off', () {
      final s = withB7(0x01);
      expect(s.usbPort, UsbPort.unknown);
      expect(s.isRailOff, isFalse, reason: 'only b7 == 0x00 is rail-off');
      expect(s.isOutputActive, isFalse);
      expect(s.isPdIn, isFalse);
      expect(s.isPdOut, isFalse);
    });

    test('0x03 (bit0+bit1) → Type-C from bit1, unaffected by bit0 (T7)', () {
      final s = withB7(0x03);
      expect(s.usbPort, UsbPort.typeC);
      expect(s.isOutputActive, isFalse);
    });

    test('0x12 (bit1+bit4) → Type-C, no PD, bit4 changes nothing (T6)', () {
      final s = withB7(0x12);
      expect(s.usbPort, UsbPort.typeC); // bit1
      expect(s.isPdIn, isFalse, reason: 'bit3 clear ⇒ no PD badge');
      expect(s.isPdOut, isFalse);
      expect(s.isOutputActive, isFalse);
      expect(s.isRailOff, isFalse);
    });
  });

  group('bit5 (non-5 V output contract) is independent of bit3 (PD input)',
      () {
    test('0x24 (bit2+bit5) → output contract set, PD input clear, not crossed',
        () {
      final s = withB7(0x24);
      expect(s.isPdOut, isTrue); // bit5
      expect(s.isPdIn, isFalse); // bit3 clear — never crossed
      expect(s.isOutputActive, isTrue); // bit2
    });
  });

  group('null until b7 is seen, and class-gated', () {
    test('a fresh sample has no port fields', () {
      final s = TelemetrySample.empty();
      expect(s.portFlagsRaw, isNull);
      expect(s.usbPort, isNull);
      expect(s.isRailOff, isNull);
      expect(s.isOutputActive, isNull);
      expect(s.isPdIn, isNull);
      expect(s.isPdOut, isNull);
    });

    test('a pack ignores 0x4B entirely — no port flags decoded', () {
      final s = TelemetryDecoder.apply(
        TelemetrySample.empty(), // no device type ⇒ not a power bank
        decodeOne(0x4B, [0x27, 0x10, 0x62, 0x0a]),
        at: at,
      );
      expect(s.portFlagsRaw, isNull);
      expect(s.usbPort, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 🔵 The wording narrowing of 2026-09-04, made mechanical.
  //
  // `docs/protocol/power-bank.md` withdrew "PD output" for bit 5: the bit is
  // 2,872/2,872 solid as "the output contract is above 5 V", but NO capture in
  // the corpus records which protocol the far end negotiated — "PD" was
  // inferred from a voltage and then written down as though it had been seen.
  //
  // 🔑 Why a test and not just an edit: the previous wording reached SEVEN
  // places across four files by being copied, and the doc that governs it lives
  // in a directory this suite cannot read. A comment sync with no guard is one
  // paste away from coming back, and nothing would report it.
  //
  // ⛔ bit3 is deliberately NOT covered. Its "PD" has ground truth — the owner
  // stated, of the capture it came from, that a Type-C PD charger was plugged
  // in — so "PD input" stays a claim this project can make.
  group('🔵 bit5: the withdrawn "PD output" wording cannot come back', () {
    /// Every `.dart` under `lib/` and `test/`, path-relative, sorted.
    List<String> sources() => ['lib', 'test']
        .expand((d) => Directory(d)
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.endsWith('.dart')))
        .toList()
      ..sort();

    test('no source phrases bit5 as PD on the output side', () {
      // Separator-required on purpose: the IDENTIFIER `isPdOut` and the capture
      // mark `pb_out_c_pd` are names, not claims, and renaming them is a
      // separate decision (see [TelemetrySample.isPdOut]). Only the PROSE form
      // is withdrawn: "PD output", "PD **output**", "output PD", "output-PD".
      final withdrawn = RegExp(
        r'\bPD[ *_-]+out|\bout(?:put)?[ *_-]+\*{0,2}PD\b',
        caseSensitive: false,
      );
      // The one legal use: naming the old wording INSIDE a sentence that says
      // it was withdrawn. "It used to say X" is history; "it says X" is a
      // claim. This test's own prose qualifies under exactly that rule, which
      // is why it needs no self-exemption.
      final history = RegExp('narrowed|withdrawn|withdrew', caseSensitive: false);
      final offenders = <String>[];
      for (final f in sources()) {
        // ⛔ The ONE exemption, and it is not a loophole: a capture mark is the
        // USER writing down what they plugged in. `pb_out_c_pd` is the single
        // place in this app where "PD" is an OBSERVATION rather than an
        // inference from a voltage — it is the ground truth the narrowed row is
        // still waiting for, not a repetition of the withdrawn claim.
        if (f == 'lib/models/capture_mark.dart') continue;
        for (final line in File(f).readAsLinesSync()) {
          if (!withdrawn.hasMatch(line)) continue;
          if (history.hasMatch(line)) continue;
          offenders.add('$f: ${line.trim()}');
        }
      }
      expect(offenders, isEmpty,
          reason: 'bit5 is evidenced as "a non-5 V output contract", never as '
              'PD — no capture records the negotiated protocol '
              '(docs/protocol/power-bank.md, narrowed 2026-09-04)');
    });

    test('the getter that decodes bit5 says what it is now evidenced as', () {
      // The negative above would stay green if somebody deleted the doc
      // comment outright. This is the positive half.
      final src = File('lib/models/telemetry_sample.dart').readAsStringSync();
      final before = src.split('bool? get isPdOut').first;
      // Just the doc block attached to the getter — everything after the last
      // blank line before it. Reading the whole file would pass on any other
      // mention of the phrase and prove nothing about this getter.
      final doc = before.split('\n\n').last;
      expect(doc, contains('non-5 V output contract'));
      expect(doc, contains('bit5'));
    });
  });
}
