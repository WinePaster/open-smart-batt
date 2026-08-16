// design 0066 — the user-declared device model. M1–M6 of §5; M7 lives in
// `schema_v20_test.dart` because it is a migration.
//
// WHAT THIS FILE IS FOR. The feature collects OPINIONS, and an opinion is only
// worth storing while it stays distinguishable from a measurement. Every test
// below is ultimately about one of two ways that can be lost:
//
//   * the opinion leaks into the measured column (M1), or
//   * the form makes people give an opinion they do not have — by forcing a
//     choice, by rejecting what is on their label, or by refusing to save
//     (M2, M4, M5).
//
// The second is the subtle one. A form that will not submit is a form that gets
// filled with whatever passes validation, and the resulting column looks exactly
// like real data.
//
// CLEAN-ROOM: expectations derive from this project's own source, design docs
// and field reports.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/devices/declared_model_dialog.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  // ===========================================================================
  // M1 — the red line (§3.5)
  // ===========================================================================
  group('M1: declaring a model does not move one byte of productClass', () {
    late AppDatabase db;
    late DeviceRepo repo;
    late DeviceController devices;

    setUp(() async {
      db = await AppDatabase.open(
          path: inMemoryDatabasePath, factory: databaseFactoryFfi);
      repo = DeviceRepo(db.db);
      devices = DeviceController(repo);
      await devices.load();
    });

    tearDown(() => db.close());

    test('the measured class survives a declaration that contradicts it',
        () async {
      // 🔑 THE REGRESSION THIS CATCHES is somebody "simplifying" the two into
      // one column — the shortcut that looks obviously right until you are
      // three months downstream holding a corpus in which every row's class
      // might have been typed by its owner. The declaration here is deliberately
      // WRONG (a wire-verified capacitor declared as a car battery), because a
      // test using a consistent pair would pass even if the write clobbered the
      // column.
      await devices.saveNew('DEV-A', 'Cap #1',
          name: 'RCE-SCAP_II', productClass: ProductClass.supercapacitor);

      await devices.setDeclaredModel(
        'DEV-A',
        DeclaredModel(
          category: DeclaredCategory.carBattery,
          region: 'jp',
          label: 'orange',
          capacity: '48',
          declaredAt: DateTime(2026, 8, 17),
        ),
      );

      final after = devices.deviceFor('DEV-A')!;
      expect(after.productClass, ProductClass.supercapacitor,
          reason: '§3.5: the wire decides this column and a person cannot');
      expect(after.declared.category, DeclaredCategory.carBattery,
          reason: '…and the contradiction is preserved, not reconciled — being '
              'able to SEE the disagreement afterwards is the point');

      // Straight at the row, past the model: a write that reached the column via
      // some other path would still be caught here.
      final row = (await db.db.query('saved_devices')).single;
      expect(row['product_class'], 'supercapacitor');
      expect(row['declared_category'], 'car-battery');
    });

    test('the reverse direction too: resolving a class leaves the declaration',
        () async {
      // The other half, and the one that regresses by accident rather than by
      // design: `setProductClass` is called from the wire on every reconnect,
      // so an over-broad UPDATE there would erase the user's answer silently and
      // repeatedly. Nobody would report it — the form still opens, it is just
      // blank again.
      await devices.saveNew('DEV-B', 'Bike', productClass: ProductClass.unknown);
      await devices.setDeclaredModel(
        'DEV-B',
        const DeclaredModel(
            category: DeclaredCategory.motorcycleBattery, model: '7.5Ah-A'),
      );
      await devices.setProductClass('DEV-B', ProductClass.smartBattery);

      final after = devices.deviceFor('DEV-B')!;
      expect(after.productClass, ProductClass.smartBattery);
      expect(after.declared.model, '7.5Ah-A');
      expect(after.declared.category, DeclaredCategory.motorcycleBattery);
    });

    test('an unsaved device is a no-op, not a crash', () async {
      // §3.7's condition, stated where it can be checked: the entrance is on
      // saved rows because there is nowhere else to write.
      await devices.setDeclaredModel(
          'NOBODY', const DeclaredModel(category: DeclaredCategory.powerBank));
      expect(devices.deviceFor('NOBODY'), isNull);
      expect(await db.db.query('saved_devices'), isEmpty);
    });

    test('clearing reaches the database — it is an answer, not a cancel',
        () async {
      // A user who mis-declared last week must be able to take it back. If the
      // repo skipped nulls (the way `setIdentity` deliberately does) a value
      // could only ever be set, and the column would ratchet.
      await devices.saveNew('DEV-C', 'X');
      await devices.setDeclaredModel(
          'DEV-C',
          const DeclaredModel(
              category: DeclaredCategory.carCapacitor, model: 'flagship'));
      expect(devices.deviceFor('DEV-C')!.declared.isNotEmpty, isTrue);

      await devices.setDeclaredModel('DEV-C', DeclaredModel.none);
      expect(devices.deviceFor('DEV-C')!.declared, DeclaredModel.none);
      final row = (await db.db.query('saved_devices')).single;
      expect(row['declared_category'], isNull);
      expect(row['declared_model'], isNull);
    });

    test('an unrelated upsert does not wipe the declaration', () async {
      // `upsertSavedDevice` is an INSERT OR REPLACE of the WHOLE ROW, so a
      // column missing from `toMap()` is not merely unsaved — it is erased later,
      // by the next write that has nothing to do with it. Same trap
      // `schema_v19_test`'s round-trip case documents for settings.
      await devices.saveNew('DEV-D', 'Y');
      await devices.setDeclaredModel('DEV-D',
          const DeclaredModel(category: DeclaredCategory.powerBank, note: 'n'));
      await devices.save(devices.deviceFor('DEV-D')!.copyWith(alias: 'Y2'));

      final after = devices.deviceFor('DEV-D')!;
      expect(after.alias, 'Y2');
      expect(after.declared.category, DeclaredCategory.powerBank);
      expect(after.declared.note, 'n');
    });
  });

  // ===========================================================================
  // M2 — the menu (§3.2)
  // ===========================================================================
  group('M2: the second level of each first-level choice', () {
    test('the five categories offer exactly the ruled lists', () {
      // The §3.2 table, transcribed. It regresses by somebody adding a model to
      // the wrong group while copy-pasting — which produces a menu that looks
      // fine and mislabels every unit declared through it.
      expect(declaredModelsFor(DeclaredCategory.motorcycleCapacitor),
          ['gen1', 'gen2', 'flagship']);
      expect(declaredModelsFor(DeclaredCategory.carCapacitor),
          ['gen1', 'gen2', 'flagship']);
      expect(declaredModelsFor(DeclaredCategory.carBattery), isEmpty,
          reason: 'the car battery asks region / label / capacity instead');
      expect(declaredModelsFor(DeclaredCategory.powerBank), isEmpty);
      expect(declaredModelsFor(DeclaredCategory.motorcycleBattery), [
        '6.0A', '6.0B', '9.0A', //
        '5.0Ah-B', '7.5Ah-B', '10.0Ah-B', //
        '5.0Ah-A', '7.5Ah-A', '10.0Ah-A', '12.5Ah-A', '17.5Ah-A', //
        'retrofit-lid',
      ]);
    });

    test("the bike battery's four branches are separate and exclusive", () {
      // 🔑 Why they must not be flattened: `9.0A` (old catalogue) and `7.5Ah-A`
      // (new catalogue) are THE SAME PHYSICAL BATTERY renamed, with the nominal
      // Ah revised DOWN. A flat list puts both in front of a user who owns one
      // of them and asks them to know that.
      final groups = declaredModelGroups(DeclaredCategory.motorcycleBattery);
      expect(groups.map((g) => g.id).toList(),
          ['oldGen', 'newGenB', 'newGenA', 'retrofit']);

      final seen = <String>{};
      for (final g in groups) {
        for (final m in g.models) {
          expect(seen.add(m), isTrue,
              reason: '$m appears in two branches — a unit declared through '
                  'one of them could not be told from the other');
        }
      }
      // The A/B split is case THICKNESS, so no slug may claim both.
      expect(groups[1].models.every((m) => m.endsWith('-B')), isTrue);
      expect(groups[2].models.every((m) => m.endsWith('-A')), isTrue);
    });

    test('every category slug round-trips, and an unknown one reads as null',
        () {
      for (final c in DeclaredCategory.values) {
        expect(DeclaredCategory.fromStorageKey(c.storageKey), c);
      }
      // A downgrade, or a category we withdraw. Never a guess.
      for (final junk in ['', 'motorbike', 'powerBank', 'zzz']) {
        expect(DeclaredCategory.fromStorageKey(junk), isNull, reason: junk);
      }
      expect(DeclaredCategory.fromStorageKey(null), isNull);
    });

    test('the smart-module generation is NOT collectable anywhere', () {
      // §3.4, ruled out by the owner: `08.04/008` separated three bike batteries
      // on twelve registers byte for byte and could not tell 1.0 from 2.0, and
      // it is an axis INDEPENDENT of the catalogue generation. This asserts the
      // absence, because the way it comes back is somebody reading "generation"
      // in the menu and adding the other kind next to it.
      final all = [
        for (final c in DeclaredCategory.values) ...declaredModelsFor(c),
      ].map((s) => s.toLowerCase());
      expect(all.any((s) => s.contains('1.0') || s.contains('2.0')), isFalse);
    });
  });

  // ===========================================================================
  // M3 / M4 / M5 — the dialog
  // ===========================================================================
  group('the form', () {
    /// Tap a control by key, scrolling it into view first.
    ///
    /// The form is a [SingleChildScrollView] — the 汽車電池 branch alone is four
    /// sections tall — so a bare `tap()` silently derives an off-screen offset
    /// and hits the backdrop. That failure looks like "the control does not
    /// work", which is exactly the wrong conclusion to hand somebody.
    Future<void> tapKey(WidgetTester tester, String key) async {
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('M3: 改智慧上蓋 gives a countable slug and a free text box',
        (tester) async {
      // §3.2's ruling in one test. A plain note cannot be counted (people write
      // 改上蓋 / 智慧上蓋 / 上蓋H2 and every other spelling), and a model list
      // would be wrong because the thing has no catalogue slot — it is somebody
      // else's battery under our lid. So it has to be BOTH, and the two halves
      // regress separately.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapKey(tester, 'declared-category-motorcycle-battery');
      expect(find.byKey(const ValueKey('declared-retrofit-note')), findsNothing,
          reason: 'the box belongs to the branch, not to the category');

      await tapKey(tester, 'declared-model-retrofit-lid');
      final box = find.byKey(const ValueKey('declared-retrofit-note'));
      expect(box, findsOneWidget,
          reason: 'a slug alone loses the detail; a note alone cannot be counted');
      await tester.enterText(box, 'stock 7 Ah underneath');
      await tapKey(tester, 'declared-save');

      expect(out!.model, kRetrofitLidModel,
          reason: 'THE COUNTABLE HALF: `SELECT count(*) WHERE declared_model = '
              "'retrofit-lid'` has to work");
      expect(out!.note, 'stock 7 Ah underneath', reason: 'the free half');
      expect(out!.category, DeclaredCategory.motorcycleBattery);
    });

    testWidgets('M4: the capacity field takes a non-numeric string',
        (tester) async {
      // 🔑 `40B19L` is the whole reason this field is free text (§3.3): it is the
      // only way to find out whether the dealer's "40Ah" was a capacity or a JIS
      // case code, and the wire cannot answer it. A `keyboardType: number`, an
      // inputFormatter or a validator added later would each silently close that
      // question — and each looks like an improvement in review.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapKey(tester, 'declared-category-car-battery');
      await tester.enterText(
          find.byKey(const ValueKey('declared-capacity')), '40B19L');
      await tapKey(tester, 'declared-save');

      expect(out!.capacity, '40B19L');
      // …and it survives the database, not just the dialog.
      expect(
        DeclaredModel.fromMap(out!.toMap()).capacity,
        '40B19L',
      );
    });

    testWidgets('M4b: the four suggestions fill the field without locking it',
        (tester) async {
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-car-battery');

      await tapKey(tester, 'declared-capacity-48');
      expect(
        tester
            .widget<TextField>(find.descendant(
              of: find.byKey(const ValueKey('declared-capacity')),
              matching: find.byType(TextField),
            ))
            .controller!
            .text,
        '48',
      );
      // Typing over a suggestion wins — a chip that could not be overridden
      // would be a dropdown with extra steps.
      await tester.enterText(
          find.byKey(const ValueKey('declared-capacity')), '55Ah');
      await tapKey(tester, 'declared-save');
      expect(out!.capacity, '55Ah');
    });

    testWidgets('M4c: the label colour never fills in a capacity', (tester) async {
      // ⛔ `car-battery.md:154-161` — the owner overturned the one-to-one
      // label↔capacity mapping on 2026-07-30. Auto-filling either from the other
      // would manufacture exactly the correlation this form exists to measure,
      // and the fabricated rows would be indistinguishable from real ones.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapKey(tester, 'declared-category-car-battery');
      await tapKey(tester, 'declared-label-orange');
      await tapKey(tester, 'declared-save');

      expect(out!.label, 'orange');
      expect(out!.capacity, isNull,
          reason: 'no capacity was typed, so none may be stored');
    });

    testWidgets('M5: a wire mismatch is shown and does NOT block the save',
        (tester) async {
      // §3.6. Both halves in one test, because either alone is a defect: a
      // silent mismatch teaches us nothing, and a blocking one throws away the
      // single most valuable thing this form could surface — somebody holding
      // hardware whose device-type byte we have never seen.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(
        onDone: (v) => out = v,
        wireClass: ProductClass.supercapacitor,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapKey(tester, 'declared-category-car-battery');
      expect(find.byKey(const ValueKey('declared-mismatch')), findsOneWidget,
          reason: 'the wire said capacitor and the user said battery');

      await tapKey(tester, 'declared-save');
      expect(out, isNotNull, reason: 'the hint must not be a gate');
      expect(out!.category, DeclaredCategory.carBattery,
          reason: 'and it is the USER’s answer that is stored, not the wire’s');
    });

    testWidgets('M5b: agreeing with the wire shows nothing', (tester) async {
      await tester.pumpWidget(_Harness(
          onDone: (_) {}, wireClass: ProductClass.supercapacitor));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-motorcycle-capacitor');
      expect(find.byKey(const ValueKey('declared-mismatch')), findsNothing);
    });

    testWidgets('M5d: 旗艦 on a 0x17 is flagged — and only while it is live',
        (tester) async {
      // The one row of §3.6's table that needs the RAW byte: [ProductClass]
      // folds 0x17 and 0x18 into one value on purpose, so `saved_devices` cannot
      // answer this and a unit off the link gets no hint at all. That silence is
      // correct — no evidence, no claim — and it is asserted here because the
      // tempting "fix" is to reach for the saved class and produce a hint that
      // is really a guess.
      await tester.pumpWidget(_Harness(
        onDone: (_) {},
        wireClass: ProductClass.supercapacitor,
        wireDeviceType: kSuperCapacitorDeviceType,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-car-capacitor');
      expect(find.byKey(const ValueKey('declared-mismatch')), findsNothing,
          reason: 'the category agrees; nothing to say yet');
      await tapKey(tester, 'declared-model-flagship');
      expect(find.byKey(const ValueKey('declared-mismatch')), findsOneWidget,
          reason: 'a flagship reports 0x18, and this unit reported 0x17');

    });

    testWidgets('M5e: …and off the link there is no byte, so no hint',
        (tester) async {
      // The other half of M5d, in its own test rather than a second act: a
      // `pumpWidget` while the first dialog is still routed leaves that route on
      // the stack, and the second harness's button is then unhittable — which
      // fails as "the control does not work" rather than as what it is.
      await tester.pumpWidget(_Harness(
          onDone: (_) {}, wireClass: ProductClass.supercapacitor));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-car-capacitor');
      await tapKey(tester, 'declared-model-flagship');
      expect(find.byKey(const ValueKey('declared-mismatch')), findsNothing,
          reason: 'no evidence, no claim — `saved_devices` keeps the resolved '
              'class, never the 0x17/0x18 byte the check needs');
    });

    testWidgets('M5c: an unclassified unit is never contradicted',
        (tester) async {
      // `ProductClass.unknown` is precisely the case where the user's answer is
      // worth more than ours. A hint here would tell somebody their correct
      // answer looks wrong.
      await tester.pumpWidget(
          _Harness(onDone: (_) {}, wireClass: ProductClass.unknown));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final c in DeclaredCategory.values) {
        await tapKey(tester, 'declared-category-${c.storageKey}');
        expect(find.byKey(const ValueKey('declared-mismatch')), findsNothing,
            reason: c.storageKey);
      }
    });

    testWidgets('cancel and clear are different answers', (tester) async {
      // The `alias_dialog.dart` bug of 2026-08-11, one layer up: if an emptied
      // form popped null, the caller would read it as "declined" and the user's
      // retraction would never reach the database — a filled amber button that
      // does nothing.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(
        onDone: (v) => out = v,
        initial: const DeclaredModel(
            category: DeclaredCategory.powerBank, note: 'old'),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tapKey(tester, 'declared-clear');
      await tapKey(tester, 'declared-save');
      expect(out, DeclaredModel.none,
          reason: 'a cleared form is SAVED as empty, not read as a cancel');
    });

    testWidgets('cancelling really does change nothing', (tester) async {
      var called = false;
      DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) {
        called = true;
        out = v;
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-power-bank');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(called, isTrue);
      expect(out, isNull);
    });

    testWidgets('every field can be left blank', (tester) async {
      // §3.1. A user who does not know must be able to say so by saying nothing;
      // a required field would fill the column with coin flips, which is worse
      // than empty because it looks like data. Saving an untouched form is the
      // sharpest form of that claim.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-save');
      expect(out, DeclaredModel.none);
    });

    testWidgets('a category with no second level still stores the category',
        (tester) async {
      // R1: the model list will go stale, and the mitigation is that the second
      // level may be empty — so a user on hardware we have not catalogued can
      // still record which of the five things it is.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-motorcycle-battery');
      await tapKey(tester, 'declared-save');
      expect(out!.category, DeclaredCategory.motorcycleBattery);
      expect(out!.model, isNull);
    });

    testWidgets('changing the category drops the answer to the old question',
        (tester) async {
      // Carrying `7.5Ah-A` across to 汽車電容 would store an answer nobody gave,
      // and it would be indistinguishable from one they did.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(onDone: (v) => out = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-motorcycle-battery');
      await tapKey(tester, 'declared-model-7.5Ah-A');
      await tapKey(tester, 'declared-category-car-capacitor');
      await tapKey(tester, 'declared-save');
      expect(out!.category, DeclaredCategory.carCapacitor);
      expect(out!.model, isNull);
    });

    testWidgets('🔴 every control is at least 40x40 dp, and it is MEASURED',
        (tester) async {
      // FB-70's lesson, and `devices_page.dart` records that it was the SECOND
      // time a control shipped working-but-unfindable (14×14 dp, then an 18 px
      // grey glyph). A twenty-target form is the obvious third, so the floor is
      // asserted on every target the widest branch can show rather than on a
      // sample.
      await tester.pumpWidget(_Harness(onDone: (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-category-car-battery');

      final keys = <String>[
        'declared-clear',
        for (final c in DeclaredCategory.values) 'declared-category-${c.storageKey}',
        for (final r in kDeclaredRegions) 'declared-region-$r',
        for (final l in kDeclaredLabels) 'declared-label-$l',
        for (final s in kDeclaredCapacitySuggestions) 'declared-capacity-$s',
        'declared-save',
      ];
      for (final k in keys) {
        final size = tester.getSize(find.byKey(ValueKey(k)));
        expect(size.height, greaterThanOrEqualTo(kDeclaredTapTarget),
            reason: '$k is ${size.height} dp tall');
        expect(size.width, greaterThanOrEqualTo(kDeclaredTapTarget),
            reason: '$k is ${size.width} dp wide');
      }

      // …and the longest branch (motorcycle battery, twelve model chips) too.
      await tapKey(tester, 'declared-category-motorcycle-battery');
      for (final m in declaredModelsFor(DeclaredCategory.motorcycleBattery)) {
        final f = find.byKey(ValueKey('declared-model-$m'));
        await tester.scrollUntilVisible(f, 60,
            scrollable: find.byType(Scrollable).last);
        final size = tester.getSize(f);
        expect(size.height, greaterThanOrEqualTo(kDeclaredTapTarget),
            reason: m);
        expect(size.width, greaterThanOrEqualTo(kDeclaredTapTarget), reason: m);
      }
    });

    testWidgets('the LINE help line is plain text, and it is always there',
        (tester) async {
      // §3.9, ruled 2026-08-17: 「不用，寫文字說明就好，不用補連結」. The assertion
      // that matters is the NEGATIVE one — no GestureDetector, no InkWell, no
      // recognizer on the span — because "helpfully" making it tappable is the
      // regression, and it would look like an improvement in review.
      await tester.pumpWidget(_Harness(onDone: (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final text = find.text(
          'If you are not sure how to fill this in, ask in the LINE community.');
      expect(text, findsOneWidget,
          reason: 'it is the third road: §3.1 and §3.6 both say "do not guess", '
              'and this says where to go instead');
      expect(
        find.ancestor(of: text, matching: find.byType(InkWell)),
        findsNothing,
        reason: 'plain text by ruling — no link, no url_launcher, no constant',
      );
      expect(
        find.ancestor(of: text, matching: find.byType(GestureDetector)),
        findsNothing,
      );
      // Present before ANY choice is made, since the people who need it are
      // exactly the ones who cannot answer the first question.
      expect(find.byKey(const ValueKey('declared-category-car-battery')),
          findsOneWidget);
    });

    testWidgets('a stored declaration comes back into the form', (tester) async {
      // Editing has to show what is there. A form that opened blank would make
      // "confirm what I said last month" cost a full re-entry, and the likely
      // outcome is a partial answer overwriting a complete one.
      late DeclaredModel? out;
      await tester.pumpWidget(_Harness(
        onDone: (v) => out = v,
        initial: const DeclaredModel(
          category: DeclaredCategory.carBattery,
          region: 'eu',
          label: 'purple',
          capacity: '60',
          note: 'hello',
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'declared-save');
      expect(out!.category, DeclaredCategory.carBattery);
      expect(out!.region, 'eu');
      expect(out!.label, 'purple');
      expect(out!.capacity, '60');
      expect(out!.note, 'hello');
      expect(out!.declaredAt, isNotNull,
          reason: 'R2: re-confirming today is a different fact from having '
              'typed it in August and never looked again');
    });
  });

  // ===========================================================================
  // M6 — the export preamble (§3.8)
  // ===========================================================================
  group('M6: the export header', () {
    List<String> header({List<ExportDeviceIdentity> devices = const []}) =>
        exportHeaderLines(
          title: 'OpenSmartBatt history export',
          exportedAt: DateTime.utc(2026, 8, 17),
          appBuild: '0.7.22+26081701',
          platform: 'android 15',
          scope: 'all devices',
          layout: 'face=standard modules=readouts',
          home: 'tiles=auto',
          mode: AppMode.personal,
          themeMode: AppThemeMode.dark,
          accent: AccentTheme.amber,
          speedDetection: false,
          gMeter: false,
          resolution: ExportResolution.none,
          devices: devices,
        );

    test('the count line is emitted even at zero, and layout: stays last', () {
      // FB-32's standing rule. A block that appeared only when somebody had
      // answered would make its absence mean both "nobody answered" and "an
      // older build wrote this" — and counting answers is what the feature is
      // FOR, so that is the one ambiguity it cannot afford.
      final lines = header();
      expect(lines, contains('declared: count=0'));
      expect(lines.last, startsWith('layout: '),
          reason: 'the ingest scripts anchor on layout: being the last line');
    });

    test('a declaration is written out beside its hashed id', () {
      final lines = header(devices: [
        const ExportDeviceIdentity(
          deviceId: 'AA:BB:CC:DD:EE:FF',
          classSlug: 'capacitor',
          declared: DeclaredModel(
            category: DeclaredCategory.carBattery,
            region: 'jp',
            label: 'orange',
            capacity: '40B19L',
          ),
        ),
        const ExportDeviceIdentity(deviceId: 'OTHER', classSlug: 'battery'),
      ]);
      expect(lines, contains('declared: count=1'),
          reason: 'one of the two units has an answer');
      final line = lines.firstWhere((l) => l.startsWith('declared: hash='));
      expect(line, contains('category=car-battery'));
      expect(line, contains('region=jp'));
      expect(line, contains('label=orange'));
      expect(line, contains('capacity=40B19L'));
      // 🔑 The join key is the same hash the `devices:` block uses, so a reader
      // can tie the opinion to the unit without either of them carrying a raw id.
      expect(line, contains('hash='));
      expect(line, isNot(contains('AA:BB:CC:DD:EE:FF')));
      // …and the unit with no answer contributes no line at all.
      expect(lines.where((l) => l.startsWith('declared: hash=')), hasLength(1));
    });

    test('the declaration is never merged into class=', () {
      // §3.5 at the file level: `class=` is what the wire measured and the
      // `declared:` block is what a person typed. A reader who cannot separate
      // them holds a file in which every class might be an opinion.
      final lines = header(devices: [
        const ExportDeviceIdentity(
          deviceId: 'AA',
          classSlug: 'capacitor',
          declared: DeclaredModel(category: DeclaredCategory.carBattery),
        ),
      ]);
      final device = lines.firstWhere((l) => l.contains('class='));
      expect(device, contains('class=capacitor'));
      expect(device, isNot(contains('car-battery')));
    });

    test('🔴 the free-text note is NOT exported, only its existence', () {
      // It is a sentence about the user's own vehicle, and in this corpus that
      // routinely means a plate number or a person's name — the reason
      // `save_device_flow.dart` keeps the alias out of the diagnostic log. An
      // export is mailed to us.
      final lines = header(devices: [
        const ExportDeviceIdentity(
          deviceId: 'AA',
          declared: DeclaredModel(
              category: DeclaredCategory.powerBank, note: 'ABC-1234 我的車'),
        ),
      ]);
      final line = lines.firstWhere((l) => l.startsWith('declared: hash='));
      expect(line, contains('note=yes'));
      expect(line, isNot(contains('ABC-1234')));
    });

    test('a capacity with a space stays ONE key=value token', () {
      // Free text meets a format the ingest recipes split on whitespace. A user
      // typing `40 B19L` must not silently produce a `B19L` field.
      final lines = header(devices: [
        const ExportDeviceIdentity(
          deviceId: 'AA',
          declared: DeclaredModel(
              category: DeclaredCategory.carBattery, capacity: '40 B19L'),
        ),
      ]);
      final line = lines.firstWhere((l) => l.startsWith('declared: hash='));
      expect(line, contains('capacity=40_B19L'));
    });
  });
}

/// A host that opens the dialog and hands the popped value to [onDone].
///
/// Its own widget rather than a closure so each test states the wire values it
/// is asking about right where it asks.
class _Harness extends StatelessWidget {
  const _Harness({
    required this.onDone,
    this.initial = DeclaredModel.none,
    this.wireClass = ProductClass.unknown,
    this.wireDeviceType,
  });

  final void Function(DeclaredModel?) onDone;
  final DeclaredModel initial;
  final ProductClass wireClass;
  final int? wireDeviceType;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                onDone(await showDeclaredModelDialog(
                  ctx,
                  initial: initial,
                  wireClass: wireClass,
                  wireDeviceType: wireDeviceType,
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}
