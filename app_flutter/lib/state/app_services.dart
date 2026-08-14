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
import 'device_facts_controller.dart';
import 'g_force_controller.dart';
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
    required this.deviceFactsRepo,
    required this.settingsRepo,
    required this.logRepo,
    required this.autoConnectArmRepo,
    required this.restoredArm,
    required this.settings,
    required this.devices,
    required this.facts,
    required this.connection,
    required this.telemetry,
    required this.speed,
    required this.gforce,
    required this.pending,
    required this.appBuild,
    required this.platform,
  });

  final AppDatabase appDb;
  final BleService ble;

  final HistoryRepo historyRepo;
  final DeviceRepo deviceRepo;
  final DeviceFactsRepo deviceFactsRepo;
  final SettingsRepo settingsRepo;
  final LogRepo logRepo;

  /// design 0060 (FB-67): the armed iOS autoConnect hand-off, persisted so it
  /// outlives a process iOS reclaims.
  final AutoConnectArmRepo autoConnectArmRepo;

  /// What the PREVIOUS run was waiting for when it stopped existing, or null.
  ///
  /// Read once here — before any controller can write to the table — and kept
  /// so `bootstrap()` can put it in the `cold-start:` line (design 0060 §3.5).
  /// [connection] has already been handed the same value and owns the actual
  /// reconciliation; this field is the instrument's copy, not a second
  /// authority.
  final AutoConnectArm? restoredArm;

  final SettingsController settings;
  final DeviceController devices;

  /// What each unit said about ITSELF, cached whether or not it was ever named
  /// (design 0057). 🔴 Serves the read-back of past records only — see
  /// [DeviceFacts] for the boundary, and note that [connection] holds this to
  /// WRITE and never to route.
  final DeviceFactsController facts;
  final ConnectionController connection;
  final TelemetryController telemetry;

  /// GPS speed (design 0042). Constructed unconditionally but INERT until all
  /// three of its lifecycle gates are opened, so a build where nobody ever
  /// selects the `riding` watchface never touches the location plugin.
  final GpsSpeedController speed;

  /// The G meter (design 0045). Constructed unconditionally and, like [speed],
  /// INERT until its gate opens — a build where nobody turns the switch on and
  /// calibrates never touches the accelerometer.
  final GForceController gforce;

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
    final deviceFactsRepo = DeviceFactsRepo(db.db);
    final settingsRepo = SettingsRepo(db.db);
    final logRepo = LogRepo(db.db);
    final autoConnectArmRepo = AutoConnectArmRepo(db.db);
    // design 0060 §3.3: read BEFORE the controller exists, so the value handed
    // to it cannot have been written by it. Same shape as `lastSessionId()`
    // below — a single read the composition root already does at this point.
    final restoredArm = await autoConnectArmRepo.read();

    final settings = SettingsController(settingsRepo, history: historyRepo);
    final devices = DeviceController(deviceRepo);
    final facts = DeviceFactsController(deviceFactsRepo);
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
      facts: facts,
      logs: logRepo,
      session: session,
      appBuild: env.build,
      monitor: monitorService,
      pending: pending,
      autoConnectArm: autoConnectArmRepo,
    );
    // design 0060 §3.3 — immediately after construction, so no link event can
    // reach the controller before it knows there is an episode to close. A null
    // arm (the ordinary launch) returns without touching anything.
    connection.restoreArm(restoredArm);
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
    // Same contract; see [GForceController].
    final gforce = GForceController();
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
    // …and the G meter's own two components (design 0045 §3.7). A third stream
    // rather than a field on either of the others, for design 0044's reason
    // applied once more: the three series have different lifetimes, and a
    // minute that measured speed but no G must record the one and leave the
    // other null.
    telemetry.bindGForceEstimates(gforce.estimates);

    // Prime the persisted controllers before the first frame.
    await Future.wait([settings.load(), devices.load(), facts.load()]);

    // 🔴 The G meter's ONLY input. It holds no persistence of its own (see
    // [GForceController]), so the stored switch and matrix reach it here and
    // nowhere else — once now, and again on every settings write. Forgetting
    // either half fails CLOSED: the card never appears and Settings reports
    // "not calibrated", which is wrong but visible, rather than a calibration
    // that works until the next unrelated settings change.
    gforce.applySettings(settings.settings);
    settings.addListener(() => gforce.applySettings(settings.settings));

    // Apply the retention window once per launch. The window is measured in
    // days, so there is no reason to prune more often than this —
    // and doing it on every write would be pure I/O for no benefit.
    pending.add(settings.pruneHistory());

    return AppServices._(
      appDb: db,
      ble: bleService,
      historyRepo: historyRepo,
      deviceRepo: deviceRepo,
      deviceFactsRepo: deviceFactsRepo,
      settingsRepo: settingsRepo,
      logRepo: logRepo,
      autoConnectArmRepo: autoConnectArmRepo,
      restoredArm: restoredArm,
      settings: settings,
      devices: devices,
      facts: facts,
      connection: connection,
      telemetry: telemetry,
      speed: speed,
      gforce: gforce,
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
  /// runtime path had a write in flight at teardown).
  ///
  /// 🔴 "No controller's own `dispose()` queues a write" stopped being true on
  /// 2026-08-13. Design 0060 hangs the deletion of the `autoconnect_arm` row on
  /// `_cancelAutoConnectWatchdog`, which `ConnectionController.dispose()` calls
  /// — and that is deliberate, because a `dispose` that runs is precisely the
  /// evidence that this shutdown was orderly (ruling (c) of 2026-08-13). So
  /// there is now a SECOND drain, after the controllers and before the close.
  /// Without it that delete would resume against a closed database and raise
  /// the exact `DatabaseException(error database_closed)` [PendingWrites] was
  /// built to end.
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
    // 🔴 FLUSH, THEN DRAIN, THEN CLOSE — and the order is the whole point
    // (design 0061 T7e). History rows are buffered for ~10 seconds before they
    // are committed, so at this instant up to ten seconds of the user's data
    // exists only in a Dart list. `drain()` cannot wait for a write that has
    // not been STARTED — [PendingWrites] tracks futures, it does not schedule
    // them — so without this line those rows would be dropped by a shutdown
    // that otherwise looks completely orderly.
    //
    // ⚠️ It also raises the stakes on the drain's 5 s budget, which used to be
    // unreachable (one write a minute) and now has real work behind it. If it
    // expires we close anyway, on purpose (see below); flushing first is what
    // makes that the rare case rather than the normal one.
    telemetry.flushPendingHistory();
    await pending.drain();
    telemetry.dispose();
    connection.dispose();
    speed.dispose();
    gforce.dispose();
    devices.dispose();
    // After the drain for [devices]' reason: `record()` finishes with
    // `load()` -> `notifyListeners()`, and the connection controller queues
    // those writes without awaiting them.
    facts.dispose();
    settings.dispose();
    // The second drain (see above): `connection.dispose()` deletes the
    // `autoconnect_arm` row, and that write is registered, not awaited.
    await pending.drain();
    await appDb.close();
  }
}
