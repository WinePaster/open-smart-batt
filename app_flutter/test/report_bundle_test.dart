// design 0100 P1 — the report bundle's zip, against a real temp directory.
//
// What a recipient (and `fbparse`, after unzipping) depends on: the members
// keep their stand-alone names and bytes, the note is its own file and only
// when written, and a stale bundle of the same name is replaced, not appended.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/config/app_config.dart';
import 'package:open_smart_batt/ui/util/export_scope.dart';
import 'package:open_smart_batt/ui/util/report_bundle.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('osb_report_'));
  tearDown(() async => dir.delete(recursive: true));

  Map<String, List<int>> unzip(File zip) => {
        for (final f in ZipDecoder().decodeBytes(zip.readAsBytesSync()))
          if (f.isFile) f.name: f.content as List<int>,
      };

  String note(String text) => reportNoteText(
        note: text,
        appName: 'OpenSmartBatt',
        appBuild: '0.7.51+26111035',
        platform: 'ios 18.1',
        edition: AppEdition.community,
        scope: 'device=battery/016801020001261',
        at: DateTime.utc(2026, 11, 10, 9),
      )!;

  group('reportNoteText', () {
    test('blank or whitespace-only ⇒ null (no empty note.txt)', () {
      for (final blank in ['', '   ', '\n\t ']) {
        expect(
          reportNoteText(
            note: blank,
            appName: 'x',
            appBuild: 'x',
            platform: 'x',
            edition: AppEdition.pro,
            scope: 'x',
            at: DateTime(2026),
          ),
          isNull,
          reason: '"$blank"',
        );
      }
    });

    test('preamble names build, edition, instant and scope; body verbatim', () {
      final t = note('  車子發不動，\n早上 7 點  ');
      final lines = t.split('\n');
      expect(lines.take(5), [
        '# OpenSmartBatt problem report',
        '# app: 0.7.51+26111035  platform: ios 18.1',
        '# edition: community',
        '# exported: 2026-11-10T09:00:00.000Z',
        '# scope: device=battery/016801020001261',
      ]);
      expect(lines[5], '', reason: 'a blank line before the user text');
      // Trimmed at the ends only; the user's own line breaks survive.
      expect(t.substring(t.indexOf('\n\n') + 2), '車子發不動，\n早上 7 點\n');
    });
  });

  group('writeReportBundle', () {
    test('members keep their names and bytes; note.txt when given', () async {
      final csv = File('${dir.path}/a.csv')..writeAsStringSync('# h\nt,v\n1,2\n');
      final log = File('${dir.path}/a.log')
        ..writeAsBytesSync(utf8.encode('# 診斷\nRX b81001\n'));
      final zip = await writeReportBundle(
        zip: File('${dir.path}/r.zip'),
        members: [
          (file: csv, name: 'opensmartbatt-history-x.csv'),
          (file: log, name: 'opensmartbatt-x.log'),
        ],
        noteText: note('hello'),
      );
      final got = unzip(zip);
      expect(got.keys.toSet(), {
        'opensmartbatt-history-x.csv',
        'opensmartbatt-x.log',
        kReportNoteFileName,
      });
      expect(got['opensmartbatt-history-x.csv'], csv.readAsBytesSync());
      expect(got['opensmartbatt-x.log'], log.readAsBytesSync());
      expect(utf8.decode(got[kReportNoteFileName]!), note('hello'));
    });

    test('no note ⇒ no note.txt', () async {
      final csv = File('${dir.path}/a.csv')..writeAsStringSync('x');
      final zip = await writeReportBundle(
        zip: File('${dir.path}/r.zip'),
        members: [(file: csv, name: 'a.csv')],
      );
      expect(unzip(zip).keys, ['a.csv']);
    });

    test('a note alone is a valid bundle', () async {
      final zip = await writeReportBundle(
        zip: File('${dir.path}/r.zip'),
        members: const [],
        noteText: note('it will not connect'),
      );
      expect(unzip(zip).keys, [kReportNoteFileName]);
    });

    test('an existing file of the same name is replaced, not appended to',
        () async {
      final target = File('${dir.path}/r.zip');
      final a = File('${dir.path}/a.csv')..writeAsStringSync('a');
      final b = File('${dir.path}/b.csv')..writeAsStringSync('b');
      await writeReportBundle(zip: target, members: [(file: a, name: 'a.csv')]);
      await writeReportBundle(zip: target, members: [(file: b, name: 'b.csv')]);
      expect(unzip(target).keys, ['b.csv']);
    });
  });

  test('bundle filename follows the export naming scheme', () {
    const t = ExportTarget(
      scope: ExportScope.currentDevice,
      deviceId: 'D',
      classSlug: 'battery',
      ident: '016801020001261',
    );
    expect(reportBundleFileName(t, stamp: '20261110-090000'),
        'opensmartbatt-report-battery-016801020001261-20261110-090000.zip');
  });
}
