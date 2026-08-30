// design 0092 — 品牌字串抽成可注入的 AppConfig（design 0003 Phase 2）。
//
// WHY THIS EXISTS. Pro is getting its own installed identity
// (`com.winepaster.openSmartBattPro`, home-screen label `OSB Pro`), and pro's
// `app_flutter/` is a WHOLESALE MIRROR of this repo — it is replaced in one
// copy, not merged. So every brand string pro needs to differ in has exactly
// two possible homes: a patch pro re-applies by hand after each sync, or an
// injected value both editions share. The 22 brand strings live in files this
// repo touches 277 times a month (`app_zh.arb`/`app_en.arb` 101 each,
// `settings_screen.dart` 42, `main.dart` 32), so the patch answer means
// re-doing 22 edits every month, forever. Hence injection.
//
// 🔴 WHAT THESE TESTS ARE FOR, precisely: the extraction must be BEHAVIOUR
// NEUTRAL for the open build. Every assertion below on [AppConfig.open] is a
// pre-extraction literal copied from the source it came out of. If somebody
// later "tidies" one of those defaults, this file is what turns red — the app
// would otherwise start calling itself something else with no test noticing.
//
// ⛔ What they do NOT cover: whether the strings READ well on a real screen.
// Design 0092 §5 T6 says so plainly — the only real acceptance for that案 is two
// apps installed side by side on one phone, and no test can stand in for it.
//
// CLEAN-ROOM: every expectation derives from this project's own source.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/l10n/app_localizations_en.dart';
import 'package:open_smart_batt/l10n/app_localizations_zh.dart';

