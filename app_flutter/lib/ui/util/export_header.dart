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
/// middle; the layout line stays last. [home] is required for the same reason
/// [layout] is — see its line.
List<String> exportHeaderLines({
  required String title,
  required DateTime exportedAt,
  required String appBuild,
  required String platform,
  required String scope,
  required String layout,
  required String home,
  required bool speedDetection,
  required bool gMeter,
  String? window,
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
    // FB-60. WHICH TIME RANGE THE USER ASKED FOR — distinct from the
    // `range: A .. B` the repo computes, and the distinction is the whole
    // point. `range:` says what the data happens to span; `window:` says what
    // was requested, so the two together separate "there is nothing older" from
    // "older rows exist and this file does not contain them". A recipient
    // holding only `range:` cannot tell those apart, and both readings have
    // been made in this corpus.
    //
    // Machine-stable and NOT localized, for the same reason
    // [exportScopeLabel] is: the reader of a preamble is whoever receives the
    // file, months later, not the phone that produced it.
    //
    // Optional, because only the two CSV paths have a time range to declare —
    // the diagnostic log has none, and an unconditional `window: -` there would
    // be a field with nothing behind it (the rule the rest of this preamble
    // follows). Both CSV call sites supply it.
    if (window != null) 'window: $window',
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
    // Ruled 2026-08-09, alongside FB-56 — same answer as FB-37, DIFFERENT
    // reason, and the difference is why this is its own line rather than a
    // clause on the one above.
    //
    // FB-37 discloses an address belonging to OUR OWN unit: the person who
    // exported the file owns the thing being named, so telling them is the
    // whole of the duty. This line discloses THIRD PARTIES — the scan roster
    // (`connection_controller.dart`, `scan hit …`) records every nearby
    // advertiser's advertised name verbatim, including phones, earbuds and
    // laptops belonging to people who never installed this app. "You were told,
    // and it is your own hardware" does not carry across to them. Nobody should
    // be able to cite FB-37 as a precedent for leaving a stranger's device name
    // undisclosed.
    //
    // Disclosure and not redaction, all the same, because the roster's value
    // IS the names: `RCE-SCAP_III` / `RCE-CarBatt` / `RCE-BikeBatt` are the
    // cross-check that tied selector 0x18 to a product class across three
    // units, and a name that looks like a bystander is very often the
    // reporter's own second device (`聖杰的AirPods` beside a readme signed
    // 陳聖杰 is how one batch was attributed to a new reporter at all). The
    // code cannot tell those three cases apart at the moment it writes the
    // line — only a reader can — so the honest move is to say what is in the
    // file rather than to guess which half to destroy. The id beside each name
    // is already hashed; it is the name that is in the clear, and this line
    // says so.
    //
    // 🔴 Emitted for EVERY diagnostic log, never gated on whether the scan
    // actually saw anything. That is FB-32's rule: a note that appears only
    // when there were hits makes its absence mean both "nothing nearby" and
    // "an older build wrote this", and a reader deciding whether to attach the
    // capture to a public issue would have to know our version history to read
    // it. It is gated on `rawPacketLog != null` because that — not the file's
    // contents — is what distinguishes the diagnostic log from the history CSV
    // (only the log path supplies it, and only the log has a scan roster).
    if (rawPacketLog != null)
      'note: this log lists nearby Bluetooth devices seen while scanning, '
          'including their advertised names',
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
    // design 0045 §3.7, and the same FB-32 rule one more time — `required`
    // rather than `bool?` so no call site can quietly stop emitting it.
    //
    // Empty `g_long`/`g_lat` columns have THREE readings and this line settles
    // the first: `off` means the feature was off. `on` narrows the remaining
    // two to "on but never calibrated" and "on, calibrated, but the card was
    // not on screen that minute" — which the `layout:` line below helps with,
    // since a face that never lists `gForce` cannot have shown one. Those two
    // call for different replies to a reporter; neither is "your data is
    // missing".
    //
    // 🔴 It reports the SWITCH, not availability. Availability moves during a
    // session — the still-window check can withdraw a calibration mid-ride —
    // and a preamble line written once at export time cannot describe a moving
    // value honestly. The switch is a fact about the whole file.
    'g meter: ${gMeter ? 'on' : 'off'}',
    // design 0046 Step 10. The same argument as `layout:` below, applied to the
    // page most screenshots are now OF: since design 0046 R3 the home grid is
    // the default entry point, so "there is no charge reading on screen" needs
    // this line to be readable at all.
    //
    // In the OPTIONAL MIDDLE rather than after `layout:`, deliberately: the
    // ingest scripts anchor on `layout:` being the LAST line
    // (`export_layout_header_test.dart`'s T10 constraint 1), and a value that
    // has shipped for two months is not worth re-negotiating to save a line.
    'home: $home',
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
