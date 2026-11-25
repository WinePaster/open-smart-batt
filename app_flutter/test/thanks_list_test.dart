// pro design 0109 — Settings → About → 感謝名單.
//
// WHAT THIS PINS. The names never live in this repository (owner ruling
// 2026-11-25: a rider who asks to be taken off could not be once git has
// them). They arrive as a build-time asset; these tests use an in-memory
// bundle, and the names below are fixtures, not the list.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/theme/app_theme.dart';
import 'package:open_smart_batt/ui/settings/thanks_list.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final s = files[key];
    if (s == null) throw FlutterError('missing $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(s)));
  }
}

const _json = '{"as_of":"2026-11-25","entries":[["A1",3],["Bee",1],["測試",12]]}';

Widget _app(Widget child, AssetBundle bundle) => DefaultAssetBundle(
      bundle: bundle,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('parse', () {
    test('keeps the file order and the counts', () {
      final l = ThanksList.parse(_json)!;
      expect(l.asOf, '2026-11-25');
      expect(l.entries.map((e) => e.name), ['A1', 'Bee', '測試']);
      expect(l.entries.map((e) => e.reports), [3, 1, 12]);
    });

    test('anything off-shape is no list, never a partial one', () {
      for (final bad in [
        '',
        'not json',
        '[]',
        '{"as_of":"2026-11-25","entries":[]}',
        '{"entries":[["A",1]]}',
        '{"as_of":"2026-11-25","entries":[["A"]]}',
        '{"as_of":"2026-11-25","entries":[["A",0]]}',
        '{"as_of":"2026-11-25","entries":[["  ",2]]}',
        '{"as_of":"2026-11-25","entries":[["A","2"]]}',
      ]) {
        expect(ThanksList.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('the About row', () {
    testWidgets('no asset (a build from source) ⇒ no row at all', (t) async {
      await t.pumpWidget(_app(const ThanksListRow(), _Bundle({})));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-thanks')), findsNothing);
      expect(find.text('感謝名單'), findsNothing);
    });

    testWidgets('with the asset ⇒ row with the rider count, opens the page',
        (t) async {
      await t.pumpWidget(
          _app(const ThanksListRow(), _Bundle({kThanksListAsset: _json})));
      await t.pumpAndSettle();
      expect(find.text('感謝名單'), findsOneWidget);
      expect(find.text('3 位車友'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('settings-thanks')));
      await t.pumpAndSettle();
      expect(find.byType(ThanksListPage), findsOneWidget);
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('12 次'), findsOneWidget);
      expect(find.textContaining('在 RCE Battery 結束營業的那一天'), findsOneWidget);
      await t.scrollUntilVisible(find.textContaining('回報次數統計至 2026-11-25'), 200);
      expect(find.textContaining('回報次數統計至 2026-11-25'), findsOneWidget);
    });
  });

  test('the list file is gitignored, not tracked', () {
    // The one property the whole design rests on.
    final ignore = File('../.gitignore').readAsStringSync();
    expect(ignore, contains('app_flutter/assets/credits/thanks.json'));
  });
}
