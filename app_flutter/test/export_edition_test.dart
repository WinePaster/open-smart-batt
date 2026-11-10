// The export preamble names which edition wrote the file (2026-11-10).
//
// Community and OSB Pro share one version scheme, one filename prefix and the
// whole preamble, so a pro capture from the dealer and a community capture
// were told apart only by the brand inside the title — and the title has been
// wrong before (FB-109: every 0.7.41 export reads `$appName history export`).
// The corpus ingest keys on this line; these tests pin the shape it relies on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/config/app_config.dart' show AppEdition;
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  List<String> header(AppEdition edition) => exportHeaderLines(
        title: 'OSB Pro diagnostic log',
        exportedAt: DateTime.utc(2026, 11, 10, 9, 30),
        appBuild: '0.7.51+26111000',
        // Spaces on purpose: `platform:` runs to end of line, which is why the
        // edition cannot ride on the `app:` line.
        platform: 'ios Version 26.6.1 (Build 23G93)',
        edition: edition,
        scope: 'device=battery/1206',
        layout: 'face=standard modules=gaugeVoltage',
        home: 'tiles=auto',
        mode: AppMode.personal,
        themeMode: AppThemeMode.light,
        accent: AccentTheme.amber,
        speedDetection: false,
        gMeter: false,
        resolution: ExportResolution.none,
        devices: const [],
      );

  test('each edition writes its own machine-stable value', () {
    expect(header(AppEdition.community), contains('edition: community'));
    expect(header(AppEdition.pro), contains('edition: pro'));
  });

  test('emitted for community too, exactly once (FB-32 rule)', () {
    for (final e in AppEdition.values) {
      final lines = header(e).where((l) => l.startsWith('edition:')).toList();
      expect(lines, ['edition: ${e.name}']);
    }
  });

  test('its own line, right after `app:`; the fixed four-line head is intact',
      () {
    final h = header(AppEdition.pro);
    expect(h[0], 'OSB Pro diagnostic log');
    expect(h[1], startsWith('exported: '));
    expect(h[2], startsWith('scope: '));
    expect(h[3], 'app: 0.7.51+26111000  platform: ios Version 26.6.1 (Build 23G93)');
    expect(h[4], 'edition: pro');
  });

  test('every lib/ call site passes the edition read from AppConfigScope', () {
    // Same shape as FB-109's caller sweep: the list comes from `lib/`, so a
    // new export surface is covered the day it is written. Hard-coding
    // `AppEdition.community` at a shared call site would compile and would
    // stamp every OSB Pro export as community.
    final grep = Process.runSync('grep', ['-rn', 'exportHeaderLines(', 'lib/']);
    final callers = (grep.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .map((l) => l.split(':'))
        // `path:line:source`. A doc comment that names the function is not a
        // call to it.
        .where((p) => !p.sublist(2).join(':').trimLeft().startsWith('//'))
        .map((p) => p.first)
        .where((f) => !f.endsWith('export_header.dart'))
        .toSet();
    // Same pair FB-109's sweep pins; a third surface must be added to both.
    expect(callers, {
      'lib/ui/util/history_csv_export.dart',
      'lib/ui/settings/settings_screen.dart',
    });
    expect(callers, isNotEmpty);
    for (final f in callers) {
      final src = File(f).readAsStringSync();
      expect(src, isNot(contains('edition: AppEdition.')), reason: f);
      expect(src, contains('AppConfigScope.of(context).edition'), reason: f);
    }
  });
}
