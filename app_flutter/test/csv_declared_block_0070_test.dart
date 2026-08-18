// design 0070 — the history CSV carries the same identity block as the log.
//
// The defect: `exportHeaderLines()` takes `devices` with a `const []` default,
// and BOTH CSV call sites omitted it. So every history CSV ever exported said
// `declared: count=0` and carried no `devices:` block at all, while the
// diagnostic log written seconds later from the same phone said `count=3` and
// named fourteen units. `feedback_log/2026.08.18/008` is one such pair, seven
// minutes apart.
//
// 🔴 Why that is worse than a missing field: `conventions/export-header.md`
// states a READING RULE — "count=0 ⇒ this build has the feature but nobody
// filled one in". On a CSV that rule returned the wrong answer every time,
// because the zero recorded which call site wrote the file, not what any user
// had done.
//
// ⚠️ WHAT THIS FILE CAN AND CANNOT PIN. These are unit tests of
// `exportHeaderLines()`, and the bug was a CALL SITE forgetting an argument —
// no test at this level could have caught it, and none here would catch it
// coming back. That job belongs to design 0070's stage two, which removes the
// default so the type system asks every caller. What IS pinned here is the
// behaviour that stage two protects: given the list, both files say the same
// thing, and neither block can be dropped without the other.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/theme/accent_theme.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';

void main() {
  const declaredUnit = ExportDeviceIdentity(
    deviceId: 'AA:BB:CC:DD:EE:FF',
    serial: '016802170007928',
    classSlug: 'capacitor',
    name: 'RCE-SCAP_II',
    label: '二代電容',
    declared: DeclaredModel(
      category: DeclaredCategory.carCapacitor,
      model: 'gen2',
    ),
  );
  const silentUnit = ExportDeviceIdentity(
    deviceId: '11:22:33:44:55:66',
    classSlug: 'battery',
    name: 'RCE-CarBatt',
  );

  // The only difference between the two files' preambles, once both are given
  // the same list, must be the things that genuinely differ: the title, and the
  // CSV-only `window:`/`ampereColumn`/`resolution` fields.
  List<String> header({
    required String title,
    required List<ExportDeviceIdentity> devices,
    bool csv = true,
  }) =>
      exportHeaderLines(
        title: title,
        exportedAt: DateTime.utc(2026, 8, 18, 20),
        appBuild: '0.7.24+26081786',
        platform: 'ios Version 26.5 (Build 23F77)',
        scope: 'all devices',
        window: csv ? 'all' : null,
        ampereColumn: csv,
        resolution: csv
            ? ExportResolution.forCsv(HistoryGranularity.second, const [1])
            : ExportResolution.none,
        layout: 'face=standard modules=readouts',
        home: 'tiles=readouts@d1',
        mode: AppMode.personal,
        themeMode: AppThemeMode.dark,
        accent: AccentTheme.amber,
        speedDetection: true,
        gMeter: true,
        devices: devices,
      );

  List<String> identityLines(List<String> lines) => lines
      .where((l) =>
          l.startsWith('devices: ') ||
          l.startsWith('  ') ||
          l.startsWith('declared: '))
      .toList();

  group('design 0070: the CSV says what the log says', () {
    test(
        'C1 🔑 given one identity list, both files emit byte-identical '
        'devices:/declared: blocks', () {
      const units = [declaredUnit, silentUnit];
      final csv =
          identityLines(header(title: 'OpenSmartBatt history export', devices: units));
      final log = identityLines(header(
          title: 'OpenSmartBatt diagnostic log', devices: units, csv: false));

      // Whole-list equality on purpose. This is the ONE claim design 0070
      // makes, so it is asserted directly rather than inferred from two
      // separate per-file checks that could drift apart.
      expect(csv, log,
          reason: 'a reporter sending both files must not be handing over two '
              'documents that disagree about which units they describe');
      expect(csv, isNotEmpty,
          reason: 'equality of two empty lists would pass while proving '
              'nothing — that is the shape of the bug being fixed');
    });

    test('C2 a declared unit is counted and named in the CSV', () {
      final lines = header(
          title: 'OpenSmartBatt history export',
          devices: const [declaredUnit, silentUnit]);
      expect(lines, contains('declared: count=1'),
          reason: 'one of the two units carries a declaration');
      final detail =
          lines.where((l) => l.startsWith('declared: hash=')).toList();
      expect(detail, hasLength(1),
          reason: 'detail lines appear only for units actually declared');
      expect(detail.single, contains('category=car-capacitor'));
      expect(detail.single, contains('model=gen2'));
    });

    test('C3 🔴 layout: is still the last line — the ingest anchor', () {
      // The added block sits in the optional middle. `export_header.dart`
      // states the scripts anchor on `layout:` being last, so growing the
      // preamble must not push anything past it.
      final lines = header(
          title: 'OpenSmartBatt history export',
          devices: const [declaredUnit, silentUnit]);
      expect(lines.last, startsWith('layout: '));
    });

    test('C4 with nothing declared the CSV still prints the zero', () {
      // FB-32's standing rule, unchanged by 0070: a block that appeared only
      // when somebody had answered would make its absence mean both "nobody
      // answered" and "an older build wrote this".
      final lines = header(
          title: 'OpenSmartBatt history export', devices: const [silentUnit]);
      expect(lines, contains('declared: count=0'));
      expect(lines.where((l) => l.startsWith('declared: hash=')), isEmpty);
    });

    test(
        'C5 🔑 the two blocks are fed by ONE parameter — neither can be '
        'dropped alone', () {
      // §3.5. `devices:` and `declared:` are both built from `devices`, which
      // is why 0070 could not add one without the other, and why nobody should
      // later "tidy up" the CSV by removing just the device lines: doing so
      // means dropping the list, and the declarations go with it.
      final withList = header(
          title: 'OpenSmartBatt history export', devices: const [declaredUnit]);
      expect(withList, contains('devices: 1'));
      expect(withList, contains('declared: count=1'));

      final without =
          header(title: 'OpenSmartBatt history export', devices: const []);
      expect(without.where((l) => l.startsWith('devices: ')), isEmpty,
          reason: 'no list ⇒ no device block');
      expect(without, contains('declared: count=0'),
          reason: 'but the count line is required and survives — that is '
              'exactly why an empty list read as "nobody declared anything"');
    });
  });
}
