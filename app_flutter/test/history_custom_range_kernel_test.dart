// The shared kernel learns about a custom span — design 0083 S2 (T3–T8).
//
// 🔴 **What this pins, in one sentence:** everything a screen needs to know
// about "which slice of time is on screen" comes from ONE value and ONE
// derivation, including the half-open conversion that nobody can see is wrong.
//
// S2 adds no entry point — the picker is S3 — so these are the tests that make
// the kernel real before any UI can reach it. Four of them guard failures that
// produce no error and no visible symptom:
//
//  * `historySinceFor(custom)` returning null would widen a two-day window to
//    the whole database and draw a perfectly plausible chart on it (T3);
//  * a cache key that ignores the ends serves window A's rows under window B's
//    dates for thirty seconds (T4);
//  * `23:59:59` instead of next-midnight silently drops the last second of the
//    range — a real row at second resolution (T5);
//  * a preamble that states only the lower end cannot be told apart from a
//    preset's (T6).
import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/protocol.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/history/device_history_tab.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

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
  late _FakeBle ble;
  late TelemetryController tele;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    history = HistoryRepo(db.db);
    ble = _FakeBle();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: history,
      logs: LogRepo(db.db),
      session: SessionContext(),
    );
    debugClearDeviceHistoryCache();
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    tele.dispose();
    await ble.dispose();
    await db.close();
  });

  Future<void> put(DateTime at, {String deviceId = 'AA'}) =>
      db.db.insert(Db.tableHistory, <String, Object?>{
        'timestamp': at.millisecondsSinceEpoch,
        'pvlt': 13.4,
        'temperature': 30,
        'mode': ReportedStatus.normal,
        'device_id': deviceId,
        'samples': 1,
        'bucket_s': 1,
      });

  // ==========================================================================
  group('T3 — a custom range cannot be derived from the enum alone', () {
    test('T3a: `historySinceFor(custom)` throws rather than returning null',
        () {
      // CATCHES: the "harmless" simplification. `null` means "no lower bound"
      // everywhere downstream, so returning it here turns a window the user
      // chose into the whole database — and the chart, the stats and the list
      // would all agree with each other about it.
      expect(() => historySinceFor(HistoryRange.custom), throwsArgumentError);
    });

    test('T3b: the three presets still answer exactly as before', () {
      final today = DateTime.now();
      expect(historySinceFor(HistoryRange.today),
          DateTime(today.year, today.month, today.day));
      expect(
          historySinceFor(HistoryRange.week),
          DateTime(today.year, today.month, today.day)
              .subtract(const Duration(days: 6)));
      expect(historySinceFor(HistoryRange.all), isNull);
    });

    test('T3c: a preset selection cannot be built for `custom`', () {
      expect(() => HistoryRangeSel.preset(HistoryRange.custom),
          throwsA(isA<AssertionError>()));
    });

    test('T3d: `historyBoundsFor` is the one derivation for both kinds', () {
      final n = DateTime.now();
      final midnight = DateTime(n.year, n.month, n.day);
      expect(historyBoundsFor(HistoryRangeSel.initial),
          (since: midnight, until: null));
      expect(historyBoundsFor(const HistoryRangeSel.preset(HistoryRange.all)),
          (since: null, until: null));

      final sel = historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      expect(historyBoundsFor(sel),
          (since: DateTime(2026, 8, 1), until: DateTime(2026, 8, 16)));
    });
  });

  // ==========================================================================
  group('T4 — the cache key describes the whole selection', () {
    test('T4a: two different custom spans do not collide', () {
      // CATCHES: the pre-0083 key (`'$deviceId|${range.name}'`), which was
      // complete only while every range was fully described by its name. Under
      // it both spans below key to `AA|custom` and the second one is served the
      // first one's rows for the whole TTL — dates change on screen, numbers do
      // not, nothing is logged.
      final a = historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 7));
      final b = historyCustomRange(DateTime(2026, 8, 8), DateTime(2026, 8, 14));
      expect(debugDeviceHistoryCacheKey('AA', a),
          isNot(debugDeviceHistoryCacheKey('AA', b)));

      // …and one differing end is enough.
      final c = historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 8));
      expect(debugDeviceHistoryCacheKey('AA', a),
          isNot(debugDeviceHistoryCacheKey('AA', c)));
    });

    test('T4b: the same span keys the same, and units stay apart', () {
      final a = historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 7));
      final again =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 7));
      expect(debugDeviceHistoryCacheKey('AA', a),
          debugDeviceHistoryCacheKey('AA', again));
      expect(debugDeviceHistoryCacheKey('AA', a),
          isNot(debugDeviceHistoryCacheKey('BB', a)));
    });

    test('T4c: the presets key as they always did — no cache churn', () {
      // A preset's key must not start carrying nulls as text in a way that
      // changes it, or every existing entry misses once on upgrade.
      expect(debugDeviceHistoryCacheKey('AA', HistoryRangeSel.initial),
          isNot(debugDeviceHistoryCacheKey(
              'AA', const HistoryRangeSel.preset(HistoryRange.all))));
    });
  });

  // ==========================================================================
  group('T5 — half-open, local, and it covers the last day', () {
    test('T5a: "up to the 15th" stores midnight on the 16th', () {
      final sel =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      expect(sel.from, DateTime(2026, 8, 1));
      expect(sel.to, DateTime(2026, 8, 16));
      expect(sel.to!.isUtc, isFalse, reason: 'local, like every bucket');
    });

    test('T5b: the last second of the last day is INSIDE the range', () async {
      // CATCHES: `23:59:59`. At second resolution that boundary drops a real
      // row, and the chart above it still looks complete.
      await put(DateTime(2026, 8, 15, 23, 59, 59));
      await put(DateTime(2026, 8, 16, 0, 0, 0)); // the next day, and outside

      final sel =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      final (:since, :until) = historyBoundsFor(sel);
      final stats =
          await history.aggregate(since: since, until: until, deviceId: 'AA');
      expect(stats.count, 1);
      expect(stats.lastAt, DateTime(2026, 8, 15, 23, 59, 59));
    });

    test('T5c: a time-of-day in the picker cannot change what it means', () {
      // 🔵 Q4 ruled date-only. Truncating here means a picker that grows a
      // clock later cannot silently move the boundary.
      final a =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      final b = historyCustomRange(
          DateTime(2026, 8, 1, 14, 30), DateTime(2026, 8, 15, 9, 5));
      expect(b.from, a.from);
      expect(b.to, a.to);
    });

    test('T5d: month and year ends do not need calendar arithmetic', () {
      expect(
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)).to,
          DateTime(2026, 9, 1));
      expect(
          historyCustomRange(DateTime(2026, 1, 1), DateTime(2026, 12, 31)).to,
          DateTime(2027, 1, 1));
    });

    test('T5e: a single day is a 24-hour half-open window', () {
      final sel =
          historyCustomRange(DateTime(2026, 8, 15), DateTime(2026, 8, 15));
      expect(sel.span, const Duration(hours: 24));
    });
  });

  // ==========================================================================
  group('T6 — the export preamble states both ends (FB-60)', () {
    test('T6a: custom writes `since=` and `until=`', () {
      final sel =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      final (:since, :until) = historyBoundsFor(sel);
      expect(
        historyWindowLabel(sel, since),
        'custom  since=${since!.toIso8601String()}'
        '  until=${until!.toIso8601String()}',
      );
    });

    test('T6b: the presets are byte-for-byte unchanged', () {
      final since = DateTime(2026, 8, 4);
      expect(
          historyWindowLabel(
              const HistoryRangeSel.preset(HistoryRange.today), since),
          'today  since=${since.toIso8601String()}');
      expect(
          historyWindowLabel(
              const HistoryRangeSel.preset(HistoryRange.week), since),
          '7d  since=${since.toIso8601String()}');
      expect(
          historyWindowLabel(
              const HistoryRangeSel.preset(HistoryRange.all), null),
          'all');
    });
  });

  // ==========================================================================
  group('T7 — a custom range is framed by its span, not by its name', () {
    late AppLocalizations l10n;

    setUp(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('T7a: ≤ 24 h is single-day, > 24 h is multi-day', () {
      final oneDay =
          historyCustomRange(DateTime(2026, 8, 15), DateTime(2026, 8, 15));
      expect(historyChartFraming(l10n, oneDay).multiDay, isFalse);

      final twoDays =
          historyCustomRange(DateTime(2026, 8, 15), DateTime(2026, 8, 16));
      expect(historyChartFraming(l10n, twoDays).multiDay, isTrue);
    });

    test('T7b: a custom range never claims the "Today" heading', () {
      // Even when the dates happen to be today. The user picked dates; a title
      // saying otherwise is a second statement about what is on screen.
      final now = DateTime.now();
      final today = historyCustomRange(now, now);
      expect(historyChartFraming(l10n, today).heading, l10n.historyChartTitle);
      expect(
          historyChartFraming(
                  l10n, const HistoryRangeSel.preset(HistoryRange.today))
              .heading,
          l10n.historyChartTodayTitle);
    });

    test('T7c: the presets are unchanged', () {
      expect(
          historyChartFraming(
                  l10n, const HistoryRangeSel.preset(HistoryRange.today))
              .multiDay,
          isFalse);
      for (final r in [HistoryRange.week, HistoryRange.all]) {
        expect(historyChartFraming(l10n, HistoryRangeSel.preset(r)).multiDay,
            isTrue);
      }
    });
  });

  // ==========================================================================
  group('T8 — one selection, one slice, whichever surface asks', () {
    test('T8a: the same custom selection yields the same rows and buckets',
        () async {
      for (var i = 0; i < 6; i++) {
        await put(DateTime(2026, 8, 3, 9, i * 7));
      }
      await put(DateTime(2026, 8, 20)); // outside

      final sel =
          historyCustomRange(DateTime(2026, 8, 1), DateTime(2026, 8, 15));
      final (:since, :until) = historyBoundsFor(sel);

      Future<HistorySlice> load() => loadHistorySlice(tele,
          since: since, until: until, deviceId: 'AA');

      final a = await load();
      final b = await load();
      expect(a.stats.count, 6);
      expect(b.stats.count, a.stats.count);
      expect(b.bucketMs, a.bucketMs);
      expect(b.rows.length, a.rows.length);
      expect(b.buckets.length, a.buckets.length);
    });

    test('T8b: neither surface derives the bounds itself', () {
      // A SOURCE-level check, in the same spirit as T79-12: the failure it
      // guards is one surface quietly growing its own idea of what a range
      // covers, which produces no error until the two disagree.
      for (final path in const [
        'lib/ui/history/history_screen.dart',
        'lib/ui/history/device_history_tab.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src.contains('historyBoundsFor('), isTrue,
            reason: '$path must ask the kernel for both ends');
        expect(src.contains('HistoryRange.today)'), isFalse,
            reason: '$path builds a preset cut-off by hand');
      }
    });
  });
}
