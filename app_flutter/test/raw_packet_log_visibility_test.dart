// Make the raw-packet-log switch visible (FB-32).
//
// THE CAPTURE THIS PINS DOWN. A 2026-07-30 field capture arrived holding one
// line of content:
//
//   # ---- device=<unit> session=1 app=0.6.11+26072909 ----
//   2026-07-30T17:54:19.088 EVT  # link: ready
//
// beside a CSV with 366 samples from the same minute. Telemetry was flowing;
// `rawPacketLog` defaults off, so `_onPacket()` discarded every packet before
// it reached the database. Nothing in the exported file said so, and we spent
// three replies telling reporters to change their export scope — which a
// corpus cross-tab later showed was never the cause (a device-scoped export in
// the same batch carries 27,085 RX lines).
//
// Two reporters doing the same thing produced 63,375 frames and 1 line. The
// file has to be able to say which of those it is.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';

void main() {
  List<String> header({bool? rawPacketLog}) => exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: DateTime.utc(2026, 7, 30, 17, 55),
        appBuild: '0.6.12+1',
        platform: 'ios 26.6',
        scope: 'all devices',
        connections: 1,
        rawPacketLog: rawPacketLog,
      );

  group('the preamble states the switch', () {
    test('off is stated', () {
      expect(header(rawPacketLog: false), contains('raw packet log: off'));
    });

    test('ON is stated too — absence must not be ambiguous', () {
      // If only `off` were emitted, a missing line would mean both "it was on"
      // and "an older build wrote this". That ambiguity is what made FB-10's
      // version inference a coincidence rather than a fact.
      expect(header(rawPacketLog: true), contains('raw packet log: on'));
    });

    test('omitted when not supplied, so the CSV preamble is unchanged', () {
      expect(header().where((l) => l.contains('raw packet log')), isEmpty);
    });
  });

  group('FB-37 disclosure — ruled 2026-07-30: disclose, do not redact', () {
    test('a raw-frame capture warns the RECIPIENT about the BLE address', () {
      // The person deciding whether to attach a capture to a public issue is
      // not the person who saw the export dialog, so the file has to say it.
      final h = header(rawPacketLog: true);
      expect(h.any((l) => l.contains('0x38')), isTrue);
      expect(h.any((l) => l.contains('BLE address')), isTrue);
    });

    test('no such note when there are no raw frames to disclose', () {
      expect(header(rawPacketLog: false).any((l) => l.contains('0x38')),
          isFalse);
      expect(header().any((l) => l.contains('0x38')), isFalse);
    });

    test('the address itself is never redacted out of the frames', () {
      // Recorded as an executable statement of the ruling: redacting inside an
      // XOR-checksummed frame either breaks the checksum or forges it, so the
      // preamble discloses instead. Nothing here strips anything.
      final h = header(rawPacketLog: true);
      expect(h.any((l) => l.toLowerCase().contains('redact')), isFalse);
    });
  });

  group('format compatibility: the preamble may only grow at the end', () {
    test('the existing four lines keep their exact order and position', () {
      // Eleven collected batches are parsed with scripts written against this
      // preamble. A new line may be appended; nothing above it may move.
      final h = header(rawPacketLog: false);
      expect(h[0], 'OpenSmartBatt diagnostic log');
      expect(h[1], startsWith('exported: '));
      expect(h[2], startsWith('scope: '));
      expect(h[3], startsWith('app: '));
    });

    test('the new line is appended last, not inserted', () {
      expect(header(rawPacketLog: false).last, 'raw packet log: off');
    });

    test('the four original lines survive the FB-37 note too', () {
      final h = header(rawPacketLog: true);
      expect(h[0], 'OpenSmartBatt diagnostic log');
      expect(h[1], startsWith('exported: '));
      expect(h[2], startsWith('scope: '));
      expect(h[3], startsWith('app: '));
      expect(h[4], 'raw packet log: on');
    });

    test('adding it changes nothing else about the preamble', () {
      final without = header();
      final with_ = header(rawPacketLog: true);
      expect(with_.sublist(0, without.length), without);
      // `raw packet log: on` plus the FB-37 disclosure line.
      expect(with_.length, without.length + 2);
    });

    test('no line carries its own comment prefix — the writer adds it', () {
      // The log and the CSV emit these at different points; a `# ` baked in
      // here would double up in one of them.
      for (final line in header(rawPacketLog: false)) {
        expect(line, isNot(startsWith('#')));
      }
    });
  });
}
