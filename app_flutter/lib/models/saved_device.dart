/// Open-RCE-Batt — saved device model (our own SQLite, not the vendor's).
///
/// PURE Dart. Represents a battery the user has chosen to remember, with an
/// editable alias, for the device-list quick-reconnect flow (mockup screen 3).
library;

/// A user-saved battery + its alias and last-seen metadata.
class SavedDevice {
  /// BLE device id (platform remote id; stable per device).
  final String id;

  /// User-editable display alias (e.g. "電容 #1（前車）").
  final String alias;

  /// When this device was last connected/seen.
  final DateTime? lastSeen;

  /// Last PVLT value (V) shown in the quick-pick meta line; null if never read.
  final double? lastValue;

  const SavedDevice({
    required this.id,
    required this.alias,
    this.lastSeen,
    this.lastValue,
  });

  SavedDevice copyWith({
    String? id,
    String? alias,
    DateTime? lastSeen,
    double? lastValue,
  }) =>
      SavedDevice(
        id: id ?? this.id,
        alias: alias ?? this.alias,
        lastSeen: lastSeen ?? this.lastSeen,
        lastValue: lastValue ?? this.lastValue,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'alias': alias,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'last_value': lastValue,
      };

  static SavedDevice fromMap(Map<String, Object?> m) => SavedDevice(
        id: m['id'] as String,
        alias: (m['alias'] as String?) ?? '',
        lastSeen: m['last_seen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['last_seen'] as num).toInt()),
        lastValue: (m['last_value'] as num?)?.toDouble(),
      );
}
