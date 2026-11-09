/// A peripheral that lives in Dart instead of on the radio (design 0099 P3).
///
/// The demo unit (design 0097) was the only one, and the transport knew it by
/// its concrete type. Generalised so a test can put a protocol that is not RCE
/// behind the same link machinery — connect, keep-alive, write gate,
/// teardown — without a radio. PURE Dart.
library;

/// Answers what the app writes, the way a unit on the other end of a link
/// would: zero or more notification payloads per write.
abstract interface class SimulatedPeer {
  List<List<int>> answer(List<int> written);
}
