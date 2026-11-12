// 2026.11.12/001: a design-0103 secondary link is a whole BleService that is
// disposed while work may still be in flight; a late add to its closed streams
// threw `Bad state: Cannot add new events after calling close` (5 uncaught in
// 16 minutes, each at a release). A disposed service drops the event instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a late diagnostics line after dispose is dropped, not thrown', () async {
    final ble = BleService();
    final lines = <String>[];
    final sub = ble.diagnostics.listen(lines.add);
    ble.setNotifyDrivenKeepAlive(true);
    await ble.dispose();
    await sub.cancel();
    // Leaving the notify-driven window emits its closing summary line — onto a
    // stream that is now closed.
    expect(() => ble.setNotifyDrivenKeepAlive(false), returnsNormally);
  });

  test('a live service still emits that line', () async {
    final ble = BleService();
    final lines = <String>[];
    final sub = ble.diagnostics.listen(lines.add);
    ble.setNotifyDrivenKeepAlive(true);
    ble.setNotifyDrivenKeepAlive(false);
    await Future<void>.delayed(Duration.zero);
    expect(lines, isNotEmpty);
    await sub.cancel();
    await ble.dispose();
  });
}
