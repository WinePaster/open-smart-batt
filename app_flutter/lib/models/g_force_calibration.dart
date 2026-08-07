/// OpenSmartBatt — the stored phone→vehicle rotation (design 0045 §3.2).
///
/// PURE Dart. Persisted as JSON TEXT in `settings.g_calibration`, a column
/// design 0042's v12 migration created on this feature's behalf — so the column
/// shipped a release before anything wrote it.
///
/// ## Why this is a storage shape and not just a matrix
///
/// The accelerometer reports in PHONE coordinates. "Longitudinal G" and
/// "lateral G" are statements about the VEHICLE, and nothing on the phone knows
/// how it was strapped to the frame. This object is the entire bridge between
/// the two, which is why it is stored rather than recomputed: the alignment is
/// a property of the physical mount, so it survives until the mount changes.
///
/// 🔴 [decode] NEVER throws, and a matrix it cannot vouch for decodes to NULL
/// rather than to something approximate. The precedent is
/// `DisplayLayout.decode` / `HomeLayout.decode`, but the stakes here are
/// different in kind: an unreadable layout costs a wrong-looking page, while an
/// unreadable rotation would put a plausible number under a label that names a
/// direction — "braking 0.4 g" when the phone was measuring sideways. Design
/// 0045 G1 says the app must not pretend to have axes it does not have, and
/// NULL is how that is said. NULL means "not calibrated", the card does not
/// render, and the settings page asks for a calibration.
library;

import 'dart:convert';
import 'dart:math' as math;

/// A three-component vector, in whichever frame the holder says it is in.
///
/// Deliberately tiny and local rather than `vector_math`'s `Vector3`: this file
/// and its estimator are the only users, they need six operations between them,
/// and a pure-Dart type with no package behind it is what lets the whole
/// calibration layer be tested with synthetic vectors and no plugin.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);

  final double x, y, z;

  double get magnitude => math.sqrt(x * x + y * y + z * z);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);

  Vec3 scaled(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) => Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  /// Unit vector, or null when this is too short to have a direction.
  ///
  /// Null rather than a division by a near-zero: a "direction" derived from
  /// numerical noise is exactly the kind of confident nonsense G1 forbids.
  Vec3? get normalized {
    final m = magnitude;
    if (!m.isFinite || m < 1e-6) return null;
    return scaled(1 / m);
  }

  /// Angle to [o] in degrees, or null when either has no direction.
  double? angleDegreesTo(Vec3 o) {
    final a = normalized, b = o.normalized;
    if (a == null || b == null) return null;
    final c = a.dot(b).clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${z.toStringAsFixed(3)})';
}

/// The rotation from phone coordinates to vehicle coordinates, plus when it was
/// established.
///
/// The vehicle frame is **x = forward, y = left, z = up** (right-handed:
/// x × y = z). [rotation] is row-major 3×3, and its ROWS are those three
/// vehicle axes expressed in phone coordinates — so `toBody` is three dot
/// products and needs no matrix library.
class GForceCalibration {
  const GForceCalibration(
      {required this.rotation,
      required this.calibratedAt,
      this.invalidated = false});

  /// Row-major 3×3, exactly nine finite values. Row 0 = forward, row 1 = left,
  /// row 2 = up, each a unit vector in PHONE coordinates.
  final List<double> rotation;

  /// When the user completed the wizard. Shown on the settings row so "I
  /// calibrated it ages ago, before I moved the mount" is answerable without
  /// guessing.
  final DateTime calibratedAt;

  /// The mount has been detected to have moved since this matrix was taken.
  ///
  /// 🔴 Persisted rather than held in memory, and kept ALONGSIDE the matrix
  /// rather than replacing it.
  ///
  /// Memory-only was the first attempt and it forgot across a restart: the old
  /// matrix read back, the meter went on drawing, and a rider who moved the
  /// mount and rode off without ever standing still for the two seconds the
  /// check needs had a whole session on wrong axes — landing in
  /// `g_long`/`g_lat`.
  ///
  /// Clearing the column instead was the second attempt and it was worse than
  /// it looked. Design 0045 §3.6 specifies two DIFFERENT sentences on the
  /// settings page — 「尚未校準」 and 「校準已失效 —— 手機位置似乎被移動過」 —
  /// plus the date of the last calibration. Clearing collapses them into the
  /// first one, so the app stops being able to tell the user WHY the meter
  /// disappeared, and the date goes with it. The card's ruling (Q8: it simply
  /// does not appear) is about the CARD; the settings page was designed to
  /// carry the distinction, and it does.
  ///
  /// Riding in the same column is what keeps this off the schema: `g_calibration`
  /// is already JSON TEXT, so a key costs nothing and v12 stays the last
  /// migration (design 0044 Q2 forbids a v13).
  final bool invalidated;

