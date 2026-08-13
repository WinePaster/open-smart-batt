/// OpenSmartBatt — "which unit am I exporting?"
///
/// The dealer runs several units through the same phone, so an export has to
/// say which one it covers — both in the rows it contains and in the filename.
/// This file owns that choice and the identity fragments derived from it, so
/// the three export call sites (settings CSV, settings log, history CSV) behave
/// identically.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../dashboard/watchfaces.dart';
import 'export_header.dart';
import 'export_naming.dart';

/// What a chosen export covers.
enum ExportScope {
  /// Every row, including rows recorded before device attribution existed.
  allDevices,

  /// Only the unit currently connected.
  currentDevice,

  /// Only the current connection of the current unit (diagnostic log only).
  currentSession,
}

/// A resolved export scope: the DB filters, the filename fragments, and the
/// layout line — **all of it resolved ONCE**, at the instant the user asked for
/// the export.
///
/// ## 🔑 Why this object carries `layout` (FB-68)
///
/// An export is not atomic and never was: the user taps export, a scope sheet
/// opens, a file is streamed, and it is shared. Each of those steps used to
/// re-derive what the file says about the unit — the ident here, the layout at
/// the call site, seconds apart — and the link can drop in between. It did, in
/// the field, TWICE on the same unit across two releases (batches 2026.08.03-002
/// on 0.6.14 and 2026.08.13-001 on 0.7.15): the history CSV and the diagnostic
/// log of one sitting, 14 s and 17 s apart, named the SAME device with two
/// different identity strings — a 15-digit serial in one file and the sanitized
/// alias in the other — in both `# scope:` and the filename. The 08.13 pair also
/// disagreed on `layout:` (`face=fixed modules=…` against `face=- modules=-`),
/// from the same teardown, because `currentExportLayoutValue` is gated on
/// `conn.isOnline`.
///
/// Persistent fallbacks alone (see [exportDeviceIdent]) make the two answers
/// USUALLY agree; they cannot make them agree BY CONSTRUCTION, because two
/// lookups at two instants are still two lookups. This value is the guarantee:
/// every field a file stamps about the unit is resolved in one place
/// ([chooseExportScope]) and then carried, immutable, to every writer. If the
/// link dies mid-export the files fall back TOGETHER, to the same string.
class ExportTarget {
  const ExportTarget({
    required this.scope,
    this.deviceId,
    this.sessionId,
    this.classSlug,
    this.ident,
    this.layout = kExportLayoutNone,
  });

  /// Everything, no filename fragments — the pre-0006 behaviour.
  ///
  /// ⚠️ Carries the "no layout was in force" default. [chooseExportScope] does
  /// NOT return this constant; it stamps the snapshot's layout onto an
  /// all-devices target of its own, because an all-devices export taken from a
  /// connected phone still has a dashboard to describe.
  static const ExportTarget all = ExportTarget(scope: ExportScope.allDevices);

  final ExportScope scope;

  /// Storage filter. Never rendered into a filename (it is a MAC on Android).
  final String? deviceId;
  final int? sessionId;

  /// Filename fragments: locale-independent class slug + human identity.
  final String? classSlug;
  final String? ident;

  /// The `layout:` preamble line for this export — [exportLayoutValue]'s
  /// output, snapshotted with [ident] rather than read again at write time.
  ///
  /// Not nullable and not omitted: `exportHeaderLines` requires the line, and
  /// [kExportLayoutNone] is the honest value for "no unit's layout was in
  /// force", which is what an offline export means.
  final String layout;

  /// The same identity, re-scoped to the current connection (diagnostic log
  /// only).
  ///
  /// The point is what it does NOT do: it copies [ident], [classSlug] and
  /// [layout] instead of resolving them a second time, so the two entries the
  /// scope sheet offers cannot describe the unit differently.
  ExportTarget asSession(int? sessionId) => ExportTarget(
        scope: ExportScope.currentSession,
        deviceId: deviceId,
        sessionId: sessionId,
        classSlug: classSlug,
        ident: ident,
        layout: layout,
      );
}

