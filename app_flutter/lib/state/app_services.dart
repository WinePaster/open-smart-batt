/// OpenSmartBatt — composition root for the state layer.
///
/// Opens the app database, constructs the repositories + the BLE service, and
/// wires the four [ChangeNotifier] controllers. Created once at startup (see
/// `main.dart`) and provided to the widget tree via `MultiProvider`.
///
/// Owns the lifecycle of everything IO-bound: call [dispose] on app teardown to
/// release the controllers' stream subscriptions, the BLE link and the DB.
library;

import '../ble/ble.dart';
import '../data/data.dart';
import 'connection_controller.dart';
import 'device_controller.dart';
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

  /// Open the DB and assemble the full graph.
  ///
  /// - [dbPath]/[dbFactory]: injection points for tests (sqflite_common_ffi).
  /// - [ble]: inject a fake/stub [BleService] in tests; defaults to the real one.
  static Future<AppServices> create({
    String? dbPath,
    AppDatabase? appDatabase,
    BleService? ble,
  }) async {
    final db = appDatabase ?? await AppDatabase.open(path: dbPath);
    final bleService = ble ?? BleService();

    final historyRepo = HistoryRepo(db.db);
    final deviceRepo = DeviceRepo(db.db);
    final settingsRepo = SettingsRepo(db.db);
    final logRepo = LogRepo(db.db);

    final settings = SettingsController(settingsRepo);
    final devices = DeviceController(deviceRepo);
    final connection = ConnectionController(
      bleService,
      settings: settings,
      devices: devices,
      logs: logRepo,
    );
    final telemetry = TelemetryController(
      bleService,
      settings: settings,
      history: historyRepo,
      logs: logRepo,
    );

    // Prime the persisted controllers before the first frame.
    await Future.wait([settings.load(), devices.load()]);

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
    );
  }

  /// Tear everything down (controllers → BLE → DB).
  Future<void> dispose() async {
    telemetry.dispose();
    connection.dispose();
    devices.dispose();
    settings.dispose();
    await ble.dispose();
    await appDb.close();
  }
}
