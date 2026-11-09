// The cut-off / release dialogs must not repeat two claims that were false.
//
// * "release is NOT yet proven to work": 2026.08.14/003 shows this app
//   restoring power 5 times on 3 independent batteries. What is still true is
//   that it is not guaranteed (2026.08.15/003 still fails), and the copy says
//   that instead.
// * "known-safe release (mode 0x06)": release sends 0x00
//   (ConnectionController.releaseCutOff); 0x06 is a capacitor self-check.
//   See the header of release_cutoff_dialog.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/l10n/app_localizations.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('cut-off copy is accurate ($locale)', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      expect(l10n.releaseDialogBody, isNot(contains('0x06')));
      expect(l10n.releaseDialogBody.toLowerCase(), isNot(contains('known-safe')));
      expect(l10n.releaseDialogBody, isNot(contains('已知安全')));
      expect(l10n.cutOffDialogBody, isNot(contains('NOT yet proven')));
      expect(l10n.cutOffDialogBody, isNot(contains('尚未被證實')));
      // The risk warning itself must survive the rewrite.
      expect(l10n.cutOffDialogBody,
          anyOf(contains('not guaranteed'), contains('不保證')));
    });
  }
}