void main() {
  group('T1 — the open build says exactly what it said before the extraction',
      () {
    // Each literal here was read out of the file named in the comment, at the
    // commit before design 0092 touched it. They are the whole point: an
    // injected default that drifts is a rebrand nobody asked for.
    test('AppConfig.open is unchanged, field by field', () {
      // was `title: 'OpenSmartBatt'` — main.dart:313, startup_failure.dart:35
      expect(AppConfig.open.appName, 'OpenSmartBatt');
      // the open build is the community edition; "社群版" / "Community Edition"
      expect(AppConfig.open.edition, AppEdition.community);
      // was `const String kProjectUrl = …` — main.dart:28
      expect(
        AppConfig.open.projectUrl,
        'https://github.com/WinePaster/open-smart-batt',
      );
      // was `static const String _repo = …` — update_service.dart:44
      expect(AppConfig.open.updateRepo, 'WinePaster/open-smart-batt');
    });

    test('the open build still has a release channel', () {
      // The null case is pro's (design 0092 §8.1). If this ever goes null on
      // the open build, the "檢查更新" row silently disappears for everyone.
      expect(AppConfig.open.updateRepo, isNotNull);
    });
  });

  group('T1b — AppConfigScope falls back rather than throwing', () {
    // This is why it is an InheritedWidget and not a Provider: ~168 test files
    // pump a single screen with no composition root above it. A lookup that
    // threw would have made every one of them a design-0092 edit.
    testWidgets('no scope in the tree ⇒ the open branding', (tester) async {
      late AppConfig seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = AppConfigScope.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, same(AppConfig.open));
    });

    testWidgets('a scope in the tree ⇒ that branding', (tester) async {
      const pro = AppConfig(
        appName: 'OSB Pro',
        edition: AppEdition.pro,
        projectUrl: 'https://example.invalid/pro',
        updateRepo: null,
      );
      late AppConfig seen;
      await tester.pumpWidget(
        AppConfigScope(
          config: pro,
          child: Builder(
            builder: (context) {
              seen = AppConfigScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen.appName, 'OSB Pro');
      expect(seen.edition, AppEdition.pro);
      expect(seen.updateRepo, isNull);
    });
  });

  group('T2 — the six name-only strings render the injected name', () {
    final en = AppLocalizationsEn();
    final zh = AppLocalizationsZh();

    test('English keeps its exact pre-extraction wording', () {
      expect(en.historyExportSubject('OpenSmartBatt'), 'OpenSmartBatt History');
      expect(
        en.monitorNotificationTitle('OpenSmartBatt'),
        'OpenSmartBatt · monitoring',
      );
      expect(
        en.monitorNotificationTitleConnecting('OpenSmartBatt'),
        'OpenSmartBatt · connecting…',
      );
      expect(
        en.monitorNotificationTitleStalled('OpenSmartBatt'),
        'OpenSmartBatt · no data',
      );
      expect(
        en.settingsExportSubjectAllData('OpenSmartBatt'),
        'OpenSmartBatt all data',
      );
      expect(
        en.settingsExportSubjectDiagLog('OpenSmartBatt'),
        'OpenSmartBatt diagnostic log',
      );
    });

    test('Chinese keeps its exact pre-extraction wording', () {
      expect(zh.historyExportSubject('OpenSmartBatt'), 'OpenSmartBatt 歷史紀錄');
      expect(
        zh.monitorNotificationTitle('OpenSmartBatt'),
        'OpenSmartBatt · 監看中',
      );
      expect(
        zh.monitorNotificationTitleConnecting('OpenSmartBatt'),
        'OpenSmartBatt · 連線中…',
      );
      expect(
        zh.monitorNotificationTitleStalled('OpenSmartBatt'),
        'OpenSmartBatt · 無資料',
      );
      expect(
        zh.settingsExportSubjectAllData('OpenSmartBatt'),
        'OpenSmartBatt 全部資料',
      );
      expect(
        zh.settingsExportSubjectDiagLog('OpenSmartBatt'),
        'OpenSmartBatt 診斷日誌',
      );
    });

    test('a pro name substitutes cleanly — no stray original left behind', () {
      for (final s in <String>[
        en.historyExportSubject('OSB Pro'),
        en.monitorNotificationTitle('OSB Pro'),
        en.monitorNotificationTitleConnecting('OSB Pro'),
        en.monitorNotificationTitleStalled('OSB Pro'),
        en.settingsExportSubjectAllData('OSB Pro'),
        en.settingsExportSubjectDiagLog('OSB Pro'),
        zh.historyExportSubject('OSB Pro'),
        zh.monitorNotificationTitle('OSB Pro'),
        zh.monitorNotificationTitleConnecting('OSB Pro'),
        zh.monitorNotificationTitleStalled('OSB Pro'),
        zh.settingsExportSubjectAllData('OSB Pro'),
        zh.settingsExportSubjectDiagLog('OSB Pro'),
      ]) {
        expect(s, contains('OSB Pro'));
        expect(s, isNot(contains('OpenSmartBatt')));
      }
    });
  });

  group('T3 — the version line is the one that was WRONG on a pro build', () {
    final en = AppLocalizationsEn();
    final zh = AppLocalizationsZh();

    // 🔑 The other six only had to swap a name. This one asserted an EDITION:
    // "OpenSmartBatt 社群版" on a build that is not the community edition is
    // a false statement, not a stale name.
    test('community reproduces the pre-extraction line exactly', () {
      expect(
        zh.settingsVersionSub('OpenSmartBatt', AppEdition.community.label(zh)),
        'OpenSmartBatt 社群版',
      );
      expect(
        en.settingsVersionSub('OpenSmartBatt', AppEdition.community.label(en)),
        'OpenSmartBatt Community Edition',
      );
    });

    test('pro says pro, in both languages', () {
      expect(
        zh.settingsVersionSub('OSB Pro', AppEdition.pro.label(zh)),
        'OSB Pro 專業版',
      );
      expect(
        en.settingsVersionSub('OSB Pro', AppEdition.pro.label(en)),
        'OSB Pro Pro',
      );
      expect(AppEdition.pro.label(zh), isNot(contains('社群')));
      expect(AppEdition.pro.label(en), isNot(contains('Community')));
    });
  });

  group('T4 — the brand strings cannot quietly come back hard-coded', () {
    // The failure this guards is specific and WILL be attempted: pro's
    // app_flutter is replaced wholesale from this repo, so a brand string
    // re-hard-coded here silently un-does design 0092 on the pro side, and
    // nothing on the pro side would report it.
    const brand = 'OpenSmartBatt';

    test('neither .arb still carries the brand name', () {
      for (final f in ['lib/l10n/app_en.arb', 'lib/l10n/app_zh.arb']) {
        expect(
          File(f).readAsStringSync(),
          isNot(contains(brand)),
          reason: '$f re-introduced a hard-coded brand string — '
              'inject it via AppConfig.appName instead (design 0092 §3.4)',
        );
      }
    });

    test('the four extracted call sites hold no brand literal', () {
      // Two things here are deliberate and were both learned the hard way:
      //   * `[^'\n]` — an apostrophe in prose ("the app's name") pairs with a
      //     later one across many lines and swallows real code in between,
      //     which is how this matcher first "found" `OpenSmartBattApp`.
      //   * matching only INSIDE quotes — `OpenSmartBattApp` is the root
      //     widget's class name, a Dart identifier, and renaming it is not
      //     what design 0092 is about.
      final literal = RegExp("'[^'\n]*\$brand[^'\n]*'");
      for (final f in [
        'lib/main.dart',
        'lib/ui/startup_failure.dart',
        'lib/ui/settings/settings_screen.dart',
        'lib/data/update_service.dart',
      ]) {
        expect(
          literal.hasMatch(File(f).readAsStringSync()),
          isFalse,
          reason: '$f has a hard-coded brand string literal again '
              '(design 0092 §3.3)',
        );
      }
    });

    test('the only place the open name is written is AppConfig.open', () {
      final src = File('lib/config/app_config.dart').readAsStringSync();
      expect(src, contains("appName: 'OpenSmartBatt'"));
    });
  });
}
