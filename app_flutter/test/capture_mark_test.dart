// Capture state marks.
//
// Several registers cannot be resolved from passive logs at all — nothing in
// the stream distinguishes Type-A from Type-C, or charging from standby. A mark
// is the user declaring which situation a stretch of data belongs to.
//
// The contract that matters is the CODE. Community members produce these files
// independently, and the analysis side matches on the code string; a rename or
// a translation would silently break every capture that came before it. So the
// codes are asserted literally here — if one changes, this test is the place
// that argument has to be made.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/diagnostics/capture_wizard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('codes are a stable, closed set', () {
    test('the six-step power-bank script matches the codes we handed out', () {
      // These were published to testers in this order before the app could
      // write them. Returning captures line up only if they stay identical.
      expect(
        [
          CaptureMark.powerBankOutA,
          CaptureMark.powerBankOutC5v,
          CaptureMark.powerBankOutCPd,
          CaptureMark.powerBankOutBoth,
          CaptureMark.powerBankIn,
          CaptureMark.powerBankIdle,
        ].map((m) => m.code).toList(),
        ['pb_out_a', 'pb_out_c_5v', 'pb_out_c_pd', 'pb_out_a_c', 'pb_in',
          'pb_idle'],
      );
    });

    test('pack marks are observation only — no deliberate-fault codes', () {
      // Owner ruling: marks that ask a user to drive a vehicle battery past its
      // over-voltage or over-temperature threshold are not shipped in the app.
      // FB-22 had just shown how wrong our reading of those flags could be.
      final codes = CaptureMark.values.map((m) => m.code).toList();
      for (final banned in ['pack_fault_ov', 'pack_fault_uv', 'pack_fault_ot']) {
        expect(codes, isNot(contains(banned)));
      }
      expect(codes, containsAll(['pack_idle', 'pack_charging', 'pack_load']));
    });

    test('every code is unique and ASCII snake_case', () {
      final codes = CaptureMark.values.map((m) => m.code).toList();
      expect(codes.toSet().length, codes.length);
      for (final c in codes) {
        expect(RegExp(r'^[a-z0-9_]+$').hasMatch(c), isTrue, reason: c);
      }
    });
  });

  group('log line format', () {
    test('carries the code and the human label, in that order', () {
      final line = CaptureMark.powerBankOutCPd.logLine('Type-C output (PD)');
      expect(line, 'mark: pb_out_c_pd | Type-C output (PD)');
      // Tooling splits on the pipe, so the code must precede it.
      expect(line.split(' |').first, 'mark: pb_out_c_pd');
    });

    test('a free-text note rides in the LABEL position, never the code', () {
      // Keeps the code set closed and enumerable no matter what a user types.
      final line = CaptureMark.note.logLine('Custom note', note: 'fan on');
      expect(line, 'mark: note | fan on');
      expect(line.split(' |').first, 'mark: note');
    });

    test('a translated label does not disturb the code', () {
      final zh = CaptureMark.powerBankIn.logLine('只接輸入充電');
      expect(zh.startsWith('mark: pb_in |'), isTrue);
    });

    test('end and skipped lines are distinguishable from a start', () {
      expect(CaptureMark.powerBankIn.endLogLine(), 'mark_end: pb_in');
      // "Deliberately skipped" must not read as "missing" — the same
      // distinction the export headers draw when they count what they left out.
      expect(CaptureMark.skippedLogLine(CaptureMark.powerBankOutBoth),
          'mark: skipped | pb_out_a_c');
    });
  });

  group('which marks are offered', () {
    test('a power bank gets its six steps, not the pack ones', () {
      final codes =
          CaptureMark.forClass(ProductClass.powerBank).map((m) => m.code);
      expect(codes, contains('pb_out_a'));
      expect(codes, isNot(contains('pack_charging')));
      expect(codes, contains('note'));
    });

    test('a capacitor gets the pack marks — same physical situations', () {
      final codes =
          CaptureMark.forClass(ProductClass.supercapacitor).map((m) => m.code);
      expect(codes, contains('pack_idle'));
      expect(codes, isNot(contains('pb_out_a')));
    });

    test('an unclassified unit is offered only the generic mark', () {
      // Offering power-bank steps for a unit we have not identified would
      // invite exactly the mislabelled ground truth marks exist to prevent.
      final codes =
          CaptureMark.forClass(ProductClass.unknown).map((m) => m.code).toList();
      expect(codes, ['note']);
    });
  });

  group('export surfaces the marks', () {
    late AppDatabase db;
    late LogRepo logs;

    setUp(() async {
      db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      logs = LogRepo(db.db);
    });
    tearDown(() async => db.close());

    test('the header lists count and distinct codes', () async {
      await logs.insertLog(LogEntry.event('link: ready', deviceId: 'AA'));
      await logs.insertLog(LogEntry.event(
          CaptureMark.powerBankOutA.logLine('A out'),
          deviceId: 'AA'));
      await logs.insertLog(LogEntry.event(
          CaptureMark.powerBankIn.logLine('charging'),
          deviceId: 'AA'));
      await logs.insertLog(LogEntry.event(
          CaptureMark.powerBankOutA.logLine('A out again'),
          deviceId: 'AA'));

      final out = await logs.exportLog(header: const ['scope: all']);
      // Three marks, two distinct states.
      expect(out, contains('marks: 3 (pb_out_a, pb_in)'));
    });

    test('a capture with no marks says so explicitly', () async {
      await logs.insertLog(LogEntry.event('link: ready', deviceId: 'AA'));
      final out = await logs.exportLog(header: const ['scope: all']);
      // "none" is information; a blank would read as a missing feature.
      expect(out, contains('marks: none'));
    });

    test('ordinary event lines are never mistaken for marks', () async {
      await logs.insertLog(LogEntry.event('scan done: 21 device(s)'));
      await logs.insertLog(LogEntry.event("scan hit id=x name='mark' rssi=-1 "
          'vendor=false'));
      final out = await logs.exportLog(header: const ['scope: all']);
      expect(out, contains('marks: none'));
    });
  });

  group('guided run — what the dwell rule protects', () {
    test('the minimum dwell exceeds the telemetry stall threshold', () {
      // A step shorter than one poll gap can legitimately contain ZERO frames
      // of the state being declared — which is how a real capture ended up with
      // a 2-second session that proved nothing. The dwell has to clear the
      // stall threshold with margin, or the guarantee is cosmetic.
      expect(kCaptureStepDwell.inSeconds,
          greaterThan(BleService.telemetryStallThreshold.inSeconds));
      expect(kCaptureStepDwell, const Duration(seconds: 10));
    });

    test('the run covers the full script, without the free-text mark', () {
      // The wizard walks declared states; "custom note" is not a state.
      final script = CaptureMark.forClass(ProductClass.powerBank)
          .where((m) => m != CaptureMark.note)
          .map((m) => m.code)
          .toList();
      expect(script.length, 6);
      expect(script.first, 'pb_out_a');
      expect(script.last, 'pb_idle');
    });

    test('a completed step yields a CLOSED interval, a skipped one does not',
        () {
      // The analysis side needs a span, not a start. But a skipped step must
      // NOT produce mark_end — that would hand back an interval containing
      // unrelated data.
      const m = CaptureMark.powerBankOutCPd;
      expect(m.logLine('x'), startsWith('mark: pb_out_c_pd'));
      expect(m.endLogLine(), 'mark_end: pb_out_c_pd');
      expect(CaptureMark.skippedLogLine(m), isNot(contains('mark_end')));
    });

    test('skipped lines do not inflate the export mark summary as states', () {
      // `mark: skipped | pb_x` parses to the code `skipped`, which is exactly
      // right: it is a distinct thing from having been in that state.
      final line = CaptureMark.skippedLogLine(CaptureMark.powerBankIn);
      expect(line.substring(6).split(' |').first.trim(), 'skipped');
    });
  });
}
