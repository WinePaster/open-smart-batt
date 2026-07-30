/// OpenSmartBatt — composition root for the state layer.
///
/// Opens the app database, constructs the repositories + the BLE service, and
/// wires the four [ChangeNotifier] controllers. Created once at startup (see
/// `main.dart`) and provided to the widget tree via `MultiProvider`.
///
/// Owns the lifecycle of everything IO-bound: call [dispose] on app teardown to
/// release the controllers' stream subscriptions, the BLE link and the DB.
library;

import 'dart:async';

import '../ble/ble.dart';
import '../data/data.dart';
import '../platform/platform.dart';
import '../protocol/protocol.dart';
import 'build_info.dart';
import 'connection_controller.dart';
import 'device_controller.dart';
import 'session_context.dart';
import 'settings_controller.dart';
import 'telemetry_controller.dart';

/// Holds the long-lived services + controllers for the app.
class AppServices {
  AppServices._({
    required this.appDb,
    required this.ble,
    required this.historyRepo,
    required this.deviceRepo,
    required this.settingsRepo,
    required this.logRepo,
    required this.settings,
    required this.devices,
    required this.connection,
    required this.telemetry,
    required this.pending,
    required this.appBuild,
    required this.platform,
  });

  final AppDatabase appDb;
  final BleService ble;

  final HistoryRepo historyRepo;
  final DeviceRepo deviceRepo;
  final SettingsRepo settingsRepo;
  final LogRepo logRepo;

  final SettingsController settings;
  final DeviceController devices;
  final ConnectionController connection;
  final TelemetryController telemetry;

  /// Fire-and-forget database writes still in flight. Drained by [dispose]
  /// before the database closes; see [PendingWrites].
  final PendingWrites pending;

  /// This build (`version+buildNumber`) and OS description, resolved ONCE at
  /// startup (design 0010). Stamped on every recorded row and reused by the
  /// export preamble, so no export path waits on a plugin channel. Falls back
  /// to [kUnknownEnv] where the channel is unavailable.
  final String appBuild;
  final String platform;

  /// Open the DB and assemble the full graph.
  ///
  /// - [dbPath]/[dbFactory]: injection points for tests (sqflite_common_ffi).
  /// - [ble]: inject a fake/stub [BleService] in tests; defaults to the real one.
  /// - [parser]: device-metadata parser forwarded to
  ///   the default [BleService]. The open build passes [NoopMetadataParser];
  ///   a closed composition root injects its own. Ignored when [ble] is provided.
  /// - [monitor]: inject a fake background-monitor handle in tests; defaults to
  ///   the platform's implementation (Android foreground service, else no-op).
  static Future<AppServices> create({
    String? dbPath,
    AppDatabase? appDatabase,
    BleService? ble,
    MonitorService? monitor,
    MetadataParser parser = const NoopMetadataParser(),
  }) async {
    final db = appDatabase ?? await AppDatabase.open(path: dbPath);
    final bleService = ble ?? BleService(parser: parser);
    // Resolved before any controller exists, so the very first recorded row
    // already carries it.
    final env = await resolveBuildInfo();
    final monitorService = monitor ?? MonitorService.forPlatform();

    final historyRepo = HistoryRepo(db.db);
    final deviceRepo = DeviceRepo(db.db);
    final settingsRepo = SettingsRepo(db.db);
    final logRepo = LogRepo(db.db);

    final settings = SettingsController(settingsRepo, history: historyRepo);
    final devices = DeviceController(deviceRepo);
    // design 0006: ONE session context shared by both controllers, so the log
    // events and the packet/history rows are attributed to the same unit. Seed
    // the counter from storage to keep session ids monotonic across restarts.
    final session = SessionContext()..seed(await logRepo.lastSessionId());
    // ONE tracker shared by everything that writes without awaiting, so
    // [dispose] can drain the lot before closing the database.
    final pending = PendingWrites();
    final connection = ConnectionController(
      bleService,
      settings: settings,
      devices: devices,
      logs: logRepo,
      session: session,
      appBuild: env.build,
      monitor: monitorService,
      pending: pending,
    );
    final telemetry = TelemetryController(
      bleService,
      settings: settings,
      history: historyRepo,
      logs: logRepo,
      session: session,
      appBuild: env.build,
      pending: pending,
    );

    // Prime the persisted controllers before the first frame.
    await Future.wait([settings.load(), devices.load()]);

    // Apply the retention window once per launch (design 0011). The window is
    // measured in days, so there is no reason to prune more often than this —
    // and doing it on every write would be pure I/O for no benefit.
    pending.add(settings.pruneHistory());

    return AppServices._(
      appDb: db,
      ble: bleService,
      historyRepo: historyRepo,
      deviceRepo: deviceRepo,
      settingsRepo: settingsRepo,
      logRepo: logRepo,
      settings: settings,
      devices: devices,
      connection: connection,
      telemetry: telemetry,
      pending: pending,
      appBuild: env.build,
      platform: env.platform,
    );
  }

  /// Tear everything down (controllers → BLE → pending writes → DB).
  ///
  /// The order matters and the middle step is the whole point. Disposing the
  /// controllers and the BLE service stops *new* work being queued; draining
  /// [pending] then waits for the writes already in flight. Only then is it
  /// safe to close the database.
  ///
  /// 🔴 Closing before the drain is what produced the intermittent
  /// `DatabaseException(error database_closed)` — a two-step `insertLog`
  /// resuming after `close()`. See [PendingWrites] for the full trace.
  ///
  /// The drain is bounded: if a write wedges we close anyway rather than hang
  /// shutdown forever. Its result is deliberately ignored here — there is no
  /// remedy at this point and nowhere left to report to, since the log sink is
  /// the database we are about to close.
  Future<void> dispose() async {
    telemetry.dispose();
    connection.dispose();
    devices.dispose();
    settings.dispose();
    await ble.dispose();
    await pending.drain();
    await appDb.close();
  }
}
