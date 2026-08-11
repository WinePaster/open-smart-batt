// Direction follow-ups (design 0056 §8, ruled 2026-08-11, later the same day).
//
// The card was fixed first: the live pack current reads `35.0 A` over a
// 「放電中」badge instead of a bare `−35.0 A` (`pack_current_direction_test.dart`).
// That left the SAME number stated two other ways in the same app —
//
//   * the history list row, still `電流 −35.0A`;
//   * the exported CSV's `ampere` column, signed, with nothing in the file
//     saying what the sign meant.
//
// Both are read by the same people who misread the card: the second one is read
// by them WITHOUT the app in front of them, months later, which is worse.
//
// H1–H7 — the history row.
// X1–X5 — the CSV preamble's sign lines.
//
// CLEAN-ROOM: every expectation derives from this project's own protocol notes
// and its own source.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StubBle extends BleService {
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  final _linkOut = StreamController<BleLinkState>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetryOut.close();
    await _linkOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppLocalizations zh;
  late AppLocalizations en;
  setUpAll(() async {
    zh = await AppLocalizations.delegate.load(const Locale('zh'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  // ===========================================================================
  // H — the history list row
  // ===========================================================================
  group('H1 a battery row names the direction instead of printing a sign', () {
    test('discharge', () {
      expect(historyCurrentBit(zh, ProductClass.smartBattery, -35.0),
          '電流 35.0A 放電中');
      expect(historyCurrentBit(en, ProductClass.smartBattery, -35.0),
          'Current 35.0A DISCHARGING');
    });

    test('charge', () {
      expect(historyCurrentBit(zh, ProductClass.smartBattery, 14.2),
          '電流 14.2A 充電中');
      expect(historyCurrentBit(en, ProductClass.smartBattery, 14.2),
          'Current 14.2A CHARGING');
    });

    test('no minus sign survives on a battery row', () {
      for (final a in [-35.0, -1.98, -0.4, -211.0]) {
        expect(historyCurrentBit(zh, ProductClass.smartBattery, a),
            isNot(contains('-')),
            reason: 'a bare signed number is the FB-47 defect');
      }
    });
  });

  group('H2 the dead-band on a MINUTE AVERAGE', () {
    test('a float average past one count still names a direction', () {
      // −1.98 is a real shape: a minute that sat mostly on the −2 count. Past
      // 1.5, so it is a direction — and it prints rounded, as it always did.
      expect(historyCurrentBit(zh, ProductClass.smartBattery, -1.98),
          '電流 2.0A 放電中');
    });

    test('an average inside one count claims nothing', () {
      // Averaging does not recover what quantisation threw away: `0x2E` is 1 A
      // per count, so a minute averaging −0.4 is a minute of 0s and −1s and its
      // sign is not evidence of anything.
      expect(historyCurrentBit(zh, ProductClass.smartBattery, -0.4),
          '電流 0.4A 靜置');
      expect(historyCurrentBit(zh, ProductClass.smartBattery, 0.0),
          '電流 0.0A 靜置');
    });

    test('H3 the same PRINTED number never carries two different words', () {
      // 🔴 The reason the direction is derived from the rounded value. With the
      // raw one, −1.46 and −1.52 fall on opposite sides of the 1.5 A line while
      // BOTH print `1.5A` — two rows, one visible number, two words, and a bug
      // report. Swept rather than spot-checked, because the defect is a
      // boundary and a spot check would sit next to it without touching it.
      //
      // Keyed on the sign of the RAW value as well as the printed magnitude:
      // `4.0A 充電中` and `4.0A 放電中` are two different rows and must stay
      // distinguishable — that is what the word is FOR. What must never happen
      // is two rows on the SAME side of zero printing one number and two words.
      final wordFor = <String, Set<String>>{};
      for (var milli = -4000; milli <= 4000; milli += 1) {
        final a = milli / 1000.0;
        final bit = historyCurrentBit(zh, ProductClass.smartBattery, a)!;
        final parts = bit.split(' ');
        final key = '${a.isNegative ? '-' : '+'}${parts[1]}';
        wordFor.putIfAbsent(key, () => <String>{}).add(parts[2]);
      }
      for (final e in wordFor.entries) {
        expect(e.value, hasLength(1),
            reason: '${e.key} is printed with ${e.value} — a reader cannot '
                'tell which row is which');
      }
    });

    test('H4 it is the SAME 1.5 A line the live card uses', () {
      // A second, tighter threshold here would make one battery read 靜置 on
      // the dashboard and 放電中 in history, which is the disagreement
      // `power_flow.dart` exists to prevent.
      expect(historyCurrentBit(zh, ProductClass.smartBattery, -1.4),
          contains('靜置'));
      expect(historyCurrentBit(zh, ProductClass.smartBattery, -1.6),
          contains('放電中'));
    });
  });

  group('H5 the other three classes are untouched', () {
    test('a capacitor still shows no current at all', () {
      // Its `0x2E` is pinned at 0.0 A on a unit that cannot measure current,
      // and the CSV blanks the column — the row must not disagree with the file
      // exported from it.
      expect(historyCurrentBit(zh, ProductClass.supercapacitor, 0.0), isNull);
      expect(historyCurrentBit(zh, ProductClass.supercapacitor, -35.0), isNull);
    });

    test('H6 a power bank keeps its signed number — its sign is the OTHER way',
        () {
      // `0x4A − 0x49` is positive while DIScharging, so `packFlowOf` would
      // label it backwards. Naming its direction here is a behaviour change
      // nobody has ruled on; printing the stored number is what it always did.
      expect(historyCurrentBit(zh, ProductClass.powerBank, -0.43),
          '電流 -0.4A');
      expect(historyCurrentBit(zh, ProductClass.powerBank, -0.43),
          isNot(contains('充電中')));
    });

    test('H7 a row with no attribution keeps its number too', () {
      // Written before history rows carried a device id. With no family there
      // is no convention to read the sign by, and inventing one is how FB-43
      // happened.
      expect(historyCurrentBit(zh, ProductClass.unknown, -35.0), '電流 -35.0A');
    });
  });

  group('H8 the screen really renders it', () {
    late AppServices services;

    Future<void> boot(WidgetTester tester) async {
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(appDatabase: db, ble: _StubBle());
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(services.dispose);
      });
    }

    Future<void> pumpHistory(WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
            ChangeNotifierProvider<GForceController>.value(
                value: services.gforce),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: const Scaffold(body: HistoryScreen()),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a battery row on screen reads 放電中, never −35.0A',
        (tester) async {
      await boot(tester);
      final now = DateTime.now();
      await tester.runAsync(() async {
        await services.devices.save(SavedDevice(
          id: 'DEV-BATT',
          alias: 'Car battery',
          lastSeen: now,
          productClass: ProductClass.smartBattery,
        ));
        await services.historyRepo.insertSample(
          TelemetrySample(
            timestamp: now.subtract(const Duration(minutes: 3)),
            pvlt: 12.4,
            temperatureC: 30,
            current: -35.0,
          ),
          deviceId: 'DEV-BATT',
        );
      });

      await pumpHistory(tester);

      expect(find.textContaining('35.0A 放電中'), findsOneWidget);
      expect(find.textContaining('-35.0A'), findsNothing);
    });
  });

  // ===========================================================================
  // X — the CSV preamble
  // ===========================================================================
  group('X the ampere sign lines', () {
    final at = DateTime(2026, 8, 11, 14, 30);

    List<String> header({bool ampereColumn = false, String? window}) =>
        exportHeaderLines(
          title: 'OpenSmartBatt history export',
          exportedAt: at,
          appBuild: '0.7.12+26081101',
          platform: 'android 15',
          scope: 'all devices',
          window: window,
          ampereColumn: ampereColumn,
          layout: 'face=fixed modules=gaugeVoltage,readouts',
          home: 'grid',
          speedDetection: false,
          gMeter: false,
        );

    test('X1 the CSV header states BOTH conventions and the blank case', () {
      final lines =
          header(ampereColumn: true, window: 'all').where((l) => l.startsWith('ampere sign: '));
      expect(lines, hasLength(2));
      final text = lines.join('\n');
      // The honesty requirement, one clause at a time. A file that stated only
      // the battery rule would be WORSE than one that stated none: a recipient
      // would confidently read a power bank's column backwards.
      expect(text, contains('battery negative=discharge positive=charge'));
      expect(text, contains('power bank positive=discharge (0x4A-0x49)'));
      expect(text, contains('capacitor rows are blank'));
    });

    test('X2 ASCII only — the ingest recipes read this with sed/grep', () {
      for (final l in header(ampereColumn: true).where((l) => l.startsWith('ampere'))) {
        expect(l.runes.every((r) => r < 128), isTrue, reason: l);
        // No `: ` inside the VALUE: the recipes split on the first one.
        expect(l.substring('ampere sign: '.length), isNot(contains(': ')));
      }
    });

    test('X3 the diagnostic log has no ampere column, so it says nothing', () {
      // Not an empty line and not a rule about a column that is not there —
      // the same reason `window:` is absent from the log.
      expect(header().any((l) => l.startsWith('ampere')), isFalse);
    });

    test('X4 they sit in the optional middle; layout: is still last', () {
      final lines = header(ampereColumn: true, window: 'all');
      expect(lines.last, startsWith('layout: '));
      // Directly after `window:`, which is where a reader looks for facts about
      // the file's own columns.
      expect(lines.indexOf(lines.firstWhere((l) => l.startsWith('ampere'))),
          lines.indexWhere((l) => l.startsWith('window: ')) + 1);
    });

    test('X5 both CSV call sites ask for them, and only those two', () {
      // The list is only honest if it is complete: `exportHeaderLines` has
      // three call sites in `lib/`, and exactly the two that write a CSV must
      // pass the flag. A new export path that forgets it fails here rather than
      // shipping a file nobody can read the sign of.
      final grep = Process.runSync(
          'grep', ['-rn', 'exportHeaderLines(', 'lib/'],
          runInShell: false);
      final callers = (grep.stdout as String)
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .map((l) => l.split(':'))
          // `path:line:source`. Doc comments mention the function by name —
          // `watchfaces.dart` explains that `layout:` goes last in it — and a
          // sentence about a function is not a call to it.
          .where((p) => !p.sublist(2).join(':').trimLeft().startsWith('//'))
          .map((p) => p.first)
          .where((f) => !f.endsWith('export_header.dart'))
          .toSet();
      expect(callers, {
        'lib/ui/history/history_screen.dart',
        'lib/ui/settings/settings_screen.dart',
      });
      for (final f in callers) {
        final src = File(f).readAsStringSync();
        expect(src, contains('ampereColumn: true'),
            reason: '$f writes a CSV and must declare the ampere convention');
        // Paired with `window:`, since both are the CSV-only half of the
        // preamble — if one is there the other has to be.
        expect(src.contains('window:'), isTrue, reason: f);
      }
    });
  });
}
