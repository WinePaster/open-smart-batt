// Shared harness for the design 0105 (landscape) widget tests: an inert BLE,
// a real AppServices over a temp-file database, the window sizes of 0105
// §4.9, and an overflow collector.
//
// Modelled on `text_size_test.dart`'s shell harness (same fake BLE, same
// "file per call, not inMemoryDatabasePath" reason).
//
// CLEAN-ROOM: expectations derive from this project's own source and docs.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/main.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/state.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The window sizes of design 0105 §4.9, in logical px (dpr 1).
class Win {
  const Win(this.name, this.size);
  final String name;
  final Size size;

  static const portrait = Win('portrait 390×844', Size(390, 844));
  static const phoneLandscape = Win('phone landscape 844×390', Size(844, 390));
  static const unit853 = Win('head unit 853×480', Size(853, 480));
  static const unit1024 = Win('head unit 1024×600', Size(1024, 600));
  static const unit1280 = Win('head unit 1280×720', Size(1280, 720));
  static const unit1920 = Win('wide head unit 1920×720', Size(1920, 720));

  static const landscapes = [phoneLandscape, unit1024, unit1280, unit1920];
  static const all = [portrait, ...landscapes];

  @override
  String toString() => name;
}

/// Inert BLE with a link stream, so a demo unit can be "connected" the way
/// `demo_ui_test` does it. Never reaches the flutter_blue_plus platform.
class LandscapeFakeBle extends BleService {
  final _linkOut = StreamController<BleLinkState>.broadcast();
  final _telemetryOut = StreamController<TelemetrySample>.broadcast();
  String? connectedId;

  /// Push one sample, as if it arrived over the link.
  void emit(TelemetrySample s) => _telemetryOut.add(s);

  @override
  String? get connectedDeviceId => connectedId;
  @override
  Stream<BleLinkState> get linkState => _linkOut.stream;
  @override
  Stream<List<DiscoveredDevice>> get scanResults =>
      const Stream<List<DiscoveredDevice>>.empty();
  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);
  @override
  Stream<TelemetrySample> get telemetry => _telemetryOut.stream;
  @override
  Stream<bool> get scanning => const Stream<bool>.empty();
  @override
  bool get isScanning => false;
  @override
  Future<bool> ensurePermissions() async => true;
  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(
    String deviceId, {
    Duration? timeout,
    bool autoConnect = false,
  }) async {
    connectedId = deviceId;
    _linkOut.add(BleLinkState.connecting);
    _linkOut.add(BleLinkState.connected);
    _linkOut.add(BleLinkState.ready);
  }

  @override
  Future<void> disconnect() async {
    connectedId = null;
    _linkOut.add(BleLinkState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _linkOut.close();
    await _telemetryOut.close();
    await super.dispose();
  }
}

/// Device-type bytes of the three saved harness units (smart battery,
/// second-generation super-capacitor, power bank).
const int kTypeBattery = 0x02;
const int kTypeCapacitor = 0x17;
const int kTypePowerBank = 0x22;

