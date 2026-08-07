/// OpenSmartBatt — export provenance preamble.
///
/// Every exported file should be able to answer "which build produced this,
/// on what platform, covering what?" without the reader having to guess. The
/// 2026-07-28 field report could only be dated by noticing its CSV was missing
/// two columns — a coincidence, and one that nearly led to reading an app bug
/// (no keep-alive write ⇒ no metadata burst) as a hardware limitation.
///
/// PURE formatting only. The build/platform lookup lives in
/// `state/build_info.dart` and is resolved once at startup by `AppServices`,
/// so an export never waits on a plugin channel — and the preamble necessarily
/// names the same build the rows were stamped with, rather than re-reading the
/// plugin and possibly disagreeing with them.
library;

import '../../models/device_ident.dart';
import 'export_scope.dart';

/// One device the export touches, for the `# devices:` header block (design
/// 0027 §3.1). Carries the RAW device id and MAC internally; [deviceLine]
/// hashes both before they reach the file.
class ExportDeviceIdentity {
  const ExportDeviceIdentity({
    required this.deviceId,
    this.mac,
    this.serial,
    this.classSlug,
    this.name,
    this.label,
  });

  /// Platform device id — Android MAC, iOS NSUUID. Written as its
  /// [shortDeviceHash] (`hash=`), the same value block separators fall back to,
  /// so old NSUUID-keyed corpus and new records join up (design 0027 §3.2.3).
  final String deviceId;

  /// The device's own BLE address (0x38), if known. 🔴 Written as its
  /// [shortDeviceHash] (`mac=`) — NEVER the raw address (design 0027 §3.1).
  final String? mac;

  /// Full 15-digit product serial, if known.
  final String? serial;

  /// Locale-independent product-class slug (`battery` / `capacitor` /
  /// `powerbank`); omitted when unknown.
  final String? classSlug;

  /// Advertised local name (e.g. `RCE-CarBatt`) — a model, not a unit id.
  final String? name;

  /// The user's alias for the unit, if any.
  final String? label;
}

/// One `#   mac= hash= serial= class= name= label=` line (WITHOUT the `# `
/// prefix), or null if [d] carries nothing beyond its (always-present) hash and
/// even that is empty. Unknown fields are omitted entirely — an empty `serial=`
/// reads as a bug, the same rule the rest of the preamble follows.
///
/// 🔴 CLEAN-ROOM: `mac=` and `hash=` are BOTH [shortDeviceHash] digests. The raw
/// MAC and the raw device id never appear in the output. The hash is a join
/// key, not a privacy control (a 48-bit MAC over five known OUIs is brute-
/// forceable) — its job is only to avoid widening the leak surface a file with
/// `rawPacketLog` off never had (design 0027 §3.1).
String? deviceLine(ExportDeviceIdentity d) {
  final id = d.deviceId;
  if (id.isEmpty) return null;
  final parts = <String>[
    if (d.mac != null && d.mac!.isNotEmpty) 'mac=${shortDeviceHash(d.mac!)}',
    'hash=${shortDeviceHash(id)}',
    if (d.serial != null && d.serial!.isNotEmpty) 'serial=${d.serial}',
    if (d.classSlug != null &&
        d.classSlug!.isNotEmpty &&
        d.classSlug != 'unknown')
      'class=${d.classSlug}',
    if (d.name != null && d.name!.isNotEmpty) 'name=${d.name}',
    if (d.label != null && d.label!.isNotEmpty) 'label=${d.label}',
  ];
  return '  ${parts.join('  ')}';
}

