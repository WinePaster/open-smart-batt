// FB-108 (2026-09-02, 經銷商何先生) — the way into the landscape chart has to
// be FINDABLE, not merely present.
//
// Verbatim report: 「關於我們曲線圖的 全螢幕icon的辨識度有點低 user不好理解那是
// 全螢幕」. What shipped up to `v0.7.40` was a 16 px `Icons.open_in_full` drawn
// in `muted`, at the right end of a 10 px `muted` footnote row, explained only
// by a tooltip — and it is the ONLY route to the page (design 0081 Q1 = E2).
//
// 🔴 **The fourth time this project has shipped an entry nobody could see**:
// FB-70 (a 14×14 rename pencil) → FB-103 (an unlabelled ⇅) → FB-107 (the same
// ⇅ again, fixed with a word) → this one. Three defects at once, all fixed
// here: no word, the wrong glyph (`open_in_full` is a diagonal "expand"; full
// screen is the four-corner `Icons.fullscreen`, which this app ALREADY spends
// on the home tab), and the lowest visual weight on the card.
//
// ⚠️ **What these tests can and cannot prove.** They pin that the word is in
// the tree, inside the tap target, that the glyph is the same one the home tab
// uses, that the footnote stays centred once the button has a variable width,
// and that a 320 dp phone still lays the row out. They CANNOT prove it reads
// as a control on a real phone — the defect being fixed is a visibility
// defect, and no widget test has ever been able to see. Real-device acceptance
// is owed, and FB-107 exists precisely because the previous round of this same
// problem shipped without it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/l10n/app_localizations_zh.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/history/history_screen.dart';
import 'package:open_smart_batt/ui/widgets/industrial_card.dart';

import 'support/series_host.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();
  final t0 = DateTime(2026, 9, 2, 10, 0);

  List<HistoryBucket> run() => [
        for (var i = 0; i < 6; i++)
          HistoryBucket(
            at: t0.add(Duration(minutes: i)),
            avgPvlt: 13.2 + i * 0.01,
            minPvlt: 13.1,
            maxPvlt: 13.3,
            avgAmpere: -3.0 + i,
            minAmpere: -4.0 + i,
            maxAmpere: -2.0 + i,
            count: 60,
          ),
      ];

  Widget host({VoidCallback? onExpand, String locale = 'en'}) => MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale(locale),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeriesHost(
              cls: ProductClass.smartBattery,
              child: (series, onChanged) => HistoryTrendCard(
                buckets: run(),
                stats: HistoryStats.empty,
                tempUnit: TempUnit.celsius,
                multiDay: false,
                bucketMs: 60000,
                deviceClass: ProductClass.smartBattery,
                series: series,
                onSeriesChanged: onChanged,
                onExpand: onExpand,
              ),
            ),
          ),
        ),
      );

  group('FB-108 — the door says what it is', () {
    testWidgets('the button carries the word AND the four-corner glyph',
        (t) async {
      await t.pumpWidget(host(onExpand: () {}));
      await t.pump();

      expect(find.text(en.historyChartExpand), findsOneWidget,
          reason: 'a tooltip is not a label — it needs a long-press first');
      expect(find.byIcon(Icons.fullscreen), findsOneWidget,
          reason: 'the word JOINS the glyph, it does not replace it');
      expect(find.byIcon(Icons.open_in_full), findsNothing,
          reason: 'one concept, one glyph — the home tab already picked it');
    });

    testWidgets('the word is INSIDE the tap target, which clears 40x40',
        (t) async {
      // 🔑 A label that is not part of the button is a caption, and a caption
      // makes nothing pressable. FB-70's floor is asserted on the SAME widget
      // the tap lands on, not on some ancestor that happens to be big.
      var opened = 0;
      await t.pumpWidget(host(onExpand: () => opened++));
      await t.pump();

      final target = find
          .ancestor(
            of: find.text(en.historyChartExpand),
            matching: find.byType(InkWell),
          )
          .first;
      final size = t.getSize(target);
      expect(size.width, greaterThanOrEqualTo(40));
      expect(size.height, greaterThanOrEqualTo(40));

      await t.tap(find.text(en.historyChartExpand));
      await t.pump();
      expect(opened, 1, reason: 'pressing the WORD has to open the page');
    });

    testWidgets('the footnote stays centred on the card, in both languages',
        (t) async {
      // 🔴 This is what the MEASURED spacer on the left of the row buys, and
      // why it is not a hard-coded width: the button is now as wide as its
      // label, which differs per locale and per text scale. A fixed 40 px
      // spacer was right when the button was a bare 40 px icon and would be
      // wrong the moment it grew a word — off by 55 px in English, by a
      // different amount in Chinese.
      for (final locale in ['en', 'zh']) {
        await t.pumpWidget(host(onExpand: () {}, locale: locale));
        await t.pump();
        final l10n = locale == 'en' ? en : zh;
        final note = find.text(historyBucketWidthNote(l10n, 60000));
        expect(note, findsOneWidget);
        expect(
          t.getCenter(note).dx,
          closeTo(t.getCenter(find.byType(IndustrialCard).first).dx, 0.5),
          reason: 'the sentence is centred on the CARD, not on what is left '
              'of it after a $locale-width button',
        );
      }
    });

    testWidgets('no data to zoom into ⇒ no door, and the row still lays out',
        (t) async {
      // 🔑 Both ends of the row keep the SAME reserved box when the button is
      // gone, so the sentence does not jump sideways between a card that can
      // be expanded and one that cannot.
      await t.pumpWidget(host());
      await t.pump();
      expect(find.text(en.historyChartExpand), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(
        t.getCenter(find.text(historyBucketWidthNote(en, 60000))).dx,
        closeTo(t.getCenter(find.byType(IndustrialCard).first).dx, 0.5),
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('a 320 dp phone still lays the footnote row out', (t) async {
      // 🔴 The word is not free: the footnote's `Expanded` loses whatever the
      // button gains, on the narrowest phone this app targets, with the LONGER
      // of the two labels ("Full screen" vs 「全螢幕」).
      //
      // ⚠️ The sentence WRAPS rather than overflowing — that `Text` has no
      // `maxLines`, which is exactly why design 0081 rejected the two-`Spacer`
      // layout that overflowed by 20 px. What must never regress is the row
      // laying out at all.
      t.view.physicalSize = const Size(320, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(host(onExpand: () {}));
      await t.pump();
      expect(t.takeException(), isNull, reason: 'no overflow at 320 dp');
      expect(find.text(en.historyChartExpand), findsOneWidget);
      expect(find.text(historyBucketWidthNote(en, 60000)), findsOneWidget);
    });

    testWidgets('the two full-screen entries say the same word', (t) async {
      // 🔵 FB-108's third half: the reporter called it 「全螢幕」, and that was
      // already this app's word for the home tab's immersive mode — while the
      // chart's button said 「放大檢視」 / "Expand chart". One idea must not have
      // two names inside one app.
      //
      // ⛔ The two keys stay separate on purpose (two different actions that
      // share a name); this pins that they keep AGREEING, which is the part a
      // future edit can silently break.
      expect(en.historyChartExpand, en.fullscreenEnter);
      expect(zh.historyChartExpand, zh.fullscreenEnter);
      expect(zh.historyChartExpand, '全螢幕');
    });
  });
}
