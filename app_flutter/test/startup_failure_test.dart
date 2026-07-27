// Startup resilience: the DB is opened BEFORE runApp(), so a failure there
// used to be a blank screen with no message and no exportable log.
//
// Covers the two failure modes we can actually hit in the field:
//   * a DOWNGRADE (user reinstalls an older APK after running a newer one) —
//     must refuse to touch the data and say so, never wipe it;
//   * any other open/migration failure — must show the error and offer a
//     user-confirmed reset.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/ui/startup_failure.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('downgrade guard', () {
    test('refuses to open a newer schema and keeps the file intact', () async {
      final dir = await Directory.systemTemp.createTemp('osb_downgrade');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'future.db');

      // A database written by a hypothetical later build.
      final future = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: Db.schemaVersion + 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE keepme (id INTEGER PRIMARY KEY)');
            await db.insert('keepme', {'id': 42});
          },
        ),
      );
      await future.close();

      await expectLater(
        AppDatabase.open(path: path, factory: databaseFactoryFfi),
        throwsA(isA<DatabaseDowngradeException>()),
      );

      // The point of the guard: the data is still there afterwards.
      final reopened = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: Db.schemaVersion + 1),
      );
      addTearDown(reopened.close);
      expect(await reopened.query('keepme'), hasLength(1));
    });

    test('reports both versions so the user knows what to install', () async {
      const e = DatabaseDowngradeException(storedVersion: 9, appVersion: 5);
      expect(e.storedVersion, 9);
      expect(e.appVersion, 5);
      expect('$e', contains('stored=9'));
    });
  });

  group('reset', () {
    test('deletes the database file', () async {
      final dir = await Directory.systemTemp.createTemp('osb_reset');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'app.db');
      final db = await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      await db.close();
      expect(File(path).existsSync(), isTrue);

      await AppDatabase.reset(path: path, factory: databaseFactoryFfi);
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('StartupFailureApp', () {
    testWidgets('generic failure shows the error and offers a reset',
        (tester) async {
      await tester.pumpWidget(StartupFailureApp(
        error: Exception('disk is on fire'),
        onRetry: () async {},
      ));
      await tester.pumpAndSettle();

      expect(find.text('無法啟動'), findsOneWidget);
      expect(find.textContaining('disk is on fire'), findsOneWidget);
      expect(find.text('重試'), findsOneWidget);
      expect(find.text('重設資料庫（刪除所有紀錄）'), findsOneWidget);
    });

    testWidgets('downgrade offers NO reset — the data must survive',
        (tester) async {
      await tester.pumpWidget(StartupFailureApp(
        error: const DatabaseDowngradeException(storedVersion: 9, appVersion: 5),
        onRetry: () async {},
      ));
      await tester.pumpAndSettle();

      expect(find.text('App 版本比資料舊'), findsOneWidget);
      expect(find.text('重試'), findsOneWidget);
      // The whole point: no wipe button on a recoverable mistake.
      expect(find.text('重設資料庫（刪除所有紀錄）'), findsNothing);
    });

    testWidgets('retry re-runs bootstrap', (tester) async {
      var retries = 0;
      await tester.pumpWidget(StartupFailureApp(
        error: Exception('nope'),
        onRetry: () async => retries++,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('重試'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    });

    testWidgets('reset asks for confirmation and honours cancel',
        (tester) async {
      var retries = 0;
      await tester.pumpWidget(StartupFailureApp(
        error: Exception('nope'),
        onRetry: () async => retries++,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('重設資料庫（刪除所有紀錄）'));
      await tester.pumpAndSettle();
      expect(find.text('確定要重設資料庫？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // Cancelling must not delete anything nor restart.
      expect(retries, 0);
    });
  });
}