/// The `#`-preamble lines for an export, WITHOUT the `# ` prefix (the writer
/// adds it, since the log and the CSV emit them at different points).
///
/// Optional fields are omitted entirely rather than rendered empty — a line
/// that says `connections=` tells the reader nothing and looks like a bug.
/// [layout] is the exception: it is REQUIRED, so that no call site can quietly
/// stop emitting it. See the line itself for why.
///
/// The shape is a fixed head (four lines, positions relied on by the ingest
/// scripts), an optional middle, and a fixed tail. New optional lines join the
/// middle; the layout line stays last.
List<String> exportHeaderLines({
  required String title,
  required DateTime exportedAt,
  required String appBuild,
  required String platform,
  required String scope,
  required String layout,
  required bool speedDetection,
  int? connections,
  bool? rawPacketLog,
  List<ExportDeviceIdentity> devices = const [],
}) {
  final scopeLine = StringBuffer('scope: $scope');
  if (connections != null) scopeLine.write('  connections=$connections');
  // design 0027 §3.1: one authoritative list of every device this export
  // touches, so an all-devices export names its units instead of leaving only
  // user nicknames. Each line's mac/hash are hashed by [deviceLine].
  final deviceLines = <String>[
    for (final d in devices) ?deviceLine(d),
  ];
  return <String>[
    title,
    'exported: ${exportedAt.toIso8601String()}',
    scopeLine.toString(),
    'app: $appBuild  platform: $platform',
    // FB-32. A capture arrived holding ONE line of content beside a CSV with
    // 366 samples: raw packet logging defaults off, so the packets were never
    // written at all. Nothing in the file said so, and we spent three replies
    // telling reporters to change their export scope instead — which was not
    // the cause.
    //
    // `on` is emitted too, deliberately. If only `off` appeared, a missing line
    // would mean both "it was on" and "an older build wrote this" — the same
    // ambiguity that made FB-10's version inference a coincidence rather than a
    // fact.
    if (rawPacketLog != null)
      'raw packet log: ${rawPacketLog ? 'on' : 'off'}',
    // FB-37, ruled 2026-07-30: disclose rather than redact. Whoever RECEIVES
    // the file needs this as much as whoever sent it — a reader deciding
    // whether to attach a capture to a public issue is not the same person who
    // saw the export dialog.
    if (rawPacketLog == true)
      'note: raw frames include the device\'s own BLE address (selector 0x38)',
    // design 0027 §3.1. Emitted as a `devices: N` count line followed by one
    // indented line per unit — all `#` comments, so the ingest scripts skip
    // them (G3). Placed in the optional middle, before the required layout tail.
    if (deviceLines.isNotEmpty) 'devices: ${deviceLines.length}',
    ...deviceLines,
    // design 0042 §3.9, and the same FB-32 rule as `raw packet log:` above —
    // which is why it is `required` rather than `bool?`. Without it, a CSV with
    // no values in the `speed` column has TWO readings: the feature was off, or
    // it was on and the signal never arrived for a single minute. Those call
    // for opposite replies to a reporter.
    //
    // It also disambiguates the layout line below it, which is deliberately NOT
    // filtered by the switch: a phone with `riding` stored and the switch off
    // reports `face=riding modules=speed,…` while DRAWING `standard`. The two
    // lines read together say why. Neither line alone can.
    'speed detection: ${speedDetection ? 'on' : 'off'}',
    // Design 0034 §8. Our problem-reading runs on screenshots: every entry in
    // `feedback-attachments/our-app.md` is a field read off a picture, and
    // sentences like "SOC shows --" or "four DVOL bars of similar length" are
    // only evidence because we knew what that screen was supposed to look like.
    // A customisable dashboard makes "there is no charge reading on screen"
    // mean two different things — the data never came, or that card is not on
    // their page — and we would find out the slow way, months later, from a
    // capture we could no longer interpret.
    //
    // Required rather than optional, and emitted even for the default layout,
    // for the FB-32 reason: if only a customised layout were written, a missing
    // line would mean both "they kept the default" and "an older build wrote
    // this". Last, on its own line, and never merged into `scope:` — the ingest
    // regexes anchor on those prefixes. The value itself carries no `: `,
    // because the analysis recipes read it with a greedy `sed 's/.*: //'`.
    'layout: $layout',
  ];
}

/// Machine-stable description of what an export covers, e.g.
/// `device=battery/1206 session=3`. Deliberately NOT localized: a preamble is
/// read by whoever receives the file (and by us, months later), so it must not
/// change with the exporting phone's UI language.
String exportScopeLabel(ExportTarget target) => switch (target.scope) {
      ExportScope.allDevices => 'all devices',
      ExportScope.currentDevice =>
        'device=${target.classSlug}/${target.ident ?? '-'}',
      ExportScope.currentSession =>
        'device=${target.classSlug}/${target.ident ?? '-'} '
            'session=${target.sessionId}',
    };
