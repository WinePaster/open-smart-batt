/// OpenSmartBatt — the `device_facts` table (design 0057).
///
/// A cache of what each unit said about itself, written on every connection
/// whether or not the user ever named the device. See [DeviceFacts] for what it
/// is for and — more importantly — what it is NOT allowed to be used for.
library;

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'app_database.dart';

/// Reads + the one write path over `device_facts`.
class DeviceFactsRepo {
  DeviceFactsRepo(this._db);

  final Database _db;

  /// The three columns [observe] reconciles between two ids of one machine.
  /// `mac` is not among them — it is the key the match was made on — and
  /// `first_seen`/`last_seen` are not either: they describe when THAT id was
  /// seen, which is exactly what a reinstall makes different.
  static const List<String> _sharedFacts = ['product_class', 'serial', 'name'];

  /// Every row, oldest-first-seen first. Small by construction — one row per
  /// BLE id the phone has ever connected to — so it is read whole into memory
  /// by [DeviceFactsController] rather than queried per lookup.
  Future<List<DeviceFacts>> getAll() async {
    final rows = await _db.query(
      Db.tableDeviceFacts,
      orderBy: 'first_seen ASC, id ASC',
    );
    return rows.map(DeviceFacts.fromMap).toList(growable: false);
  }

  /// One row by BLE id, or null when this id has never connected.
  Future<DeviceFacts?> get(String id) async {
    final rows = await _db.query(
      Db.tableDeviceFacts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DeviceFacts.fromMap(rows.first);
  }

  /// Record what [id] just said about itself (design 0057 §4.1.1).
  ///
  /// Two keys, on purpose:
  ///
  /// 1. **[id] unseen ⇒ INSERT.** Every BLE id keeps a row of its own forever,
  ///    which is what keeps history written under an old id findable.
  /// 2. **[id] seen ⇒ UPDATE**, writing only the arguments that carry a value.
  ///    A frame without `0x38` must not blank a MAC we already know (§4.1,
  ///    the same rule `DeviceRepo.setIdentity` follows) — T57-7.
  /// 3. **A known [mac] additionally reconciles across rows.** Rows sharing a
  ///    MAC are the same physical machine under two platform ids (iOS reinstall
  ///    ⇒ fresh NSUUID), so each fills the other's GAPS. Nothing already known
  ///    is overwritten and no row is deleted or re-keyed — see [_reconcileMac].
  ///
  /// Empty strings count as "nothing observed", matching [DeviceFacts.toMap].
  Future<void> observe(
    String id, {
    String? name,
    ProductClass? productClass,
    String? mac,
    String? serial,
    DateTime? at,
  }) async {
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final observed = <String, Object?>{
      if (_has(name)) 'name': name,
      if (productClass != null && productClass != ProductClass.unknown)
        'product_class': productClass.storageKey,
      if (_has(mac)) 'mac': mac,
      if (_has(serial)) 'serial': serial,
    };
    // ONE transaction for the insert/update AND the cross-row reconcile: a
    // reader that saw the new row but not yet the facts copied into it would
    // report "connected, class unknown" for a machine we had just identified.
    await _db.transaction((txn) async {
      final existing = await txn.query(
        Db.tableDeviceFacts,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert(Db.tableDeviceFacts, {
          'id': id,
          ...observed,
          'first_seen': stamp,
          'last_seen': stamp,
        });
      } else {
        await txn.update(
          Db.tableDeviceFacts,
          {...observed, 'last_seen': stamp},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      // Reconcile off whatever MAC this row is now known by — the one just
      // observed, else the one already stored. Reconciling on the stored value
      // too costs one indexed lookup on a write that is already throttled to
      // roughly one a minute, and it catches the case where THIS row was the
      // complete one all along and the incomplete sibling arrived later.
      final knownMac = _has(mac) ? mac : existing.firstOrNull?['mac'] as String?;
      if (_has(knownMac)) await _reconcileMac(txn, knownMac!);
    });
  }

  /// Fill the gaps between every row that reports [mac], in both directions.
  ///
  /// 🔴 The rules that make this safe to run on real data:
  ///
  /// * **Nothing is deleted and no `id` is rewritten.** That is the entire
  ///   reason the primary key is the BLE id and not the MAC: `history.device_id`
  ///   holds BLE ids, so re-keying a row to "fix" the newer id would make every
  ///   row recorded under the older one unidentifiable — repairing one half by
  ///   breaking the other, and the broken half is the half design 0057 exists
  ///   to save (T57-10).
  /// * **An existing value is never overwritten**, so two ids cannot take turns
  ///   stamping each other. Ties go to the row seen first, which is why the
  ///   scan is ordered by `first_seen` (T57-11).
  Future<void> _reconcileMac(Transaction txn, String mac) async {
    final rows = await txn.query(
      Db.tableDeviceFacts,
      where: 'mac = ?',
      whereArgs: [mac],
      orderBy: 'first_seen ASC, id ASC',
    );
    // One row means one id — nothing to reconcile with. This is the ordinary
    // case; the index on `mac` is what keeps it cheap (and it is deliberately
    // NOT unique, because rule 3 makes duplicates legitimate — §4.1.1).
    if (rows.length < 2) return;
    final earliest = <String, Object?>{};
    for (final row in rows) {
      for (final field in _sharedFacts) {
        earliest[field] ??= row[field];
      }
    }
    for (final row in rows) {
      final patch = <String, Object?>{
        for (final field in _sharedFacts)
          if (row[field] == null && earliest[field] != null)
            field: earliest[field],
      };
      if (patch.isEmpty) continue;
      await txn.update(
        Db.tableDeviceFacts,
        patch,
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  static bool _has(String? v) => v != null && v.isNotEmpty;
}
