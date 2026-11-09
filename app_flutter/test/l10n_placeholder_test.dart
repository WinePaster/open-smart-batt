// 🅰️ 甲 — an l10n placeholder that never got substituted must not be able to
// reach a user again.
//
// ---------------------------------------------------------------------------
// The accident this is the receipt for
// ---------------------------------------------------------------------------
//
// FB-109. design 0092 replaced the hard-coded brand with an injected
// [AppConfig.appName]. Two of the replacements landed inside SINGLE-quoted Dart
// literals as `'\$appName …'` — an escaped dollar, so no interpolation ever
// happened — and every diagnostic log and "export all data" CSV shipped since
// v0.7.40 opened with the literal text `$appName`. Nothing went red because
// every existing assertion was about the l10n GETTER (`en.foo('X') == 'X …'`),
// never about THE LINE THAT ACTUALLY SHIPS.
//
// The same shape can be written one level up, in the `.arb` itself: a
// translation whose value contains the six characters `$appName` instead of the
// ICU placeholder `{appName}` compiles, generates, analyzes and runs — and
// prints `$appName` to the user. That form has never occurred here (group B1 is
// green on a clean tree, see the report for the scan), which is exactly when a
// guard is cheap to add.
//
// ---------------------------------------------------------------------------
// ⛔ WHAT THIS FILE DOES **NOT** COVER — read before trusting it
// ---------------------------------------------------------------------------
//
// 🔴 **It cannot catch the SECOND accident, and the second accident is real.**
// On 2026-09-07 it turned out that `3e15a73` changed four `.arb` strings and did
// NOT commit the three regenerated tracked files
// `lib/l10n/app_localizations{,_en,_zh}.dart`. The test suite therefore read the
// OLD strings, three tests asserting the OLD wording stayed green, and the
// "2,578 all green" of that batch was a false green. `flutter analyze` cannot
// see it (the generated files are valid Dart) and `flutter test` cannot see it
// (it never runs `gen-l10n`); only somebody running `flutter build` did.
//
// ⛔ **Group A below would have stayed green through that too**, and the reason
// is worth stating plainly: when the generated files are stale, the call site
// receives the *old* string — a perfectly well-formed sentence with no `$` and
// no `{}` in it. There is nothing malformed to detect. Staleness is a
// PROVENANCE defect, not a CONTENT defect, and no assertion made from inside
// the Dart process can see it, because the process only ever loads the
// generated files.
//
// That half is 🅱️ 乙: `.github/workflows/ci.yml` runs `flutter gen-l10n` and
// then `git diff --exit-code lib/l10n/`. The two guards are disjoint. Do not
// delete either on the grounds that the other exists.
//
// 🔴 Also not covered here: whether the substituted line READS well. Group A
// asserts that `BrandUnderTest · monitoring` is what the notification carries;
// it says nothing about whether that is good wording on a real phone.
//
// CLEAN-ROOM: every expectation derives from this project's own source.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/main.dart' show RootShell, kDisclaimerAck;
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/platform/platform.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// The matcher every assertion in this file is built on
// ---------------------------------------------------------------------------

/// A placeholder that survived into user-visible text.
///
/// Two shapes, because there are two ways to fail to substitute one:
///   * `$name` — the FB-109 shape. A dollar followed by an identifier is never
///     something this app deliberately shows anyone; the scan behind group B1
///     found ZERO legitimate `$` in either `.arb`, so there is no whitelist and
///     no reason to widen this pattern. (⛔ If a future string genuinely needs a
///     dollar — a currency prefix — add the KEY to an explicit exemption list
///     with the reason written next to it. Do not relax the regex.)
///   * `{name}` — an ICU placeholder that gen-l10n emitted verbatim because it
///     was never declared in `@key.placeholders`.
final RegExp _residue = RegExp(r'\$[A-Za-z_]|\{[A-Za-z_][A-Za-z0-9_]*\}');

void _expectNoResidue(String text, String where) {
  final m = _residue.firstMatch(text);
  expect(m, isNull,
      reason: '$where ships an unsubstituted placeholder '
          '(${m?.group(0)}) to the user: ${jsonEncode(text)}');
}

// ---------------------------------------------------------------------------
// Group A fixtures — the real call site, not a re-implementation of it
// ---------------------------------------------------------------------------

/// Deliberately NOT `OpenSmartBatt` and not a superstring of it: an assertion
/// against a name that contains the default cannot tell injection from a
/// surviving literal.
const AppConfig _injected = AppConfig(
  appName: 'BrandUnderTest',
  edition: AppEdition.pro,
  projectUrl: 'https://example.invalid/pro',
  updateRepo: null,
);

/// Records what the platform channel would have been asked to post.
/// Same shape as `foreground_service_test.dart`'s `_FakeMonitor`.
class _FakeMonitor implements MonitorService {
  final List<MonitorNotification> posted = [];
  final _stop = StreamController<void>.broadcast();

