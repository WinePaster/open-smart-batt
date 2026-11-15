/// OpenSmartBatt — what the 搜尋裝置 list shows, and what it hides and why.
///
/// Two independent filters act on the scan hits that are not saved:
///
///  * the vendor toggle (「顯示全部 BLE 裝置」), default RCE-only;
///  * 「搜尋訊號門檻」— the weakest RSSI shown (何先生 request 2026-11-15;
///    owner ruling: scan list only, default no limit).
///
/// 🔑 The two hidden counts never overlap, so each note under the list names
/// rows that ITS OWN control would bring back:
///
///  * [ScanListView.nonVendorHidden] counts non-RCE rows that PASS the
///    threshold — tapping 顯示全部 reveals exactly that many;
///  * [ScanListView.weakHidden] counts rows that the vendor toggle would show
///    but the threshold hides — relaxing the threshold reveals exactly those.
///
/// A row that is both weak AND non-RCE (with the toggle off) is in neither
/// count: no single control brings it back, and counting it under one note
/// would make that note's promise false.
///
/// Saved devices, the pinned linked-but-unsaved row, auto-connect and the
/// multi-link presence scan never pass through here — the threshold is a
/// display filter on this one list and nothing else.
library;

import '../../ble/ble.dart';

/// The 搜尋裝置 list after both filters.
class ScanListView {
  const ScanListView({
    required this.shown,
    required this.nonVendorHidden,
    required this.weakHidden,
  });

  final List<DiscoveredDevice> shown;
  final int nonVendorHidden;
  final int weakHidden;
}

/// Filters [nearby] (scan hits not already saved). [rssiMin] null = 不限制.
///
/// `rssi >= rssiMin` passes, so a threshold of -80 keeps a -80 dBm row.
ScanListView filterScanList({
  required List<DiscoveredDevice> nearby,
  required bool showAll,
  required int? rssiMin,
}) {
  bool strong(DiscoveredDevice r) => rssiMin == null || r.rssi >= rssiMin;
  bool vendorOk(DiscoveredDevice r) => showAll || r.isVendor;
  final passing = [for (final r in nearby) if (strong(r)) r];
  final shown = [for (final r in passing) if (vendorOk(r)) r];
  return ScanListView(
    shown: shown,
    nonVendorHidden: passing.length - shown.length,
    weakHidden: rssiMin == null
        ? 0
        : nearby.where((r) => !strong(r) && vendorOk(r)).length,
  );
}
