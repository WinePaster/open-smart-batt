// Finding vendor hardware in a crowded scan (FB-24 / FB-25, design 0015).
//
// A dealer reported that one of his two power banks "cannot be found", while
// the vendor's own app listed both. Our scan does not drop anything — it tags
// each hit `isVendor` and the sheet then shows only those by default — so a
// name our matcher does not recognise is invisible among the 21–31 unrelated
// peripherals a single scan turns up.
//
// The matcher is widened here, but the fix that matters is diagnostic: until a
// scan roster reaches us we cannot tell a radio-level miss from a filter-level
// hide, and those need opposite remedies.
//
// FB-25 is the same mistake seen from the other side. Two DIFFERENT power banks
// advertise the identical name 'RCE_RSPB-01' (confirmed in the vendor app's own
// scan list), and saved-device rebinding used that name as an identity.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/ble/ble.dart';
import 'package:open_smart_batt/models/models.dart';

void main() {
  group('looksLikeVendorName — matches the family, not the alphabet', () {
    test('every known product name is recognised', () {
      for (final n in [
        'RCE_RSPB-01', // power bank, from the vendor app's scan list
        'RCE-SCAP_II', // 2nd-gen capacitor
        'RCE-SCAP_III', // flagship capacitor
        'RCE-CarBatt', // car battery
      ]) {
        expect(looksLikeVendorName(n), isTrue, reason: n);
      }
    });

    test('is a strict superset of the old whole-name startsWith rule', () {
      // Anything the previous rule accepted must still be accepted: its first
      // token necessarily starts with the same marker.
      for (final n in ['RCE', 'RCEanything', 'RCE_x', 'rce-lower']) {
        expect(n.toUpperCase().startsWith('RCE'), isTrue);
        expect(looksLikeVendorName(n), isTrue, reason: n);
      }
    });

    test('recognises a bare family token with no RCE prefix', () {
      // The reason the rule was widened. Note this remains UNPROVEN in the
      // field — it is defensive, and cheap.
      expect(looksLikeVendorName('rspb'), isTrue);
      expect(looksLikeVendorName('RSPB-01'), isTrue);
    });

    test('CJK counts as a separator, so a mixed alias still matches', () {
      // Users rename devices; one field CSV carried 'RSPB-01行動電源'.
      expect(looksLikeVendorName('RSPB-01行動電源'), isTrue);
    });

    test('does NOT match English words that merely contain "rce"', () {
      // This is why the rule is token-prefix and not `contains`: a single scan
      // holds 30+ strangers, and RCE is an embedded syllable.
      for (final n in [
        'AirForce Buds', // foRCE
        'Source One', // souRCE
        'Pierce-BT', // pieRCE
        'Commerce Hub', // commeRCE
        'Resource Monitor', // resouRCE
      ]) {
        expect(looksLikeVendorName(n), isFalse, reason: n);
      }
    });

    test('an unnamed peripheral is not claimed', () {
      // Widening the name rule cannot help a device that advertises no name —
      // that case needs the hidden-count affordance instead.
      expect(looksLikeVendorName(''), isFalse);
    });
  });

  group('rebindSavedDeviceId — refuses to guess between duplicates', () {
    test('an exact id match always wins, ambiguity or not', () {
      final id = rebindSavedDeviceId(
        savedId: 'AA',
        savedName: 'RCE_RSPB-01',
        candidates: {'AA': 'RCE_RSPB-01', 'BB': 'RCE_RSPB-01'},
        useNameKey: true,
      );
      expect(id, 'AA');
    });

    test('a UNIQUE name match rebinds a volatile id', () {
      // The feature this function exists for: iOS peripheral identifiers can
      // change, and the advertised name is the stable secondary key.
      final id = rebindSavedDeviceId(
        savedId: 'OLD',
        savedName: 'RCE-SCAP_II',
        candidates: {'NEW': 'RCE-SCAP_II', 'OTHER': 'Some Headphones'},
        useNameKey: true,
      );
      expect(id, 'NEW');
    });

    test('TWO devices sharing a name rebinds to NEITHER', () {
      // The 007 scenario. Picking one would connect to whichever entry the map
      // yielded first and write its telemetry into the other unit's history —
      // silent, and unrecoverable afterwards. Falling back to the saved id
      // surfaces the existing "cannot resolve" path instead.
      final id = rebindSavedDeviceId(
        savedId: 'GONE',
        savedName: 'RCE_RSPB-01',
        candidates: {'0F70900B': 'RCE_RSPB-01', '58711753': 'RCE_RSPB-01'},
        useNameKey: true,
      );
      expect(id, 'GONE');
    });

    test('an empty saved name never rebinds', () {
      expect(
        rebindSavedDeviceId(
          savedId: 'OLD',
          savedName: '',
          candidates: {'NEW': '', 'OTHER': ''},
          useNameKey: true,
        ),
        'OLD',
      );
    });

    test('candidates advertising no name are not matched against each other',
        () {
      // Two nameless peripherals are not "the same device"; empty must never
      // count as a match.
      expect(
        rebindSavedDeviceId(
          savedId: 'OLD',
          savedName: 'RCE-SCAP_II',
          candidates: {'A': '', 'B': ''},
          useNameKey: true,
        ),
        'OLD',
      );
    });
  });

  group('DiscoveredDevice vendor tagging', () {
    test('the vendor flag is what the default list filters on', () {
      // Documents the coupling: widening looksLikeVendorName is only useful
      // because this flag drives visibility.
      const hidden = DiscoveredDevice(
          id: 'x', name: 'Random Speaker', rssi: -60, isVendor: false);
      const shown = DiscoveredDevice(
          id: 'y', name: 'RCE_RSPB-01', rssi: -60, isVendor: true);
      expect(hidden.isVendor, isFalse);
      expect(shown.isVendor, isTrue);
    });
  });
}
