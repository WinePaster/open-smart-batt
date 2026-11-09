// design 0099 P2 — choosing the protocol from the GATT table.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

import 'support/fake_profiles.dart';

const _gap = '00001800-0000-1000-8000-00805f9b34fb';
final _svc = normaliseUuid(Gatt.serviceUuid);
final _write = normaliseUuid(Gatt.writeCharUuid);
final _notify = normaliseUuid(Gatt.notifyCharUuid);

GattCharacteristicInfo _c(String uuid) => GattCharacteristicInfo(uuid);

void main() {
  group('resolveProfile — exactly one confirmed, or nothing', () {
    const empty = GattSnapshot([]);

    test('one confirmed resolves to it', () {
      final a = FixedMatchProfile('a', ProfileMatch.confirmed);
      final b = FixedMatchProfile('b', ProfileMatch.candidate);
      final c = resolveProfile([a, b], empty);
      expect(c.resolution, ProfileResolution.resolved);
      expect(c.profile, same(a));
      expect(c.candidates, ['b']);
    });

    test('no match resolves to nothing', () {
      final c = resolveProfile([
        FixedMatchProfile('a', ProfileMatch.none),
      ], empty);
      expect(c.resolution, ProfileResolution.noMatch);
      expect(c.profile, isNull);
    });

    test('candidates alone never resolve', () {
      final a = FixedMatchProfile('a', ProfileMatch.candidate);
      final b = FixedMatchProfile('b', ProfileMatch.candidate);
      final c = resolveProfile([a, b], empty);
      expect(c.resolution, ProfileResolution.candidatesOnly);
      expect(c.profile, isNull);
      expect(c.candidates, ['a', 'b']);
      expect(
        a.sessionsOpened + b.sessionsOpened,
        0,
        reason: 'resolving must not open a session',
      );
    });

    test('two confirmed is ambiguous, and resolves to nothing', () {
      final a = FixedMatchProfile('a', ProfileMatch.confirmed);
      final b = FixedMatchProfile('b', ProfileMatch.confirmed);
      final c = resolveProfile([a, b], empty);
      expect(c.resolution, ProfileResolution.ambiguous);
      expect(c.profile, isNull);
      expect(c.confirmed, ['a', 'b']);
    });
  });

  group('RceProfile', () {
    const rce = RceProfile();

    test('both characteristics under the vendor service: confirmed', () {
      final g = GattSnapshot([
        GattServiceInfo(_gap, const []),
        GattServiceInfo(_svc, [_c(_write), _c(_notify)]),
      ]);
      expect(rce.matchGatt(g), ProfileMatch.confirmed);
      expect(resolveProfile(const [rce], g).profile, same(rce));
    });

    test('characteristics outside the vendor service still count (sweep)', () {
      final g = GattSnapshot([
        GattServiceInfo(_gap, [_c(_write), _c(_notify)]),
      ]);
      expect(rce.matchGatt(g), ProfileMatch.confirmed);
    });

    test('only one of the two: not RCE', () {
      expect(
        rce.matchGatt(
          GattSnapshot([
            GattServiceInfo(_svc, [_c(_write)]),
          ]),
        ),
        ProfileMatch.none,
      );
      expect(
        rce.matchGatt(
          GattSnapshot([
            GattServiceInfo(_svc, [_c(_notify)]),
          ]),
        ),
        ProfileMatch.none,
      );
    });

    test('advertising: vendor service (any spelling) or a vendor name', () {
      expect(
        rce.looksLikeThisDevice(
          AdvertisementEvidence(name: '', serviceUuids: [_svc]),
        ),
        isTrue,
      );
      expect(
        rce.looksLikeThisDevice(
          const AdvertisementEvidence(name: 'RCE-SCAP_II'),
        ),
        isTrue,
      );
      expect(
        rce.looksLikeThisDevice(
          const AdvertisementEvidence(name: 'Force Meter'),
        ),
        isFalse,
      );
    });

    test('opens an RceSession', () {
      expect(rce.openSession(), isA<RceSession>());
    });
  });

  group('pickEndpoints keeps the old characteristic rule', () {
    // The loop `BleService._setupConnection` ran before design 0099, restated
    // over plain values: prefer the vendor service, fall back to a full sweep,
    // last match wins.
    (int, int, int, int)? oldRule(GattSnapshot g) {
      int? ws, wc, ns, nc;
      for (var i = 0; i < g.services.length; i++) {
        final preferred = g.services[i].uuid == _svc;
        for (var j = 0; j < g.services[i].characteristics.length; j++) {
          final u = g.services[i].characteristics[j].uuid;
          if (u == _write && (ws == null || preferred)) {
            ws = i;
            wc = j;
          }
          if (u == _notify && (ns == null || preferred)) {
            ns = i;
            nc = j;
          }
        }
      }
      if (ws == null || ns == null) return null;
      return (ws, wc!, ns, nc!);
    }

    test('vendor-service characteristics win over earlier strays', () {
      final g = GattSnapshot([
        GattServiceInfo(_gap, [_c(_write), _c(_notify)]),
        GattServiceInfo(_svc, [_c(_notify), _c(_write)]),
      ]);
      final p = pickEndpoints(g, const RceProfile().endpoints)!;
      expect((p.writeService, p.writeChar), (1, 1));
      expect((p.notifyService, p.notifyChar), (1, 0));
    });

    test('agrees with the old loop on 2,000 random tables', () {
      final rng = math.Random(99);
      final pool = [
        _write,
        _notify,
        _gap,
        '0000beef-0000-1000-8000-00805f9b34fb',
      ];
      for (var n = 0; n < 2000; n++) {
        final g = GattSnapshot([
          for (var i = 0; i < rng.nextInt(4); i++)
            GattServiceInfo(rng.nextBool() ? _svc : _gap, [
              for (var j = 0; j < rng.nextInt(4); j++)
                _c(pool[rng.nextInt(pool.length)]),
            ]),
        ]);
        final p = pickEndpoints(g, const RceProfile().endpoints);
        final want = oldRule(g);
        expect(
          p == null
              ? null
              : (p.writeService, p.writeChar, p.notifyService, p.notifyChar),
          want,
          reason: 'table #$n',
        );
      }
    });
  });

  test('normaliseUuid', () {
    expect(normaliseUuid('FFF0'), '0000fff0-0000-1000-8000-00805f9b34fb');
    expect(normaliseUuid('0000FFF0'), '0000fff0-0000-1000-8000-00805f9b34fb');
    expect(normaliseUuid(Gatt.serviceUuid.toUpperCase()), Gatt.serviceUuid);
  });
}
