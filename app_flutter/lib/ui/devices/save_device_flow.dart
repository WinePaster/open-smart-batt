/// OpenSmartBatt — "name it and remember it", in ONE place (design 0055 §4.4).
///
/// 🔴 This function exists because design 0055 made every row openable, and that
/// change had a way of destroying the feature it was next to.
///
/// Before 0055, a nearby row's tap WAS the connect, so the alias prompt could
/// live inside `DevicesPage._connectNew` and still catch every first connection
/// there was. 0055 gives the row a second destination — the detail page — and
/// the detail page can connect too. Leave the prompt where it was and a user who
/// connects from there is never asked for a name, which means the unit is never
/// saved, which means it never gets a home tile or a history: "save" would have
/// become unreachable through an entrance we just built.
///
/// So the prompt moves to where BOTH callers can reach it. Nothing about it
/// changes — same dialog, same fields, same "cancel means no" — only its
/// address. See design 0055 §4.4 for why this is a move and not a new UI: an
/// AppBar save icon was considered and rejected (an icon cannot explain itself,
/// and the common path needs no new entry point at all).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import 'alias_dialog.dart';

/// Ask for an alias and save [deviceId], unless it is saved already.
///
/// Returns true only when a NEW record was written — false covers both "already
/// saved" and "the user cancelled", because neither is a thing to react to.
///
/// 🔴 Cancelling is a real answer, not a failure. `DeviceController` states the
/// rule this honours: "a device the user declined to name is one they declined
/// to remember." Nothing is written, and the caller must not retry.
Future<bool> promptAndSaveDevice(BuildContext context, String deviceId) async {
  final devices = context.read<DeviceController>();
  if (devices.isSaved(deviceId)) return false;

  final conn = context.read<ConnectionController>();
  final tele = context.read<TelemetryController>();

  // 🔴 The diagnostic trail this flow used to leave behind: NOTHING (design
  // 0058 §3.3). `saveNew` / `save` write no event, so on a phone's log these
  // four were indistinguishable — an empty name pressed 儲存, a tap on the
  // barrier, a deliberate 跳過, and a prompt that never appeared. Three
  // independent「無法儲存裝置」reports landed on 2026-08-11 and the analysis of
  // FB `08.11/005` could only reach "compatible with the defect", never
  // "confirmed", for exactly that reason.
  //
  // Written straight to [LogRepo] rather than through
  // `ConnectionController._event` (ruled 2026-08-11, design 0058 §6 Q1):
  // saving a device is a UI decision, not a link event, and borrowing that
  // pipeline would grow the connection controller a responsibility that has
  // nothing to do with connections.
  final services = context.read<AppServices>();
  final settings = context.read<SettingsController>();
  void note(String what) {
    services.pending.add(services.logRepo.insertLog(
      LogEntry.event(
        'save-device: $what',
        deviceId: deviceId,
        sessionId: services.connection.session.sessionIdFor(deviceId),
        appBuild: services.appBuild,
      ),
      maxBytes: settings.logTrimBudget,
    ));
  }

  // Captured BEFORE the dialog awaits, and both for reasons that outlive it:
  //
  //   * the advertised name is the stable secondary key an iOS NSUUID is
  //     rebound against (D.3), and the scan that produced it has been stopped
  //     by whoever opened a detail page (W-3);
  //   * the class seed is whatever has resolved so far (design 0001 §5 Phase 5)
  //     — the connection controller keeps it current afterwards.
  //
  // Reading them after `await` would read them from a link the user may have
  // dropped while the dialog was up.
  final advName = conn.connectedDeviceName;
  final initialClass = conn.isPowerBank ? conn.resolvedClass : conn.packLabel;
  final pvlt = tele.pvlt;

  // Q2 (ruled 2026-08-11): the prompt APPEARING is its own fact. Without it,
  // "the dialog never opened" and "it opened and the user declined" collapse
  // into the same silence — and telling those two apart is half the reason
  // this trail exists.
  note('prompt');

  final alias = await showAliasDialog(context);
  if (alias == null) {
    note('result=declined');
    return false;
  }
  // 🔴 NOT gated on `context.mounted`. Every caller of this lives on a widget
  // that the save itself removes — the 尚未儲存 row unmounts the moment a record
  // exists, and the offline body unmounts the moment the link goes ready — so a
  // mounted check here throws away the alias the user just typed, on exactly the
  // paths this function was written for. Nothing below touches `context`; the
  // controllers were captured above precisely so it does not have to.
  //
  // Re-checked after the await instead: the same unit may have been named from
  // the other surface while this dialog was open.
  if (devices.isSaved(deviceId)) {
    note('result=already-saved');
    return false;
  }

  await devices.saveNew(
    deviceId,
    alias,
    name: advName,
    lastValue: pvlt,
    productClass: initialClass,
  );
  // 🔴 The OUTCOME only — never the alias itself. It is free text a user typed
  // about their own vehicle, and names and plate numbers are exactly what ends
  // up in it; a diagnostic log is shared with us by email.
  note(alias.isEmpty ? 'result=unnamed' : 'result=named');
  return true;
}

/// What to call an unsaved device on screen (design 0055 §4.2).
///
/// 🔴 Ruled 2026-08-11: **"未命名裝置" is not an acceptable title.** It is what
/// the detail page used to show, because it read the alias of a saved record
/// that does not exist — a label that tells the user nothing about which of the
/// six things in the room they are looking at.
///
/// The chain is advertised name → id, and the second half is platform-shaped:
/// on Android [id] IS the MAC and worth showing in full; on iOS it is an
/// install-scoped NSUUID that is neither a MAC nor stable across a reinstall
/// ([DiscoveredDevice.id]), so it is shortened to the same head…tail form the
/// list uses. Both beat a blank.
///
String unsavedDeviceTitle({
  required String id,
  required String advertisedName,
}) {
  if (advertisedName.isNotEmpty) return advertisedName;
  // A MAC is 17 characters with its separators; anything longer is a UUID and
  // gets shortened. Deliberately a SHAPE test rather than `Platform.isIOS`: the
  // widget layer should not have to know which OS produced a string in order to
  // decide whether it fits on one line.
  return id.length <= 17 ? id : shortDeviceId(id);
}

/// Condense a BLE id (MAC / UUID) to "head…tail" for a one-line slot.
///
/// Lives here rather than in the list because the detail page needs the exact
/// same abbreviation: the two screens name the same device, and two spellings of
/// one id is how a user stops believing they are looking at the same unit.
String shortDeviceId(String id) {
  final s = id.replaceAll(':', '');
  if (s.length <= 9) return s;
  return '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
}