/// Link [ble] to saved unit [id] and feed it a few seconds of fixed
/// telemetry carrying [deviceType], so the device page routes and classifies
/// exactly as it would for real hardware — deterministically.
Future<void> linkWithTelemetry(
  WidgetTester tester,
  AppServices s,
  String id,
  int deviceType,
) async {
  final ble = s.ble as LandscapeFakeBle;
  await tester.runAsync(() => s.connection.connect(id));
  final t0 = DateTime.now();
  final pb = deviceType == kTypePowerBank;
  for (var i = 0; i < 6; i++) {
    ble.emit(
      TelemetrySample(
        timestamp: t0.add(Duration(seconds: i)),
        deviceId: id,
        deviceType: deviceType,
        pvlt: pb ? null : 13.18 + i * 0.01,
        svlt: pb ? 5.02 : 12.64,
        temperatureC: 25,
        current: pb ? 1.2 : 0.0,
        dvol: deviceType == kTypeBattery
            ? const [3.299, 3.292, 3.296, 3.293]
            : null,
        socPercent: pb ? 76 : null,
        mode: 0,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settleHarness(tester);
}

/// Saved units of every class, so the home grid has tiles to lay out.
final List<SavedDevice> kHarnessDevices = [
  SavedDevice(
    id: 'AA:BB:CC:DD:EE:01',
    alias: '機車電池 Motorcycle battery',
    name: 'RCE-BATT',
    lastSeen: DateTime.utc(2026, 11, 13, 8),
    lastValue: 13.21,
    productClass: ProductClass.smartBattery,
  ),
  SavedDevice(
    id: 'AA:BB:CC:DD:EE:02',
    alias: '汽車電容 Car capacitor',
    name: 'RCE-CAP',
    lastSeen: DateTime.utc(2026, 11, 13, 8),
    lastValue: 14.02,
    productClass: ProductClass.supercapacitor,
  ),
  SavedDevice(
    id: 'AA:BB:CC:DD:EE:03',
    alias: '行動電源 Power bank',
    name: 'RSPB',
    lastSeen: DateTime.utc(2026, 11, 13, 8),
    lastValue: 3.91,
    lastSoc: 76,
    productClass: ProductClass.powerBank,
  ),
];

/// Build real [AppServices] over a fresh temp-file database.
Future<AppServices> makeHarnessServices(
  WidgetTester tester, {
  AppTextSize? size,
  AppLang? lang,
  bool? allowLandscape,
  List<SavedDevice>? devices,
  LandscapeFakeBle? ble,
}) async {
  late final AppServices s;
  await tester.runAsync(() async {
    // The one-time disclaimer is a modal: left up, it swallows every tap.
    final markerDir = await Directory.systemTemp.createTemp('osb_land_ack');
    AckMarker.debugDirectoryOverride = markerDir;
    addTearDown(() {
      AckMarker.debugDirectoryOverride = null;
      markerDir.deleteSync(recursive: true);
    });
    await kDisclaimerAck.markAcknowledged();
    final dbDir = await Directory.systemTemp.createTemp('osb_land_db');
    addTearDown(() async {
      // The services close the database fire-and-forget; SQLite may remove
      // its journal while the recursive delete is walking the directory.
      try {
        await dbDir.delete(recursive: true);
      } on FileSystemException {
        // Best effort: it is a temp directory.
      }
    });
    final db = await AppDatabase.open(
      path: p.join(dbDir.path, 'app.db'),
      factory: databaseFactoryFfi,
    );
    final repo = DeviceRepo(db.db);
    for (final d in devices ?? kHarnessDevices) {
      await repo.upsertSavedDevice(d);
    }
    s = await AppServices.create(
      appDatabase: db,
      ble: ble ?? LandscapeFakeBle(),
    );
    if (size != null) await s.settings.setTextSize(size);
    if (lang != null) await s.settings.setLang(lang);
    if (allowLandscape != null) {
      await s.settings.setAllowLandscape(allowLandscape);
    }
    await s.pending.drain();
  });
  return s;
}

/// Let real async work (DB reads) and a few frames run.
Future<void> settleHarness(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Size the test window (dpr 1) and the OS text scale; both reset on teardown.
void setWindow(WidgetTester tester, Size size, {double os = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = os;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Pump the real shell and tear it down cleanly at the end of the test.
Future<void> pumpShell(WidgetTester tester, AppServices s) async {
  await tester.pumpWidget(OpenSmartBattApp(services: s));
  await settleHarness(tester);
  addTearDown(() async {
    // Writes queued by a link (touch, class) call back into controllers the
    // app disposes with itself — drain them while those are still alive.
    await tester.runAsync(() => s.pending.drain());
    await tester.pumpWidget(const SizedBox());
  });
}

/// One layout overflow, identified by the strings drawn inside the widget the
/// report blames.
class SeenOverflow {
  SeenOverflow(this.texts, this.px, this.inBrandBar);
  final List<String> texts;
  final double px;

  /// Inside the root brand app bar — see [collectOverflows].
  final bool inBrandBar;

  @override
  String toString() =>
      '${px.toStringAsFixed(1)} px in <${texts.take(4).join(' | ')}>'
      '${inBrandBar ? ' (brand bar)' : ''}';
}

/// Collect every layout overflow reported while the test runs; any OTHER
/// Flutter error still fails the test.
///
/// The root brand app bar is flagged, not dropped: `text_size_test.dart`
/// documents that under the test font (every glyph a full em wide) that bar
/// overflows in TODAY's portrait build too, so differential assertions need
/// to tell it apart.
List<SeenOverflow> collectOverflows() {
  final found = <SeenOverflow>[];
  final previous = FlutterError.onError;
  final overflowPx = RegExp(r'overflowed by ([\d.]+) pixels');
  FlutterError.onError = (d) {
    final px = [
      for (final m in overflowPx.allMatches(d.exceptionAsString()))
        double.parse(m.group(1)!),
    ];
    if (px.isEmpty) {
      previous?.call(d);
      return;
    }
    px.sort();
    found.add(SeenOverflow(_textsUnder(d), px.last, _inBrandAppBar(d)));
  };
  addTearDown(() => FlutterError.onError = previous);
  return found;
}

bool _inBrandAppBar(FlutterErrorDetails d) {
  for (final node
      in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
    if (node is! DiagnosticsDebugCreator) continue;
    final creator = node.value;
    if (creator is! DebugCreator) continue;
    var found = false;
    creator.element.visitAncestorElements((e) {
      final name = e.widget.runtimeType.toString();
      found = name == '_BrandAppBar' || name == '_RailHeader';
      return !found;
    });
    return found;
  }
  return false;
}

List<String> _textsUnder(FlutterErrorDetails d) {
  final out = <String>[];
  for (final node
      in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
    if (node is! DiagnosticsDebugCreator) continue;
    final creator = node.value;
    if (creator is! DebugCreator) continue;
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null) out.add(w.data!);
      e.visitChildren(visit);
    }

    visit(creator.element);
  }
  return out;
}
