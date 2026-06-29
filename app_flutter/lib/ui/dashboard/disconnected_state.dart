/// Open-RCE-Batt — dashboard disconnected empty state (mockup `.empty`).
///
/// Shown when no device is connected: a pulsing Bluetooth glyph, a prompt, a
/// quick-select list of saved devices (one-tap reconnect) and a "scan others"
/// button that hands off to the device-list sheet.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../devices/signal_bars.dart';

/// The dashboard's disconnected placeholder.
class DisconnectedState extends StatelessWidget {
  const DisconnectedState({super.key, this.onScanRequested});

  /// Invoked by the "掃描其他裝置" button. Typically opens the device-list
  /// sheet; falls back to starting a scan if not provided.
  final VoidCallback? onScanRequested;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final devices = conn.savedDevices;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight,
            minWidth: constraints.maxWidth, // fill width (IndexedStack passes loose constraints)
          ),
          child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _PulseIcon(),
            const SizedBox(height: 24),
            Text(
              '尚未連線裝置',
              style: TextStyle(
                fontSize: 23,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                '選擇已儲存的裝置快速重連，或掃描附近的 RCE 電容。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.7,
                  color: context.colors.muted,
                ),
              ),
            ),
            const SizedBox(height: 26),

            if (devices.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '快速選擇',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      color: context.colors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (final d in devices)
                _QuickPick(
                  device: d,
                  busy: conn.isBusy && conn.connectedDeviceId == d.id,
                  onTap: () => conn.connectToSaved(d),
                ),
              const SizedBox(height: 14),
            ],

            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      (onScanRequested ?? () => conn.startScan())(),
                  icon: const Icon(Icons.bluetooth, size: 16),
                  label: const Text('掃描其他裝置'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

/// Quick-reconnect row (mockup `.qpick`).
class _QuickPick extends StatelessWidget {
  const _QuickPick({
    required this.device,
    required this.busy,
    required this.onTap,
  });

  final SavedDevice device;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final alias = device.alias.isNotEmpty ? device.alias : device.id;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.colors.panel,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                const _DeviceGlyph(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: context.colors.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _metaLine(device),
                        style: AppTextStyles.mono(context).copyWith(
                          fontSize: 10.5,
                          color: context.colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.amber,
                    ),
                  )
                else
                  SignalBars(level: _recencyLevel(device.lastSeen)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _metaLine(SavedDevice d) {
    final parts = <String>[];
    if (d.lastValue != null) {
      parts.add('上次 ${d.lastValue!.toStringAsFixed(2)} V');
    }
    parts.add(_relativeTime(d.lastSeen));
    return parts.join(' · ');
  }
}

/// Amber capacitor glyph tile (mockup `.qpick .dico`).
class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(Icons.battery_charging_full,
          size: 19, color: AppColors.amber),
    );
  }
}

/// Pulsing Bluetooth glyph (mockup `.bigico` + ring animation).
class _PulseIcon extends StatefulWidget {
  const _PulseIcon();

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              return Transform.scale(
                scale: 1 + 0.25 * t,
                child: Opacity(
                  opacity: (0.35 * (1 - t)).clamp(0.0, 1.0),
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: AppColors.amber),
                    ),
                  ),
                ),
              );
            },
          ),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: context.colors.panel,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.bluetooth, size: 42, color: AppColors.amber),
          ),
        ],
      ),
    );
  }
}

/// Maps last-seen recency to a 1..4 quick-pick signal hint (no live RSSI here).
int _recencyLevel(DateTime? lastSeen) {
  if (lastSeen == null) return 1;
  final d = DateTime.now().difference(lastSeen);
  if (d < const Duration(minutes: 5)) return 4;
  if (d < const Duration(hours: 1)) return 3;
  if (d < const Duration(days: 1)) return 2;
  return 1;
}

/// Coarse relative-time label (mockup "剛剛 / 2 分鐘前 / 2 天前").
String _relativeTime(DateTime? t) {
  if (t == null) return '從未連線';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '剛剛';
  if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
  if (d.inHours < 24) return '${d.inHours} 小時前';
  return '${d.inDays} 天前';
}
