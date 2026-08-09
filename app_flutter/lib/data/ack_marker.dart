/// OpenSmartBatt — "the user has seen this once" markers.
///
/// A marker is an EMPTY-ish file in the app-support directory whose mere
/// existence is the fact. Nothing else is stored: the timestamp inside is for a
/// human reading a bug report, and no code parses it.
///
/// ## Why a file and not the settings table
///
/// This started as [Disclaimer] in `main.dart` and is generalised here because
/// design 0053 needed a second one (the home-editor tutorial). The reasons the
/// first one was a file all still hold, and one of them is a defect this
/// project has actually shipped:
///
///  * **No schema migration.** A settings column costs `schemaVersion 13 → 14`
///    and a migration, for a boolean nobody can see.
///  * **The settings table's `INSERT OR REPLACE` trap.** `SettingsRepo` writes
///    the WHOLE row; a field missing from `toMap` is silently reset to its
///    default the next time the user changes any OTHER setting. A one-time
///    acknowledgement that quietly un-acknowledges itself is worse than one
///    that never persisted at all, because it looks like it works.
///  * **It is not the user's data.** Purely local UI state — it has no business
///    in the export file, and the export is built from the settings row.
///
/// ## The cost, stated because it is real
///
/// The directory lookup is asynchronous, so every read is a `Future` and every
/// caller has to be somewhere that can await one — in practice a post-frame
/// callback, which is exactly the shape `_maybeShowDisclaimer` already had.
///
/// [debugDirectoryOverride] exists so a widget test can point markers at a temp
/// dir: without it `getApplicationSupportDirectory()` is a platform channel
/// with no implementation under `flutter_test`, and "the marker could not be
/// read" is deliberately indistinguishable from "not acknowledged".
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One named acknowledgement flag.
///
/// Name convention: `<feature>_ack_v<N>`. The version is not decoration — a
/// material rewrite of the text it guards should re-prompt everybody, and
/// bumping to `_v2` is how that is done without touching any of this code.
class AckMarker {
  const AckMarker(this.name);

  /// File name inside the app-support dir, e.g. `disclaimer_ack_v1`.
  final String name;

  /// Test seam. When set, markers are read and written here instead of the
  /// platform's app-support directory. Never set in production code.
  static Directory? debugDirectoryOverride;

  /// True once [markAcknowledged] has run and [clear] has not.
  ///
  /// A failure to read is reported as `false`: the worst case is showing a
  /// notice a second time, and the alternative — swallowing an I/O error as
  /// "already seen" — hides the notice forever on the device where it broke.
  Future<bool> acknowledged() async {
    try {
      return (await _file()).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> markAcknowledged() async {
    try {
      await (await _file()).parent.create(recursive: true);
      (await _file()).writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {
      // Best-effort; worst case the notice shows again next time.
    }
  }

  /// Un-acknowledge. Needed because design 0053's "don't show again" checkbox
  /// starts CHECKED and has to work in both directions — a box that can only
  /// ever set the flag is decoration on one of its two positions.
  Future<void> clear() async {
    try {
      final file = await _file();
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best-effort.
    }
  }

  Future<File> _file() async {
    final dir = debugDirectoryOverride ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }
}
