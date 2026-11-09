// A MADE-UP query/response protocol for exercising the device-profile seam
// (design 0099 P5).
//
// ⚠️ Invented for this test. It deliberately resembles no real battery
// management system: the sync byte, framing, checksum, UUIDs and register
// layout are all arbitrary. Its only job is to be shaped unlike RCE in the
// ways that matter to the seam:
//
//   * request/response, ONE request outstanding at a time (RCE streams on a
//     token);
//   * its own framing and checksum (RCE: 0xB8 + XOR over a different layout);
//   * 16 cells, 500 ms polling (RCE: 4 cells, 1 Hz);
//   * read-only: only its two read requests may be written;
//   * generic UUIDs, so GATT alone only makes it a CANDIDATE; a signature
//     characteristic is what confirms it.
//
// Frame: 0x5A, LEN, PAYLOAD[LEN], XOR of every preceding byte.
import 'package:open_smart_batt/demo/demo.dart';
import 'package:open_smart_batt/models/telemetry_sample.dart';
import 'package:open_smart_batt/protocol/protocol.dart';

const int kFqSync = 0x5A;
const int kFqCells = 0x01;
const int kFqStatus = 0x02;

const String kFqService = '0000fe50-0000-1000-8000-00805f9b34fb';
const String kFqWrite = '0000fe51-0000-1000-8000-00805f9b34fb';
const String kFqNotify = '0000fe52-0000-1000-8000-00805f9b34fb';
const String kFqSignature = '0000fe5f-0000-1000-8000-00805f9b34fb';

List<int> fqFrame(List<int> payload) {
  final body = [kFqSync, payload.length, ...payload];
  return [...body, body.fold<int>(0, (a, b) => a ^ b)];
}

final List<int> fqReadCells = fqFrame(const [kFqCells]);
final List<int> fqReadStatus = fqFrame(const [kFqStatus]);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class FakeQueryProfile implements DeviceProfile {
  const FakeQueryProfile();

  @override
  String get id => 'fake-query';

  @override
  GattEndpoints get endpoints => const GattEndpoints(
    serviceUuid: kFqService,
    writeCharUuid: kFqWrite,
    notifyCharUuid: kFqNotify,
  );

  @override
  bool looksLikeThisDevice(AdvertisementEvidence ad) =>
      ad.name.startsWith('FQ-');

  @override
  ProfileMatch matchGatt(GattSnapshot gatt) {
    if (pickEndpoints(gatt, endpoints) == null) return ProfileMatch.none;
    final hasSignature = gatt.services.any(
      (s) => s.characteristics.any((c) => c.uuid == kFqSignature),
    );
    return hasSignature ? ProfileMatch.confirmed : ProfileMatch.candidate;
  }

  @override
  ProtocolSession openSession() => FakeQuerySession();
}

class FakeQuerySession implements ProtocolSession {
  FakeQuerySession({this.timeoutTicks = 3});

  /// Ticks to wait for an answer before asking again.
  final int timeoutTicks;

  final List<int> _buf = [];
  int? _outstandingSince;
  bool _askCellsNext = true;
  TelemetrySample _sample = TelemetrySample.empty();

  /// Frames dropped for a bad checksum or impossible length.
  int dropped = 0;

  @override
  Duration get tickInterval => const Duration(milliseconds: 500);

  @override
  Duration get stallThreshold => const Duration(seconds: 3);

  @override
  List<int>? nextPoll(int tick) {
    final since = _outstandingSince;
    if (since != null && tick - since < timeoutTicks) return null;
    _outstandingSince = tick;
    final req = _askCellsNext ? fqReadCells : fqReadStatus;
    _askCellsNext = !_askCellsNext;
    return req;
  }

  @override
  bool ingest(List<int> chunk, DateTime at) {
    _buf.addAll(chunk);
    var changed = false;
    while (true) {
      final sync = _buf.indexOf(kFqSync);
      if (sync < 0) {
        _buf.clear();
        break;
      }
      if (sync > 0) _buf.removeRange(0, sync);
      if (_buf.length < 2) break;
      final total = _buf[1] + 3;
      if (_buf.length < total) break;
      final f = _buf.sublist(0, total);
      final xor = f.sublist(0, total - 1).fold<int>(0, (a, b) => a ^ b);
      if (xor != f.last) {
        // A spliced or truncated answer: drop just the sync byte and resync,
        // and never decode any part of it.
        dropped++;
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, total);
      _outstandingSince = null;
      changed = _apply(f.sublist(2, total - 1), at) || changed;
    }
    return changed;
  }

  bool _apply(List<int> p, DateTime at) {
    if (p.isEmpty) return false;
    if (p.first == kFqCells && p.length == 1 + 32) {
      final cells = [
        for (var i = 0; i < 16; i++) (p[1 + 2 * i] * 256 + p[2 + 2 * i]) / 1000,
      ];
      _sample = _sample.copyWith(
        timestamp: at,
        dvol: cells,
        pvlt: double.parse(
          cells.fold<double>(0, (a, b) => a + b).toStringAsFixed(3),
        ),
      );
      return true;
    }
    if (p.first == kFqStatus && p.length == 3) {
      _sample = _sample.copyWith(
        timestamp: at,
        temperatureC: p[1] - 40,
        socPercent: p[2],
      );
      return true;
    }
    return false;
  }

  @override
  TelemetrySample get sample => _sample;

  @override
  DeviceMetadata get metadata => const EmptyDeviceMetadata();

  @override
  void discardPartial() => _buf.clear();

  @override
  bool allowsWrite(List<int> bytes) =>
      _same(bytes, fqReadCells) || _same(bytes, fqReadStatus);
}

/// How the simulated unit misbehaves.
enum FqFault { none, truncateCells, glueAnswers, silent }

/// The simulated unit on the other end.
class FakeQueryPeer implements SimulatedPeer {
  FakeQueryPeer({this.fault = FqFault.none});
  FqFault fault;
  final written = <List<int>>[];
  List<int>? _held;

  static List<int> cellsAnswer() => fqFrame([
    kFqCells,
    for (var i = 0; i < 16; i++) ...[0x0D, 0x00 + i], // 3.328 V + i mV
  ]);

  static List<int> statusAnswer() => fqFrame(const [kFqStatus, 65, 87]);

  @override
  List<List<int>> answer(List<int> w) {
    written.add(List<int>.of(w));
    if (fault == FqFault.silent) return const [];
    final List<int> a;
    if (_same(w, fqReadCells)) {
      a = cellsAnswer();
    } else if (_same(w, fqReadStatus)) {
      a = statusAnswer();
    } else {
      return const [];
    }
    switch (fault) {
      case FqFault.truncateCells:
        // The cells answer loses its tail and the next answer lands right
        // after it, the way a unit answering an overlapping request would.
        if (_same(w, fqReadCells)) return [a.sublist(0, a.length - 5)];
        return [a];
      case FqFault.glueAnswers:
        // Hold one answer back and send two in one go.
        final held = _held;
        if (held == null) {
          _held = a;
          return const [];
        }
        _held = null;
        return [
          [...held, ...a],
        ];
      case FqFault.none:
      case FqFault.silent:
        return [a];
    }
  }
}
