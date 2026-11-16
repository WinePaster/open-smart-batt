// The diagnostic log export, streamed page by page (realme 9 Pro+,
// 2026-11-16: a log near the 100 MiB cap built as one string hung the export
// and Android killed the app).
//
// What must not change is the text: every page size has to produce the file
// the old one-query join produced, section separators across page boundaries
// included.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late LogRepo logs;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    logs = LogRepo(db.db);
    // Two units, three connections, an unattributed scan line, and two marks —
    // so separators and the preamble's counts all have something to say.
    await logs.insertLog(LogEntry.event('scan done: 2 device(s)'));
    for (var i = 0; i < 23; i++) {
      final dev = i < 9 ? 'AA' : (i < 17 ? 'BB' : 'AA');
      final session = i < 9 ? 1 : (i < 17 ? 2 : 3);
      await logs.insertLog(LogEntry.event(
          i == 4 ? 'mark: pack_idle | idle' : 'line $i',
          deviceId: dev,
          sessionId: session));
    }
    await logs.insertLog(LogEntry.event('mark: pack_load | load',
        deviceId: 'BB', sessionId: 2));
  });
  tearDown(() async => db.close());

  for (final header in [const <String>[], const ['scope: all']]) {
    test('every page size writes the same text (header: ${header.isNotEmpty})',
        () async {
      final whole = await logs.exportLog(header: header);
      for (final pageRows in [1, 2, 5, 9, 25, 26, 1000]) {
        final buf = StringBuffer();
        final lines =
            await logs.exportLogTo(buf, header: header, pageRows: pageRows);
        expect(buf.toString(), whole, reason: 'pageRows=$pageRows');
        expect(lines, whole.split('\n').length);
      }
    });
  }

  test('the preamble counts the scope, not the page', () async {
    final buf = StringBuffer();
    await logs.exportLogTo(buf,
        deviceId: 'AA', header: const ['scope: AA'], pageRows: 3);
    final out = buf.toString();
    expect(out, contains('# rows: 15'));
    expect(out, contains('# marks: 1 (pack_idle)'));
    expect(out.split('\n').where((l) => l.startsWith('# ---- ')),
        hasLength(2), reason: 'sessions 1 and 3');
  });

  test('a session scope pages too', () async {
    final whole = await logs.exportLog(deviceId: 'BB', sessionId: 2);
    final buf = StringBuffer();
    await logs.exportLogTo(buf, deviceId: 'BB', sessionId: 2, pageRows: 2);
    expect(buf.toString(), whole);
    expect(whole, contains('mark: pack_load'));
  });

  test('an empty scope writes nothing and says 0', () async {
    final buf = StringBuffer();
    expect(await logs.exportLogTo(buf, deviceId: 'ZZ'), 0);
    expect(buf.toString(), isEmpty);
  });

  test('into a file: identical bytes, flushed page by page', () async {
    final dir = Directory.systemTemp.createTempSync('osb_log_stream');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/out.log');
    final sink = file.openWrite();
    final lines = await logs.exportLogTo(sink,
        header: const ['scope: all'], pageRows: 4);
    await sink.close();
    final whole = await logs.exportLog(header: const ['scope: all']);
    expect(file.readAsStringSync(), whole);
    expect(lines, whole.split('\n').length);
  });
}
