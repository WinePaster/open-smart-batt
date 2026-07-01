/// OpenSmartBatt — diagnostic raw-packet log entry (mockup settings: diagnostics).
///
/// PURE Dart. Records raw BLE TX/RX hex when the diagnostics toggle is ON
/// (DEFAULT OFF). Exportable as a .log file.
library;

/// Direction of a logged BLE packet, or `event` for a connection/error note.
enum LogDirection { tx, rx, event }

/// One raw BLE packet (or note) for the diagnostics log.
class LogEntry {
  /// Row id (null until persisted).
  final int? id;

  /// When the packet was sent/received.
  final DateTime timestamp;

  /// TX (app -> battery) or RX (battery -> app).
  final LogDirection direction;

  /// Lower-case hex of the raw bytes (no separators), e.g. "b8230001069c".
  final String hex;

  /// Optional human note (e.g. "keep-alive", "switchMode(6)", decoded selector).
  final String? note;

  const LogEntry({
    this.id,
    required this.timestamp,
    required this.direction,
    required this.hex,
    this.note,
  });

  /// Build from raw bytes.
  factory LogEntry.fromBytes(
    LogDirection direction,
    List<int> bytes, {
    DateTime? at,
    String? note,
    int? id,
  }) =>
      LogEntry(
        id: id,
        timestamp: at ?? DateTime.now(),
        direction: direction,
        hex: bytes
            .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0'))
            .join(),
        note: note,
      );

  /// A connection/error event (no raw bytes). Always safe to record.
  factory LogEntry.event(String message, {DateTime? at}) => LogEntry(
        timestamp: at ?? DateTime.now(),
        direction: LogDirection.event,
        hex: '',
        note: message,
      );

  /// One-line `.log` rendering: `2026-06-29T13:09:12.000 TX b823... # note`.
  String toLogLine() {
    final dir = switch (direction) {
      LogDirection.tx => 'TX',
      LogDirection.rx => 'RX',
      LogDirection.event => 'EVT',
    };
    final n = note == null ? '' : ' # $note';
    return '${timestamp.toIso8601String()} $dir $hex$n';
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'direction': direction.name,
        'hex': hex,
        'note': note,
      };

  static LogEntry fromMap(Map<String, Object?> m) => LogEntry(
        id: (m['id'] as num?)?.toInt(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            (m['timestamp'] as num).toInt()),
        direction: LogDirection.values.firstWhere(
          (d) => d.name == m['direction'],
          orElse: () => LogDirection.rx,
        ),
        hex: m['hex'] as String,
        note: m['note'] as String?,
      );
}