/// The human identity fragment for one unit — serial, else alias, else hash.
///
/// 🔴 The serial has THREE sources and they are consulted in this order:
/// the saved record, then the `device_facts` cache, then the live link. That is
/// deliberately the same ladder [exportDeviceIdentities] has used since design
/// 0057 for the `# devices:` block, and the divergence between the two is what
/// FB-68 was: the header list already survived a disconnect, while THIS chain
/// began at `tele.fullSerial` — a value the telemetry controller wipes the
/// moment the link drops (`_sample = TelemetrySample.empty()`), so a teardown
/// mid-export silently demoted the whole file to the alias rung.
///
/// Stored before live is not a statement about trust — both come off the wire,
/// `_persistIdentity` writes exactly `fullSerial` onto the record — it is about
/// having ONE answer, and it is the order [deviceClassFor] and
/// [exportDeviceIdentities] already use. It also means `# scope:` and the
/// `serial=` in `# devices:` name the unit identically, which they could not be
/// relied on to do before.
///
/// [liveSerial] stays as the last serial rung rather than being dropped: it is
/// the only source for a unit that is neither saved nor yet cached, and it is
/// where the pre-FB-68 behaviour lived. Passing `tele.fullSerial ?? tele.serial`
/// keeps the partial 0x26 tail usable mid-burst exactly as before.
///
/// Takes the controllers rather than a [BuildContext] for [deviceLabelFor]'s
/// reason — nothing here may depend on the screen still existing.
String? exportDeviceIdent(
  DeviceController devices,
  String deviceId, {
  DeviceFactsController? facts,
  String? liveSerial,
}) {
  final saved = devices.deviceFor(deviceId);
  final serials = <String?>[
    saved?.serial,
    facts?.factFor(deviceId)?.serial,
    liveSerial,
  ];
  return deviceIdentFragment(
    serial: serials.firstWhere(
      (s) => s != null && s.isNotEmpty,
      orElse: () => null,
    ),
    alias: saved?.alias,
    deviceId: deviceId,
  );
}

/// Builds the [ExportTarget] for the connected unit, or null when offline.
///
/// One resolution of everything a file will say about the unit: class slug,
/// identity ([exportDeviceIdent]) and the [layout] the caller has already
/// snapshotted. Called EXACTLY ONCE per export — the session variant is derived
/// with [ExportTarget.asSession] rather than by calling this again.
ExportTarget? currentDeviceTarget(
  BuildContext context, {
  required String layout,
}) {
  final tele = context.read<TelemetryController>();
  final deviceId = tele.recordingDeviceId;
  if (deviceId == null) return null;
  final devices = context.read<DeviceController>();
  // Looked up as a nullable type (design 0057): provider yields null where
  // nobody supplied a cache, and this then behaves as it did before it existed.
  final facts = context.read<DeviceFactsController?>();
  final conn = context.read<ConnectionController>();
  return ExportTarget(
    scope: ExportScope.currentDevice,
    deviceId: deviceId,
    // Same three-rung ladder as the identity above, and the cached middle rung
    // is here for the identical FB-68 reason: without it a unit that was never
    // named reported its real class while the link was up and `unknown` a few
    // seconds later, in the FILENAME.
    classSlug: productClassSlug(deviceClassFor(
      devices,
      deviceId,
      facts: facts,
      liveDeviceId: deviceId,
      liveClass: conn.resolvedClass,
    )),
    ident: exportDeviceIdent(
      devices,
      deviceId,
      facts: facts,
      liveSerial: tele.fullSerial ?? tele.serial,
    ),
    layout: layout,
  );
}

/// The authoritative `# devices:` list for an export (design 0027 §3.1): one
/// [ExportDeviceIdentity] per unit the export touches.
///
/// A device-scoped export touches exactly its one unit; an all-devices export
/// touches every unit the diagnostic log has an attributed row for. Each unit's
/// mac / serial / class / name come from its saved record, with a live fallback
/// to the connected unit's freshly-decoded MAC and serial for the case where a
/// 0x38 frame has arrived this session but not yet been persisted.
///
/// 🔴 The RAW mac is carried here; the file only ever sees its hash — the
/// hashing happens in [deviceLine], never here.
Future<List<ExportDeviceIdentity>> exportDeviceIdentities(
  DeviceController devices,
  TelemetryController tele,
  ExportTarget target, {
  DeviceFactsController? facts,
}) async {
  final ids = target.deviceId != null
      ? <String>[target.deviceId!]
      : await tele.logDistinctDeviceIds();
  final recordingId = tele.recordingDeviceId;
  return [
    for (final id in ids)
      () {
        final saved = devices.deviceFor(id);
        // design 0057 §4.3: the middle rung. Without it the header could only
        // name a unit that was either saved or still on the link, so the
        // provenance of an unnamed unit's rows — G3 — went missing the moment
        // it disconnected. It is consulted BELOW the saved record (one answer,
        // and the user's own record is the one to keep) and ABOVE the live
        // fallback (a stored observation outranks re-reading it).
        final cached = facts?.factFor(id);
        final isLive = id == recordingId;
        final savedName = saved?.name ?? '';
        return ExportDeviceIdentity(
          deviceId: id,
          mac: saved?.mac ?? cached?.mac ?? (isLive ? tele.mac : null),
          serial:
              saved?.serial ?? cached?.serial ?? (isLive ? tele.fullSerial : null),
          classSlug: productClassSlug(deviceClassFor(devices, id, facts: facts)),
          // `saved.name` is NOT NULL and defaults to '', so an empty one is
          // "this record predates the name column" rather than a name — fall
          // through to the cache instead of writing the blank out.
          name: savedName.isNotEmpty ? savedName : cached?.name,
          label: saved?.alias,
        );
      }(),
  ];
}

