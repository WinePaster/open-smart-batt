// 2026.11.16/006 §3.1 (owner ruling 2026-11-16, 「先保守處理」): a paused link
// (design 0103 D5 demotion / D1 power-bank pause) must not go silent. A 0169
// capacitor on iOS dropped the link 3/3 at ~240 s after the last write, so a
// paused link now writes one poll per [MultiLinkConfig.pausedKeepAliveEvery].
//
// Driven over the real transport with a demo link, the way
// `seam_golden_test.dart` drives it, under fake time.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/config/multi_link_config.dart';
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_blue_plus/methods');
  late Duration savedConnect;
  late Duration savedReply;

  setUp(() {
    savedConnect = BleService.demoConnectDelay;
    savedReply = BleService.demoReplyDelay;
    BleService.demoConnectDelay = Duration.zero;
    BleService.demoReplyDelay = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    BleService.demoConnectDelay = savedConnect;
    BleService.demoReplyDelay = savedReply;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the constant keeps a 4x margin under the 240 s the unit allowed', () {
    expect(MultiLinkConfig.pausedKeepAliveEvery,
        lessThanOrEqualTo(const Duration(seconds: 60)));
  });

  test('paused: one poll a minute, never silent; resume: 1 Hz again', () {
    fakeAsync((async) {
      final ble = BleService();
      var tx = 0;
      final sub = ble.packets.listen((e) {
        if (e.direction == LogDirection.tx) tx++;
      });
      ble.connect(DemoKind.battery.id);
      async.elapse(const Duration(seconds: 5));
      expect(ble.pausePolling(reason: 'test'), isTrue);
      final atPause = tx;
      // 250 s: just past the 240 s the field unit tolerated.
      async.elapse(const Duration(seconds: 250));
      expect(tx - atPause, 4, reason: 'at 60, 120, 180 and 240 s');
      ble.resumePolling();
      final atResume = tx;
      async.elapse(const Duration(seconds: 10));
      expect(tx - atResume, greaterThanOrEqualTo(10), reason: '1 Hz again');
      ble.disconnect();
      async.elapse(const Duration(seconds: 2));
      sub.cancel();
      ble.dispose();
      async.flushMicrotasks();
    });
  });

  test('a new pause starts its own minute', () {
    fakeAsync((async) {
      final ble = BleService();
      var tx = 0;
      final sub = ble.packets.listen((e) {
        if (e.direction == LogDirection.tx) tx++;
      });
      ble.connect(DemoKind.battery.id);
      async.elapse(const Duration(seconds: 5));
      ble.pausePolling(reason: 'test');
      async.elapse(const Duration(seconds: 70)); // one sparse write at 60 s
      ble.resumePolling();
      async.elapse(const Duration(seconds: 3));
      ble.pausePolling(reason: 'test');
      final atPause = tx;
      async.elapse(const Duration(seconds: 59));
      expect(tx - atPause, 0, reason: 'not before a full minute of this pause');
      async.elapse(const Duration(seconds: 2));
      expect(tx - atPause, 1);
      ble.disconnect();
      async.elapse(const Duration(seconds: 2));
      sub.cancel();
      ble.dispose();
      async.flushMicrotasks();
    });
  });

  test('sparse writes stay out of the D5 write window', () {
    fakeAsync((async) {
      final ble = BleService()..trackWriteWindow = true;
      ble.connect(DemoKind.battery.id);
      // ~31 ordinary keep-alives …
      async.elapse(const Duration(seconds: 30));
      ble.pausePolling(reason: 'test');
      // … 10 sparse ones …
      async.elapse(const Duration(minutes: 10, seconds: 5));
      ble.resumePolling();
      // … ~21 ordinary ones: ~52 < 60 unless the sparse ten were counted.
      async.elapse(const Duration(seconds: 20));
      expect(ble.recentWriteAvgMs, isNull,
          reason: 'the window must hold only 1 Hz writes');
      ble.disconnect();
      async.elapse(const Duration(seconds: 2));
      ble.dispose();
      async.flushMicrotasks();
    });
  });
}
