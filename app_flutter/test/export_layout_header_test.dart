// The export preamble records the dashboard layout (design 0034 §8, test T10).
//
// WHY THIS LINE IS NOT OPTIONAL. Our problem-reading runs on screenshots:
// every entry in `docs/feedback-attachments/our-app.md` is a field read off a
// picture, and statements like "SOC shows --" or "four DVOL bars of similar
// length" are evidence only because we knew what that screen was supposed to
// look like. One entry (`our-app.md:29`) infers an APP VERSION from "two
// protection cells versus three". The moment the dashboard is customisable,
// "there is no charge reading on screen" means either "the data never came" or
// "that card is not on their page" — and without this line we would find out
// the slow way, from a capture we could no longer interpret.
//
// The six format constraints are asserted individually below because each one
// has a specific downstream consumer that breaks silently, not loudly.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/dashboard/watchfaces.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  /// Every (class, face) pair, plus the offline case.
  List<String> allValues() => [
        for (final cls in ProductClass.values)
          for (final f in Watchface.values)
            exportLayoutValue(cls: cls, layout: DisplayLayout(watchface: f)),
        exportLayoutValue(cls: null, layout: null),
      ];

  List<String> header(
          {required String layout,
          String home = 'tiles=auto',
          bool speedDetection = false}) =>
      exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: DateTime.utc(2026, 8, 4, 9, 30),
        appBuild: '0.6.16+1',
        platform: 'android 15',
        scope: 'device=battery/1206',
        layout: layout,
        home: home,
        speedDetection: speedDetection,
      );

  group('T10 constraint 1+6: last, and exactly one line', () {
    test('the layout line closes the preamble', () {
      for (final v in allValues()) {
        expect(header(layout: v).last, 'layout: $v');
      }
    });

    test('it is one line — no embedded newline could split it', () {
      // The writer prefixes each preamble entry with `# `. A value containing a
      // newline would emit a second, UNCOMMENTED line into the middle of a CSV
      // header block, which the parser would then read as data.
      for (final v in allValues()) {
        expect(v, isNot(contains('\n')));
        expect(v, isNot(contains('\r')));
      }
    });
  });

  group('T10 constraint 2: unconditional, default layout included', () {
    test('the default layout is written out, not omitted', () {
      // Same reasoning as FB-32's `raw packet log: on`. If only a customised
      // layout appeared, a missing line would mean BOTH "they kept the default"
      // AND "an older build wrote this" — which is exactly how FB-10's version
      // inference turned out to be a coincidence rather than a fact.
      final v = exportLayoutValue(
          cls: ProductClass.smartBattery, layout: DisplayLayout.defaults);
      final lines = header(layout: v);
      expect(lines.where((l) => l.startsWith('layout: ')), hasLength(1));
      expect(lines.last, 'layout: face=standard modules=gaugeVoltage,readouts,cells');
    });

    test('the parameter is required, so no call site can drop it', () {
      // Enforced by the compiler rather than by review: `layout` is a required
      // named parameter of exportHeaderLines. This test exists to record that
      // the requiredness IS the mechanism — if someone gives it a default
      // value, this comment is the reason not to.
      final lines = header(layout: 'face=- modules=-');
      expect(lines.any((l) => l.startsWith('layout: ')), isTrue);
    });
  });

  group('T10 constraint 3: its own line, never folded into another', () {
    test('scope: and exported: are untouched and carry no layout text', () {
      final lines = header(layout: 'face=compact modules=gaugeSoc,energyPath');
      final scope = lines.firstWhere((l) => l.startsWith('scope: '));
      final exported = lines.firstWhere((l) => l.startsWith('exported: '));
      expect(scope, 'scope: device=battery/1206');
      expect(exported, isNot(contains('face=')));
      expect(scope, isNot(contains('face=')));
      // `fbingest.py` matches `scope:` and `exported:` by prefix and takes the
      // rest of the line. Appending to either would be swallowed silently — no
      // error, just a field that quietly stops parsing.
    });

    test('no preamble line carries its own comment prefix', () {
      for (final line in header(layout: 'face=- modules=-')) {
        expect(line, isNot(startsWith('#')));
      }
    });
  });

  group('T10 constraint 4: the VALUE contains no ": "', () {
    test('literally, for every class and every face', () {
      // The collected batches are read with a GREEDY `sed 's/.*: //'`, so a
      // second ": " anywhere in the line silently truncates the value to
      // whatever follows the last one. This is the assertion that keeps the
      // format choice (`face=… modules=…`, `=` not `:`) from drifting back.
      for (final v in allValues()) {
        expect(v, isNot(contains(': ')),
            reason: '"$v" would be truncated by the greedy sed recipe');
      }
    });

    test('and the whole line has exactly one ": " — the key separator', () {
      for (final v in allValues()) {
        final line = 'layout: $v';
        expect(': '.allMatches(line).length, 1, reason: line);
      }
    });
  });

  group('T10 constraint 5: not localized', () {
    test('every value is pure ASCII, in any app language', () {
      // The value is built from `Watchface.slug` and `DisplayModule.name`,
      // which are Dart identifiers — exportLayoutValue takes no
      // AppLocalizations at all, so there is no language for it to vary with.
      // (Same rule as `exportScopeLabel`: whoever RECEIVES a capture is not the
      // person whose phone exported it.)
      for (final v in allValues()) {
        expect(v.runes.every((r) => r < 128), isTrue, reason: v);
      }
    });

    test('the value matches a strict machine-readable grammar', () {
      final grammar = RegExp(r'^face=([a-z]+|-) modules=([A-Za-z,]+|-)$');
      for (final v in allValues()) {
        expect(grammar.hasMatch(v), isTrue, reason: v);
      }
    });
  });

  group('the value says what the LAYOUT is, verbatim', () {
    test('default battery — the line a normal user exports', () {
      expect(
        exportLayoutValue(
            cls: ProductClass.smartBattery, layout: DisplayLayout.defaults),
        'face=standard modules=gaugeVoltage,readouts,cells',
      );
    });

    test('a customised power bank', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.powerBank,
          layout: const DisplayLayout(watchface: Watchface.diagnostic),
        ),
        'face=diagnostic modules=chart,readouts,energyPath,gaugeSoc',
      );
    });

    test('a capacitor on the compact face', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.supercapacitor,
          layout: const DisplayLayout(watchface: Watchface.compact),
        ),
        'face=compact modules=gaugeVoltage,cells',
      );
    });

    test('an unclassified unit always reports the standard face (Q4)', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.unknown,
          layout: const DisplayLayout(watchface: Watchface.compact),
        ),
        'face=standard modules=gaugeVoltage,readouts,cells',
        reason: 'the stored face is not applied to an unclassified unit, so '
            'the preamble must not claim it was',
      );
    });

    test('offline: no unit, therefore no layout in force', () {
      // Q3 bound the setting to the device, so with nothing connected there is
      // genuinely no layout to name — and printing the default would claim a
      // screen the user was not looking at. `-` is the same "absent" token
      // `exportScopeLabel` already uses for a missing ident.
      expect(exportLayoutValue(cls: null, layout: null), 'face=- modules=-');
      expect(
          exportLayoutValue(cls: null, layout: DisplayLayout.defaults),
          'face=- modules=-');
    });

    test('the list reports the CHOSEN cards, not the ones that had data', () {
      // The point of §8: a face that includes `cells` says `cells` even on a
      // session where DVOL never arrived, because "the data was missing" and
      // "the card was not on the page" are exactly the two readings this line
      // exists to separate. The value function takes no telemetry, which is how
      // that is guaranteed rather than remembered.
      expect(
        exportLayoutValue(
            cls: ProductClass.smartBattery, layout: DisplayLayout.defaults),
        contains('cells'),
      );
    });
  });

  // ===========================================================================
  // T6 (design 0040 §6) — the whole table, in one snapshot.
  // ===========================================================================
  //
  // Every (class, face) the preamble can print, written out literally. Two jobs:
  //
  //  1. it is the machine-readable statement of design 0040 §3.3, so a change to
  //     `watchfaceModules` cannot land without someone editing the exact strings
  //     that will appear in the field captures we analyse;
  //  2. ⚠️ it scopes the COMPATIBILITY BREAKS, of which there are now TWO, each
  //     one face wide. Before design 0040 the chart was not placeable, so
  //     `modules=` never contained `chart`; `face=diagnostic` therefore names a
  //     different set of cards across that boundary. Design 0041 then moved a
  //     pack's `compact` from `gaugeVoltage,readouts` to `gaugeVoltage,cells`,
  //     so `face=compact` is a second break — on PACKS only; the power bank's
  //     compact list is untouched since 0040.
  //
  //     `face=standard` is the one that does NOT break, on any class: 0040 Q1
  //     was reversed on review and 0041 did not touch it, so `standard` keeps
  //     its pre-0040 list verbatim and stays directly comparable all the way
  //     back. That matters more than the other two put together — `standard` is
  //     the default, and therefore what almost every field capture carries.
  //
  //     Same class of thing as the `usb` → `energyPath` rename (design 0035
  //     §5.3 / R4), and recorded the same way, in
  //     `docs/feedback-index/conventions.md`.
  //
  // `ProductClass.unknown` is absent by design — Q4 forces it onto the standard
  // face, which the group above already pins.
  group('T6: the exported module list, class by class and face by face', () {
    const expected = <ProductClass, Map<Watchface, String>>{
      ProductClass.smartBattery: {
        Watchface.standard: 'face=standard modules=gaugeVoltage,readouts,cells',
        Watchface.compact: 'face=compact modules=gaugeVoltage,cells',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=chart,readouts,cells,gaugeVoltage',
        Watchface.riding: 'face=riding modules=speed,gaugeVoltage,cells',
      },
      ProductClass.supercapacitor: {
        Watchface.standard: 'face=standard modules=gaugeVoltage,readouts,cells',
        Watchface.compact: 'face=compact modules=gaugeVoltage,cells',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=chart,readouts,cells,gaugeVoltage',
        Watchface.riding: 'face=riding modules=speed,gaugeVoltage,cells',
      },
      ProductClass.powerBank: {
        Watchface.standard: 'face=standard modules=gaugeSoc,readouts,energyPath',
        // No `readouts` here, and that is design 0040 Q2, not an omission: a
        // one-screenful power-bank layout keeps the direction row and drops the
        // grid — which also drops temperature (R3), accepted knowingly.
        Watchface.compact: 'face=compact modules=gaugeSoc,energyPath',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=chart,readouts,energyPath,gaugeSoc',
        // design 0042: `compact`'s shell with the speed card on top. The value
        // is what the LAYOUT declares and is emitted even when the master
        // switch is off and the phone is actually drawing `standard` — the
        // `speed detection: off` line beside it is what resolves the two. A
        // preamble filtered by the switch would delete exactly the evidence a
        // reader needs to explain the screenshot.
        Watchface.riding: 'face=riding modules=speed,gaugeSoc,energyPath',
      },
    };

    expected.forEach((cls, byFace) {
      byFace.forEach((face, value) {
        test('${cls.name} / ${face.slug}', () {
          expect(
            exportLayoutValue(cls: cls, layout: DisplayLayout(watchface: face)),
            value,
          );
        });
      });
    });

    test('and the table itself covers every face of every listed class', () {
      // A new face must be added here, not silently default to untested.
      for (final byFace in expected.values) {
        expect(byFace.keys.toSet(), Watchface.values.toSet());
      }
    });
  });

  // =========================================================================
  // design 0042 §3.9 — `speed detection: on/off`
  // =========================================================================
  //
  // The same rule as FB-32's `raw packet log:`, applied to a second switch, and
  // for the same reason: without it an empty `speed` column in a CSV has TWO
  // readings — the feature was off, or it was on and no minute ever had a live
  // fix — which call for opposite replies to a reporter.
  group('the preamble states the speed switch', () {
    test('off is stated, not omitted', () {
      expect(header(layout: 'face=standard modules=x', speedDetection: false),
          contains('speed detection: off'));
    });

    test('on is stated too', () {
      expect(header(layout: 'face=riding modules=speed,x', speedDetection: true),
          contains('speed detection: on'));
    });

    test('exactly one line, in both states', () {
      for (final on in [true, false]) {
        final lines = header(layout: 'face=standard modules=x', speedDetection: on);
        expect(lines.where((l) => l.startsWith('speed detection: ')),
            hasLength(1));
      }
    });

    test('it comes BEFORE the layout line, which stays last', () {
      // Constraint 1 of the six: the layout line closes the preamble. A new
      // optional line joins the middle; putting it after would move the one
      // line the ingest scripts index from the end.
      final lines = header(layout: 'face=riding modules=speed,x', speedDetection: true);
      expect(lines.last, startsWith('layout: '));
      expect(lines.indexWhere((l) => l.startsWith('speed detection: ')),
          lessThan(lines.length - 1));
    });

    test('the value carries no second `: ` and no newline', () {
      // Constraints 4 and 6: the collection recipes read a value with a greedy
      // `sed 's/.*: //'`, which would eat everything up to the LAST colon-space.
      for (final on in [true, false]) {
        final line = header(layout: 'face=standard modules=x', speedDetection: on)
            .firstWhere((l) => l.startsWith('speed detection: '));
        expect(line.substring('speed detection: '.length), isNot(contains(': ')));
        expect(line, isNot(contains('\n')));
        expect(line, isNot(contains('\r')));
      }
    });

    test('the two lines together explain a riding face that drew standard', () {
      // The layout line reports what the LAYOUT declares, deliberately
      // unfiltered by the switch. A phone with `riding` stored and detection
      // off draws `standard` while still declaring `face=riding` — and it is
      // ONLY the pair of lines that says why. Filtering the layout line would
      // delete the evidence; omitting the switch line would leave the
      // contradiction unexplained.
      final lines = header(
        layout: exportLayoutValue(
          cls: ProductClass.smartBattery,
          layout: const DisplayLayout(watchface: Watchface.riding),
        ),
        speedDetection: false,
      );
      expect(lines, contains('speed detection: off'));
      expect(lines.last, 'layout: face=riding modules=speed,gaugeVoltage,cells');
    });
  });

  group('end to end: the line reaches the exported file', () {
    test('a CSV export carries it, commented, after the other preamble lines',
        () async {
      final db = await AppDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      final repo = HistoryRepo(db.db);
      await repo.insertSample(
        TelemetrySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(60000), pvlt: 12.5),
        deviceId: 'AA',
      );
      final out = await repo.exportCsv(
        header: header(
          layout: exportLayoutValue(
            cls: ProductClass.supercapacitor,
            layout: const DisplayLayout(watchface: Watchface.diagnostic),
          ),
        ),
      );
      final lines = out.text.split(RegExp(r'\r?\n'));
      final layoutLine = lines.firstWhere((l) => l.contains('layout: '));
      expect(layoutLine,
          '# layout: face=diagnostic modules=chart,readouts,cells,gaugeVoltage');
      // Still inside the commented preamble, above the column header.
      expect(lines.indexOf(layoutLine),
          lessThan(lines.indexWhere((l) => !l.startsWith('#'))));
    });
  });

  // =========================================================================
  // design 0046 Step 10 — the same six constraints, for the home grid.
  //
  // WHY THIS LINE EXISTS AT ALL. The argument for `layout:` above is that our
  // problem-reading runs on screenshots, and a customisable page makes "there
  // is no charge reading on screen" mean two different things. Design 0046 R3
  // made the home grid the app's DEFAULT ENTRY POINT — so most screenshots we
  // are sent from now on are of THIS page, and the argument is stronger here
  // than it was there.
  //
  // Copied from the `layout` group rather than merged with it, deliberately:
  // the two lines have different positions in the preamble (one is the required
  // tail, one is in the optional middle) and a shared loop would stop being
  // able to say so.
  // =========================================================================
  group('T10 for home: the value obeys the same grammar', () {
    List<String> homeValues() => [
          exportHomeValue(null),
          exportHomeValue(HomeLayout.defaultFor(const [])),
          exportHomeValue(HomeLayout.defaultFor(
              const [SavedDevice(id: 'AA:BB', alias: 'one')])),
          exportHomeValue(HomeLayout.defaultFor(const [
            SavedDevice(id: 'AA:BB', alias: 'one'),
            SavedDevice(id: 'CC:DD', alias: 'two'),
          ])),
          exportHomeValue(HomeLayout(const [
            HomeTile.module(DisplayModule.speed, span: HomeSpan.half),
            HomeTile.device('AA:BB'),
            HomeTile.module(DisplayModule.readouts, deviceId: 'AA:BB'),
          ])),
        ];

    test('one line, and never merged into another', () {
      for (final v in homeValues()) {
        expect(v, isNot(contains('\n')));
        expect(v, isNot(contains('\r')));
        final lines = header(layout: 'face=- modules=-', home: v);
        expect(lines.where((l) => l.startsWith('home: ')), hasLength(1));
      }
    });

    test('the value carries no ": " for the greedy sed to eat', () {
      // The analysis recipes read a preamble value with `sed 's/.*: //'`, which
      // takes everything up to the LAST occurrence.
      for (final v in homeValues()) {
        expect(v, isNot(contains(': ')));
      }
    });

    test('it sits in the optional middle — layout: is still last', () {
      // The one constraint `home:` must NOT copy. The ingest scripts anchor on
      // `layout:` closing the preamble (constraint 1 above), and that contract
      // has shipped for two months.
      for (final v in homeValues()) {
        final lines = header(layout: 'face=- modules=-', home: v);
        expect(lines.last, 'layout: face=- modules=-');
        expect(lines.indexWhere((l) => l.startsWith('home: ')),
            lessThan(lines.length - 1));
      }
    });

    test('it is emitted unconditionally, "never customised" included', () {
      // FB-32's rule. If only a customised grid were written, a missing line
      // would mean both "they kept the default" and "an older build wrote
      // this".
      final lines = header(layout: 'face=- modules=-', home: exportHomeValue(null));
      expect(lines, contains('home: tiles=auto'));
    });

    test('it is not localized', () {
      // A preamble is read by whoever RECEIVES the file, not by the phone that
      // exported it.
      //
      // `:` joined the alphabet on 2026-08-07 for the `:half` span suffix — a
      // grammar EXTENSION, deliberately additive so a reader that predates it
      // still parses the module name. This test caught the change, which is
      // what it is for; widening it was the ruling, not the workaround.
      for (final v in homeValues()) {
        expect(v, matches(RegExp(r'^tiles=[A-Za-z0-9@,:]+$')));
      }
    });

    test('the span suffix never introduces the one sequence the parser splits on',
        () {
      // The header is `key: value`, and analysis scripts split on the FIRST
      // ': '. A colon inside the value is harmless; a colon-SPACE is not. The
      // six hard constraints on the layout line (design 0034 §12.3 #3) apply
      // here verbatim, and `:half` is the first thing that ever put a colon in
      // one of these values — so it gets its own test rather than an assumption.
      for (final v in homeValues()) {
        expect(v.contains(': '), isFalse, reason: v);
      }
    });

    test('raw device ids never reach the file', () {
      // design 0027 §3.1: on Android the device id is the MAC. Tiles that name
      // the same unit share an ordinal, which is the only thing a reader needs
      // from them.
      final v = exportHomeValue(HomeLayout(const [
        HomeTile.device('AA:BB:CC:DD:EE:FF'),
        HomeTile.module(DisplayModule.readouts, deviceId: 'AA:BB:CC:DD:EE:FF'),
        HomeTile.device('11:22:33:44:55:66'),
      ]));
      expect(v, isNot(contains('AA:BB')));
      expect(v, isNot(contains('11:22')));
      expect(v, 'tiles=deviceCard@d1,readouts@d1,deviceCard@d2');
    });

    test('a device-free module carries no ordinal at all', () {
      // design 0042's `speed` reads the phone, not a unit — inventing a device
      // token for it would tell a reader it was about a battery.
      expect(exportHomeValue(HomeLayout(const [
        HomeTile.module(DisplayModule.speed),
      ])), 'tiles=speed');
    });
  });
}