/// The product class for one `device_id`, or [ProductClass.unknown].
///
/// Used by the CSV export to blank the current column for a super-capacitor,
/// which streams a permanent 0.0 A it cannot actually measure. Exporting that
/// zero would state, as fact, that the unit is drawing no current.
///
/// 🔴 [liveDeviceId] / [liveClass] are not an optional nicety. This read the
/// SAVED record and nothing else, which was safe only while "connected but not
/// saved" was a dead end — design 0055 made it an ordinary way to use the app,
/// and an unsaved capacitor's export therefore carried its fake `0.0 A` as
/// measured fact. The live pair closes that: for the unit actually on the link,
/// the class comes from the wire.
///
/// The stored value still wins where both exist — same order as
/// [currentDeviceTarget] — and the live one is consulted ONLY for the unit whose
/// id matches, never as an ambient default. That restriction is the whole point:
/// applying the connected unit's class to another unit's rows is FB-41 with a
/// different column.
///
/// Takes plain values rather than a [BuildContext] for [deviceNameFor]'s reason
/// — this runs inside the repo after an await, when the screen may be gone.
/// [facts] is design 0057's middle rung: what the unit itself said, cached on
/// every connection whether or not it was ever named. It sits BELOW the saved
/// record (which the user owns) and ABOVE the live pair, and it is what makes
/// the capacitor case survive a disconnect — before it, connect / look / export
/// / never name it left the class `unknown` the instant the link dropped, and
/// the file went out with a fabricated `0.0 A` again.
ProductClass deviceClassFor(
  DeviceController devices,
  String? deviceId, {
  DeviceFactsController? facts,
  String? liveDeviceId,
  ProductClass liveClass = ProductClass.unknown,
}) {
  if (deviceId == null) return ProductClass.unknown;
  final stored = devices.deviceFor(deviceId)?.productClass;
  if (stored != null && stored != ProductClass.unknown) return stored;
  final cached = facts?.factFor(deviceId)?.productClass;
  if (cached != null && cached != ProductClass.unknown) return cached;
  if (liveDeviceId != null && deviceId == liveDeviceId) return liveClass;
  return ProductClass.unknown;
}

/// Where a unit's displayed name came from. The distinction is not cosmetic —
/// see [deviceLabelFor] for what rides on it (design 0057 Q2).
enum _NameSource {
  /// The user's alias, or the advertised name on their own saved record.
  user,

  /// The advertised name out of `device_facts` — a MODEL name, which two units
  /// in the same room can share.
  advertised,

  /// Nothing is known.
  none,
}

/// The one name-resolution chain, so [deviceNameFor] and [deviceLabelFor]
/// cannot drift apart: alias → saved advertised name → `device_facts` name.
({String name, _NameSource source}) _resolveName(
  DeviceController devices,
  String deviceId,
  DeviceFactsController? facts,
) {
  final saved = devices.deviceFor(deviceId);
  final alias = saved?.alias ?? '';
  if (alias.isNotEmpty) return (name: alias, source: _NameSource.user);
  final savedName = saved?.name ?? '';
  if (savedName.isNotEmpty) return (name: savedName, source: _NameSource.user);
  final cached = facts?.factFor(deviceId)?.name ?? '';
  if (cached.isNotEmpty) {
    return (name: cached, source: _NameSource.advertised);
  }
  return (name: '', source: _NameSource.none);
}

/// A never-blank label for one `device_id`, used for the CSV `device` column
/// and the history picker. Falls back to the short hash so a row is never blank
/// when the unit was never named.
///
/// Takes the controllers rather than a [BuildContext] on purpose: this runs
/// inside the repo AFTER an await, by which time the screen may be gone and a
/// `context.read` would throw mid-export.
///
/// 🔴 A name that came from `device_facts` ALWAYS carries the short hash
/// (`RCE_RSPB-01 · a3f1c2d4`), and that is the Q2 ruling rather than a
/// preference: it is the advertised name, i.e. a model, and models repeat. Two
/// power banks in the 2026-07-29 capture both advertise `RCE_RSPB-01` — the
/// vendor's own scan list shows them side by side — so a picker offering that
/// string twice would be asking the user to choose between two identical
/// entries. A name the USER wrote needs no such suffix; they know which unit
/// they meant.
String deviceLabelFor(
  DeviceController devices,
  String? deviceId, {
  DeviceFactsController? facts,
}) {
  if (deviceId == null) return '';
  final resolved = _resolveName(devices, deviceId, facts);
  return switch (resolved.source) {
    _NameSource.user => resolved.name,
    _NameSource.advertised => '${resolved.name} · ${shortDeviceHash(deviceId)}',
    _NameSource.none => shortDeviceHash(deviceId),
  };
}

