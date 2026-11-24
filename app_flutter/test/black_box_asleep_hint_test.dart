// FB-119 — a black box that does not answer is probably asleep.
//
// WHAT THIS PINS. Field report `2026.11.24/003` (a dealer, one unit, on a real
// vehicle): a few minutes after its link drops the black box stops
// advertising, and ignition / engine start does not reliably wake it; the
// headlight or a throttle blip does. The generic advice — "check it is nearby
// and powered" — points the wrong way for that unit, so a black box gets its
// own hint on every "did not answer" path, and ONLY there.
//
// CLEAN-ROOM: expectations derive from this project's own source and reports.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import 'package:open_smart_batt/models/product_class.dart';
import 'package:open_smart_batt/ui/devices/connection_failure.dart';

ConnectionFailureCopy _copy(
  AppLocalizations l10n, {
  String? lastError,
  bool setupStalled = false,
  bool unreachableRun = false,
  ProductClass? productClass,
}) =>
    connectionFailureCopy(
      l10n: l10n,
      lastError: lastError,
      working: false,
      isBusy: false,
      isRetrying: false,
      autoConnectArmed: false,
      setupStalled: setupStalled,
      setupFailures: setupStalled ? 3 : 0,
      reconnectAttempts: 0,
      unreachableRun: unreachableRun,
      reachFailures: unreachableRun ? 3 : 0,
      productClass: productClass,
    );

void main() {
  for (final locale in const [Locale('en'), Locale('zh')]) {
    group('FB-119 black-box asleep hint (${locale.languageCode})', () {
      late AppLocalizations l10n;
      setUpAll(() async {
        l10n = await AppLocalizations.delegate.load(locale);
      });

      test('every "did not answer" give-up code gets the black-box hint', () {
        for (final code in blackBoxAsleepCodes) {
          expect(gaveUpCodes, contains(code), reason: code);
          expect(
            _copy(l10n, lastError: code, productClass: ProductClass.blackBox)
                .adviceHint,
            l10n.blackBoxAsleepHint,
            reason: code,
          );
        }
      });

      test('the unreachable-run card gets it too', () {
        expect(
          _copy(l10n,
                  unreachableRun: true, productClass: ProductClass.blackBox)
              .adviceHint,
          l10n.blackBoxAsleepHint,
        );
      });

      test('other classes, and an unknown class, keep the generic advice', () {
        for (final cls in [
          null,
          ProductClass.smartBattery,
          ProductClass.supercapacitor,
          ProductClass.unknown,
        ]) {
          expect(
            _copy(l10n, lastError: 'device_unreachable', productClass: cls)
                .adviceHint,
            l10n.disconnectedGaveUpHint,
            reason: '$cls',
          );
          expect(
            _copy(l10n, unreachableRun: true, productClass: cls).adviceHint,
            l10n.disconnectedUnreachableRunHint,
            reason: '$cls',
          );
        }
      });

      test('radio, wrong-device and stalled keep their own remedies', () {
        const bb = ProductClass.blackBox;
        for (final code in radioCodes) {
          expect(_copy(l10n, lastError: code, productClass: bb).adviceHint,
              l10n.disconnectedGaveUpRadioHint,
              reason: code);
        }
        expect(
            _copy(l10n, lastError: 'wrong_device', productClass: bb)
                .adviceHint,
            l10n.disconnectedWrongDeviceHint);
        expect(_copy(l10n, setupStalled: true, productClass: bb).adviceHint,
            l10n.disconnectedStalledHint);
      });

      test('the hint is short (owner ruling: shortened version)', () {
        final max = locale.languageCode == 'zh' ? 30 : 100;
        expect(l10n.blackBoxAsleepHint.length, lessThanOrEqualTo(max));
      });
    });
  }
}
