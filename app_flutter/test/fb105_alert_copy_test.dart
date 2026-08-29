/// FB-105 — the two per-platform lines are gone from the alerts copy.
///
/// The defect was not a typo. The sentences described HOW iOS wakes the app
/// ("only during the short windows where the device's data wakes the app"), and
/// a real iOS user (`fb-registry` FB-105) read that and concluded detection was
/// intermittent — so he stopped trusting the feature. It is not intermittent:
/// alerts are evaluated per frame on BOTH platforms (`AlertController` holds no
/// Timer; `TelemetryController._onTelemetry` calls it with no lifecycle gate),
/// and design 0047's Phase 2 field verification measured 65 minutes of
/// background windows with zero missing rows on the very same frame stream.
///
/// 🔴 These are guards, not decoration. The copy is easy to re-add "for
/// honesty", and §6.1's honesty clause forbids OVERCLAIMING — which not
/// writing a sentence already satisfies. What the screen still owes the user is
/// the LIMIT (connected only), which is asserted below as still present.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/ui/alerts/alert_consent_dialog.dart';

/// Package root regardless of the runner's cwd (same helper shape as T11 in
/// `power_path_test.dart`, which guards retired keys the same way).
Directory _packageRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate package root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
}

const _retired = [
  'settingsAlertsLimitsAndroid',
  'settingsAlertsLimitsIos',
  'alertsConsentPointAndroid',
  'alertsConsentPointIos',
];

/// The limit the user actually needs — deleting THIS would be the regression
/// the FB-105 ruling was careful not to cause.
const _kept = [
  'settingsAlertsLimitsBody',
  'alertsConsentPointConnected',
  'alertsConsentPointPermission',
  'alertsConsentPointThresholds',
];

void main() {
  final root = _packageRoot().path;

  test('FB-105 retired keys gone from both .arb, the limit line kept', () {
    for (final f in ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
      final text = File('$root/$f').readAsStringSync();
      for (final k in _retired) {
        expect(text.contains('"$k"'), isFalse, reason: '$k must be gone from $f');
      }
      for (final k in _kept) {
        expect(text.contains('"$k"'), isTrue, reason: '$k must remain in $f');
      }
    }
  });

  test('FB-105 retired keys regenerated out of the localizations', () {
    for (final f in [
      'lib/l10n/app_localizations.dart',
      'lib/l10n/app_localizations_zh.dart',
      'lib/l10n/app_localizations_en.dart',
    ]) {
      final gen = File('$root/$f').readAsStringSync();
      for (final k in _retired) {
        expect(gen.contains(k), isFalse, reason: '$k must be regenerated out of $f');
      }
    }
  });

  test('FB-105 no widget reaches for a per-platform alerts line', () {
    // Source-level, because a getter that no longer exists cannot be caught by
    // a widget test — it would be a compile error in ONE build config and this
    // guard is meant to survive someone re-adding the key.
    final hits = <String>[];
    for (final f in Directory('$root/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') &&
            !f.path.contains('/l10n/'))) {
      final text = f.readAsStringSync();
      for (final k in _retired) {
        // `l10n.<key>` is the only way these were consumed.
        if (text.contains('.$k')) hits.add('${f.path}: $k');
      }
    }
    expect(hits, isEmpty, reason: 'FB-105: per-platform mechanism copy re-added');
  });

  testWidgets('FB-105 consent dialog shows three bullets, none about a platform',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox.shrink());
      }),
    ));

    openConsentDialog(ctx);
    await tester.pumpAndSettle();

    // The bullet glyph is the list's own marker, so counting it counts bullets.
    expect(find.text('· '), findsNWidgets(3));

    // And none of the surviving text names a platform or a wake window.
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    for (final banned in ['Android', 'iPhone', '短暫期間', '喚醒']) {
      expect(texts.contains(banned), isFalse,
          reason: 'FB-105: "$banned" is back in the consent dialog');
    }

    // The limit that must survive.
    expect(texts.contains('斷線之後不會有任何檢查'), isTrue);
  });
}

/// Fire-and-forget the dialog: the test asserts on what it renders, not on the
/// button the user did not press.
void openConsentDialog(BuildContext context) {
  showAlertsConsentDialog(context);
}
