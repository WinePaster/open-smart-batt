/// OpenSmartBatt — in-memory trend buffer for the dashboard's chart mode.
///
/// A fixed-capacity ring over the last few minutes of telemetry. It exists
/// because the stored history is one AVERAGED row per minute, and a minute
/// average cannot show a second-scale event: in one field capture the current
/// swung between -29 A and +8 A inside a single minute, and the row written for
/// that minute reads -0.31 A. The shape the user is looking for — an electric
/// start, a cranking load, a charger dropping out — lives entirely inside the
/// interval the average destroys.
///
/// Deliberately NOT persisted and NOT exported. Storage granularity is a
/// separate decision with its own costs (60x the rows, and the export path has
/// to be made streaming first); this buffer is the part that costs nothing.
/// Dropping it on disconnect is not a limitation to be fixed later — it is what
/// makes it free.
library;


import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// One scalar series the chart can draw.
enum TrendField {
  /// Pack/main voltage (`0x19`).
  pvlt,

  /// Secondary voltage (`0x37`) — on a power bank this is the output rail.
  svlt,

  /// Main current, signed — but with OPPOSITE conventions per family: a pack's
  /// `0x2E` is negative while discharging, a power bank's `0x4A − 0x49` is
  /// positive while discharging (see [LiveTrendBuffer.add]).
  current,

  /// Temperature in the unit the device reports (°C).
  temperature,

  /// State of charge, power bank only (`0x4B`).
  soc,
}

/// Ring buffer of recent telemetry, one entry per decoded sample.
///
/// Capacity is a count, not a duration: samples arrive at whatever rate the
/// link sustains (field captures put a full telemetry group every ~211 ms, so
/// ~4.8 Hz), and a count keeps the memory bound exact regardless. At the
/// default it is five `Float32List`s plus a `Float64List` of timestamps —
/// roughly 25 KB, which is why nothing here needs a size setting.
///
/// Writes are unthrottled on purpose: every sample goes in, because the shape
/// is the point and a dropped sample is a dropped transient. Throttling belongs
/// to the reader — the chart repaints at a capped rate, driven by [revision].
class LiveTrendBuffer extends ChangeNotifier {
  LiveTrendBuffer({this.capacity = defaultCapacity})
      : assert(capacity > 1),
        _t = Float64List(capacity),
        _pvlt = Float32List(capacity),
        _svlt = Float32List(capacity),
        _current = Float32List(capacity),
        _temp = Float32List(capacity),
        _soc = Float32List(capacity);

  /// ~3 minutes at the ~4.8 Hz seen in the field, rounded up.
  static const int defaultCapacity = 900;

  /// Maximum entries retained. Older entries are overwritten in place.
  final int capacity;

  final Float64List _t;
  final Float32List _pvlt, _svlt, _current, _temp, _soc;

  int _len = 0;
  int _next = 0;
  int _revision = 0;

  /// Bumped on every mutation. A painter compares it in `shouldRepaint` so a
  /// rebuild that changed nothing does not re-rasterise the chart.
  int get revision => _revision;

  /// Number of entries currently held (<= [capacity]).
  int get length => _len;

  bool get isEmpty => _len == 0;

  /// Milliseconds since epoch of the oldest retained entry, or null when empty.
  double? get firstMs => _len == 0 ? null : _t[_indexOf(0)];

  /// Milliseconds since epoch of the newest entry, or null when empty.
  double? get lastMs => _len == 0 ? null : _t[_indexOf(_len - 1)];

  /// Wall-clock span covered, or [Duration.zero] when fewer than two entries.
  Duration get span => _len < 2
      ? Duration.zero
      : Duration(milliseconds: (lastMs! - firstMs!).round());

  /// Fold one decoded sample in.
  ///
  /// [current] is taken from [TelemetrySample.current] as-is, INCLUDING its
  /// sign. On a pack that is `512 - u16(0x2E)`, where **negative is discharge**
  /// (`docs/protocol/telemetry-decoding.md` §8.2, established 2026-08-11);
  /// on a power bank it is `0x4A − 0x49`, the other way round.
  ///
  /// 🔒 Flattening it to a magnitude here is forbidden (2026-08-03 ruling,
  /// design 0030 §7 Q5: `abs()`, `clamp(0, …)` and a positive-only Y range all
  /// violate it). It would erase the reversal that makes a cranking load
  /// recognisable — the one thing the curve shows that the readout cannot. The
  /// readout is where the magnitude-plus-word presentation lives (design 0056);
  /// this buffer feeds both, so it stores neither presentation.
  void add(TelemetrySample s) {
    final i = _next;
    _t[i] = s.timestamp.millisecondsSinceEpoch.toDouble();
    _pvlt[i] = s.pvlt ?? double.nan;
    _svlt[i] = s.svlt ?? double.nan;
    _current[i] = s.current ?? double.nan;
    _temp[i] = s.temperatureC?.toDouble() ?? double.nan;
    _soc[i] = s.socPercent?.toDouble() ?? double.nan;
    _next = (i + 1) % capacity;
    if (_len < capacity) _len++;
    _revision++;
    notifyListeners();
  }

  /// Drop everything. Called when the link goes down or the unit changes —
  /// carrying one unit's trace into another's chart would draw a step that
  /// never happened.
  void clear() {
    if (_len == 0) return;
    _len = 0;
    _next = 0;
    _revision++;
    notifyListeners();
  }

  /// Timestamp of entry [i], oldest first.
  double timeAt(int i) => _t[_indexOf(i)];

  /// Value of [field] at entry [i], oldest first. NaN where the sample did not
  /// carry that field — callers must skip those rather than plot them as zero.
  double valueAt(TrendField field, int i) {
    final k = _indexOf(i);
    return switch (field) {
      TrendField.pvlt => _pvlt[k],
      TrendField.svlt => _svlt[k],
      TrendField.current => _current[k],
      TrendField.temperature => _temp[k],
      TrendField.soc => _soc[k],
    };
  }

  /// True when at least two entries carry a finite value for [field] — i.e.
  /// there is a line to draw at all.
  bool hasData(TrendField field) {
    var n = 0;
    for (var i = 0; i < _len; i++) {
      if (valueAt(field, i).isFinite && ++n > 1) return true;
    }
    return false;
  }

  /// Finite min/max of [field] over the buffer, or null when it has no data.
  ({double min, double max})? rangeOf(TrendField field) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (var i = 0; i < _len; i++) {
      final v = valueAt(field, i);
      if (!v.isFinite) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    return lo.isFinite ? (min: lo, max: hi) : null;
  }

  int _indexOf(int i) =>
      _len < capacity ? i : (_next + i) % capacity;
}
