// Design 0098 (2026-11-09) — `0x2B` is the unit's internal PROTECTION setting
// and must not reach any screen, alert or export.
//
// Owner, verbatim: 「0x2B 我們定義為保護參數/保護數據…也不放app內」.
//
// Removing `TelemetryController.warnOv/warnUv/warnOt` closed the obvious door,
// but `tele.sample.warnOv` is still one dot away from any widget. This test is
// the structural half: outside the protocol layer and the sample model itself,
// no CODE line may read the decoded `0x2B` fields. Comments are allowed — the
// design history refers to them by name.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The only places allowed to touch the decoded `0x2B` fields: the decoder
/// that writes them and the model that holds them. Everything else — the
/// threshold resolver included — may name them in comments only.
const _allowed = {
  'lib/protocol/telemetry_decoder.dart',
  'lib/models/telemetry_sample.dart',
};

final _field = RegExp(r'\bwarn(Ov|Uv|Ot|OtByte)\b');

void main() {
  test('no code outside the protocol layer reads the 0x2B fields', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path)) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first; // drop line comments / docs
        if (_field.hasMatch(code)) offenders.add('$path:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty,
        reason: '0x2B is a protection parameter (design 0098) — read it in the '
            'protocol layer only');
  });

  test('the guard actually sees the decoder (it is not scanning nothing)', () {
    final decoder = File('lib/protocol/telemetry_decoder.dart').readAsStringSync();
    expect(_field.hasMatch(decoder), isTrue);
  });
}
