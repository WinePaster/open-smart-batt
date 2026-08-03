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

    test('power bank: SOC ring, USB card, no DVOL, no SOH', () {
      const m = DisplayModules.powerBank;

      expect(m.has(DisplayModule.gaugeSoc), isTrue);
      expect(m.has(DisplayModule.gaugeVoltage), isFalse);
      expect(m.has(DisplayModule.usb), isTrue);
      expect(m.has(DisplayModule.cells), isFalse);
      // power_bank_view.dart's sub-line is the single-cell voltage, not SOH.
      expect(m.sohGaugeLine, isNull);
      expect(m.showsSohReadout, isFalse);
      expect(m.showsCurrentReadout, isTrue);
      expect(m.chartTracks, {
        TrendField.current,
        TrendField.svlt,
        TrendField.soc,
      });
      expect(m.chartFootnote, isNull);
    });

    test('unclassified: the lenient pack set, no footnote', () {
      const m = DisplayModules.unclassified;

      expect(m.sohGaugeLine, isNotNull);
      expect(m.showsSohReadout, isTrue);
      expect(m.showsCurrentReadout, isTrue);
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
        ProductClass.unknown: true,
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
        ProductClass.unknown: true,
      },
      // chart — every class has a non-empty track list.
      DisplayModule.chart: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: true,
        ProductClass.unknown: true,
      },
      // cells (DVOL) — pack classes only; a power bank does not send it.
      DisplayModule.cells: {
        ProductClass.smartBattery: true,
        ProductClass.supercapacitor: true,
        ProductClass.powerBank: false,
        ProductClass.unknown: true,
      },
      // usb — power bank only.
      DisplayModule.usb: {
        ProductClass.smartBattery: false,
        ProductClass.supercapacitor: false,
        ProductClass.powerBank: true,
        ProductClass.unknown: false,
      },
    };

    test('availability matches §4 for all six modules × four classes', () {
      for (final row in table.entries) {
        for (final cell in row.value.entries) {
          expect(
            DisplayModules.forClass(cell.key).has(row.key),
            cell.value,
            reason: '${row.key} on ${cell.key} should be ${cell.value}',
          );
        }
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
        expect(m.has(DisplayModule.chart), m.chartTracks.isNotEmpty,
            reason: 'chart availability must follow tracks on $c');
      }
    });

    test('data conditions are declared, not merged into the class column', () {
      // §12.3 #2: the two are different questions. DVOL is the only module
      // whose PRESENCE flips on live data — the card disappears entirely when
      // neither `dvol` nor `dvolPending` is set.
      for (final c in [
        ProductClass.smartBattery,
        ProductClass.supercapacitor,
        ProductClass.unknown,
      ]) {
        expect(DisplayModules.forClass(c).dataGated, {DisplayModule.cells});
      }
      // The SOC ring renders `--` rather than vanishing, and the USB card is
      // unconditional today, so nothing on a power bank is presence-gated.
      expect(DisplayModules.powerBank.dataGated, isEmpty);

      // Whatever is data-gated must first be available at all.
      for (final c in ProductClass.values) {
        final m = DisplayModules.forClass(c);
        expect(m.dataGated.difference(m.modules), isEmpty);
      }
    });
  });

  group('quirks pinned as-is (design 0034 §12.3 #1)', () {
    test('(a) unclassified == battery is a byproduct, not a decision', () {
      const u = DisplayModules.unclassified;
      const b = DisplayModules.battery;

      // Today they agree on every gate, because all six gates in the pack
      // shell are written `!= supercapacitor` and an unclassified pack is on
      // the same side of all of them.
      expect(u.modules, b.modules);
      expect(u.chartTracks, b.chartTracks);
      expect(u.showsCurrentReadout, b.showsCurrentReadout);
      expect(u.showsSohReadout, b.showsSohReadout);
      expect(u.chartFootnote, b.chartFootnote);

      // ⚠️ Dart canonicalises two const objects with equal fields into ONE
      // instance, so `identical(unclassified, battery)` is true today. That is
      // a language fact about equal values — NOT evidence that the two
      // declarations were merged. They are separate `static const` entries
      // with separate rationale in display_modules.dart, and the meaning
      // differs: "unclassified" is "everything except what the capacitor
      // excludes", never "assume a battery". The day one gate is written
      // `== smartBattery` instead, they stop being canonicalised together and
      // every expectation in this test starts failing — which is the point.
      expect(identical(u, b), isTrue);
      expect(DisplayModules.forClass(ProductClass.unknown), same(u));
    });

    test('(b) a powerBank label in the pack shell draws the unclassified set',
        () {
      // pack_view.dart:52-62 routes a stray `powerBank` LABEL to the
      // PackControls fallback — routing comes off the device-type byte, the
      // body comes off the cosmetic label, and the two can disagree. The
      // readouts have always followed the fallback too.
      expect(
        DisplayModules.forPackShell(ProductClass.powerBank),
        same(DisplayModules.unclassified),
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
        ProductClass.unknown,
      ]) {
        expect(DisplayModules.forPackShell(c), same(DisplayModules.forClass(c)),
            reason: 'only the powerBank label is remapped');
      }
    });
  });
}
