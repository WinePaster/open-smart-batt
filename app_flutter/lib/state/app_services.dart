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
import 'gps_speed_controller.dart';
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
    required this.speed,
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

  /// GPS speed (design 0042). Constructed unconditionally but INERT until all
  /// three of its lifecycle gates are opened, so a build where nobody ever
  /// selects the `riding` watchface never touches the location plugin.
  final GpsSpeedController speed;

  /// Fire-and-forget database writes still in flight. Drained by [dispose]
  /// before the database closes; see [PendingWrites].
  final PendingWrites pending;

  /// This build (`version+buildNumber`) and OS description, resolved ONCE at
  /// startup. Stamped on every recorded row and reused by the export preamble,
  /// so no export path waits on a plugin channel — and, more importantly, so
  /// the build named in a file's header and the build stamped on its rows can
  /// never disagree about the same run. Falls back to [kUnknownEnv] where the
  /// channel is unavailable; a missing version must never fail an export.
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
    // ONE session context shared by both controllers, so the log events and the
    // packet/history rows are attributed to the same unit — attribution has to
    // come from a single place or the two writers will disagree. Seed
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
    // Holds no resources until its gate opens; see [GpsSpeedController].
    final speed = GpsSpeedController();
    // One judgement about link freshness, two presentations: the dashboard's
    // stale banner and the ongoing notification. Wired here because it is the
    // only place both controllers exist (design 0038 §5.5).
    connection.bindTelemetryHealth(telemetry);
    // The phone's speed reaches recorded history here and nowhere else
    // (design 0042 §3.9). Wired at the composition root for the same reason as
    // the line above: it is the only place both controllers exist, and neither
    // has to learn about the other's domain to be tested.
    telemetry.bindSpeedEstimates(speed.estimates);
    // …and its acceleration with it (design 0044 §3.5). Separate stream, same
    // reasoning: the recorded value is the estimator's raw slope, so what the
    // analyst reads and what the rider saw come from one source.
    telemetry.bindAccelEstimates(speed.accelEstimates);

    // Prime the persisted controllers before the first frame.
    await Future.wait([settings.load(), devices.load()]);

    // Apply the retention window once per launch. The window is measured in
    // days, so there is no reason to prune more often than this —
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
      speed: speed,
      pending: pending,
      appBuild: env.build,
      platform: env.platform,
    );
  }

  /// Tear everything down (BLE → pending writes → controllers → DB).
  ///
  /// The order matters at both ends. Disposing the BLE service FIRST stops the
  /// event sources, so nothing new can be queued; draining [pending] then
  /// waits for the writes already in flight — and those writes need the
  /// controllers still alive: `DeviceController.touch`/`setProductClass`
  /// finish with `load()` → `notifyListeners()`, which on a disposed
  /// ChangeNotifier is a "used after being disposed" error. That is why the
  /// controllers come AFTER the drain, not before it (found 2026-08-04; the
  /// old order was controllers-first, which was safe only while no test or
  /// runtime path had a write in flight at teardown). No controller's own
  /// `dispose()` queues a write, so nothing is enqueued past the drain.
  ///
  /// 🔴 Closing before the drain is what produced the intermittent
  /// `DatabaseException(error database_closed)` — a two-step `insertLog`
  /// resuming after `close()`. See [PendingWrites] for the full trace. That
  /// invariant (drain before close) is unchanged.
  ///
  /// The drain is bounded: if a write wedges we close anyway rather than hang
  /// shutdown forever. Its result is deliberately ignored here — there is no
  /// remedy at this point and nowhere left to report to, since the log sink is
  /// the database we are about to close.
  Future<void> dispose() async {
    await ble.dispose();
    await pending.drain();
    telemetry.dispose();
    connection.dispose();
    speed.dispose();
    devices.dispose();
    settings.dispose();
    await appDb.close();
  }
}
