import 'package:flutter_test/flutter_test.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

void main() {
  group('CommandBuilder.parseAuthValue ("use my code" direct entry)', () {
    test('decimal', () {
      expect(CommandBuilder.parseAuthValue('204'), 204);
      expect(CommandBuilder.parseAuthValue('168'), 168);
      expect(CommandBuilder.parseAuthValue(' 0 '), 0);
    });

    test('hex 0x prefix (case-insensitive)', () {
      expect(CommandBuilder.parseAuthValue('0xCC'), 0xCC);
      expect(CommandBuilder.parseAuthValue('0Xa8'), 0xA8);
    });

    test('masks to 16 bits', () {
      expect(CommandBuilder.parseAuthValue('0x1FFFF'), 0xFFFF);
    });

    test('rejects garbage / empty / negative', () {
      expect(() => CommandBuilder.parseAuthValue(''), throwsFormatException);
      expect(() => CommandBuilder.parseAuthValue('abc'), throwsFormatException);
      expect(() => CommandBuilder.parseAuthValue('-5'), throwsFormatException);
    });

    test('direct values build the captured-style auth frame', () {
      // cb=168 (0x00A8), pwSum=204 (0x00CC) → payload 00 A8 00 CC
      final creds = AuthCredentials(
        cb: CommandBuilder.parseAuthValue('168'),
        pwSum: CommandBuilder.parseAuthValue('0xCC'),
      );
      expect(creds.cbHi, 0x00);
      expect(creds.cbLo, 0xA8);
      expect(creds.pwHi, 0x00);
      expect(creds.pwLo, 0xCC);
    });
  });
}
