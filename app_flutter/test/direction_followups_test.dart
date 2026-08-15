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
import 'package:open_smart_batt/ui/dashboard/power_flow.dart';
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

  group('H5 the other classes', () {
    test('a capacitor still shows no current at all', () {
      // Its `0x2E` is pinned at 0.0 A on a unit that cannot measure current,
      // and the CSV blanks the column — the row must not disagree with the file
      // exported from it.
      expect(historyCurrentBit(zh, ProductClass.supercapacitor, 0.0), isNull);
      expect(historyCurrentBit(zh, ProductClass.supercapacitor, -35.0), isNull);
    });

    test('H7 a row with no attribution keeps its signed number', () {
      // Written before history rows carried a device id. With no family there
      // is no convention to read the sign by, and inventing one is how FB-43
      // happened. The ONLY place a bare signed current still reaches a screen.
      expect(historyCurrentBit(zh, ProductClass.unknown, -35.0), '電流 -35.0A');
      expect(historyCurrentBit(zh, ProductClass.unknown, 0.43), '電流 0.4A');
    });
  });

  // ===========================================================================
  // P — the power bank's history row (ruled 2026-08-11, after the battery)
  // ===========================================================================
  group('P1 a power bank names its direction with its OWN convention', () {
    test('positive is DIScharging — the opposite of a battery', () {
      // 🔴 The assertion that catches anyone routing this family through
      // `packFlowOf`: the same sign gets the opposite word on the two families.
      expect(historyCurrentBit(zh, ProductClass.powerBank, 2.72),
          '電流 2.7A 放電中');
      expect(historyCurrentBit(zh, ProductClass.smartBattery, 2.72),
          '電流 2.7A 充電中');
    });

    test('negative is charging — the FB-47 reading, now explained', () {
      // The 2026-08-04 capture: `−0.43 A` with no direction shown, which the
      // owner — who had ruled on the sign convention himself — read as a fault.
      expect(historyCurrentBit(zh, ProductClass.powerBank, -0.43),
          '電流 0.4A 充電中');
      expect(historyCurrentBit(en, ProductClass.powerBank, -0.43),
          'Current 0.4A CHARGING');
    });

    test('P2 no minus sign survives on a power bank row either', () {
      for (final a in [-0.43, -2.712, -0.06, -0.667]) {
        expect(historyCurrentBit(zh, ProductClass.powerBank, a),
            isNot(contains('-')));
      }
    });

    test('P3 its own 0.05 A band, not the pack 1.5 A one', () {
      // A power bank at 0.5 A is discharging; a battery at 0.5 A is a rounding
      // artefact. One shared band would be wrong on both families at once.
      expect(historyCurrentBit(zh, ProductClass.powerBank, 0.5),
          '電流 0.5A 放電中');
      expect(historyCurrentBit(zh, ProductClass.smartBattery, 0.5),
          '電流 0.5A 靜置');
      // In-band: a magnitude, no direction claimed.
      expect(historyCurrentBit(zh, ProductClass.powerBank, 0.02),
          '電流 0.0A 待機');
    });

    test('P4 it uses the EXISTING power-bank words, coining nothing', () {
      // `powerBankDirection*` has been on the SOC dial since design 0037. The
      // pack's idle word is 靜置 and the bank's is 待機, and they must stay
      // separately changeable — hence separate keys, asserted here as different
      // so a future "tidy-up" that merges them fails.
      expect(historyCurrentBit(zh, ProductClass.powerBank, 0.0),
          contains(zh.powerBankDirectionIdle));
      expect(zh.powerBankDirectionIdle, isNot(zh.packDirectionIdle));
    });

    test('P5 the same PRINTED number never carries two different words', () {
      // The H3 property, re-run for this family: its 0.05 A line sits strictly
      // between the 0.0 and 0.1 a one-decimal row can print, so no displayed
      // value can straddle it. Swept rather than reasoned about, because that
      // is the claim.
      final wordFor = <String, Set<String>>{};
      for (var milli = -4000; milli <= 4000; milli += 1) {
        final a = milli / 1000.0;
        final bit = historyCurrentBit(zh, ProductClass.powerBank, a)!;
        final parts = bit.split(' ');
        wordFor
            .putIfAbsent('${a.isNegative ? '-' : '+'}${parts[1]}', () => {})
            .add(parts[2]);
      }
      for (final e in wordFor.entries) {
        expect(e.value, hasLength(1), reason: '${e.key} → ${e.value}');
      }
    });

    test('P6 the rail-off residual reads as a small charge — known and why',
        () {
      // ⚠️ NOT the live screen's answer, and this test exists so nobody
      // "fixes" it by widening the band. `powerFlowOf`'s rail-off veto needs
      // the same burst's `0x4B` b7; history has no flag column, and a
      // per-minute average of a bit-field would not be one. So the RSPB-01
      // unit's 58–69 mA offset reads CHARGING here while the dashboard reads
      // STANDBY. Documented in `historyCurrentBit`; the remedy, if one is ever
      // ruled, is to persist b7 — not a second dead-band.
      expect(historyCurrentBit(zh, ProductClass.powerBank, -0.06),
          '電流 0.1A 充電中');
      // The live derivation, for contrast — same number, with the flag.
      expect(powerFlowOf(-0.06, portFlagsRaw: 0x00), PowerFlow.idle);
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

    /// A sample time that is guaranteed to be inside the screen's DEFAULT range.
    ///
    /// 🔴 The screen opens on `HistoryRange.today`, whose floor is literal
    /// midnight (`_sinceFor` → `DateTime(y, m, d)`). These tests used to insert
    /// at `now - 3 min`, which is yesterday for the first three minutes of every
    /// day — the row was then filtered out, the finders found nothing, and both
    /// tests failed for reasons that had nothing to do with what they assert.
    /// Caught 2026-08-12 at 00:02 while verifying an unrelated branch.
    ///
    /// A few minutes back is only there to look like real data, so it yields to
    /// the range floor rather than the other way round.
    DateTime recentlyToday(DateTime now) {
      final midnight = DateTime(now.year, now.month, now.day);
      final wanted = now.subtract(const Duration(minutes: 3));
      return wanted.isBefore(midnight) ? now : wanted;
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
            timestamp: recentlyToday(now),
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

    testWidgets('P7 a power bank row on screen reads 充電中, never −0.4A',
        (tester) async {
      // The end-to-end proof for the family FB-47 was filed on: the stored
      // value is NEGATIVE and the word is CHARGING, which is only correct
      // because the row went through `powerFlowOf` and not `packFlowOf`.
      await boot(tester);
      final now = DateTime.now();
      await tester.runAsync(() async {
        await services.devices.save(SavedDevice(
          id: 'DEV-PB',
          alias: 'Power bank',
          lastSeen: now,
          productClass: ProductClass.powerBank,
        ));
        await services.historyRepo.insertSample(
          TelemetrySample(
            timestamp: recentlyToday(now),
            pvlt: 3.95,
            temperatureC: 30,
            current: -0.43,
          ),
          deviceId: 'DEV-PB',
        );
      });

      await pumpHistory(tester);

      expect(find.textContaining('0.4A 充電中'), findsOneWidget);
      expect(find.textContaining('-0.4A'), findsNothing);
      expect(find.textContaining('放電中'), findsNothing);
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
          // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
          mode: AppMode.personal,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.forCsv(
              HistoryGranularity.minute, const [60]),
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
      // Directly after the `resolution:` pair, which is itself directly after
      // `window:` — that stretch of the middle is where a reader looks for
      // facts about the file's own columns and rows. (The pair arrived with
      // design 0061 T4a on 2026-08-14 and pushed this down by two; the
      // adjacency is asserted rather than loosened, so the next insertion has
      // to be written down here too.)
      final windowAt = lines.indexWhere((l) => l.startsWith('window: '));
      expect(lines[windowAt + 1], startsWith('resolution: requested='));
      expect(lines[windowAt + 2], startsWith('resolution: contains='));
      expect(lines.indexOf(lines.firstWhere((l) => l.startsWith('ampere'))),
          windowAt + 3);
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
