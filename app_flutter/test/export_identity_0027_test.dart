/// Design 0027 — export identity (App side, Phases 1–3).
///
/// Covers the four moving parts the design introduces:
///   * reading the device's own BLE address from selector 0x38 (ASCII → MAC),
///     ungated by rawPacketLog;
///   * the full-serial 0x26-all-zero → NULL guard (never fabricate a serial);
///   * the schema v11 migration adding nullable `mac` / `serial` to
///     saved_devices, with NO backfill of old rows;
///   * the `# devices:` export header block — which writes the MAC as a HASH,
///     never the raw address (clean-room red line) — and the sanitizeIdent
///     fallback that stops a CJK nickname collapsing to a single character.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:open_smart_batt/data/data.dart';
import 'package:open_smart_batt/models/models.dart';
import 'package:open_smart_batt/protocol/frame.dart';
import 'package:open_smart_batt/protocol/inbound_frame.dart';
import 'package:open_smart_batt/protocol/selectors.dart';
import 'package:open_smart_batt/protocol/telemetry_decoder.dart';
import 'package:open_smart_batt/ui/util/export_header.dart';
import 'package:open_smart_batt/ui/util/export_naming.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A checksum-valid 0x38 frame whose payload is the ASCII of [text].
InboundFrame ble38(String text) {
  final bytes = Uint8List.fromList(text.codeUnits);
  return InboundFrame(
    selector: Selectors.bleAddress,
    flag: 0x01,
    len: bytes.length,
    payload: bytes,
    checksumOk: true,
  );
}

