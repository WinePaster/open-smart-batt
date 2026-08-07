// RSPB-01 rail-off residual (`feedback-analysis/2026.08.07-rspb01-deadband-
// fix.md`) — the rail-off veto inside `powerFlowOf`.
//
// One unit's `0x49` reads a constant 58–69 mA while its boost rail is off —
// beyond the ±0.05 A dead-band — so sign-plus-band alone printed a permanent
// "charging 0.06 A" on a bank that was doing nothing, with the contradiction
// guard then withholding every port badge on top of it: "charging, through no
// port at all", forever. The fix is a ONE-WAY veto inside the single direction
// derivation: charging sign + magnitude under [kRailOffChargeVetoA] + the same
// burst's b7 == 0x00 reads idle.
//
// These are unit tests on the derivation itself, on the exact field vectors
// the analysis names. The rendered consequences (the row reading STANDBY, the
// contradiction guard no longer firing) are pinned where the other row
// behaviour is, in `power_path_test.dart`.
import 'package:flutter_test/flutter_test.dart';

import 'package:open_smart_batt/ui/dashboard/power_flow.dart';

void main() {
  group('rail-off veto — the RSPB-01 residual reads idle', () {
    test('60 mA charge-side residual + b7 == 0x00 → idle, not charging', () {
      // The reported unit: 0x49 residual 58–69 mA with the rail off, so the
      // signed current computes to about −0.060 A — beyond the dead-band.
      expect(powerFlowOf(-0.060, portFlagsRaw: 0x00), PowerFlow.idle);
    });

    test('the whole observed residual span (58–69 mA) is vetoed', () {
      expect(powerFlowOf(-0.058, portFlagsRaw: 0x00), PowerFlow.idle);
      expect(powerFlowOf(-0.069, portFlagsRaw: 0x00), PowerFlow.idle);
    });
  });

  group('rail-off veto — what it must NOT catch', () {
    test('genuine 667 mA charge survives a spurious b7 == 0x00', () {
      // The corpus's spurious-0x00 charging frames sit at 667 / 2,712 mA —
      // an order of magnitude above the veto line. A one-frame flag glitch
      // must not turn a real charge into "standby".
      expect(powerFlowOf(-0.667, portFlagsRaw: 0x00), PowerFlow.charging);
      expect(powerFlowOf(-2.712, portFlagsRaw: 0x00), PowerFlow.charging);
    });

    test('a discharge is never vetoed — the gate is one-way', () {
      // The 68 mA spurious-0x00 discharge frame: beyond the band, discharge
      // sign. The contradiction guard handles it; the direction stands.
      expect(powerFlowOf(0.068, portFlagsRaw: 0x00), PowerFlow.discharging);
    });

    test('without b7 == 0x00 the derivation is unchanged', () {
      // Any lit bit means the rail is not off — no veto, sign decides. And a
      // null b7 (a non-power-bank, or 0x4B not yet arrived) is the exact
      // pre-veto function: same 60 mA reading, no flag, still charging.
      expect(powerFlowOf(-0.060, portFlagsRaw: 0x02), PowerFlow.charging);
      expect(powerFlowOf(-0.060), PowerFlow.charging);
    });
  });

  group('dead-band — unchanged underneath the veto', () {
    test('idle Type-C cable at 10 mA with bit1 set is in-band idle', () {
      // The 12:09:21 frame: C cable inserted (bit1), 10 mA. In-band, so it
      // reads idle with or without the flag — bit1 is cable-present, never a
      // direction (design 0035 §4.2/§4.3).
      expect(powerFlowOf(0.010, portFlagsRaw: 0x02), PowerFlow.idle);
      expect(powerFlowOf(-0.010, portFlagsRaw: 0x02), PowerFlow.idle);
    });

    test('null current is still unknown, not idle', () {
      expect(powerFlowOf(null, portFlagsRaw: 0x00), PowerFlow.unknown);
    });
  });
}
