// The `speed-timing:` diagnostic line (design 0071 follow-up, FB-89).
//
// WHY IT EXISTS. `speed_estimator.dart`'s M2 note records 2.1 s of delivery
// latency between the GNSS chipset and this isolate — measured ONCE, in passing,
// while fixing a different bug, and never characterised. Every lag figure design
// 0071 reasons about is measured from the moment a sample reaches US, so if the
// delivery in front of that is routinely a second or more then α is being tuned
// against the small half of the problem. The 2026-08-19 field check ("still
// feels slow" at α=0.632) is exactly the kind of report that cannot be resolved
// without knowing which side the time is being spent on. Hence: measure.
//
// It also settles design 0071 §2.2, which asserts iOS delivers ~1 Hz and marks
// the claim 未實測 — sourced to a code comment, never to a phone. `dt_med` is
// that measurement.
//
// WHAT THESE TESTS DEFEND. Four things, in rough order of how quietly they
// would break:
//
//   1. 🔴 Only estimates carrying a NEW fix count as samples. The stream also
//      fires on `SpeedEstimator.tick`, and counting those would report a
//      receiver faster than the one in the phone — a wrong number that looks
//      entirely plausible.
//   2. The percentiles are the ones claimed (nearest-rank, no interpolation).
//   3. A window too short to mean anything writes nothing.
//   4. One line per window, never one per sample: at 1 Hz the latter is 3,600
//      rows an hour of a log the user is asked to send us.
//
// 🔴 G5 (design 0042's privacy red line). The estimate carries a SPEED, and a
// series of speeds against timestamps is a journey. The last test reads the
// emitted line back and checks it contains durations and counts and nothing
// else.
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothAdapterState;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/state/settings_controller.dart';
import 'package:open_smart_batt/state/speed_estimator.dart';
import 'package:open_smart_batt/state/telemetry_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBle extends BleService {
  final _telemetry = StreamController<TelemetrySample>.broadcast();

  @override
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Stream<bool> get scanning => const Stream<bool>.empty();

  @override
  bool get isScanning => false;

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await super.dispose();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late LogRepo logs;
  late _FakeBle ble;
  late TelemetryController tele;
  late StreamController<SpeedEstimate> estimates;

  final t0 = DateTime.utc(2026, 8, 19, 9);

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    logs = LogRepo(db.db);
    ble = _FakeBle();
    tele = TelemetryController(
      ble,
      settings: SettingsController(SettingsRepo(db.db)),
      history: HistoryRepo(db.db),
      logs: logs,
    );
    estimates = StreamController<SpeedEstimate>.broadcast();
    tele.bindSpeedEstimates(estimates.stream);
  });

  tearDown(() async {
    await tele.pendingWrites.drain();
    tele.dispose();
    await estimates.close();
    await ble.dispose();
    await db.close();
  });

  /// One estimate, exactly as the estimator publishes it: [at] is our clock,
  /// [fixAt] is when the platform says the sample was taken. The gap between
  /// them IS the delivery lag this feature measures.
  ///
  /// `vSmoothMps` is set to something non-zero on purpose — no assertion here
  /// depends on it, and a test where every speed is 0 could not notice a leak
  /// of the speed into the log line.
  SpeedEstimate est(
    DateTime at,
    DateTime fixAt, {
    SpeedState state = SpeedState.live,
  }) =>
      SpeedEstimate(
        t: at,
        vSmoothMps: 17.25,
        state: state,
        quality: SpeedSignalQuality.good,
        lastLiveAt: fixAt,
      );

  Future<void> push(SpeedEstimate e) async {
    estimates.add(e);
    await pumpEventQueue();
  }

  /// Every `speed-timing:` line written so far, oldest first.
  Future<List<String>> timingLines() async {
    await tele.pendingWrites.drain();
    final rows = await logs.queryLog();
    return rows.reversed
        .map((r) => r.note ?? '')
        .where((n) => n.startsWith('speed-timing:'))
        .toList();
  }

  /// A ride of [n] samples, one per [dt], delivered [lag] after being taken.
  Future<void> ride(
    int n, {
    Duration dt = const Duration(seconds: 1),
    Duration lag = const Duration(milliseconds: 300),
    DateTime? from,
  }) async {
    var at = from ?? t0;
    for (var i = 0; i < n; i++) {
      await push(est(at, at.subtract(lag)));
      at = at.add(dt);
    }
  }

  // ---------------------------------------------------------------------------

  test('① a tick is not a sample — only a new fix counts', () async {
    // 🔴 THE ONE THAT MATTERS. `tick()` republishes on any state or quality
    // change, carrying the SAME `lastLiveAt` with a fresh `t`. If those counted,
    // `dt` would be "how long after the fix did the tick land" — fractions of a
    // second — and the log would report a receiver five times faster than the
    // one in the phone. There is no way to spot that downstream: the number is
    // plausible, and it is the number the whole exercise exists to obtain.
    //
    // Thirteen real fixes, five seconds apart, each with four ticks wedged in
    // between. The thirteenth lands 60 s after the first and closes the window
    // on its own, so nothing artificial is pushed to make the line appear.
    // If ticks counted, this would read `n=61 dt_med=1.00s`.
    for (var i = 0; i < 13; i++) {
      final at = t0.add(Duration(seconds: i * 5));
      final fixAt = at.subtract(const Duration(milliseconds: 300));
      await push(est(at, fixAt));
      for (var j = 1; j <= 4; j++) {
        // Same `lastLiveAt`, later `t` — the exact shape of a tick.
        await push(est(at.add(Duration(seconds: j)), fixAt));
      }
    }

    final lines = await timingLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('n=13'),
        reason: 'thirteen fixes arrived; the forty-eight ticks between them '
            'are not samples and must not be counted as such');
    expect(lines.single, contains('dt_med=5.00s'),
        reason: 'counting ticks would put this at 1.00s — a receiver five '
            'times faster than the one in the phone');
    expect(lines.single, contains('lag_med=0.30s'));
  });

  test('② the percentiles are values that were actually measured', () async {
    // Nearest-rank, so every figure printed is a figure that occurred. An
    // interpolating median would be free to print 1.02s for a stream that only
    // ever delivered 1.00 s and 1.05 s, and this line has to be readable
    // literally.
    //
    // Sixty samples, which closes the window on COUNT (the other trigger; ④
    // covers the clock). Lags are lopsided on purpose:
    //
    //   50 × 100 ms, 6 × 500 ms, 4 × 2,100 ms   (the last is M2's observation)
    //   p50 → index ceil(0.50·60)−1 = 29 → 0.10s
    //   p90 → index ceil(0.90·60)−1 = 53 → 0.50s   (the four outliers are 56–59)
    //
    // and the 59 intervals are 52 × 500 ms with 7 × 900 ms scattered through
    // them (a fast Android fused provider rather than the 1 Hz of ①, so that
    // sixty samples fit inside the sixty seconds and the COUNT trigger is the
    // one being exercised):
    //   p50 → index ceil(0.50·59)−1 = 29 → 0.50s
    //   p90 → index ceil(0.90·59)−1 = 53 → 0.90s
    Duration lagFor(int i) {
      if (i >= 56) return const Duration(milliseconds: 2100);
      if (i >= 50) return const Duration(milliseconds: 500);
      return const Duration(milliseconds: 100);
    }

    // Seven of the gaps are longer, spread out so no run of them can be
    // mistaken for a signal gap.
    const longGaps = {3, 11, 19, 27, 35, 43, 51};
    var at = t0;
    for (var i = 0; i < 60; i++) {
      await push(est(at, at.subtract(lagFor(i))));
      at = at.add(longGaps.contains(i)
          ? const Duration(milliseconds: 900)
          : const Duration(milliseconds: 500));
    }

    final lines = await timingLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('n=60'));
    expect(lines.single, contains('dt_n=59'),
        reason: 'one fewer interval than samples, and it is reported rather '
            'than left to be assumed');
    expect(lines.single, contains('dt_med=0.50s'));
    expect(lines.single, contains('dt_p90=0.90s'));
    expect(lines.single, contains('lag_med=0.10s'));
    expect(lines.single, contains('lag_p90=0.50s'),
        reason: 'fifty-six of sixty samples landed within 500 ms, so p90 is '
            '500 ms — the four 2.1 s outliers must not become the reported p90');
  });

  test('③ too few samples writes nothing at all', () async {
    // A median over three points is not a measurement of anything, and a stream
    // that keeps starting and stopping would otherwise fill the log with them.
    // Three samples, then a fourth arriving after the window's 60 s: the window
    // closes with n=4 and is dropped.
    await ride(3);
    await push(est(t0.add(const Duration(seconds: 61)),
        t0.add(const Duration(seconds: 61))));
    expect(await timingLines(), isEmpty);

    // And the window really did close: the next full run writes exactly one
    // line, covering only itself.
    await ride(6, from: t0.add(const Duration(seconds: 62)));
    await push(est(t0.add(const Duration(seconds: 130)),
        t0.add(const Duration(seconds: 130))));
    final lines = await timingLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('n=7'));
  });

  test('④ one line per window — 60 samples or 60 seconds, whichever first',
      () async {
    // ⛔ The rule this defends is "never a line per sample": at 1 Hz that is
    // 3,600 rows an hour, in a log with a byte budget that the rest of the
    // evidence in `feedback_log` has to fit inside.
    await ride(59);
    expect(await timingLines(), isEmpty,
        reason: '59 samples is not a full window, and 58 s is not a full '
            'minute; nothing is written until one of the two limits is hit');

    await ride(1, from: t0.add(const Duration(seconds: 59)));
    final afterCount = await timingLines();
    expect(afterCount, hasLength(1));
    expect(afterCount.single, contains('n=60'));

    // The other limit: a slow stream that never reaches 60 samples still gets a
    // line once a minute. Eight seconds apart, so the ninth sample is the first
    // one 60 s past the window's start.
    await ride(10,
        dt: const Duration(seconds: 8),
        from: t0.add(const Duration(seconds: 61)));
    final afterSpan = await timingLines();
    expect(afterSpan, hasLength(2),
        reason: 'the second window closed on elapsed time, not on count');
    expect(afterSpan.last, contains('n=9'));
    expect(afterSpan.last, contains('dt_med=8.00s'));
  });

  test('⑤ the stream stopping clears the window', () async {
    // A rebind or an end of stream is the loss of a measurement, not the end of
    // one: the samples in hand were cut short by the lifecycle gate or the
    // master switch, and flushing them would report the phone's sampling rate
    // over whatever fraction of a minute the app was in the foreground. The
    // partial window is dropped, and — the half that would rot silently — the
    // NEXT window must not measure an interval across the seam.
    await ride(30);
    final rebound = StreamController<SpeedEstimate>.broadcast();
    addTearDown(rebound.close);
    tele.bindSpeedEstimates(rebound.stream);
    expect(await timingLines(), isEmpty,
        reason: 'the interrupted window is dropped, not flushed');

    // An hour later, a new session of six samples one second apart, closed by a
    // seventh past the minute.
    final t1 = t0.add(const Duration(hours: 1));
    for (var i = 0; i < 6; i++) {
      final at = t1.add(Duration(seconds: i));
      rebound.add(est(at, at.subtract(const Duration(milliseconds: 300))));
      await pumpEventQueue();
    }
    rebound.add(est(t1.add(const Duration(seconds: 61)),
        t1.add(const Duration(seconds: 61))));
    await pumpEventQueue();

    final lines = await timingLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('n=7'),
        reason: 'the 30 samples before the rebind are gone, not carried over');
    expect(lines.single, contains('dt_med=1.00s'),
        reason: 'an interval measured across the seam would be 3,600 s and '
            'would sit in the middle of a six-interval window');
  });

  test('⑥ a signal gap breaks the interval chain, not the window', () async {
    // `dt` answers "how often does the platform deliver". A value spanning a
    // tunnel answers "how long was the tunnel", and one 40 s outlier drags p90
    // on its own. So a non-live estimate breaks the chain — while the samples
    // already measured stay in the window, because nothing is wrong with them.
    await ride(5);
    // The tunnel: `tick()` publishes holding, then lost, both carrying the last
    // real fix's `lastLiveAt`.
    await push(est(t0.add(const Duration(seconds: 7)),
        t0.add(const Duration(seconds: 4)),
        state: SpeedState.holding));
    await push(est(t0.add(const Duration(seconds: 40)),
        t0.add(const Duration(seconds: 4)),
        state: SpeedState.lost));
    // Out the other side. Sixteen samples, the last of which is 60 s after the
    // window opened and therefore closes it.
    await ride(16, from: t0.add(const Duration(seconds: 45)));

    final lines = await timingLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('n=21'),
        reason: 'all twenty-one fixes were delivered and all have a lag; the '
            'two non-live ticks are neither');
    expect(lines.single, contains('dt_n=19'),
        reason: 'four intervals in the first run, fifteen in the second, and '
            'none across the gap between them');
    expect(lines.single, contains('dt_p90=1.00s'),
        reason: 'a 41 s interval across the tunnel would be the p90 here and '
            'would read as a receiver that stops for most of a minute');
  });

  test('🔴 G5: the line carries time and counts, and nothing else', () async {
    // The estimate this folder reads carries `vSmoothMps`. A log of speeds
    // against timestamps is a journey, which is the thing design 0042 G5 exists
    // to keep out of a file the user is asked to send us. The fixture rides at
    // a fixed 17.25 m/s = 62.1 km/h precisely so those digits would show up
    // here if anything leaked them.
    await ride(10, lag: const Duration(milliseconds: 350));
    await push(est(t0.add(const Duration(seconds: 61)),
        t0.add(const Duration(seconds: 61))));

    final lines = await timingLines();
    expect(lines, hasLength(1));
    final line = lines.single;
    expect(line, isNot(contains('17')));
    expect(line, isNot(contains('62')));
    // Stronger than a blocklist of the fixture's own digits: the whole line has
    // to match the shape, so a future field can only be added by editing this.
    expect(
      RegExp(r'^speed-timing: n=\d+ dt_n=\d+ dt_med=(-|[\d.]+s) '
              r'dt_p90=(-|[\d.]+s) lag_med=(-|-?[\d.]+s) '
              r'lag_p90=(-|-?[\d.]+s)$')
          .hasMatch(line),
      isTrue,
      reason: 'the line is $line',
    );
  });
}
