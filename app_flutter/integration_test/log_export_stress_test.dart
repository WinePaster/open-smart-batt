// On-device stress check for the diagnostic-log export (realme 9 Pro+,
// 2026-11-16: exporting a near-cap log spun and Android killed the app).
//
// Fills a real (platform sqflite) database to about the 100 MiB default cap
// with field-shaped rows, then times the streamed export and the report-bundle
// zip while a 16 ms timer measures how long the UI isolate was blocked.
// Results are printed as `STRESS …` lines.
//
//   flutter test integration_test/log_export_stress_test.dart -d <device>
//
// 2026-11-16, osb-play emulator (API 35, 2 GB, heap growth limit 192 MB),
// debug build: export 1,600,068 lines / 76.3 MiB in 8.4 s, max UI block 55 ms,
// zip 1.4 s. The pre-b5c3b04 one-query export on the same rows died with
// java.lang.OutOfMemoryError on the Sqflite thread (FATAL EXCEPTION) — the
// field report's "停止運作".
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ui/util/report_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// ~66 B of rotation budget per row (26-char hex average + 40 overhead), so
/// this is the 100 MiB cap's worth of rows — what a phone logging all day
/// reaches in about a week.
const int stressRows = 1600000;

Future<String> stressDbPath() async =>
    p.join(await getDatabasesPath(), 'osb_export_stress.db');

/// Max gap between 16 ms ticks while [body] runs, i.e. the longest the event
/// loop (and so the UI) was blocked.
Future<({T value, Duration elapsed, Duration maxGap})> measure<T>(
    Future<T> Function() body) async {
  final sw = Stopwatch()..start();
  var last = sw.elapsed;
  var maxGap = Duration.zero;
  final t = Timer.periodic(const Duration(milliseconds: 16), (_) {
    final now = sw.elapsed;
    final gap = now - last;
    if (gap > maxGap) maxGap = gap;
    last = now;
  });
  final value = await body();
  t.cancel();
  final tail = sw.elapsed - last;
  if (tail > maxGap) maxGap = tail;
  return (value: value, elapsed: sw.elapsed, maxGap: maxGap);
}

String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('streamed export of a 100 MiB log', (tester) async {
    await tester.runAsync(() async {
      final path = await stressDbPath();
      await deleteDatabase(path);
      final appDb = await AppDatabase.open(path: path);
      final db = appDb.db;

      final fill = await measure(() async {
        const chunk = 20000;
        final t0 = DateTime.utc(2026, 11, 10).millisecondsSinceEpoch;
        for (var base = 0; base < stressRows; base += chunk) {
          await db.transaction((txn) async {
            final b = txn.batch();
            for (var i = base; i < base + chunk && i < stressRows; i++) {
              final session = i ~/ 50000;
              final rx = i.isEven;
              b.insert(Db.tableDiagLog, {
                'timestamp': t0 + i * 120,
                'direction': rx ? 'rx' : 'tx',
                'hex': rx
                    ? 'aa55${(i & 0xffff).toRadixString(16).padLeft(4, '0')}'
                        '0d02000b0201f40000000000000000000000'.substring(0, 32)
                    : 'aa5503010c0e5d00'.substring(0, 12),
                'note': i % 997 == 0 ? 'link: ready' : null,
                'device_id': session.isEven ? 'AA:BB:CC:DD:EE:01' : 'AA:BB:CC:DD:EE:02',
                'session_id': session,
                'app_build': '0.7.51+26111593',
              });
            }
            await b.commit(noResult: true);
          });
        }
      });
      final logs = LogRepo(db);
      final approx = await logs.approxBytes();
      // ignore: avoid_print
      print('STRESS fill rows=$stressRows approx=${mb(approx)}MiB '
          'in ${fill.elapsed.inSeconds}s');

      final dir = await Directory.systemTemp.createTemp('osb_stress');
      final file = File(p.join(dir.path, 'diag.log'));
      final rssBefore = ProcessInfo.currentRss;
      final exp = await measure(() async {
        final sink = file.openWrite();
        try {
          return await logs.exportLogTo(sink, header: const ['scope: all']);
        } finally {
          await sink.close();
        }
      });
      // ignore: avoid_print
      print('STRESS export lines=${exp.value} file=${mb(file.lengthSync())}MiB '
          'in ${exp.elapsed.inMilliseconds}ms maxGap=${exp.maxGap.inMilliseconds}ms '
          'rss ${mb(rssBefore)}→${mb(ProcessInfo.currentRss)}MiB '
          'maxRss=${mb(ProcessInfo.maxRss)}MiB');

      final zipFile = File(p.join(dir.path, 'report.zip'));
      final zip = await measure(() => writeReportBundle(
          zip: zipFile, members: [(file: file, name: 'diag.log')],
          noteText: 'stress'));
      // ignore: avoid_print
      print('STRESS zip file=${mb(zipFile.lengthSync())}MiB '
          'in ${zip.elapsed.inMilliseconds}ms maxGap=${zip.maxGap.inMilliseconds}ms '
          'maxRss=${mb(ProcessInfo.maxRss)}MiB');

      expect(exp.value, greaterThan(stressRows));
      await appDb.close();
      await dir.delete(recursive: true);
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
