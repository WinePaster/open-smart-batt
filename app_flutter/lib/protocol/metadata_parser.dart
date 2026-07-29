/// OpenSmartBatt — pluggable device-metadata parser seam.
///
/// PURE Dart, no IO. This is the OPEN-SIDE contract only: an opaque marker type
/// and an injection interface, plus a no-op default. The open build ships the
/// no-op — it decodes NOTHING and enumerates NO selector numbers. A closed build
/// injects a private implementation (in a separate package) that returns its own
/// concrete [DeviceMetadata] subtype; that subtype and the selectors it handles
/// live entirely on the closed side.
///
/// Note (2026-07-30): "the selectors it handles" is a smaller set than it once
/// was. `0x25` / `0x29` / `0x38` / `0x3B` were declassified — they had their own
/// wire evidence from this project's captures and are now documented openly in
/// PROTOCOL.md §8.2.3. The seam is unaffected; the closed set is just shorter.
/// Keeping this comment honest matters, because the previous wording implied
/// the open repository disclosed nothing about those registers, and by then
/// PROTOCOL.md already did.
library;

import 'inbound_frame.dart';

/// Opaque metadata marker. The open side deliberately holds NO fields — the
/// concrete subtype and its field names are defined in the private package, so
/// none of that closed device metadata leaks into the open source. The open
/// build only ever holds one of these and hands it to an (optional, closed) UI
/// builder without reading its contents.
abstract interface class DeviceMetadata {}

/// The empty initial accumulator (open default). A closed [MetadataParser]
/// folds this forward into its own concrete subtype.
class EmptyDeviceMetadata implements DeviceMetadata {
  const EmptyDeviceMetadata();
}

/// Injection point for device-metadata decoding.
///
/// The open side does NOT hardcode any selector list: [handles] is decided by
/// the (private) implementation. The open build injects [NoopMetadataParser].
abstract interface class MetadataParser {
  /// Whether this parser consumes [selector]. The open side never enumerates
  /// closed selector numbers — each implementation self-decides.
  bool handles(int selector);

  /// Fold one inbound [frame] into [prev], returning the accumulated metadata
  /// (a private implementation returns its own concrete [DeviceMetadata]).
  DeviceMetadata fold(DeviceMetadata prev, InboundFrame frame);
}

/// Open-build default: decodes nothing, keeps the accumulator empty.
///
/// [handles] is `false` for every selector 0x00–0xFF and [fold] returns the
/// previous value unchanged, so the open build's behaviour is identical whether
/// or not the seam exists.
class NoopMetadataParser implements MetadataParser {
  const NoopMetadataParser();

  @override
  bool handles(int _) => false;

  @override
  DeviceMetadata fold(DeviceMetadata prev, InboundFrame _) => prev;
}
