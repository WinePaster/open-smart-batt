// FB-68 — one export, one identity.
//
// THE DEFECT. Two files a reporter sends from a single sitting named the SAME
// unit with two different identity strings, in `# scope:` AND in the filename:
// the history CSV said the 15-digit product serial, the diagnostic log said the
// sanitized alias. Twice, on the same unit, ten days and two releases apart —
// batch 2026.08.03-002 on 0.6.14 (the two files 14 s apart) and batch
// 2026.08.13-001 on 0.7.15 (17 s apart). An export is not atomic: each file
// resolved the identity for itself, and the field log shows what happened in
// between —
//
//     18:22:07  history CSV exported   (link up, serial known)
//     18:22:20  link: disconnected
//     18:22:23  link: connected        (never reached `ready`)
//     18:22:24  diagnostic log exported (serial gone, fell back to the alias)
//
// `TelemetryController._onLinkState` wipes the live sample on `disconnected`
// (`_sample = TelemetrySample.empty()`), and the old identity chain started at
// `tele.fullSerial` with no rung below it but the alias. The 08.13 pair carries
// the independent corroboration in a second field: the log's preamble said
// `layout: face=- modules=-` against the CSV's `face=fixed modules=…`, from the
// same teardown, because `currentExportLayoutValue` is gated on
// `conn.isOnline`.
//
// THE TWO THINGS PINNED HERE, and they are different guarantees:
//
//   1. **The identity chain outlives the link** (group A). `saved_devices` and
//      `device_facts` both hold the serial the wire already gave us, so a
//      teardown no longer demotes the file to the alias rung. This is what
//      makes two SEPARATE exports — two taps, seconds apart, which is what the
//      field pairs actually are — agree.
//
//   2. **One export resolves the unit once** (groups B and C). Identity, class
//      slug and the `layout:` line are resolved together at the moment the user
//      asks for the export and then carried, immutable, in the `ExportTarget`.
//      Fallbacks alone cannot promise this: two lookups at two instants are
//      still two lookups. The snapshot is what makes it structural.
//
// ⚠️ What is deliberately NOT pinned: that two exports taken at two different
// instants report the same `layout:`. They should not. That line states what
// was on screen when the file was made, and at 18:22:24 the link had only
// reached `connected` — no unit's layout was in force, and `face=-` is the
// honest answer (design 0034 Q3). What FB-68 owed was that a single export
// cannot say `face=fixed` and the alias, or `face=-` and the serial, in one
// breath — i.e. that the two fields come from one instant.
//
// CLEAN-ROOM: every value below is synthetic. Field batches are cited by number
// and by elapsed seconds only.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:open_smart_batt/ui/util/export_naming.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal BLE stand-in: no radio. The test says which handle the controller
/// HOLDS ([held], which is what opens a recording session) and drives link
/// transitions and telemetry frames by hand.
class _StubBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();

  String? held;

  @override
  String? get connectedDeviceId => held;

  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;

  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<bool> ensurePermissions() async => true;

  @override
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {}

  @override
  Future<void> disconnect() async {}

  void emitLink(BleLinkState s) => _linkOut.add(s);
  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _telemetryOut.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // Synthetic throughout. `dealer` + `tail` is the shape `TelemetrySample`
  // assembles into `fullSerial` (0x27 prefix + zero-padded 0x26 tail).
  const devId = 'DEV-A';
  const other = 'DEV-B';
  const dealer = '01689999';
  const tail = '0001234';
  const serial = '$dealer$tail';
  const alias = 'Pack A';

  // =========================================================================
  // A. The identity ladder: saved → device_facts → live
  // =========================================================================
  group('exportDeviceIdent: the serial outlives the link', () {
    late AppServices services;
    late DeviceController devices;
    late DeviceFactsController facts;

    setUp(() async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      services = await AppServices.create(appDatabase: db, ble: _StubBle());
      devices = services.devices;
      facts = services.facts;
    });

    tearDown(() async => services.dispose());

    test('🔑 a saved serial still names the unit after a teardown', () async {
      // THE FIELD CASE. The unit is saved and named, the wire gave us its
      // serial while the link was up, and then the link dropped between the two
      // exports. Before FB-68 this returned the sanitized alias — which is
      // exactly what the 2026.08.13-001 diagnostic log's filename and `# scope:`
      // carried, beside a CSV from 17 s earlier that carried the serial.
      await devices.saveNew(devId, alias);
      await devices.setIdentity(devId, serial: serial);

      expect(
        exportDeviceIdent(devices, devId, facts: facts, liveSerial: null),
        serial,
        reason: 'the record already held the serial; nothing had to be live',
      );
    });

    test('the device_facts cache covers a unit that was never named', () async {
      // design 0057's middle rung. Connect / look / export / never name it is an
      // ordinary way to use this app, and on that path there is no saved record
      // to fall back to at all — before the cache the file could only say the
      // short hash once the link was gone.
      await facts.record(devId, serial: serial);

      expect(devices.deviceFor(devId), isNull, reason: 'never saved');
      expect(
        exportDeviceIdent(devices, devId, facts: facts, liveSerial: null),
        serial,
      );
    });

    test('online and ready still yields the full serial (no regression)',
        () async {
      // The ruling's constraint 4: nothing about the ONLINE answer changes. All
      // three rungs carry the same wire-derived value here, so this asserts the
      // outcome rather than which rung produced it.
      await devices.saveNew(devId, alias);
      await devices.setIdentity(devId, serial: serial);
      await facts.record(devId, serial: serial);

      expect(
        exportDeviceIdent(devices, devId, facts: facts, liveSerial: serial),
        serial,
      );
      expect(serial, hasLength(15), reason: 'the 15-digit product serial');
    });

    test('a unit with no persisted serial still falls to the live one', () {
      // The pre-FB-68 rung is kept, not replaced: a unit that is neither saved
      // nor yet cached has exactly one source, and dropping it would have
      // regressed the very first export of a brand-new unit.
      expect(
        exportDeviceIdent(devices, devId, facts: facts, liveSerial: serial),
        serial,
      );
    });

    test('with no serial anywhere, the alias is still the honest answer',
        () async {
      // The fallbacks are not magic. A unit whose serial was never observed —
      // a power bank carries none at all — has nothing better than the name its
      // owner gave it, and that is unchanged behaviour.
      await devices.saveNew(devId, alias);
      expect(
        exportDeviceIdent(devices, devId, facts: facts, liveSerial: null),
        sanitizeIdent(alias),
      );
    });

    test('and with no name either, the short hash — never the raw id', () {
      // design 0027 §3.1: the raw device id is a MAC on Android and must never
      // reach a filename.
      final ident = exportDeviceIdent(devices, devId, facts: facts);
      expect(ident, shortDeviceHash(devId));
      expect(ident, isNot(contains(devId)));
    });

    test('🔴 stored outranks live, so `# scope:` and `# devices:` agree',
        () async {
      // Not a statement about trusting one source more — both come off the
      // wire. It is about having ONE answer: `exportDeviceIdentities` has used
      // saved → cached → live since design 0057, and FB-68 was born of this
      // chain starting somewhere else. If the two orders ever diverge again, a
      // file's `# scope:` line can name a unit its own `# devices:` block does
      // not.
      const stale = '016899990009999';
      await devices.saveNew(devId, alias);
      await devices.setIdentity(devId, serial: stale);
      await facts.record(devId, serial: serial);

      final ident =
          exportDeviceIdent(devices, devId, facts: facts, liveSerial: serial);
      final header = await exportDeviceIdentities(
        devices,
        services.telemetry,
        const ExportTarget(scope: ExportScope.currentDevice, deviceId: devId),
        facts: facts,
      );
      expect(ident, stale);
      expect(header.single.serial, stale, reason: 'same rung, same answer');
    });

    test('another unit lends nothing', () async {
      // The FB-41 guard, in the identity column: a serial belongs to one unit.
      await devices.saveNew(devId, alias);
      await devices.setIdentity(devId, serial: serial);
      expect(
        exportDeviceIdent(devices, other, facts: facts, liveSerial: null),
        shortDeviceHash(other),
      );
    });
  });

  // =========================================================================
  // B. The snapshot object
  // =========================================================================
  group('ExportTarget carries the snapshot', () {
    const snapshot = ExportTarget(
      scope: ExportScope.currentDevice,
      deviceId: devId,
      classSlug: 'battery',
      ident: serial,
      layout: 'face=fixed modules=gauge,readouts,cells,chart',
    );

    test('🔑 both files of one export are stamped from one resolution', () {
      // The structural claim, stated as the two writers actually make it: the
      // filename comes from `exportFileName(ident:)`, the preamble from
      // `exportScopeLabel(target)` and `exportHeaderLines(layout:)`, and every
      // one of them reads the SAME immutable object. There is no second lookup
      // left for a teardown to land in between — which is what "not atomic" cost
      // us in both field pairs.
      final csvName = exportFileName(
        base: 'opensmartbatt-history',
        classSlug: snapshot.classSlug,
        ident: snapshot.ident,
        stamp: '20260813-182207',
        extension: 'csv',
      );
      final logName = exportFileName(
        base: 'opensmartbatt',
        classSlug: snapshot.classSlug,
        ident: snapshot.ident,
        stamp: '20260813-182224',
        extension: 'log',
      );
      expect(csvName, contains('battery-$serial'));
      expect(logName, contains('battery-$serial'));

      List<String> headerFor(String title) => exportHeaderLines(
            title: title,
            exportedAt: DateTime.utc(2026, 8, 13, 18, 22),
            appBuild: '0.7.15+26081300',
            platform: 'ios 18.5',
            scope: exportScopeLabel(snapshot),
            layout: snapshot.layout,
            home: 'tiles=auto',
            // design 0063: a `required` param, so every direct caller has to name it. Personal is today's app.
            mode: AppMode.personal,
            themeMode: AppThemeMode.light,
            accent: AccentTheme.amber,
            speedDetection: false,
            gMeter: false,
            resolution: ExportResolution.none,
                      // design 0070 stage two: the parameter lost its default, so this
            // header has to say what it names. Nothing here declares a unit.
            devices: const [],
          );
      final csv = headerFor('OpenSmartBatt history export');
      final log = headerFor('OpenSmartBatt diagnostic log');
      String lineOf(List<String> h, String prefix) =>
          h.firstWhere((l) => l.startsWith(prefix));
      expect(lineOf(csv, 'scope: '), lineOf(log, 'scope: '));
      expect(lineOf(csv, 'layout: '), lineOf(log, 'layout: '));
      expect(lineOf(csv, 'scope: '), 'scope: device=battery/$serial');
    });

    test('the session variant copies the identity instead of re-resolving it',
        () {
      // The diagnostic log's sheet offers two device-scoped rows ("this unit"
      // and "this connection"). They are two ENTRIES, not two resolutions — a
      // second `currentDeviceTarget` call for the session row would reopen the
      // same window inside a single sheet.
      final session = snapshot.asSession(3);
      expect(session.scope, ExportScope.currentSession);
      expect(session.sessionId, 3);
      expect(session.ident, snapshot.ident);
      expect(session.classSlug, snapshot.classSlug);
      expect(session.layout, snapshot.layout);
      expect(exportScopeLabel(session), 'device=battery/$serial session=3');
    });

    test('an all-devices target defaults to "no layout was in force"', () {
      // `exportHeaderLines` requires the line, so the default has to be a real
      // value rather than an omission — and `face=-` is the one design 0034 Q3
      // already defined for "nothing was connected".
      expect(ExportTarget.all.layout, kExportLayoutNone);
      expect(kExportLayoutNone, exportLayoutValue(cls: null, layout: null));
    });
  });

  // =========================================================================
  // B2. "Resolved once" as a property of the SOURCE, not of one code path
  // =========================================================================
  //
  // 🔴 WHY A SOURCE SCAN. Everything above tests the value an export handler is
  // HANDED. None of it can see a handler that takes the snapshot and then goes
  // and reads the live controllers again anyway — which is precisely the bug:
  // the old call sites were each handed a perfectly good `target` and then
  // added `final layout = currentExportLayoutValue(context)` on the next line,
  // after the scope sheet's await. A behavioural test cannot fail on that
  // unless it drives all three handlers through a real share sheet; a scan of
  // the four lines involved can, and the project already takes this route where
  // a hand-written list would go stale (`give_up_visibility_test.dart`).
  group('one resolution, structurally', () {
    /// Source with `//` comment lines stripped — this file's own prose names
    /// the very identifiers being searched for.
    String sourceOf(String path) {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: '$path is the input to this test; if it moved, point this at '
              'the new path rather than deleting the test');
      return file
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }

    /// The files that BUILD an export header — the ones that must read the
    /// layout out of the target they were handed.
    ///
    /// 📦 `history_screen.dart` used to be here. Design 0065 gave the device
    /// detail page a second export button, so the CSV writer moved into
    /// `history_csv_export.dart` and both surfaces call it; the rule did not
    /// change, only where it is enforced. The screen that ASKS for an export is
    /// still checked below, for the half of the rule that still applies to it.
    const writers = <String>[
      'lib/ui/settings/settings_screen.dart',
      'lib/ui/util/history_csv_export.dart',
    ];

    /// Screens that request an export but do not write one. They may not
    /// resolve any of it themselves either — that is the whole snapshot rule —
    /// they simply have no `layout:` line of their own to read.
    const requesters = <String>[
      'lib/ui/history/history_screen.dart',
      'lib/ui/history/device_history_section.dart',
    ];

    test('🔴 no export handler reads the live layout for itself', () {
      for (final path in [...writers, ...requesters]) {
        final src = sourceOf(path);
        expect(src.contains('currentExportLayoutValue('), isFalse,
            reason: '$path must take the layout from the ExportTarget it was '
                'handed. Reading it here happens AFTER the scope sheet, and a '
                'disconnect in that window is what put `face=- modules=-` in a '
                'file whose `# scope:` named a live unit (batch '
                '2026.08.13-001).');
        expect(src.contains('currentDeviceTarget('), isFalse,
            reason: '$path gets its target from chooseExportScope, which is '
                'the one place allowed to resolve one');
      }
      for (final path in writers) {
        expect(sourceOf(path).contains('final layout = target.layout;'), isTrue,
            reason: '$path should be reading the snapshot');
      }
    });

    test('and the snapshot point resolves each field exactly once', () {
      final src = sourceOf('lib/ui/util/export_scope.dart');
      expect(RegExp(r'currentExportLayoutValue\(').allMatches(src), hasLength(1),
          reason: 'two readings of a moving value is the whole defect');
      expect(RegExp(r'currentDeviceTarget\(context').allMatches(src),
          hasLength(1),
          reason: 'the session entry is derived with asSession(); calling this '
              'again for it would reopen the window inside a single sheet');
    });
  });

  // =========================================================================
  // C. The field timeline, end to end
  // =========================================================================
  group('the 2026.08.13-001 timeline', () {
    late AppServices services;
    late _StubBle ble;

    Future<void> boot(WidgetTester tester) async {
      await tester.runAsync(() async {
        ble = _StubBle();
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(appDatabase: db, ble: ble);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(services.dispose);
      });
    }

    /// The screen an export handler runs on. Returns a context under the same
    /// provider set `main.dart` installs — `DeviceFactsController` included,
    /// since the identity ladder's middle rung is looked up through it.
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            ChangeNotifierProvider<SettingsController>.value(
                value: services.settings),
            ChangeNotifierProvider<DeviceController>.value(
                value: services.devices),
            ChangeNotifierProvider<DeviceFactsController>.value(
                value: services.facts),
            ChangeNotifierProvider<ConnectionController>.value(
                value: services.connection),
            ChangeNotifierProvider<TelemetryController>.value(
                value: services.telemetry),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: Builder(builder: (c) {
              captured = c;
              return const Scaffold(body: SizedBox.expand());
            }),
          ),
        ),
      );
      await tester.pump();
      return captured;
    }

    /// Bring the link up on [devId] and let one connect-burst frame through, so
    /// the serial reaches the live sample AND both persistent rungs.
    Future<void> comeOnline(WidgetTester tester) async {
      await tester.runAsync(() async {
        ble.held = devId;
        ble.emitLink(BleLinkState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ble.emitTelemetry(TelemetrySample(
          timestamp: DateTime.now(),
          pvlt: 13.1,
          deviceType: 0x02, // car smart battery
          dealerCode: dealer,
          serial: tail,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pump();
    }

    /// The 13 s hole in the field log: `disconnected`, then a `connected` that
    /// never reaches `ready`.
    Future<void> dropAndHalfReturn(WidgetTester tester) async {
      await tester.runAsync(() async {
        ble.emitLink(BleLinkState.disconnected);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ble.emitLink(BleLinkState.connected);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }

    /// Run one export handler's opening move — the scope sheet — and pick "this
    /// device". [duringSheet] runs while the sheet is up, i.e. after the
    /// snapshot has been taken and before the caller resumes.
    Future<ExportTarget?> chooseThisDevice(
      WidgetTester tester,
      BuildContext ctx, {
      bool offerSession = false,
      Future<void> Function()? duringSheet,
    }) async {
      ExportTarget? picked;
      final pending = chooseExportScope(ctx, offerSession: offerSession)
          .then((v) => picked = v);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (duringSheet != null) await duringSheet();
      // Found by icon, not by label: the sheet's strings are localized and this
      // test is not about them.
      await tester.tap(find.byIcon(Icons.smartphone_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await pending;
      return picked;
    }

    testWidgets('🔑 two exports across the teardown name the unit identically',
        (tester) async {
      // The whole defect, reproduced: the reporter exports the history CSV,
      // the link drops and half-returns, and 17 s later they export the
      // diagnostic log. Before FB-68 the second file's ident was the alias.
      await boot(tester);
      await tester.runAsync(() => services.devices.saveNew(devId, alias));
      await comeOnline(tester);
      final ctx = await pumpHost(tester);

      // 18:22:07 — the history CSV.
      final csvTarget = await chooseThisDevice(tester, ctx);
      expect(csvTarget, isNotNull);
      expect(csvTarget!.ident, serial,
          reason: 'the link is up; this is the answer that was already right');

      // 18:22:20 / 18:22:23 — disconnected, then connected-but-not-ready.
      await dropAndHalfReturn(tester);
      expect(services.connection.isOnline, isFalse);
      expect(services.telemetry.fullSerial, isNull,
          reason: 'the live sample really is wiped — the original cause');

      // 18:22:24 — the diagnostic log.
      final logTarget = await chooseThisDevice(tester, ctx, offerSession: true);
      expect(logTarget, isNotNull);
      expect(logTarget!.ident, csvTarget.ident,
          reason: 'ONE unit, ONE identity string, across both files');
      expect(logTarget.ident, serial,
          reason: 'and it is the serial, not the alias it collapsed to');
      expect(logTarget.classSlug, csvTarget.classSlug,
          reason: 'the class slug is in the filename too, and it flipped the '
              'same way for the same reason');

      // The filenames the two files would carry — the half of the defect a
      // reporter can actually see.
      String nameOf(ExportTarget t, String base, String ext) => exportFileName(
          base: base,
          classSlug: t.classSlug,
          ident: t.ident,
          stamp: '20260813-182207',
          extension: ext);
      expect(nameOf(csvTarget, 'opensmartbatt-history', 'csv'),
          'opensmartbatt-history-battery-$serial-20260813-182207.csv');
      expect(nameOf(logTarget, 'opensmartbatt', 'log'),
          'opensmartbatt-battery-$serial-20260813-182207.log');
    });

    testWidgets('a disconnect DURING the export cannot split the two fields',
        (tester) async {
      // The other half of the ruling, and the one fallbacks cannot deliver.
      // The layout used to be read at the call site AFTER the scope sheet
      // closed, while the identity was read before it — so a teardown inside
      // that window produced one file stating the serial and `face=-`, which is
      // literally the 2026.08.13-001 log's header. Now both come from the same
      // instant: they either both describe the live unit or both fall back.
      await boot(tester);
      await tester.runAsync(() => services.devices.saveNew(devId, alias));
      await comeOnline(tester);
      final ctx = await pumpHost(tester);
      expect(services.connection.isOnline, isTrue);

      final target = await chooseThisDevice(
        tester,
        ctx,
        duringSheet: () => dropAndHalfReturn(tester),
      );

      expect(services.connection.isOnline, isFalse,
          reason: 'the link really did go while the sheet was open');
      expect(target!.ident, serial);
      expect(target.layout, isNot(kExportLayoutNone),
          reason: 'the export began with a unit on screen, and the file says '
              'so — this is the field header that read `face=- modules=-`');
      expect(target.layout, startsWith('face=fixed modules='));
      // Re-reading it now — the pre-FB-68 call site — is what produced the
      // mismatch. Asserted so the difference between the two readings is
      // written down rather than implied.
      expect(currentExportLayoutValue(ctx), kExportLayoutNone);
    });

    testWidgets('an offline export is honest, not sticky', (tester) async {
      // The guard on the fix: persistent fallbacks must not resurrect a layout
      // that was not in force. `face=-` is the correct answer when the export
      // itself began offline (design 0034 Q3), and only the IDENTITY survives.
      await boot(tester);
      await tester.runAsync(() => services.devices.saveNew(devId, alias));
      await comeOnline(tester);
      await dropAndHalfReturn(tester);
      final ctx = await pumpHost(tester);

      final target = await chooseThisDevice(tester, ctx);
      expect(target!.ident, serial);
      expect(target.layout, kExportLayoutNone);
    });
  });
}
