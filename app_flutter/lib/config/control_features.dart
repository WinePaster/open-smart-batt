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
  const ControlFeatures({this.cutOff = false});

  /// Offer 斷電 (`0x23` <- `0x02`) on an identified smart battery (design 0104,
  /// pro only). The send path is the release's, byte for byte, with only the
  /// mode byte changed — see `sendModeWithAuthPlan`.
  final bool cutOff;

  /// The community build: nothing beyond release.
  static const ControlFeatures none = ControlFeatures();
}
