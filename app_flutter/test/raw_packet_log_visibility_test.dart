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
  // The layout line (design 0034 §8) is REQUIRED and is therefore part of
  // every call here. It is pinned as the preamble's trailer below.
  const kLayout = 'face=standard modules=gaugeVoltage,readouts,cells';

  List<String> header({bool? rawPacketLog}) => exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: DateTime.utc(2026, 7, 30, 17, 55),
        appBuild: '0.6.12+1',
        platform: 'ios 26.6',
        scope: 'all devices',
        layout: kLayout,
        home: 'tiles=auto',
        speedDetection: false, gMeter: false,
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

  // ==========================================================================
  // Scan-roster disclosure — ruled 2026-08-09. Same answer as FB-37, different
  // reason, and the reason is what these tests are for.
  // ==========================================================================
  //
  // FB-37 is about OUR OWN unit's BLE address: the exporter owns the hardware
  // being named, so telling them is the whole duty. The scan roster
  // (`connection_controller.dart`, `scan hit id=… name='…'`) records every
  // nearby advertiser's advertised name VERBATIM — earbuds, laptops and phones
  // belonging to people who never installed this app. Redaction was ruled out
  // for the same reason as FB-37 (the names are the diagnostic value:
  // `RCE-SCAP_III` / `RCE-CarBatt` / `RCE-BikeBatt` are what tied selector 0x18
  // to a product class across three units, and an apparent bystander is very
  // often the reporter's own second device) — but "you were told and it is your
  // own hardware" does NOT carry across to a stranger, so the two rulings are
  // pinned apart. Nobody should be able to cite FB-37 for leaving this one out.
  group('scan-roster disclosure — third parties, not our own hardware', () {
    test('the log warns the RECIPIENT that it names nearby devices', () {
      final h = header(rawPacketLog: false);
      expect(h.any((l) => l.contains('nearby Bluetooth devices')), isTrue);
      expect(h.any((l) => l.contains('advertised names')), isTrue);
    });

    test('it is emitted whether or not raw packet logging is on', () {
      // The roster is written by the ordinary event log, which the raw-packet
      // switch does not gate. Tying the disclosure to that switch would make a
      // file with the switch off silently undisclosed.
      for (final raw in [true, false]) {
        expect(header(rawPacketLog: raw).where((l) => l.contains('nearby')),
            hasLength(1),
            reason: 'rawPacketLog: $raw');
      }
    });

    test('it is never gated on the scan having actually seen anything', () {
      // FB-32's rule, stated as a test because the tempting implementation is
      // the wrong one. A note that appears only when there were hits makes its
      // ABSENCE mean both "nothing was nearby" and "an older build wrote this",
      // and the reader deciding whether to attach the capture to a public issue
      // would need our version history to tell those apart.
      //
      // `exportHeaderLines` is not handed the roster, or a count, or anything
      // else that could vary with it — which is what makes the wrong version
      // unimplementable here rather than merely discouraged. The assertion is
      // that the two calls produce the IDENTICAL line, byte for byte.
      final withRaw =
          header(rawPacketLog: true).firstWhere((l) => l.contains('nearby'));
      expect(header(rawPacketLog: false), contains(withRaw));
    });

    test('the history CSV does not carry it — there is no roster in a CSV', () {
      // The one thing that legitimately varies. `rawPacketLog` is supplied only
      // by the diagnostic-log export path, so its nullability is the file-KIND
      // discriminator, not a fact about the contents. A CSV claiming to list
      // nearby devices would be a different false statement.
      expect(header().where((l) => l.contains('nearby')), isEmpty);
    });

    test('it says names are in the clear, since the ids beside them are not',
        () {
      // `scan hit` already hashes the id (FB-33). Disclosing "we list devices"
      // without saying the NAMES are verbatim would leave a reader assuming the
      // same treatment applied to both halves of the line.
      final note =
          header(rawPacketLog: true).firstWhere((l) => l.contains('nearby'));
      expect(note, startsWith('note: '));
      expect(': '.allMatches(note), hasLength(1),
          reason: 'the ingest recipes read a value with a greedy `sed "s/.*: "`');
      expect(note, isNot(contains('\n')));
    });
  });

  // The contract this group states was, until design 0034, "the preamble may
  // only grow at the end". It now has a pinned TRAILER as well — the layout
  // line, which §8 requires to be last — so the contract is restated as a
  // fixed HEAD, an optional MIDDLE and a fixed TAIL. That is a change to what
  // is asserted and is made deliberately, not by loosening: every position the
  // old group nailed down is still nailed down, and the new line is nailed
  // down too. Ingest scripts match these lines by PREFIX, never by index past
  // the head, which is why appending inside the middle stays safe.
  group('format compatibility: fixed head, optional middle, pinned trailer',
      () {
    test('the existing four lines keep their exact order and position', () {
      // Eleven collected batches are parsed with scripts written against this
      // preamble. Nothing in the head may move, ever.
      final h = header(rawPacketLog: false);
      expect(h[0], 'OpenSmartBatt diagnostic log');
      expect(h[1], startsWith('exported: '));
      expect(h[2], startsWith('scope: '));
      expect(h[3], startsWith('app: '));
    });

    test('the raw-log line follows the head immediately, and layout closes',
        () {
      final h = header(rawPacketLog: false);
      expect(h[4], 'raw packet log: off');
      expect(h.last, 'layout: $kLayout');
    });

    test('the four original lines survive the FB-37 note too', () {
      final h = header(rawPacketLog: true);
      expect(h[0], 'OpenSmartBatt diagnostic log');
      expect(h[1], startsWith('exported: '));
      expect(h[2], startsWith('scope: '));
      expect(h[3], startsWith('app: '));
      expect(h[4], 'raw packet log: on');
      expect(h.last, 'layout: $kLayout');
    });

    test('adding it changes nothing else about the preamble', () {
      final without = header();
      final with_ = header(rawPacketLog: true);
      // Head unchanged, trailer unchanged, and a known number of lines
      // inserted between them. The count went 2 → 3 on 2026-08-09 when the
      // scan-roster disclosure joined the middle; the assertion is unchanged in
      // kind — a new line still has to be written down here rather than slip in
      // under a looser matcher. The three are: `raw packet log: on`, the FB-37
      // BLE-address note, and the scan-roster note.
      expect(with_.take(4), without.take(4));
      expect(with_.last, without.last);
      expect(with_.length, without.length + 3);
      // Nothing was inserted BEFORE the head, either — the old
      // `sublist(0, without.length)` check covered that implicitly and it must
      // not be lost with it.
      expect(with_.indexWhere((l) => l.startsWith('app: ')), 3);
    });

    test('the trailer is emitted even with every optional field absent', () {
      // Design 0034 §8, and the FB-32 reason: if the line only appeared when
      // something was customised, its absence would mean both "default layout"
      // and "written by a build that predates the line".
      expect(header().last, 'layout: $kLayout');
      expect(header().where((l) => l.startsWith('layout: ')), hasLength(1));
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