  @override
  Future<void> start(MonitorNotification n) async => posted.add(n);

  @override
  Future<void> update(MonitorNotification n) async => posted.add(n);

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onStopRequested => _stop.stream;

  @override
  bool get pacesKeepAliveInBackground => false;

  @override
  void dispose() => _stop.close();
}

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
  String? get connectedDeviceId => 'STUB-DEV';

  @override
  Future<void> ensureNotificationPermission() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> pokeKeepAlive() async {}

  @override
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) async {}

  void emitTelemetry(TelemetrySample s) => _telemetryOut.add(s);
  void emitLink(BleLinkState s) => _linkOut.add(s);

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

  // ==========================================================================
  // A — depth: drive the real call site and read the line the user gets
  // ==========================================================================
  group('A — the real call sites substitute, in both locales', () {
    setUp(() {
      // The GNSS gate asks permission_handler for a status on mount; there is
      // no plugin behind that channel in a unit test, so an unanswered call
      // raises MissingPluginException inside whichever test is running.
      // `denied` (index 0) — nothing here is about a location fix.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              (call) async => 0);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              null));
    });

    /// Advance BOTH clocks. The widget tree needs the fake one; the real
    /// `AppServices` awaits (sqflite ffi, the log writes behind a link event)
    /// only progress on the real one.
    Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      await tester.pump();
    }

    /// Mount [RootShell] — the widget that OWNS the call site under test
    /// (`main.dart` `didChangeDependencies`, which is the only place the three
    /// ongoing-notification titles are ever produced) — under [locale] and the
    /// injected branding, and return what the monitor was handed.
    ///
    /// 🔑 [RootShell] itself, not a hand-built stand-in. FB-109's lesson is
    /// that a test which re-states what the call site is supposed to do
    /// inherits the call site's mistake; the whole value here is that the
    /// production widget produces these strings.
    Future<_FakeMonitor> pumpShell(WidgetTester tester, Locale locale) async {
      late final AppServices services;
      final ble = _StubBle();
      final monitor = _FakeMonitor();
      await tester.runAsync(() async {
        final db = await AppDatabase.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        services = await AppServices.create(
          appDatabase: db,
          ble: ble,
          monitor: monitor,
          config: _injected,
        );
        // `inMemoryDatabasePath` is one database per PROCESS, not per test, so
        // whatever an earlier file switched on is still on. Rewrite the whole
        // row rather than one field.
        await services.settings.update(AppSettings.defaults);
        // The one-time community disclaimer resolves off a marker-file read,
        // i.e. only on a REAL event loop — so it pops open somewhere in the
        // middle of the settle loop and is still awaiting when the tear-down
        // unmounts the tree, which flutter_test reports as an unexpected
        // exception ("BuildContext is no longer valid"). Pre-acknowledging it
        // in a temp dir removes the dialog without touching the code under
        // test.
        AckMarker.debugDirectoryOverride =
            await Directory.systemTemp.createTemp('osb-l10n-ack');
        await kDisclaimerAck.markAcknowledged();
      });
      addTearDown(() {
        final dir = AckMarker.debugDirectoryOverride;
        AckMarker.debugDirectoryOverride = null;
        if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // ⚠️ No `addTearDown(services.dispose)`: it awaits a write drain and a
      // database close, and a tear-down await runs OUTSIDE `runAsync`, where
      // the fake clock never advances — the file would hang with no output
      // rather than fail. Same reason `app_mode_test.dart`'s helper omits it.
      await tester.pumpWidget(AppConfigScope(
        config: _injected,
        child: MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            Provider<BleService>.value(value: services.ble),
            Provider<HistoryRepo>.value(value: services.historyRepo),
            Provider<DeviceRepo>.value(value: services.deviceRepo),
            Provider<SettingsRepo>.value(value: services.settingsRepo),
            Provider<LogRepo>.value(value: services.logRepo),
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
            // 🔴 NOT optional padding. `didChangeDependencies` — the call site
            // under test — opens with `_syncDashboardVisible()`, which reads
            // BOTH gated controllers. A missing provider throws there and the
            // three `setNotificationStrings` lines below it never run, which
            // presents as the monitor posting its PRE-l10n seeds: a title that
            // is the injected name and nothing else. That is a green-looking
            // shape, so the length assertion on distinct titles is what keeps
            // this honest.
            ChangeNotifierProvider<GpsSpeedController>.value(
                value: services.speed),
            ChangeNotifierProvider<GForceController>.value(
                value: services.gforce),
            ChangeNotifierProvider<AlertController>.value(
                value: services.alerts),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            home: const RootShell(),
          ),
        ),
      ));
      await settle(tester, rounds: 6);
      // `ready` is what starts the monitor, i.e. what makes the controller post
      // the strings `didChangeDependencies` pushed into it.
      ble.emitLink(BleLinkState.ready);
      await settle(tester, rounds: 12);
      // A sample moves it off "connecting" onto the steady-state title, so both
      // of the two reachable states get asserted.
      ble.emitTelemetry(TelemetrySample.empty().copyWith(pvlt: 13.0));
      await settle(tester, rounds: 12);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
      });
      return monitor;
    }

    for (final (tag, locale) in const [('en', Locale('en')), ('zh', Locale('zh'))]) {
      testWidgets(
          'A1 [$tag] — the ongoing monitor notification carries the injected '
          'name, not a placeholder', (tester) async {
        final monitor = await pumpShell(tester, locale);

        expect(monitor.posted, isNotEmpty,
            reason: 'the monitor was never posted, so nothing was asserted');
        final titles = monitor.posted.map((n) => n.title).toSet();
        for (final t in titles) {
          // 🔴 EQUALITY-shaped, not "does not contain OpenSmartBatt": the
          // FB-109 text `$appName · monitoring` satisfies an absence check
          // perfectly while being exactly the defect.
          expect(t, startsWith('${_injected.appName} '),
              reason: 'notification title did not start with the injected '
                  'name: ${jsonEncode(t)}');
          _expectNoResidue(t, 'monitorNotificationTitle* [$tag]');
          expect(t, isNot(contains('OpenSmartBatt')),
              reason: 'a hard-coded brand survived injection: $t');
        }
        // Both reachable states, so this is not one title asserted twice.
        expect(titles.length, greaterThanOrEqualTo(2),
            reason: 'only ${titles.length} distinct title(s) observed — the '
                'connecting/steady transition did not happen, so the test '
                'proved less than it claims');
        // The channel name and description are the OTHER two strings the OS
        // shows for this app, on a screen this app never draws.
        for (final n in monitor.posted) {
          _expectNoResidue(n.channelName, 'monitorChannelName [$tag]');
          _expectNoResidue(
              n.channelDescription, 'monitorChannelDescription [$tag]');
          _expectNoResidue(n.stopLabel, 'monitorNotificationStop [$tag]');
        }
      });
    }
  });

  // ==========================================================================
  // B — breadth: every message, both locales, checked where it actually ships
  // ==========================================================================
  //
  // 🔑 WHY THIS IS A SOURCE SWEEP AND NOT A LOOP OVER `AppLocalizations`.
  // Enumerating "every getter and method" of a class at run time needs
  // reflection, and `dart:mirrors` is not available under `flutter test`. The
  // two artefacts below are what the app actually loads, so sweeping them is
  // not a weaker substitute — a residue in either is a residue on screen.
  group('B — no message in either locale carries an unsubstituted placeholder',
      () {
    const arbs = ['lib/l10n/app_en.arb', 'lib/l10n/app_zh.arb'];
    const generated = [
      'lib/l10n/app_localizations.dart',
      'lib/l10n/app_localizations_en.dart',
      'lib/l10n/app_localizations_zh.dart',
    ];

    /// `{key: value}` for the real messages in [path] — `@`-prefixed metadata
    /// and non-string values dropped.
    Map<String, String> messages(String path) {
      final raw = jsonDecode(File(path).readAsStringSync()) as Map;
      return {
        for (final e in raw.entries)
          if (!(e.key as String).startsWith('@') && e.value is String)
            e.key as String: e.value as String,
      };
    }

    /// The placeholders [key] declares in the EN template (the only file
    /// gen-l10n reads metadata from — `l10n.yaml` sets
    /// `template-arb-file: app_en.arb`).
    Set<String> declaredIn(Map raw, String key) {
      final meta = raw['@$key'];
      if (meta is! Map) return const {};
      final ph = meta['placeholders'];
      return ph is Map ? ph.keys.cast<String>().toSet() : const {};
    }

    /// Every placeholder NAME a value refers to: the plain `{name}` form and
    /// the ICU `{name, plural, …}` / `{name, select, …}` head.
    Set<String> usedIn(String value) => {
          ...RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}')
              .allMatches(value)
              .map((m) => m.group(1)!),
          ...RegExp(r'\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*,')
              .allMatches(value)
              .map((m) => m.group(1)!),
        };

    test('B1 — no .arb value writes a placeholder as `\$name`', () {
      // The FB-109 shape expressed one level up. gen-l10n copies the dollar
      // through verbatim (escaping it in the emitted Dart), so it reaches the
      // user as six literal characters.
      final dollar = RegExp(r'\$[A-Za-z_]');
      final offenders = <String>[];
      for (final f in arbs) {
        messages(f).forEach((k, v) {
          if (dollar.hasMatch(v)) offenders.add('$f :: $k = ${jsonEncode(v)}');
        });
      }
      expect(offenders, isEmpty,
          reason: 'an .arb value contains a literal `\$name`. ICU placeholders '
              'are written `{name}` and declared under `@key.placeholders` '
              '(FB-109)');
    });

    test('B2 — every `{name}` used is declared, and every declared one is used',
        () {
      // An UNDECLARED placeholder is not a compile error: gen-l10n emits the
      // braces as literal text, which is the `{name}` half of `_residue`.
      // A DECLARED-but-unused one is the mirror image — the caller is made to
      // pass a value that lands nowhere, which is how a brand silently stops
      // appearing.
      final rawEn =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
      final problems = <String>[];
      for (final f in arbs) {
        messages(f).forEach((k, v) {
          final declared = declaredIn(rawEn, k);
          final used = usedIn(v);
          for (final u in used.difference(declared)) {
            problems.add('$f :: $k uses {$u}, undeclared in app_en.arb');
          }
          if (f.endsWith('app_en.arb')) {
            for (final d in declared.difference(used)) {
              problems.add('$f :: $k declares $d but never uses it');
            }
          }
        });
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('B3 — a translation may not drop a placeholder the template has', () {
      // The silent rebrand: `"monitorNotificationTitle": "監看中"` in zh alone
      // compiles, generates and runs — and the Chinese build simply stops
      // saying its own name. Nothing else in the suite asks this question.
      final rawEn =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
      final en = messages('lib/l10n/app_en.arb');
      final zh = messages('lib/l10n/app_zh.arb');
      final problems = <String>[];
      for (final k in zh.keys) {
        if (!en.containsKey(k)) continue;
        final want = declaredIn(rawEn, k).intersection(usedIn(en[k]!));
        final got = usedIn(zh[k]!);
        for (final missing in want.difference(got)) {
          problems.add('app_zh.arb :: $k never uses {$missing}');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('B4 — no generated localization file escapes a dollar', () {
      // `\$` in the EMITTED Dart is, byte for byte, what shipped in v0.7.40 and
      // v0.7.41. Checked here rather than only in `lib/` because these three
      // files are generated: a bad `.arb` produces it without any human ever
      // typing a backslash.
      //
      // The scan behind this test found ZERO occurrences on a clean tree, so
      // there is no whitelist. A future string that legitimately needs a dollar
      // must be exempted BY KEY, with the reason written here.
      final offenders = <String>[];
      for (final f in generated) {
        final src = File(f).readAsStringSync();
        for (final m in RegExp(r'\\\$').allMatches(src)) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('$f:$line');
        }
      }
      expect(offenders, isEmpty,
          reason: 'an escaped dollar in generated l10n prints the placeholder '
              'NAME to the user (FB-109): ${offenders.join(', ')}');
    });

    test('B5 — every brand-bearing message is called with the injected name, '
        'never a literal', () {
      // Derived, not hand-listed — the shape `app_config_test.dart` T4 was
      // rewritten into after its hand-written four-file list inherited design
      // 0092 §1.5's own omission. The key list comes from the .arb, the call
      // sites come from grepping `lib/`, so a seventh brand string or a fourth
      // call site is covered the day it is written.
      final rawEn =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
      final branded = [
        for (final k in messages('lib/l10n/app_en.arb').keys)
          if (declaredIn(rawEn, k).contains('appName')) k,
      ];
      expect(branded, isNotEmpty,
          reason: 'no {appName} placeholder found at all — the derivation '
              'broke, and this test would otherwise pass vacuously');

      final problems = <String>[];
      for (final key in branded) {
        final grep = Process.runSync('grep', ['-rn', '$key(', 'lib/'],
            runInShell: false);
        for (final line in (grep.stdout as String).split('\n')) {
          if (line.isEmpty) continue;
          final parts = line.split(':');
          if (parts.first.startsWith('lib/l10n/')) continue; // the definitions
          final code = parts.sublist(2).join(':');
          if (code.trimLeft().startsWith('//')) continue; // prose, not a call
          // The argument list as written at the call site.
          final m = RegExp('$key\\(([^)]*)').firstMatch(code);
          if (m == null) continue;
          final arg = m.group(1)!.trim();
          // ⛔ KNOWN GAP, stated rather than papered over: `grep` is
          // line-based, so a call whose argument was wrapped onto the next
          // line reaches here with an empty `arg` and is SKIPPED. Widening
          // this to a multi-line scan means parsing Dart. `settingsVersionSub`
          // is written that way today (settings_screen.dart:1584), so this
          // test currently covers six of the seven brand-bearing keys; the
          // seventh is covered by `app_config_test.dart` T3 instead.
          if (arg.isEmpty) continue;
          if (RegExp(r'''^['"]''').hasMatch(arg)) {
            problems.add('${parts.first}:${parts[1]} passes a string literal '
                'to $key — pass AppConfigScope.of(context).appName (FB-109)');
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });
}