  /// A fresh matrix supersedes any invalidation — recalibrating IS the remedy.
  GForceCalibration get markedInvalid => GForceCalibration(
      rotation: rotation, calibratedAt: calibratedAt, invalidated: true);

  /// JSON key for the matrix. Short because this is a settings column, not a
  /// document — and stable because it is a wire value.
  static const String matrixKey = 'm';

  /// JSON key for the timestamp (epoch milliseconds, UTC).
  static const String atKey = 'at';

  /// JSON key for [invalidated].
  static const String invalidKey = 'invalid';

  /// Build from three ORTHONORMAL vehicle axes given in phone coordinates.
  ///
  /// Returns null when the three do not form a usable frame — the same refusal
  /// [decode] makes, applied at the point the wizard produces one, so a bad
  /// calibration cannot be persisted and then rejected on the next launch.
  static GForceCalibration? fromAxes({
    required Vec3 forward,
    required Vec3 left,
    required Vec3 up,
    required DateTime at,
  }) {
    final f = forward.normalized, l = left.normalized, u = up.normalized;
    if (f == null || l == null || u == null) return null;
    final c = GForceCalibration(
      rotation: [f.x, f.y, f.z, l.x, l.y, l.z, u.x, u.y, u.z],
      calibratedAt: at,
    );
    return c.isUsable ? c : null;
  }

  /// Whether the stored nine numbers really are a rotation.
  ///
  /// Checked on the way IN and on the way OUT. A matrix whose rows are not
  /// orthonormal still produces numbers — just numbers that mean nothing — and
  /// "produces a number" is precisely the failure mode this feature has to
  /// avoid. The tolerance is loose (0.02) because the axes are built from
  /// measured gravity and a measured launch, not from algebra.
  bool get isUsable {
    if (rotation.length != 9) return false;
    for (final v in rotation) {
      if (!v.isFinite) return false;
    }
    final rows = [_row(0), _row(1), _row(2)];
    for (final r in rows) {
      if ((r.magnitude - 1).abs() > 0.02) return false;
    }
    if (rows[0].dot(rows[1]).abs() > 0.02) return false;
    if (rows[0].dot(rows[2]).abs() > 0.02) return false;
    if (rows[1].dot(rows[2]).abs() > 0.02) return false;
    // Right-handedness. A mirrored frame passes every orthonormality check
    // above and silently swaps left for right — a sign error that reads as a
    // working G meter until somebody notices the ball leans the wrong way in a
    // corner.
    final handed = rows[0].cross(rows[1]).dot(rows[2]);
    return (handed - 1).abs() < 0.05;
  }

  Vec3 _row(int i) =>
      Vec3(rotation[i * 3], rotation[i * 3 + 1], rotation[i * 3 + 2]);

  /// The vehicle axes this calibration is made of, in phone coordinates.
  Vec3 get forwardAxis => _row(0);
  Vec3 get leftAxis => _row(1);
  Vec3 get upAxis => _row(2);

  /// Rotate a phone-frame vector into vehicle coordinates.
  Vec3 toBody(Vec3 phone) => Vec3(
        _row(0).dot(phone),
        _row(1).dot(phone),
        _row(2).dot(phone),
      );

  String encode() => jsonEncode({
        matrixKey: rotation,
        atKey: calibratedAt.toUtc().millisecondsSinceEpoch,
        // Written only when true: an absent key reads as false, so every
        // calibration taken before this existed decodes as valid, which is what
        // it was.
        if (invalidated) invalidKey: true,
      });

  /// Read a stored column value. NEVER throws — see the library comment.
  static GForceCalibration? decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    Object? parsed;
    try {
      parsed = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;
    final raw = parsed[matrixKey];
    if (raw is! List || raw.length != 9) return null;
    final m = <double>[];
    for (final v in raw) {
      if (v is! num || !v.toDouble().isFinite) return null;
      m.add(v.toDouble());
    }
    final at = parsed[atKey];
    if (at is! num) return null;
    final c = GForceCalibration(
      rotation: m,
      calibratedAt:
          DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true),
      // Anything other than a literal `true` reads as "not invalidated" — the
      // decoder never throws, and a corrupt flag must not be the thing that
      // silently disables the meter.
      invalidated: parsed[invalidKey] == true,
    );
    return c.isUsable ? c : null;
  }
}