void main() {
  group('0x38 → MAC decode (design 0027 §3.2.1)', () {
    test('ASCII colon-form decodes to the upper-case MAC', () {
      expect(TelemetryDecoder.mac(ble38('34:14:B5:B4:70:93')),
          '34:14:B5:B4:70:93');
    });

    test('lower-case ASCII is normalised to upper case', () {
      expect(TelemetryDecoder.mac(ble38('34:14:b5:b4:70:93')),
          '34:14:B5:B4:70:93');
    });

    test('a colon-less 12-hex form is re-inserted with colons', () {
      expect(TelemetryDecoder.mac(ble38('3414B5B47093')), '34:14:B5:B4:70:93');
    });

    test('a malformed payload decodes to null (never a fabricated MAC)', () {
      expect(TelemetryDecoder.mac(ble38('not-an-address')), isNull);
      expect(TelemetryDecoder.mac(ble38('34:14:B5:B4:70')), isNull); // 10 hex
    });

    test('ingest folds the MAC onto the sample, NOT gated on rawPacketLog', () {
      // The decoder has no notion of rawPacketLog — the raw-log switch only
      // gates the log WRITE in BleService, upstream of here. So a plain ingest
      // (as the live path does on every notification) must surface the MAC.
      final dec = TelemetryDecoder();
      dec.ingest(ble38('34:14:B5:B4:70:93'), at: DateTime.utc(2026, 8, 1));
      expect(dec.sample.mac, '34:14:B5:B4:70:93');
    });

    test('a later malformed 0x38 does not overwrite a good MAC', () {
      final dec = TelemetryDecoder();
      dec.ingest(ble38('34:14:B5:B4:70:93'), at: DateTime.utc(2026, 8, 1));
      dec.ingest(ble38('garbage'), at: DateTime.utc(2026, 8, 1));
      expect(dec.sample.mac, '34:14:B5:B4:70:93');
    });

    test('end-to-end through the reassembler (real frame bytes)', () {
      // Build the exact wire frame and reassemble it, proving the selector is
      // wired into the shipping FrameReassembler → TelemetryDecoder pipeline.
      final ascii = '34:14:B5:B4:70:93'.codeUnits;
      final body = <int>[kSyncByte, Selectors.bleAddress, 0x01, ascii.length, ...ascii];
      final frame = <int>[...body, xorFold(body)];
      final re = FrameReassembler();
      final dec = TelemetryDecoder();
      for (final f in re.addBytes(frame)) {
        expect(f.checksumOk, isTrue, reason: 'XOR must validate');
        dec.ingest(f, at: DateTime.utc(2026, 8, 1));
      }
      expect(dec.sample.mac, '34:14:B5:B4:70:93');
    });
  });

  group('full serial 0x26-all-zero → NULL (design 0027 §3.2.2)', () {
    test('a real serial derives the 15-digit value', () {
      final s = TelemetrySample.empty();
      expect(s.copyWith(dealerCode: '01680102', serial: '001206').fullSerial,
          '016801020001206');
    });

    test('an all-zero 0x26 yields NULL, not a fabricated serial', () {
      final s = TelemetrySample.empty();
      // 34:14:B5:4C:88:EF (second-gen capacitor) reports 0x26 = 000000. Padding
      // it would invent 016802170000000 — a serial that looks entirely real.
      expect(s.copyWith(dealerCode: '01680217', serial: '000000').fullSerial,
          isNull);
    });
  });

  group('saved_devices v11 migration (design 0027 §3.2.2)', () {
    setUpAll(sqfliteFfiInit);

    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('osb_0027');
      path = p.join(dir.path, 'm.db');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    // The v10 saved_devices DDL, verbatim — the table as it existed BEFORE this
    // design. Opening at version 10 then reopening via AppDatabase (v11) runs
    // the real _onUpgrade(from:10) branch.
    Future<void> createV10() async {
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (db, _) => db.execute('''
            CREATE TABLE saved_devices (
              id TEXT PRIMARY KEY,
              alias TEXT NOT NULL DEFAULT '',
              name TEXT NOT NULL DEFAULT '',
              last_seen INTEGER,
              last_value REAL,
              stale INTEGER NOT NULL DEFAULT 0,
              product_class TEXT NOT NULL DEFAULT 'unknown',
              display_layout TEXT
            )
          '''),
        ),
      );
      await db.insert('saved_devices', {'id': 'OLD', 'alias': '舊電池'});
      await db.close();
    }

    test('an old DB opens; the row survives with mac/serial = NULL (no backfill)',
        () async {
      await createV10();
      final appDb =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      final repo = DeviceRepo(appDb.db);
      final old = await repo.getDevice('OLD');
      expect(old, isNotNull);
      expect(old!.alias, '舊電池');
      // The whole point of "no backfill": a pre-v11 row must read back NULL, not
      // be stamped with whatever unit connected next.
      expect(old.mac, isNull);
      expect(old.serial, isNull);
      await appDb.close();
    });

    test('the new columns exist and round-trip mac/serial', () async {
      await createV10();
      final appDb =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      final repo = DeviceRepo(appDb.db);
      await repo.upsertSavedDevice(const SavedDevice(
        id: 'NEW',
        alias: 'new',
        mac: '34:14:B5:B4:70:93',
        serial: '016801020001261',
      ));
      final got = await repo.getDevice('NEW');
      expect(got!.mac, '34:14:B5:B4:70:93');
      expect(got.serial, '016801020001261');

      // setIdentity writes only the supplied column, leaving the other intact.
      await repo.setIdentity('OLD', mac: '6C:79:B8:33:66:06');
      final healed = await repo.getDevice('OLD');
      expect(healed!.mac, '6C:79:B8:33:66:06');
      expect(healed.serial, isNull);
      await appDb.close();
    });
  });

  group('# devices: header block (design 0027 §3.1)', () {
    const rawMac = '34:14:B5:B4:70:93';
    const deviceId = 'A1B2C3D4-NSUUID-INSTALL-SCOPED';

    List<String> build() => exportHeaderLines(
          title: 'OpenSmartBatt diagnostic log',
          exportedAt: DateTime.utc(2026, 8, 1),
          appBuild: '0.6.15+1',
          platform: 'ios',
          scope: 'all devices',
          layout: 'default',
          devices: const [
            ExportDeviceIdentity(
              deviceId: deviceId,
              mac: rawMac,
              serial: '016801020001261',
              classSlug: 'battery',
              name: 'RCE-CarBatt',
              label: '電容',
            ),
            ExportDeviceIdentity(deviceId: 'other-id', classSlug: 'unknown'),
          ],
        );

    test('emits a count line and one line per device', () {
      final lines = build();
      expect(lines, contains('devices: 2'));
    });

    test('🔴 writes the MAC as a HASH — the raw address never appears', () {
      final blob = build().join('\n');
      expect(blob.contains(rawMac), isFalse,
          reason: 'clean-room red line: raw MAC must NEVER reach the file');
      expect(blob, contains('mac=${shortDeviceHash(rawMac)}'));
    });

    test('the raw platform device id never appears either — only its hash', () {
      final blob = build().join('\n');
      expect(blob.contains(deviceId), isFalse);
      expect(blob, contains('hash=${shortDeviceHash(deviceId)}'));
    });

    test('known fields are rendered; the join key ordering is mac,hash,serial…',
        () {
      final line = build().firstWhere((l) => l.contains('serial='));
      expect(line, contains('serial=016801020001261'));
      expect(line, contains('class=battery'));
      expect(line, contains('name=RCE-CarBatt'));
      expect(line, contains('label=電容'));
      // mac before hash before serial (design 0027 §3.1 example order).
      expect(line.indexOf('mac='), lessThan(line.indexOf('hash=')));
      expect(line.indexOf('hash='), lessThan(line.indexOf('serial=')));
    });

    test('unknown fields are omitted, not emitted empty', () {
      // The 2nd device has only an id: no mac=, no serial=, class=unknown
      // dropped, but hash= is always present.
      final line = build().firstWhere((l) =>
          l.contains('hash=${shortDeviceHash('other-id')}'));
      expect(line.contains('mac='), isFalse);
      expect(line.contains('serial='), isFalse);
      expect(line.contains('class='), isFalse);
      expect(line.contains('label='), isFalse);
    });

    test('the block is absent when no devices are supplied (format G3)', () {
      final lines = exportHeaderLines(
        title: 't',
        exportedAt: DateTime.utc(2026, 8, 1),
        appBuild: '0.6.15',
        platform: 'ios',
        scope: 'all devices',
        layout: 'default',
      );
      expect(lines.any((l) => l.startsWith('devices:')), isFalse);
    });
  });

  group('sanitizeIdent CJK-collapse fallback (design 0027 §3.4)', () {
    test('a nickname that cleans to a single char is treated as no alias', () {
      // 行動外電源2 → only "2" survives → below the 2-char floor → ''.
      expect(sanitizeIdent('行動外電源2'), '');
      // Two nicknames sharing one ASCII char used to collide on it.
      expect(sanitizeIdent('電源A'), '');
      expect(sanitizeIdent('備用A'), '');
    });

    test('a >=2 char identifier is still kept', () {
      expect(sanitizeIdent('AB'), 'AB');
      expect(sanitizeIdent('1206'), '1206');
    });

    test('deviceIdentFragment falls through to the hash, not the debris', () {
      const id = 'AA:BB:CC:DD:EE:FF';
      expect(
        deviceIdentFragment(alias: '行動外電源2', deviceId: id),
        shortDeviceHash(id),
      );
    });
  });
}
