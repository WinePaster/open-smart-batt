// The History list's per-minute drill-down — design 0074 (FB-90).
//
// The list shows one row per MINUTE over per-second storage (design 0061 T3a);
// tapping a row opens the seconds inside it. Four things can go wrong here and
// none of them raises an error:
//
//   1. **The window's edges.** `[t, t+60s)` — half-open. A closed upper bound
//      puts the row written at `14:04:00.000` in both 14:03 and 14:04, and it
//      simply appears twice.
//   2. **A second can be stored as more than one row.** `insertSamples` merges
//      segments in memory but its guarantee is per BATCH, not absolute, so the
//      read path has to aggregate — and aggregate with the SAME `samples`
//      weighting the row above it used, or the minute and its seconds report
//      different numbers on one screen (FB-74's defect, with both halves
//      visible at once).
//   3. **A minute recorded before per-second storage has no seconds** and must
//      not be expanded into sixty identical ones (design 0061 §3.2.3 E3 —
//      that is inventing measurements) nor come up blank (design 0074 R3 —
//      blank reads as data loss).
//   4. 🔴 **`COUNT(*)` cannot answer "are there seconds in here".** A legacy
//      minute cut into segments by a disconnect is several rows too. Only
//      `MIN(bucket_s)` answers it, and getting this wrong opens an empty sheet
//      on exactly the rows that need the explanation most.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/session_context.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/telemetry_controller.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/history/minute_seconds_sheet.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  void emit(TelemetrySample s) => _telemetry.add(s);

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    history = HistoryRepo(db.db);
  });

  tearDown(() async => db.close());

  // 🔑 LOCAL, and in the past. Two reasons, both learned here:
  //  * the repo hands rows back as `DateTime.fromMillisecondsSinceEpoch`,
  //    i.e. local — a UTC fixture compares equal to nothing and prints a
  //    different clock face in the widget tests;
  //  * a fixture in the FUTURE makes the sheet say "still being recorded",
  //    which is correct behaviour and a confusing thing to assert around.
  // Second-wide buckets are zone-independent anyway (every offset on earth is a
  // whole number of minutes), so `tzOffsetMs: 0` stays pinned below.
  final minute = DateTime(2026, 8, 19, 14, 3);

  Future<void> put({
    required DateTime at,
    required int bucketS,
    double? pvlt,
    int? temperature,
    int? mode,
    int samples = 5,
    String deviceId = 'AA',
  }) =>
      db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': pvlt,
        'temperature': temperature,
        'mode': mode,
        'device_id': deviceId,
        'samples': samples,
        'bucket_s': bucketS,
      });

  Future<HistoryListRow> theMinute({String deviceId = 'AA'}) async =>
      (await history.queryListBuckets(
              since: minute,
              until: minute.add(const Duration(minutes: 1)),
              bucketMs: 60000,
              deviceId: deviceId,
              tzOffsetMs: 0))
          .single;

  Future<List<HistoryListRow>> seconds({String deviceId = 'AA'}) =>
      history.querySecondsInWindow(
          from: minute, deviceId: deviceId, tzOffsetMs: 0);

  group('T1 — the window is half-open', () {
    test('the row at the next minute belongs to the next minute', () async {
      await put(at: minute, bucketS: 1, pvlt: 13.0);
      await put(
          at: minute.add(const Duration(seconds: 59)), bucketS: 1, pvlt: 13.5);
      // 🔴 The boundary row. Inclusive on both ends, it would appear here AND
      // in 14:04 — the same measurement counted twice, in two places, with
      // nothing on screen to say so.
      await put(
          at: minute.add(const Duration(minutes: 1)), bucketS: 1, pvlt: 99.0);

      final s = await seconds();
      expect(s, hasLength(2));
      expect(s.map((r) => r.sample.pvlt), isNot(contains(99.0)));
      // The first instant of the window IS in the window.
      expect(s.map((r) => r.sample.timestamp), contains(minute));
    });
  });

  group('T2 — one second, however it was stored', () {
    test('two segments of one second are one row, weighted by `samples`',
        () async {
      // The shape design 0048 G2 and `insertSamples` both warn about: a flush
      // landing on a batch boundary leaves two rows for one second.
      final at = minute.add(const Duration(seconds: 7));
      await put(at: at, bucketS: 1, pvlt: 13.0, samples: 405);
      await put(at: at, bucketS: 1, pvlt: 14.0, samples: 3);

      final s = await seconds();
      expect(s, hasLength(1), reason: '14:03:07 must appear once, not twice');
      expect(s.single.rows, 2, reason: 'and it says it folded two stored rows');
      // 🔴 Weighted: (13.0*405 + 14.0*3) / 408. An unweighted mean would say
      // 13.5 — the arithmetic the corpus has measured wrong four times.
      expect(s.single.sample.pvlt, closeTo((13.0 * 405 + 14.0 * 3) / 408, 1e-9));
      expect(s.single.sample.pvlt, isNot(closeTo(13.5, 1e-3)));
      expect(s.single.samples, 408);
    });
  });

  group('T3 — a minute recorded before per-second storage', () {
    test('says it has no seconds, and `COUNT(*)` must not be asked', () async {
      // One legacy minute, cut into three segments by disconnects — exactly
      // the case where `rows > 1` lies about there being seconds to show.
      await put(at: minute, bucketS: 60, pvlt: 13.1, samples: 405);
      await put(at: minute, bucketS: 60, pvlt: 13.2, samples: 69);
      await put(at: minute, bucketS: 60, pvlt: 13.3, samples: 3);

      final m = await theMinute();
      expect(m.rows, 3, reason: 'three stored rows — and none of them a second');
      expect(m.minBucketS, 60);
      expect(m.hasStoredSeconds, isFalse,
          reason: 'the trap: rows > 1 would have said yes');

      // The drill-down still returns something — the minute average — so the
      // sheet can explain rather than come up blank.
      final s = await seconds();
      expect(s, hasLength(1));
      expect(s.single.hasStoredSeconds, isFalse);
    });

    test('a row built by hand claims nothing', () {
      final row = HistoryListRow(
          sample: TelemetrySample(timestamp: minute, pvlt: 13.0),
          deviceId: 'AA',
          bucketMs: 60000,
          rows: 1);
      expect(row.minBucketS, isNull);
      expect(row.hasStoredSeconds, isFalse,
          reason: 'unknown must not advertise a drill-down it cannot fill');
    });
  });

  group('T4 — the upgrade minute holds both', () {
    test('it is drillable, and the legacy row is not dropped', () async {
      await put(at: minute, bucketS: 60, pvlt: 13.1, samples: 300);
      for (var s = 30; s < 33; s++) {
        await put(
            at: minute.add(Duration(seconds: s)), bucketS: 1, pvlt: 13.4);
      }

      final m = await theMinute();
      expect(m.minBucketS, 1, reason: 'MIN, not MAX: there ARE seconds in here');
      expect(m.hasStoredSeconds, isTrue);

      final s = await seconds();
      expect(s, hasLength(4), reason: 'the legacy row is shown, never dropped');
      expect(s.where((r) => r.hasStoredSeconds), hasLength(3));
      final legacy = s.firstWhere((r) => !r.hasStoredSeconds);
      expect(legacy.sample.timestamp, minute,
          reason: 'it sits at :00 and names no second');
    });
  });

  group('T5/T6 — the sheet and the row above it agree', () {
    setUp(() async {
      // 37 seconds of a partly-connected minute, one of them a spike.
      for (var s = 0; s < 37; s++) {
        await put(
            at: minute.add(Duration(seconds: s)),
            bucketS: 1,
            pvlt: s == 20 ? 15.5 : 13.2,
            samples: s.isEven ? 5 : 4);
      }
    });

    test('T6 — folding the seconds back gives the minute', () async {
      final m = await theMinute();
      final s = await seconds();
      expect(s, hasLength(37));

      var num = 0.0, den = 0.0;
      for (final r in s) {
        final w = (r.samples ?? 1).toDouble();
        num += r.sample.pvlt! * w;
        den += w;
      }
      expect(m.sample.pvlt, closeTo(num / den, 1e-9),
          reason: 'one weighting, used twice — never two arithmetics');
      expect(m.maxPvlt, 15.5);
      expect(s.map((r) => r.maxPvlt), contains(15.5),
          reason: 'the spike is a second, and stays one');
      expect(m.samples, den.toInt());
    });

    testWidgets('T5 — the sheet counts what is there, never out of sixty',
        (tester) async {
      final tele = _controller(db, history);
      addTearDown(tele.dispose);
      // ⚠️ Every DB touch inside `testWidgets` goes through [runAsync]: the
      // test body runs in a FakeAsync zone where real file I/O never completes,
      // and the symptom is a hang, not a failure.
      final row = (await tester.runAsync(theMinute))!;
      await _pumpSheet(tester, tele, row);

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      // 37 seconds, alternating 5 and 4 snapshots: 19*5 + 18*4 = 167.
      expect(texts, contains('記錄到 37 秒 · 共 167 筆遙測'));
      // 🔴 No denominator anywhere: nothing in the data says what it would be
      // (design 0074 R2).
      expect(texts.join('\n'), isNot(contains('60 秒')));
      expect(texts.join('\n'), isNot(contains('/ 60')));
      expect(texts.join('\n'), isNot(contains('/60')));
      // 🔵 design 0074 §3.6 / Q4 — inside the drill-down a row IS one second's
      // measurement, so the seconds place is the honest part of it.
      expect(texts, contains('14:03:20'));
    });
  });

  group('the sheet on a minute that has no seconds', () {
    testWidgets('explains, and does not invent sixty of them', (tester) async {
      final tele = _controller(db, history);
      addTearDown(tele.dispose);
      final row = (await tester.runAsync(() async {
        await put(at: minute, bucketS: 60, pvlt: 13.1, samples: 300);
        return theMinute();
      }))!;
      await _pumpSheet(tester, tele, row);

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(texts.join('\n'), contains('還沒逐秒記錄之前'));
      expect(texts.join('\n'), isNot(contains('記錄到 60 秒')));
      expect(texts.join('\n'), isNot(contains('14:03:')),
          reason: 'no second stamps: there are no seconds to stamp');
      // Not blank — R3. The explanation is the content.
      expect(find.byType(HistoryRow), findsNothing);
    });
  });

  group('T7 — the write buffer is flushed only for a recent window', () {
    late _FakeBle ble;
    late SessionContext session;
    late TelemetryController tele;

    setUp(() async {
      ble = _FakeBle();
      session = SessionContext();
      tele = TelemetryController(
        ble,
        settings: SettingsController(SettingsRepo(db.db)),
        history: history,
        logs: LogRepo(db.db),
        session: session,
        appBuild: '0.7.27+26081987',
      );
    });

    tearDown(() async {
      await tele.pendingWrites.drain();
      tele.dispose();
      await ble.dispose();
    });

    /// Leave exactly one row waiting in the batch buffer: the first second's
    /// bucket closes when the second one opens, and one row is well under the
    /// ten a batch waits for.
    Future<void> buffer(DateTime t) async {
      session.begin('AA');
      ble.emit(TelemetrySample(timestamp: t, pvlt: 13.0));
      await Future<void>.delayed(Duration.zero);
      ble.emit(
          TelemetrySample(timestamp: t.add(const Duration(seconds: 1)), pvlt: 13.1));
      await Future<void>.delayed(Duration.zero);
      expect(tele.pendingHistoryRows, greaterThan(0),
          reason: 'the fixture itself must leave something buffered');
    }

    test('drilling into the minute in progress commits it first', () async {
      final now = DateTime.now();
      await buffer(now.subtract(const Duration(seconds: 5)));
      await tele.historySecondsInWindow(
          from: DateTime(now.year, now.month, now.day, now.hour, now.minute),
          deviceId: 'AA');
      expect(tele.pendingHistoryRows, 0,
          reason: 'the last seconds are exactly what the user tapped to see');
    });

    test('drilling into last week does not', () async {
      await buffer(DateTime.now().subtract(const Duration(seconds: 5)));
      final before = tele.pendingHistoryRows;
      await tele.historySecondsInWindow(
          from: DateTime.now().subtract(const Duration(days: 3)),
          deviceId: 'AA');
      expect(tele.pendingHistoryRows, before,
          reason: 'nothing that old can still be in the buffer — '
              'a transaction per tap would buy nothing');
    });
  });
}

TelemetryController _controller(AppDatabase db, HistoryRepo history) =>
    TelemetryController(
      _FakeBle(),
      settings: SettingsController(SettingsRepo(db.db)),
      history: history,
      logs: LogRepo(db.db),
      session: SessionContext(),
      appBuild: '0.7.27+26081987',
    );

Future<void> _pumpSheet(
  WidgetTester tester,
  TelemetryController tele,
  HistoryListRow row,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: ChangeNotifierProvider<TelemetryController>.value(
      value: tele,
      child: Scaffold(
        body: MinuteSecondsSheet(
          row: row,
          tempUnit: TempUnit.celsius,
          deviceClass: ProductClass.smartBattery,
        ),
      ),
    ),
  ));
  // ⚠️ NOT `pumpAndSettle`, twice over: the sheet shows a
  // `CircularProgressIndicator` while its query runs, and an indeterminate
  // spinner schedules frames forever — settling on it is a ten-minute timeout,
  // not a pass. The [runAsync] is the other half: the query is real file I/O
  // and the widget-test zone's clock is fake, so without it the future the
  // sheet is waiting on never completes.
  await tester.pump();
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)));
  await tester.pump();
}
