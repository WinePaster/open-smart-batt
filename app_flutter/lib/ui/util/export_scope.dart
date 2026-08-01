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

/// A resolved export scope: the DB filters plus the filename fragments.
class ExportTarget {
  const ExportTarget({
    required this.scope,
    this.deviceId,
    this.sessionId,
    this.classSlug,
    this.ident,
  });

  /// Everything, no filename fragments — the pre-0006 behaviour.
  static const ExportTarget all = ExportTarget(scope: ExportScope.allDevices);

  final ExportScope scope;

  /// Storage filter. Never rendered into a filename (it is a MAC on Android).
  final String? deviceId;
  final int? sessionId;

  /// Filename fragments: locale-independent class slug + human identity.
  final String? classSlug;
  final String? ident;
}

/// Builds the [ExportTarget] for the connected unit, or null when offline.
///
/// The identity prefers the live serial (only available once the connect burst
/// lands), then the user's alias, then a short hash of the device id.
ExportTarget? currentDeviceTarget(
  BuildContext context, {
  bool sessionOnly = false,
}) {
  final tele = context.read<TelemetryController>();
  final deviceId = tele.recordingDeviceId;
  if (deviceId == null) return null;
  final devices = context.read<DeviceController>();
  final saved = devices.deviceFor(deviceId);
  final conn = context.read<ConnectionController>();
  final cls = saved?.productClass ?? ProductClass.unknown;
  return ExportTarget(
    scope: sessionOnly ? ExportScope.currentSession : ExportScope.currentDevice,
    deviceId: deviceId,
    sessionId: sessionOnly ? tele.recordingSessionId : null,
    classSlug: productClassSlug(
      cls == ProductClass.unknown ? conn.resolvedClass : cls,
    ),
    ident: deviceIdentFragment(
      serial: tele.fullSerial ?? tele.serial,
      alias: saved?.alias,
      deviceId: deviceId,
    ),
  );
}

/// Human-readable identity for one stored `device_id`, used for the CSV
/// `device` column. Falls back to the short hash so a row is never blank when
/// the unit was never named.
///
/// Takes the controller rather than a [BuildContext] on purpose: this runs
/// inside the repo AFTER an await, by which time the screen may be gone and a
/// `context.read` would throw mid-export.
/// The stored product class for one `device_id`, or [ProductClass.unknown].
///
/// Used by the CSV export to blank the current column for a super-capacitor,
/// which streams a permanent 0.0 A it cannot actually measure. Exporting that
/// zero would state, as fact, that the unit is drawing no current.
ProductClass deviceClassFor(DeviceController devices, String? deviceId) {
  if (deviceId == null) return ProductClass.unknown;
  return devices.deviceFor(deviceId)?.productClass ?? ProductClass.unknown;
}

String deviceLabelFor(DeviceController devices, String? deviceId) {
  if (deviceId == null) return '';
  final saved = devices.deviceFor(deviceId);
  final alias = saved?.alias ?? '';
  if (alias.isNotEmpty) return alias;
  final name = saved?.name ?? '';
  if (name.isNotEmpty) return name;
  return shortDeviceHash(deviceId);
}

/// Ask the user what the export should cover.
///
/// Returns [ExportTarget.all] straight away when nothing is connected — there
/// is no meaningful choice to make then, and a one-option sheet is just a tap
/// in the way. Returns null if the user dismisses the sheet.
Future<ExportTarget?> chooseExportScope(
  BuildContext context, {
  required bool offerSession,
}) async {
  final current = currentDeviceTarget(context);
  if (current == null) return ExportTarget.all;
  final sessionTarget =
      offerSession ? currentDeviceTarget(context, sessionOnly: true) : null;
  final l10n = AppLocalizations.of(context);
  final label = current.ident ?? '';

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
            onTap: () => Navigator.of(sheetContext).pop(ExportTarget.all),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
