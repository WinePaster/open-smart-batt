/// FB 2026.09.27/003 — a link dropped while watching `0x23` after a mode write
/// must never read as "changed". The disconnect clears the live sample, so the
/// mode goes 2 → null; the old `mode != before` check turned that into
/// 「復電完成 —— 裝置現在回報：--」 for a pack that was still cut off.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ui/dashboard/status_controls_shared.dart';

/// Runs [watchModeAfterWrite] under a fake clock, with [script] giving the mode
/// the device reports at each 500 ms poll (the last value repeats).
ModeWatch _watch(int? before, List<int?> script,
    {Duration window = const Duration(seconds: 3)}) {
  late ModeWatch result;
  var polls = 0;
  fakeAsync((fa) {
    watchModeAfterWrite(() {
      final v = script[polls < script.length ? polls : script.length - 1];
      polls++;
      return v;
    }, before, window)
        .then((r) => result = r);
    fa.elapse(window + const Duration(seconds: 1));
  });
  return result;
}

void main() {
  test('the 09.27/003 shape: cut off (2), then the link drops → linkLost', () {
    expect(_watch(2, [2, null]), ModeWatch.linkLost);
  });

  test('link drops on the very first poll → linkLost, not changed', () {
    expect(_watch(2, [null]), ModeWatch.linkLost);
  });

  test('a real move off the old mode → changed', () {
    expect(_watch(2, [2, 2, 0]), ModeWatch.changed);
  });

  test('device keeps reporting the old mode → unchanged', () {
    expect(_watch(2, [2]), ModeWatch.unchanged);
  });

  test('no reading before and none after → unchanged (nothing observed)', () {
    expect(_watch(null, [null]), ModeWatch.unchanged);
  });

  test('no reading before, then a first reading → changed (as before)', () {
    expect(_watch(null, [null, 0]), ModeWatch.changed);
  });
}
