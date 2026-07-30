// FB-33 — a raw BLE device id must never reach an exported log note.
//
// `log_entry.dart` and `log_repo.dart` both state the invariant ("NEVER the raw
// id: on Android that is the MAC address, and this text ends up in a file the
// user shares"), and `_sectionLabel` honours it. The note text did not: it is
// rendered verbatim by `toLogLine`, so anything interpolated into it was
// exported as-is. Two MACs were recovered from a log a user mailed us
// (feedback_log/2026.07.27).
//
// The redaction is deliberately MAC-only. On iOS the device id is an `8-4-4-4-12`
// NSUUID — and so is every GATT service/characteristic UUID. The GATT dump is
// load-bearing diagnostic data (it is what showed `ace3` to be write-only,
// closing FB-01), so a pattern that cannot tell the two apart would destroy real
// evidence to hide an install-scoped random identifier. Known ids are hashed at
// the call site instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  // The two ids actually recovered from the shared capture.
  const mac = '6C:79:B8:33:76:9F';
  const otherMac = '18:45:16:AF:26:55';

  group('redactMacAddresses', () {
    test('replaces a MAC with its stable digest', () {
      final out = redactMacAddresses('connect → $mac');
      expect(out, contains(shortDeviceHash(mac)));
      expect(out, isNot(contains(mac)));
    });

    test('replaces every MAC in one line, keeping them distinguishable', () {
      final out = redactMacAddresses('rebound $mac → $otherMac');
      expect(out, isNot(contains(mac)));
      expect(out, isNot(contains(otherMac)));
      expect(out, contains(shortDeviceHash(mac)));
      expect(out, contains(shortDeviceHash(otherMac)));
      // Distinct units must stay distinct, or the roster stops answering
      // "is this the same device I connected to?".
      expect(shortDeviceHash(mac), isNot(shortDeviceHash(otherMac)));
    });

    test('is case-insensitive — flutter_blue_plus lower-cases on some paths',
        () {
      expect(redactMacAddresses(mac.toLowerCase()),
          isNot(contains(mac.toLowerCase())));
    });

    test('is idempotent: a digest is bare hex and cannot re-match', () {
      final once = redactMacAddresses('connect → $mac');
      expect(redactMacAddresses(once), once);
    });

    test('LEAVES GATT UUIDs alone — they are not device ids', () {
      const gatt = 'GATT svc=07b9fff0-d55f-5e82-ba44-81c0da86c46c '
          'char=07b9ace3-d55f-5e82-ba44-81c0da86c46c [W]';
      expect(redactMacAddresses(gatt), gatt);
    });

    test('leaves a bare hex packet dump alone', () {
      // No colons — the anchors must not let a MAC match start mid-run.
      const hex = 'b8230001069c';
      expect(redactMacAddresses(hex), hex);
    });

    test('leaves ordinary text alone', () {
      const plain = 'keep-alive write failed after 15000ms';
      expect(redactMacAddresses(plain), plain);
    });
  });

  group('LogEntry scrubs notes on every path', () {
    test('event() redacts the message', () {
      final e = LogEntry.event('connect → $mac');
      expect(e.note, isNot(contains(mac)));
      expect(e.toLogLine(), isNot(contains(mac)));
    });

    test('event() keeps the raw deviceId column — it is the scoping key', () {
      final e = LogEntry.event('connect → $mac', deviceId: mac);
      // The column is hashed on its way out by `_sectionLabel`, not here:
      // scoping a per-device export needs the real id to match on.
      expect(e.deviceId, mac);
      expect(e.toLogLine(), isNot(contains(mac)));
    });

    test('fromBytes() redacts the note', () {
      final e = LogEntry.fromBytes(
        LogDirection.tx,
        const [0xb8, 0x23],
        note: 'write to $mac',
      );
      expect(e.note, isNot(contains(mac)));
    });

    test('fromMap() redacts a legacy row written by an older build', () {
      // The table accumulates across upgrades: rows already on disk still hold
      // the raw MAC, and fromMap is the funnel the exporter reads through.
      final e = LogEntry.fromMap({
        'id': 1,
        'timestamp': 0,
        'direction': 'event',
        'hex': '',
        'note': 'scan hit id=$mac name=\'-CarBatt\' rssi=-60 vendor=true',
        'device_id': mac,
        'session_id': 3,
        'app_build': '0.6.11+26072909',
      });
      expect(e.note, isNot(contains(mac)));
      expect(e.note, contains(shortDeviceHash(mac)));
      // The rest of the roster line is what FB-24 diagnosis actually needs.
      expect(e.note, contains('-CarBatt'));
      expect(e.note, contains('rssi=-60'));
      expect(e.note, contains('vendor=true'));
    });

    test('fromMap() tolerates a null note', () {
      final e = LogEntry.fromMap({
        'id': 1,
        'timestamp': 0,
        'direction': 'rx',
        'hex': 'b823',
        'note': null,
        'device_id': null,
        'session_id': null,
        'app_build': null,
      });
      expect(e.note, isNull);
    });
  });
}
