// Design 0034 Phase 0 — the display-module registry.
//
//   * T1 (§9): the default module set of each class is what the dashboard drew
//     before the registry existed, element for element. Phase 0 is a pure
//     declaration move; the screen may not change (G4).
//   * T2 (§9): the registry matches §4's table cell by cell — six modules
//     across battery / capacitor / power bank, plus the `unclassified` column
//     §12.3 #1 added.
//
// Plus the two QUIRKS §12.3 #1 asked to be pinned, because both are things a
// tidy-up would "fix" and silently change the screen:
//   (a) `unclassified` equals `battery` today only because every gate in the
//       pack shell is written `!= supercapacitor`.
//   (b) a `powerBank` LABEL can land in the pack shell, where it draws the
//       unclassified set — never PowerBankView's.
//
// Pure Dart: the registry holds no widgets, and its content resolvers take an
// AppLocalizations that can be constructed directly.
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/live_trend_buffer.dart';
import 'package:open_smart_batt/ui/dashboard/display_modules.dart';

void main() {
  final AppLocalizations l10n = AppLocalizationsEn();

  group('T1 — defaults reproduce what each class drew on 2026-08-04', () {
    test('smart battery: voltage gauge, SOH, current, three tracks', () {
      const m = DisplayModules.battery;

      // pack_view.dart: gauge sub-line and SOH readout both gated
      // `packLabel != supercapacitor`.
      expect(m.sohGaugeLine, isNotNull);
      expect(m.showsSohReadout, isTrue);
      // …as was the current readout.
      expect(m.showsCurrentReadout, isTrue);
      // 🔴 FB-106 (2026-08-30): the ONE field where this entry stopped
      // reproducing 2026-08-04. `0x37` is the sum of the DVOL card sitting
      // right below it and matches PVLT to within 0.10 V on 98.1% of the
      // corpus's battery minutes, so the tile printed a third copy of a number
      // already on the page twice. Display only — the decode, the history row
      // and the CSV column are untouched.
      expect(m.showsSvltReadout, isFalse);
      // Tracks in the order the shell lists them: current, PVLT, temperature.
      expect(m.chartTracks, {
        TrendField.current,
        TrendField.pvlt,
        TrendField.temperature,
      });
      // No footnote — the footnote existed to explain a MISSING current track.
      expect(m.chartFootnote, isNull);
    });

    test('super-capacitor: no current, no SOH, and one track MORE', () {
      const m = DisplayModules.capacitor;

      expect(m.sohGaugeLine, isNull);
      expect(m.showsSohReadout, isFalse);
      expect(m.showsCurrentReadout, isFalse);
      // 🔴 The mirror of FB-106's battery assertion, and the reason that
      // change could not be applied class-wide: a capacitor has no per-cell
      // voltages (design 0050 D5), so this is the only second voltage it owns.
      expect(m.showsSvltReadout, isTrue);
      // The trap this test exists for: a capacitor has FEWER readouts but MORE
      // chart tracks than a battery. Dropping SVLT would draw a different
      // screen while every "capacitor shows less" assertion still passed.
      expect(m.chartTracks, {
        TrendField.pvlt,
        TrendField.svlt,
        TrendField.temperature,
      });
      expect(m.chartTracks.length, DisplayModules.battery.chartTracks.length);
      expect(m.hasTrack(TrendField.current), isFalse);
      // And the footnote that says why the current track is absent.
      expect(m.chartFootnote, isNotNull);
      expect(m.chartFootnote!(l10n), l10n.capacitorChartNoCurrentNote);
    });

    test('power bank: SOC ring, energy-path row, no DVOL, no SOH', () {
      const m = DisplayModules.powerBank;

      expect(m.has(DisplayModule.gaugeSoc), isTrue);
      expect(m.has(DisplayModule.gaugeVoltage), isFalse);
      expect(m.has(DisplayModule.energyPath), isTrue);
      expect(m.has(DisplayModule.cells), isFalse);
      // power_bank_view.dart's sub-line is the single-cell voltage, not SOH.
      expect(m.sohGaugeLine, isNull);
      expect(m.showsSohReadout, isFalse);
      expect(m.showsCurrentReadout, isTrue);
      // Its grid never had an SVLT tile — the port rail is the energy-path
      // row's (design 0037 Q5+Q12). The chart track below is a DIFFERENT
      // surface and is deliberately unaffected.
      expect(m.showsSvltReadout, isFalse);
      expect(m.chartTracks, {
        TrendField.current,
        TrendField.svlt,
        TrendField.soc,
      });
      expect(m.chartFootnote, isNull);
    });

    test('packFallback: the lenient pack set, no footnote', () {
      // Renamed from `unclassified` by design 0050 D2. It is no longer what
      // `forClass` hands back for an unidentified device — that returns null
      // now — and exists ONLY for `forPackShell`'s stray-label quirk.
      const m = DisplayModules.packFallback;

      expect(m.sohGaugeLine, isNotNull);
      expect(m.showsSohReadout, isTrue);
      expect(m.showsCurrentReadout, isTrue);
      // 🔴 FB-106 scoped to the battery alone (owner: 「只動電池」), so this
      // entry keeps the tile — which is the whole point of its existing
      // separately. See the quirk test below, where the divergence is pinned.
      expect(m.showsSvltReadout, isTrue);
      expect(m.chartTracks, {
        TrendField.current,
        TrendField.pvlt,
        TrendField.temperature,
      });
      expect(m.chartFootnote, isNull);
    });

    test('the SOH sub-line wording is the gauge line, bucket by bucket', () {
      final line = DisplayModules.battery.sohGaugeLine!;

      // A missing bucket is "waiting", not "this class has none" — the two are
      // different states and only the second one hides the line.
      expect(line(l10n, null), l10n.gaugeSohUnknown);
      expect(line(l10n, 90), l10n.gaugeSohValue(90, l10n.gaugeSohLabelGood));
      expect(line(l10n, 80), l10n.gaugeSohValue(80, l10n.gaugeSohLabelGood));
      expect(line(l10n, 79), l10n.gaugeSohValue(79, l10n.gaugeSohLabelFair));
      expect(line(l10n, 50), l10n.gaugeSohValue(50, l10n.gaugeSohLabelFair));
      expect(line(l10n, 49), l10n.gaugeSohValue(49, l10n.gaugeSohLabelDegraded));
    });
  });

  group('T2 — the registry cell by cell against design 0034 §4', () {
    // §4's table, transcribed. Rows are modules, columns are classes.
    const table = <DisplayModule, Map<ProductClass, bool>>{
      // gauge.voltage — a power bank looks at SOC, not the rail (FB-43).
      DisplayModule.gaugeVoltage: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: false,
        ProductClass.unknown: false,
      },
      // gauge.soc — needs 0x4B b6, which decodes for a power bank only.
      DisplayModule.gaugeSoc: {
        ProductClass.smartBattery: false,
        ProductClass.supercapacitor: false,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // readouts — always there; the CONTENTS differ per class.
      DisplayModule.readouts: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // chart — every class has a non-empty track list.
      DisplayModule.chart: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // cells (DVOL) — pack classes only; a power bank does not send it.
      DisplayModule.cells: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: false,
        ProductClass.powerBank: false,
        ProductClass.unknown: false,
      },
      // energyPath (formerly usb) — power bank only.
      DisplayModule.energyPath: {
        ProductClass.smartBattery: false,
        ProductClass.supercapacitor: false,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // speed (design 0042) — TRUE on all four, and the only row of this table
      // that is uniform for a reason rather than by coincidence: it is the
      // phone's own GNSS reading, so there is no property of the hardware for a
      // column to differ on. `unknown` gets it too — the registry says the
      // module EXISTS for the class; whether an unclassified unit can reach the
      // face that carries it is `effectiveWatchface`'s question (design 0034
      // Q4), asked somewhere else on purpose.
      DisplayModule.speed: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // gForce (design 0045) — TRUE on all four, for `speed`'s reason exactly:
      // it reads the phone's accelerometer, so no property of the hardware
      // gives a column anything to differ on. Whether it can be SEEN is a
      // different question (switch + calibration), asked by `renderedModules`.
      DisplayModule.gForce: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
      // clock (design 0052) — TRUE on all four for `speed`'s reason, and one
      // more of its own: it does not read a sensor either, so unlike the two
      // rows above there is not even a runtime state that could make it
      // absent. `unknown` is false for the same reason every other row is —
      // `forClass` returns null there (design 0050 D3), which is a statement
      // about the CLASS lookup, not about the clock.
      DisplayModule.clock: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
    };

    test('availability matches the table for every module × every class', () {
      // 🔴 The `unknown` column is ALL FALSE now (design 0050 D3): no class
      // means no cards, not "the battery's cards". `forClass` returns null
      // there, and `?? false` is how that reads as "offers nothing".
      for (final row in table.entries) {
        for (final cell in row.value.entries) {
          expect(
            DisplayModules.forClass(cell.key)?.has(row.key) ?? false,
            cell.value,
            reason: '${row.key} on ${cell.key} should be ${cell.value}',
          );
        }
      }
    });

    test('🔴 the common set is exactly the modules every real class has', () {
      // design 0050 D1. Derived rather than restated: `common` must equal the
      // intersection of the three product classes, or the split has drifted
      // from what it claims to be.
      final entries = [
        DisplayModules.battery,
        DisplayModules.capacitor,
        DisplayModules.powerBank,
      ];
      var shared = entries.first.modules;
      for (final e in entries.skip(1)) {
        shared = shared.intersection(e.modules);
      }
      expect(DisplayModules.common, shared,
          reason: 'common must BE the intersection, not merely a subset of it');
      // …and no class repeats a common module in its own additions.
      for (final e in entries) {
        expect(e.extra.intersection(DisplayModules.common), isEmpty,
            reason: 'a module declared in both places is one that can drift');
      }
    });

    test('🔴 the phone modules are common, and they read no device', () {
      // They are common for a different reason from `readouts`/`chart`: they do
      // not consult the device at all, so they are available to every class
      // precisely because they are irrelevant to all of them.
      expect(DisplayModules.common,
          containsAll([DisplayModule.speed, DisplayModule.gForce]));
      for (final m in DisplayModule.values.where((m) => m.isPhoneModule)) {
        expect(DisplayModules.common, contains(m),
            reason: '$m reads the phone, so no class may exclude it');
      }
    });

    test('the table covers every module and every class', () {
      // A new module or class must be added to §4 and to this table, not left
      // to default silently.
      expect(table.keys.toSet(), DisplayModule.values.toSet());
      for (final row in table.values) {
        expect(row.keys.toSet(), ProductClass.values.toSet());
      }
    });

    test('chart is offered exactly when the class has tracks', () {
      for (final c in ProductClass.values) {
        final m = DisplayModules.forClass(c);
        if (m == null) continue; // no class, no cards — checked above
        expect(m.has(DisplayModule.chart), m.chartTracks.isNotEmpty,
            reason: 'chart availability must follow tracks on $c');
      }
    });

    test('data conditions are declared, not merged into the class column', () {
      // §12.3 #2: the two are different questions. DVOL is the only module
      // whose PRESENCE flips on live data — the card disappears entirely when
      // neither `dvol` nor `dvolPending` is set.
      // 🔴 The capacitor left this list on 2026-08-08 (design 0050 D5): it has
      // no per-series voltages to gate.
      expect(DisplayModules.battery.dataGated, {DisplayModule.cells});
      expect(DisplayModules.packFallback.dataGated, {DisplayModule.cells});
      expect(DisplayModules.capacitor.dataGated, isEmpty);
      // The SOC ring renders `--` rather than vanishing, and the energy-path
      // row is unconditional, so nothing on a power bank is presence-gated.
      expect(DisplayModules.powerBank.dataGated, isEmpty);

      // design 0040 Q3: the CHART is not data-gated on any class either, and
      // that is a ruling rather than an oversight. An empty chart draws its own
      // `dashboardChartWaiting` label — "nothing has arrived yet", which is a
      // WAITING state, the same reading design 0035 §4.6 gave the energy-path
      // row. A data gate would instead make the card vanish and reappear as
      // samples come and go, which is the flicker `dataGated` exists to avoid
      // for cards that genuinely have nothing to say.
      for (final c in ProductClass.values) {
        expect(
            DisplayModules.forClass(c)?.isDataGated(DisplayModule.chart) ??
                false,
            isFalse,
            reason: 'chart must stay out of dataGated on $c');
      }

      // Whatever is data-gated must first be available at all.
      for (final c in ProductClass.values) {
        final m = DisplayModules.forClass(c);
        if (m == null) continue;
        expect(m.dataGated.difference(m.modules), isEmpty);
      }
      expect(
          DisplayModules.packFallback.dataGated
              .difference(DisplayModules.packFallback.modules),
          isEmpty);
    });
  });

  group('quirks pinned as-is (design 0034 §12.3 #1)', () {
    test('(a) packFallback == battery WAS a byproduct — FB-106 split them', () {
      const u = DisplayModules.packFallback;
      const b = DisplayModules.battery;

      // ~~Today they agree on every gate, because all six gates in the pack
      // shell are written `!= supercapacitor` and an unclassified pack is on
      // the same side of all of them.~~
      //
      // 🔴 2026-08-30: they no longer agree on every gate, and this test is
      // where that was predicted — the paragraph below (written 2026-08-04)
      // says the day a gate is decided per CLASS rather than per shell, "every
      // expectation in this test starts failing, which is the point". FB-106 is
      // that day: `showsSvltReadout` is decided for the battery specifically,
      // and the owner scoped the change to the battery alone.
      //
      // Everything the shell still gates with `!= supercapacitor` continues to
      // match, so those expectations are kept rather than deleted — they are
      // the ones that would catch an unrelated drift.
      expect(u.modules, b.modules);
      expect(u.chartTracks, b.chartTracks);
      expect(u.showsCurrentReadout, b.showsCurrentReadout);
      expect(u.showsSohReadout, b.showsSohReadout);
      expect(u.chartFootnote, b.chartFootnote);

      // 🔴 The divergence itself, pinned. A future edit that "tidies" the two
      // entries back together fails here, which is what stops a stray
      // powerBank label from silently losing a tile it has always had.
      expect(b.showsSvltReadout, isFalse);
      expect(u.showsSvltReadout, isTrue);

      // ~~⚠️ Dart canonicalises two const objects with equal fields into ONE
      // instance, so `identical(unclassified, battery)` is true today.~~
      // 🔴 Not any more, for the reason above: unequal fields, two instances.
      // The note is kept because it explains why the assertion below FLIPPED
      // rather than why it was written — it was a language fact about equal
      // values, NOT evidence that the two declarations were merged. They are
      // separate `static const` entries with separate rationale in
      // display_modules.dart, and the meaning differs: `packFallback` is "a
      // pack whose label we cannot use", never "assume a battery" — and since
      // design 0050 D2 it is no longer what an UNIDENTIFIED device gets, which
      // is the confusion the rename removed. The day one gate is written
      // `== smartBattery` instead, they stop being canonicalised together and
      // every expectation in this test starts failing — which is the point.
      expect(identical(u, b), isFalse);
      // 🔴 And no class no longer maps here at all (design 0050 D3).
      expect(DisplayModules.forClass(ProductClass.unknown), isNull);
    });

    test('(b) a powerBank label in the pack shell draws the fallback set',
        () {
      // pack_view.dart:52-62 routes a stray `powerBank` LABEL to the
      // PackControls fallback — routing comes off the device-type byte, the
      // body comes off the cosmetic label, and the two can disagree. The
      // readouts have always followed the fallback too.
      expect(
        DisplayModules.forPackShell(ProductClass.powerBank),
        same(DisplayModules.packFallback),
      );
      // NOT the power-bank entry: that one has no voltage gauge and no DVOL,
      // so serving it inside the pack shell would visibly change the screen.
      expect(
        DisplayModules.forPackShell(ProductClass.powerBank),
        isNot(same(DisplayModules.powerBank)),
      );
      // forClass still answers the §4 question truthfully for that class.
      expect(DisplayModules.forClass(ProductClass.powerBank),
          same(DisplayModules.powerBank));
    });

    test('forPackShell passes the other three classes straight through', () {
      for (final c in [
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
      ]) {
        expect(DisplayModules.forPackShell(c), same(DisplayModules.forClass(c)),
            reason: 'only the powerBank label is remapped');
      }
      // `unknown` reaching the pack shell means "a pack we cannot label", not
      // "a device we cannot identify" — routing already decided it is a pack.
      expect(DisplayModules.forPackShell(ProductClass.unknown),
          same(DisplayModules.packFallback));
    });
  });
}
