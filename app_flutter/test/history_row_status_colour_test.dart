// FB-104 / design 0090 — the history row's status badge is drawn only for the
// rows that have something to report.
//
// A user reported the list as 太花俏／看不清楚 and asked for "one colour",
// naming 靜置／放電／充電. The literal premise was already false — those words
// live inside one muted sub-line string and have never been coloured. What they
// were looking at is the badge, and the reason they read it as a DIRECTION is
// that the dashboard spends the SAME green and amber on `powerFlowColor`
// (charging / discharging) while this list spends them on normal / warning.
//
// So the change is not "make it one colour". It is: stop colouring the ~all of
// rows that say nothing happened (165 of 567,201 corpus samples classify as
// `event`), and keep the two badges that do. ⛔ `warning` in particular stays —
// FB-100 made the thresholds read-only, so it is the only protection signal a
// user can still see.
//
// 🔑 **What this file must NOT assert.** Q2 was ruled 保留空位, implemented with
// `Visibility(maintainSize: true)`, so the badge's box — and its Text — are
// STILL IN THE TREE for a normal row. `expect(find.text('正常'), findsNothing)`
// would fail, and "fixing" it by omitting the widget instead would silently
// undo the ruling. The assertions here are therefore: is it painted, does it
// still occupy the same box, and is it announced.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';

void main() {
  // zh is pinned, and one assertion below genuinely depends on it: 正常 and 警告
  // are both two characters, so the reserved box and the drawn box are the same
  // width. In English ("Normal" vs "Warning") they are not — that is not a
  // regression, it is the pre-existing behaviour this change preserves.
  final minute = DateTime.utc(2026, 8, 29, 14, 32);

  /// 🔑 SOH and current are BOTH set on purpose. With neither, `_subLine`
  /// falls back to `l10n.commonNormal` and the row prints 正常 a second time,
  /// as its sub-line — which makes every `find.text('正常')` here ambiguous.
  /// That fallback is deliberate and is pinned separately at the end of this
  /// file (design 0090 §3.2); it must not be confused with the badge.
  HistoryListRow rowAt({bool bare = false}) => HistoryListRow(
        sample: TelemetrySample(
          timestamp: minute,
          pvlt: 13.2,
          mode: 0,
          sohBucket: bare ? null : 92,
          current: bare ? null : -3.2,
        ),
        deviceId: 'AA',
        bucketMs: 60000,
        rows: 60,
      );

  Future<void> pump(WidgetTester tester, HistoryRowStatus status,
      {bool bare = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: HistoryRow(
          row: rowAt(bare: bare),
          tempUnit: TempUnit.celsius,
          status: status,
          deviceClass: ProductClass.smartBattery,
        ),
      ),
    ));
  }

  /// Every label a screen reader would actually read out, walked from the real
  /// semantics tree.
  ///
  /// ⚠️ NOT `find.bySemanticsLabel` — that finder reads each render object's
  /// own `debugSemantics` and still reports a node that an ancestor
  /// `ExcludeSemantics` has dropped, which is exactly the case under test here.
  Set<String> announced(WidgetTester tester) {
    final out = <String>{};
    void visit(SemanticsNode node) {
      if (node.label.isNotEmpty) out.add(node.label);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.getSemantics(find.byType(HistoryRow)));
    return out;
  }

  /// Is this badge actually painted? Reads the ruling's mechanism directly
  /// rather than the Text's presence, which `maintainSize` guarantees either
  /// way (see the header).
  bool painted(WidgetTester tester, String label) {
    final v = find.ancestor(of: find.text(label), matching: find.byType(Visibility));
    if (v.evaluate().isEmpty) return true; // never wrapped ⇒ always drawn
    return tester.widget<Visibility>(v.first).visible;
  }

  group('which rows carry a badge', () {
    testWidgets('normal is not painted', (tester) async {
      await pump(tester, HistoryRowStatus.normal);
      expect(painted(tester, '正常'), isFalse,
          reason: 'FB-104: the green badge is what the user read as a direction');
    });

    testWidgets('warning is still painted, still amber', (tester) async {
      await pump(tester, HistoryRowStatus.warning);
      expect(painted(tester, '警告'), isTrue,
          reason: 'FB-100 made the thresholds read-only — this is the only '
              'protection signal left on screen');
      expect(tester.widget<Text>(find.text('警告')).style?.color,
          AppSemantics.warn);
    });

    testWidgets('event is still painted, still cyan', (tester) async {
      await pump(tester, HistoryRowStatus.event);
      expect(painted(tester, '事件'), isTrue);
      expect(tester.widget<Text>(find.text('事件')).style?.color,
          AppSemantics.event);
    });
  });

  group('Q2 — the space is reserved, not reclaimed', () {
    testWidgets('the hidden badge keeps its box', (tester) async {
      await pump(tester, HistoryRowStatus.normal);
      final v = tester.widget<Visibility>(find
          .ancestor(of: find.text('正常'), matching: find.byType(Visibility))
          .first);
      expect(v.visible, isFalse);
      expect(v.maintainSize, isTrue,
          reason: 'Q2 was ruled 保留空位 — dropping this re-opens the ruling');
      expect(tester.getSize(find.text('正常')).width, greaterThan(0),
          reason: 'a reclaimed box would not lay the label out at all');
    });

    testWidgets('a normal row and a warning row lay out identically',
        (tester) async {
      // The point of 保留空位: rows with and without a drawn badge must not wrap
      // their sub-line differently.
      //
      // The badge's own Text is the anchor rather than its Container: the
      // hidden badge carries two extra wrappers, and `find.ancestor` does not
      // order the two trees' Containers the same way, so `.first` silently
      // resolved to the 800×600 root on one side. Both labels are two zh
      // characters in the same style ⇒ identical rects iff the row laid the
      // text column out to the same width on both sides.
      await pump(tester, HistoryRowStatus.normal);
      final hidden = tester.getRect(find.text('正常'));
      await pump(tester, HistoryRowStatus.warning);
      final shown = tester.getRect(find.text('警告'));
      expect(hidden, shown);
    });
  });

  group('a badge nobody can see is not announced', () {
    testWidgets('normal exposes no semantics label', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, HistoryRowStatus.normal);
      expect(announced(tester), isNot(contains('正常')));
      handle.dispose();
    });

    testWidgets('warning still does', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, HistoryRowStatus.warning);
      expect(announced(tester), contains('警告'));
      handle.dispose();
    });
  });

  // design 0090 §3.2 — a row with neither SOH nor current has nothing else to
  // put in its sub-line, so `_subLine` falls back to the word 正常. That is the
  // sub-line's CONTENT, not a status mark: it is muted like every other
  // sub-line and it must survive FB-104 untouched. ⛔ Do not "finish the job"
  // by removing it — that leaves those rows with a blank second line, which is
  // what a broken row looks like.
  testWidgets('the sub-line fallback word survives, unbadged', (tester) async {
    await pump(tester, HistoryRowStatus.normal, bare: true);
    expect(find.text('正常'), findsNWidgets(2),
        reason: 'one is the sub-line fallback, one is the hidden badge');
    // The badge half is still the hidden one.
    expect(
        tester
            .widgetList<Visibility>(find.byType(Visibility))
            .where((v) => !v.visible)
            .length,
        1);
  });
}
