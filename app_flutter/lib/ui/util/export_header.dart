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

import 'export_scope.dart';

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
  int? connections,
  bool? rawPacketLog,
}) {
  final scopeLine = StringBuffer('scope: $scope');
  if (connections != null) scopeLine.write('  connections=$connections');
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
