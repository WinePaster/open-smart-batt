// FB-79 — a display window is a MINUTE, and a minute can hold more than one
// pack mode.
//
// The list aggregates `mode` with `MAX`, which is right for the badge: the most
// serious thing that happened in the window is what the row should be coloured
// by, and averaging a status code is meaningless. But `MAX` is LOSSY, and the
// direction it loses in is the bad one — cut-off (2) outranks anti-theft (1),
// so a minute that held both keeps the cut-off and the anti-theft leaves no
// trace anywhere on the screen. Per `docs/devices/common.md` (斷電 vs 防盜) it
// is the anti-theft that trips LATER, on a current spike, so for a vehicle that
// was moving it is the more dangerous of the two to have silently dropped from
// the record.
//
// The fix keeps `MAX(mode)` for classification, filtering and the badge, and
// adds two un-collapsed flags that only the sub-line reads. This file pins both
// halves: that the flags survive the aggregation, and that the sub-line says
// both when both are set.
//
// 📌 The mirror-image defect is history, and it is why the widget half exists:
// until `8182269` (2026-07-30, first released in v0.6.13) `ReportedStatus` held
// 0/2/4, so a pack sitting in CUT-OFF decoded to anti-theft and this very row
// told an owner the opposite of the truth. Nothing pinned that label. Now
// something does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late HistoryRepo history;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    history = HistoryRepo(db.db);
  });

  tearDown(() async => db.close());

  // UTC fixtures; every query pins `tzOffsetMs: 0`, so the machine's zone never
  // enters into it.
  final minute = DateTime.utc(2026, 8, 14, 19, 45);

  Future<void> put({
    required int second,
    int? mode,
    String deviceId = 'AA',
  }) async {
    await db.db.insert(Db.tableHistory, <String, Object?>{
      'timestamp': minute.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'pvlt': 13.2,
      'mode': mode,
      'device_id': deviceId,
      'samples': 5,
      'bucket_s': 1,
    });
  }

  Future<HistoryListRow> window({String deviceId = 'AA'}) async =>
      (await history.queryListBuckets(
              bucketMs: 60000, deviceId: deviceId, tzOffsetMs: 0))
          .single;

  group('the flags survive the minute aggregation', () {
    test('a minute of anti-theft only reports anti-theft, and nothing else',
        () async {
      for (var s = 0; s < 60; s++) {
        await put(
          second: s,
          mode: s >= 20 ? ReportedStatus.antiTheftActive : ReportedStatus.normal,
        );
      }
      final w = await window();
      expect(w.sample.mode, ReportedStatus.antiTheftActive);
      expect(w.sawAntiTheft, isTrue);
      expect(w.sawCutOff, isFalse,
          reason: 'nothing in this minute was ever a cut-off');
    });

    test('a minute holding BOTH keeps the cut-off badge AND remembers the '
        'anti-theft', () async {
      // The shape the corpus can produce at a mode transition: the pack sits in
      // anti-theft, is released, and is cut off again inside the same minute.
      for (var s = 0; s < 60; s++) {
        await put(
          second: s,
          mode: switch (s) {
            < 20 => ReportedStatus.antiTheftActive,
            < 40 => ReportedStatus.normal,
            _ => ReportedStatus.cutOffActive,
          },
        );
      }
      final w = await window();
      // Unchanged on purpose — the badge and the "warnings only" filter still
      // read `MAX(mode)`, and this test is here to catch anyone "fixing" that.
      expect(w.sample.mode, ReportedStatus.cutOffActive);
      expect(historyClassifyRow(w), HistoryRowStatus.event);
      expect(w.sawCutOff, isTrue);
      expect(w.sawAntiTheft, isTrue,
          reason: 'the whole point: MAX(mode) alone would have lost this');
    });

    test('a quiet minute sets neither flag', () async {
      for (var s = 0; s < 60; s++) {
        await put(second: s, mode: ReportedStatus.normal);
      }
      final w = await window();
      expect(w.sawAntiTheft, isFalse);
      expect(w.sawCutOff, isFalse);
      expect(historyClassifyRow(w), HistoryRowStatus.normal);
    });

    test('a minute whose rows all have a NULL mode sets neither flag', () async {
      // ⚠️ This pins the OUTCOME, not the SQL form. Rewriting the aggregate as
      // `MAX(mode = 1)` — which returns NULL here, since `NULL = 1` is NULL —
      // leaves this test green, because the repo coalesces null to false on the
      // way out. It was run: 0 red. The truthful claim is "an unknown minute
      // answers no", and that is what is asserted.
      for (var s = 0; s < 60; s++) {
        await put(second: s);
      }
      final w = await window();
      expect(w.sample.mode, isNull);
      expect(w.sawAntiTheft, isFalse);
      expect(w.sawCutOff, isFalse);
    });

    test('the flags stay with their own unit', () async {
      // Same minute, two units, one mode each. Grouping is by (device, window)
      // and the flags must not leak across it.
      for (var s = 0; s < 60; s++) {
        await put(second: s, mode: ReportedStatus.antiTheftActive);
        await put(
            second: s, mode: ReportedStatus.cutOffActive, deviceId: 'BB');
      }
      final a = await window();
      final b = await window(deviceId: 'BB');
      expect((a.sawAntiTheft, a.sawCutOff), (true, false));
      expect((b.sawAntiTheft, b.sawCutOff), (false, true));
    });
  });

  group('what the row actually says', () {
    /// Render one [HistoryRow] and return every string it drew.
    Future<List<String>> labels(
      WidgetTester tester, {
      required int mode,
      bool sawAntiTheft = false,
      bool sawCutOff = false,
    }) async {
      final row = HistoryListRow(
        sample: TelemetrySample(timestamp: minute, pvlt: 13.2, mode: mode),
        deviceId: 'AA',
        bucketMs: 60000,
        sawAntiTheft: sawAntiTheft,
        sawCutOff: sawCutOff,
        rows: 60,
      );
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: HistoryRow(
            row: row,
            tempUnit: TempUnit.celsius,
            status: historyClassifyRow(row),
            deviceClass: ProductClass.smartBattery,
          ),
        ),
      ));
      return tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
    }

    testWidgets('anti-theft alone reads as anti-theft', (tester) async {
      final l = await labels(tester,
          mode: ReportedStatus.antiTheftActive, sawAntiTheft: true);
      expect(l, contains('防盜模式已啟動'));
    });

    testWidgets('cut-off alone reads as cut-off', (tester) async {
      final l = await labels(tester,
          mode: ReportedStatus.cutOffActive, sawCutOff: true);
      expect(l, contains('斷電模式已啟動'));
    });

    testWidgets('both in one minute says both, not just the cut-off',
        (tester) async {
      final l = await labels(tester,
          mode: ReportedStatus.cutOffActive,
          sawAntiTheft: true,
          sawCutOff: true);
      expect(l, contains('這一分鐘內斷電與防盜都啟動過'));
      expect(l, isNot(contains('斷電模式已啟動')),
          reason: 'the collapsed label is what FB-79 replaces here');
    });

    testWidgets('a row built without flags falls back to the single label',
        (tester) async {
      // Rows the screen builds by hand (and every older caller) default both
      // flags to false. They must keep the old behaviour rather than claim an
      // event that was never recorded.
      final l = await labels(tester, mode: ReportedStatus.cutOffActive);
      expect(l, contains('斷電模式已啟動'));
    });
  });
}
