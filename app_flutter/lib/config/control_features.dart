/// Which device-state controls this build offers beyond the community set.
///
/// Injected by a composition root through `bootstrap(allowCutOff: …)` and
/// published with `Provider<ControlFeatures>`. The community `main.dart` passes
/// nothing, so every field is off and the protection card is exactly what it
/// was before this class existed.
///
/// 🔴 Deliberately NOT a field of [AppConfig]: that class carries branding only
/// and its header forbids behaviour (design 0092). A control that can leave a
/// vehicle unable to start is behaviour if anything is, so it travels through
/// its own seam — the same shape as `deviceInfoPanelBuilder`.
library;

class ControlFeatures {
  const ControlFeatures({this.cutOff = false, this.lock = false});

  /// Offer 斷電 (`0x23` <- `0x02`) on an identified smart battery (design 0104,
  /// pro only). The send path is the release's, byte for byte, with only the
  /// mode byte changed — see `sendModeWithAuthPlan`.
  final bool cutOff;

  /// Offer 上鎖 (`0x23` <- `0x01`, anti-theft) on an identified smart battery
  /// or black box (design 0108, pro only). Sent through the same
  /// `sendModeWithAuthPlan` as 復電 and 斷電 — mode byte changed, nothing else.
  final bool lock;

  /// The community build: nothing beyond release.
  static const ControlFeatures none = ControlFeatures();
}
