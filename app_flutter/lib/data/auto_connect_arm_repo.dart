/// OpenSmartBatt — the `autoconnect_arm` table (design 0060 / FB-67).
///
/// One row, or none: the iOS autoConnect hand-off this app is currently waiting
/// on. It exists because everything else about an armed hand-off lives in
/// `ConnectionController`'s memory, and iOS reclaims a suspended app without
/// telling it — so the deadline is not late, it is gone, and the next launch
/// has no way to know a hand-off was ever in flight.
///
/// 🔑 The row is an INSTRUMENT, not a plan. Nothing reads it back to decide what
/// to connect to on a cold start except the adopt path (design 0060 §3.7 #1);
/// its purpose is to let the next launch say, in the diagnostic log, what the
/// last one was doing. There is deliberately no UI (owner's ruling, 2026-08-13:
/// 「只要寫log, 顯示在ui要幹麻？」).
library;

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// An armed autoConnect hand-off, as persisted.
///
/// Field-for-field the FB-66 in-memory state (`_autoConnectArmedId` /
/// `_autoConnectArmedAt`) plus the two things only a LATER process needs:
/// which build armed it and which log section it belonged to. Deliberately not
/// a snapshot of the whole controller — every extra field is one more way for
/// a dead process's opinion to override what this one can observe for itself
/// (design 0060 §4).
class AutoConnectArm {
  const AutoConnectArm({
    required this.deviceId,
    required this.armedAt,
    this.appBuild,
    this.sessionId,
  });

  /// Which unit the hand-off was waiting for.
  final String deviceId;

  /// When it was armed, on the WALL clock — the same `clock.now()` the FB-66
  /// watchdog judges its 180 s against. A monotonic source would be useless
  /// here for the additional reason that it does not survive a reboot.
  final DateTime armedAt;

  /// The build that armed it, so an app updated while armed still reads.
  final String? appBuild;

  /// The diagnostic-log session the arm belonged to, so the reconciliation line
  /// written by the NEXT process can be tied back to it in a capture.
  final int? sessionId;

  Map<String, Object?> toMap() => <String, Object?>{
        'device_id': deviceId,
        'armed_at': armedAt.millisecondsSinceEpoch,
        'app_build': appBuild,
        'session_id': sessionId,
      };

  static AutoConnectArm fromMap(Map<String, Object?> row) => AutoConnectArm(
        deviceId: row['device_id'] as String,
        armedAt: DateTime.fromMillisecondsSinceEpoch(row['armed_at'] as int),
        appBuild: row['app_build'] as String?,
        sessionId: row['session_id'] as int?,
      );

  @override
  String toString() => 'AutoConnectArm($deviceId, $armedAt, $appBuild, '
      '$sessionId)';
}

/// Reads + the two writes over `autoconnect_arm`.
///
/// The same fixed-single-row shape as [SettingsRepo], for the same reason: the
/// state it holds is singular for the whole app, so "insert or replace id = 1"
/// makes a second concurrent arm unrepresentable rather than merely unlikely.
class AutoConnectArmRepo {
  AutoConnectArmRepo(this._db);

  final Database _db;

  /// The armed hand-off left behind by the previous run, or null when the last
  /// run converged (or there was no last run).
  Future<AutoConnectArm?> read() async {
    final rows = await _db.query(
      Db.tableAutoConnectArm,
      where: 'id = ?',
      whereArgs: [Db.autoConnectArmRowId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AutoConnectArm.fromMap(rows.first);
  }

  /// Record that a hand-off is in flight. Replaces any previous row — see the
  /// class comment for why there can only be one.
  Future<void> write(AutoConnectArm arm) async {
    await _db.insert(
      Db.tableAutoConnectArm,
      {'id': Db.autoConnectArmRowId, ...arm.toMap()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The hand-off converged, or was superseded, or the app is shutting down
  /// cleanly — in every one of those cases there is nothing left to report.
  Future<void> clear() async {
    await _db.delete(
      Db.tableAutoConnectArm,
      where: 'id = ?',
      whereArgs: [Db.autoConnectArmRowId],
    );
  }
}

/// The `cold-start:` diagnostic line (design 0060 §3.5).
///
/// 🔑 Its independent value is the FIRST half, not the arm. Until this line
/// existed, "this launch was a cold start" was not recorded anywhere at all —
/// FB-67 had to infer it from the ABSENCE of the four lifecycle lines a live
/// process prints on the way back to the foreground, which is a reconstruction,
/// not a fact. One greppable line per launch turns it into one.
///
/// Pure so it can be tested: `bootstrap()` is the only caller and no test calls
/// `bootstrap()` (that isolation is deliberate — design 0060 §6 R4).
String formatColdStartLine({
  required String appBuild,
  required AutoConnectArm? arm,
  required DateTime now,
}) {
  if (arm == null) return 'cold-start: build=$appBuild armed=none';
  final waited = now.difference(arm.armedAt).inSeconds;
  final by = arm.appBuild;
  final provenance = (by == null || by == appBuild) ? '' : ' (armed by $by)';
  return 'cold-start: build=$appBuild armed=${shortDeviceHash(arm.deviceId)} '
      'waited=${waited}s$provenance';
}
