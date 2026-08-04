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

  List<String> header({required String layout}) => exportHeaderLines(
        title: 'OpenSmartBatt diagnostic log',
        exportedAt: DateTime.utc(2026, 8, 4, 9, 30),
        appBuild: '0.6.16+1',
        platform: 'android 15',
        scope: 'device=battery/1206',
        layout: layout,
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
      expect(lines.last,
          'layout: face=standard modules=gaugeVoltage,readouts,cells,chart');
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
        'face=standard modules=gaugeVoltage,readouts,cells,chart',
      );
    });

    test('a customised power bank', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.powerBank,
          layout: const DisplayLayout(watchface: Watchface.diagnostic),
        ),
        'face=diagnostic modules=readouts,energyPath,chart,gaugeSoc',
      );
    });

    test('a capacitor on the compact face', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.supercapacitor,
          layout: const DisplayLayout(watchface: Watchface.compact),
        ),
        'face=compact modules=gaugeVoltage,readouts',
      );
    });

    test('an unclassified unit always reports the standard face (Q4)', () {
      expect(
        exportLayoutValue(
          cls: ProductClass.unknown,
          layout: const DisplayLayout(watchface: Watchface.compact),
        ),
        'face=standard modules=gaugeVoltage,readouts,cells,chart',
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
  //  2. ⚠️ it records the COMPATIBILITY BREAK. Before design 0040 the chart was
  //     not a placeable module, so `modules=` never contained `chart` and
  //     `face=standard` on a battery read `gaugeVoltage,readouts,cells`. The
  //     same face name now names a different set of cards. Anyone diffing
  //     `modules=` across the v0.7.2 boundary needs this table, in the same way
  //     the `usb` → `energyPath` rename (design 0035 §5.3 / R4) needed its own
  //     note. `ProductClass.unknown` is absent by design — Q4 forces it onto the
  //     standard face, which the group above already pins.
  group('T6: the exported module list, class by class and face by face', () {
    const expected = <ProductClass, Map<Watchface, String>>{
      ProductClass.smartBattery: {
        Watchface.standard: 'face=standard '
            'modules=gaugeVoltage,readouts,cells,chart',
        Watchface.compact: 'face=compact modules=gaugeVoltage,readouts',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=readouts,cells,chart,gaugeVoltage',
      },
      ProductClass.supercapacitor: {
        Watchface.standard: 'face=standard '
            'modules=gaugeVoltage,readouts,cells,chart',
        Watchface.compact: 'face=compact modules=gaugeVoltage,readouts',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=readouts,cells,chart,gaugeVoltage',
      },
      ProductClass.powerBank: {
        Watchface.standard: 'face=standard '
            'modules=gaugeSoc,readouts,energyPath,chart',
        // No `readouts` here, and that is design 0040 Q2, not an omission: a
        // one-screenful power-bank layout keeps the direction row and drops the
        // grid — which also drops temperature (R3), accepted knowingly.
        Watchface.compact: 'face=compact modules=gaugeSoc,energyPath',
        Watchface.diagnostic: 'face=diagnostic '
            'modules=readouts,energyPath,chart,gaugeSoc',
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
          '# layout: face=diagnostic modules=readouts,cells,chart,gaugeVoltage');
      // Still inside the commented preamble, above the column header.
      expect(lines.indexOf(layoutLine),
          lessThan(lines.indexWhere((l) => !l.startsWith('#'))));
    });
  });
}