/// The name for one `device_id` (their alias, else the advertised name, else —
/// with [facts] — the one cached from the wire), or '' when nothing is known.
/// No hash fallback: callers that need a never-blank string use
/// [deviceLabelFor], while the scope sheet has to be able to tell "unnamed"
/// apart from "named a3f1c2d4".
///
/// Returns the bare name even when it came from `device_facts`; the caller that
/// renders it decides how to disambiguate. The scope sheet already pairs it with
/// [ExportTarget.ident], which produces the same `name · hash` shape Q2 asks
/// for, so appending a second one here would print the hash twice.
String deviceNameFor(
  DeviceController devices,
  String? deviceId, {
  DeviceFactsController? facts,
}) {
  if (deviceId == null) return '';
  return _resolveName(devices, deviceId, facts).name;
}

/// Label for the "this device only" row of the scope sheet.
///
/// Deliberately NOT [deviceIdentFragment] alone. That one is filename-first, so
/// it prefers the serial — which left the sheet saying `1206` on the very same
/// screen whose device filter (history `_deviceBar`) was already saying the
/// user's own name for the unit, with nothing to say they were one and the same
/// unit. The sheet is on-screen text under no filesystem constraint, so the
/// name leads and the serial trails as the confirmation.
///
/// Falls back to [ident] alone when the unit was never named, so an unnamed
/// unit reads exactly as it did before.
String exportScopeDeviceLabel({String? name, String? ident}) {
  final n = name?.trim() ?? '';
  final i = ident?.trim() ?? '';
  if (n.isEmpty) return i;
  if (i.isEmpty || i == n) return n;
  return '$n · $i';
}

/// Ask the user what the export should cover.
///
/// Returns an all-devices target straight away when nothing is connected —
/// there is no meaningful choice to make then, and a one-option sheet is just a
/// tap in the way. Returns null if the user dismisses the sheet.
///
/// 🔑 **This is the snapshot point (FB-68).** All three export handlers reach
/// their first `await` here, so this is the one instant every export shares —
/// the moment the user asked for it. Identity and layout are resolved here,
/// ONCE, and travel inside the returned [ExportTarget]; a handler that reached
/// for `currentExportLayoutValue` again after the sheet closed would be taking a
/// second reading of a value that can have changed, which is the defect.
///
/// ⚠️ The layout is read BEFORE the sheet, alongside the identity, not after the
/// user taps. A few seconds of "which instant is the export stamped from" is
/// worth trading for two files that agree — and the sheet is the user's decision
/// point, not work, so the export it describes starts here.
Future<ExportTarget?> chooseExportScope(
  BuildContext context, {
  required bool offerSession,
}) async {
  // The two halves of the snapshot, taken together. `layout` first because
  // `currentDeviceTarget` takes it: there is no code path that builds a target
  // and then goes looking for a layout.
  final layout = currentExportLayoutValue(context);
  final current = currentDeviceTarget(context, layout: layout);
  if (current == null) {
    return ExportTarget(scope: ExportScope.allDevices, layout: layout);
  }
  // Derived from `current`, never resolved again — see [ExportTarget.asSession].
  final sessionTarget = offerSession
      ? current.asSession(context.read<TelemetryController>().recordingSessionId)
      : null;
  final l10n = AppLocalizations.of(context);
  final label = exportScopeDeviceLabel(
    // Looked up as a nullable type on purpose (design 0057): provider returns
    // null instead of throwing where nobody supplied one, so a screen without
    // the cache degrades to the pre-0057 label rather than failing to build.
    name: deviceNameFor(
      context.read<DeviceController>(),
      current.deviceId,
      facts: context.read<DeviceFactsController?>(),
    ),
    ident: current.ident,
  );

  return showModalBottomSheet<ExportTarget>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.exportScopeTitle,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.smartphone_outlined),
            title: Text(l10n.exportScopeThisDevice(label)),
            onTap: () => Navigator.of(sheetContext).pop(current),
          ),
          if (sessionTarget != null)
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: Text(l10n.exportScopeThisSession),
              onTap: () => Navigator.of(sheetContext).pop(sessionTarget),
            ),
          ListTile(
            leading: const Icon(Icons.all_inclusive_outlined),
            title: Text(l10n.exportScopeAllDevices),
            onTap: () => Navigator.of(sheetContext).pop(
              // Carries the snapshot's layout: an all-devices export taken from
              // a connected phone still has a dashboard to describe, and it is
              // the same dashboard the device-scoped option would have named.
              ExportTarget(scope: ExportScope.allDevices, layout: layout),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
