/// OpenSmartBatt — the demo units (design 0097).
///
/// PURE Dart (no Flutter imports).
///
/// A demo unit exists so that someone WITHOUT the hardware — an App Store
/// reviewer, or a prospective owner — can see every screen the app has. It is
/// reached through the same `connect(id)` path as a real unit, and the one
/// thing that tells the two apart anywhere in the app is the id.
///
/// 🔴 THE PREFIX IS THE ISOLATION BOUNDARY. Exports, diagnostic logs and the
/// corpus tooling all filter on it, because a demo session produces frames in
/// the real wire format (design 0097 §1, option A) and would otherwise be
/// indistinguishable from field evidence (§2). Real ids are an iOS NSUUID or an
/// Android MAC — hex digits with `-` or `:` — and cannot start with `DEMO-`.
library;

/// The prefix every demo unit's id carries, and the ONLY test for "is this a
/// demo unit". Never infer it from a name or a class.
const String kDemoIdPrefix = 'DEMO-';

/// True when [id] names a demo unit.
bool isDemoDeviceId(String? id) => id != null && id.startsWith(kDemoIdPrefix);

/// The two demo units of the first release (design 0097, owner ruling
/// 2026-11-05: battery + capacitor; flagship capacitor and power bank are out
/// of scope).
enum DemoKind {
  /// A 12 V four-cell smart battery (device-type `0x02`).
  battery('DEMO-BATTERY', 'Demo Battery', 0x02),

  /// A second-generation super-capacitor (device-type `0x17`).
  capacitor('DEMO-CAPACITOR', 'Demo Capacitor', 0x17);

  const DemoKind(this.id, this.advertisedName, this.deviceType);

  /// The unit's id. Starts with [kDemoIdPrefix] — pinned by a test.
  final String id;

  /// What the transport reports as the unit's name. The UI shows a localised
  /// name instead (see `isDemoDeviceId`); this one only reaches places that
  /// print a raw advertised name.
  final String advertisedName;

  /// The `0x10` byte this unit sends. It is what makes the app route to the
  /// right dashboard, exactly as on a real unit (design 0097 §1).
  final int deviceType;

  /// The demo unit [id] names, or null for any other id.
  static DemoKind? fromId(String? id) {
    for (final k in DemoKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }
}
