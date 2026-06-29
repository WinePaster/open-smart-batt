/// Open-RCE-Batt — device-list bottom sheet (mockup screen 3, `.devwrap`).
///
/// A modal bottom sheet listing:
///   * 已儲存裝置 — saved batteries (editable alias, signal if nearby,
///     連線 / 已連線), and
///   * 附近掃描中 — live vendor-service (07b9fff0) scan results, filtered to the
///     RCE service, sorted by RSSI, with signal bars.
///
/// Connecting a previously-unsaved device pops the sheet returning its BLE id;
/// the host then shows [showAliasDialog] so the user can name + save it.
///
/// CLEAN-ROOM: layout/flow from mockup/index.html only. Scan filter + BLE facts
/// from docs/PROTOCOL.md (service 07b9fff0, RSSI). State via provider.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ble/ble.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'alias_dialog.dart';
import 'signal_bars.dart';

/// Open the device-list sheet. After it closes, if the user connected a brand
/// new (unsaved) device, prompt for an alias and persist it.
Future<void> showDeviceListSheet(BuildContext context) async {
  // [host] is the caller's context (e.g. the dashboard); it stays mounted after
  // the sheet pops, so the post-connect alias dialog has a valid context.
  final host = context;

  final connectedNewId = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0xB804060A), // mockup rgba(4,6,10,.72)
    builder: (_) => const DeviceListSheet(),
  );

  if (connectedNewId == null || !host.mounted) return;

  final devices = host.read<DeviceController>();
  if (devices.isSaved(connectedNewId)) return; // already named elsewhere

  final tele = host.read<TelemetryController>();
  final alias = await showAliasDialog(host);
  if (alias == null || !host.mounted) return;
  await devices.saveNew(connectedNewId, alias, lastValue: tele.pvlt);
}

/// The sheet body (mockup `.devpanel`). Starts a scan on open, stops on close.
class DeviceListSheet extends StatefulWidget {
  const DeviceListSheet({super.key});

  @override
  State<DeviceListSheet> createState() => _DeviceListSheetState();
}

class _DeviceListSheetState extends State<DeviceListSheet> {
  /// BLE id of the row whose connect is in flight (drives the row spinner).
  String? _connectingId;

  /// Captured in [initState] so [dispose] can stop the scan without touching
  /// the (possibly deactivated) element tree.
  ConnectionController? _conn;

  @override
  void initState() {
    super.initState();
    _conn = context.read<ConnectionController>();
    // Begin scanning as soon as the sheet appears.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override
  void dispose() {
    // Best-effort stop; controller tolerates a no-op when not scanning.
    _conn?.stopScan();
    super.dispose();
  }

  void _startScan() {
    if (!mounted) return;
    context.read<ConnectionController>().startScan();
  }

  Future<void> _rescan() async {
    final conn = context.read<ConnectionController>();
    await conn.stopScan();
    await conn.startScan();
  }

  /// Connect to a saved device, then close the sheet (no alias prompt).
  Future<void> _connectSaved(SavedDevice d) async {
    final conn = context.read<ConnectionController>();
    setState(() => _connectingId = d.id);
    try {
      await conn.connectToSaved(d);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _connectingId = null);
        _showError();
      }
    }
  }

  /// Connect to a freshly-discovered device; on success pop the sheet returning
  /// its id so the host can prompt for an alias.
  Future<void> _connectNew(DiscoveredDevice d) async {
    final conn = context.read<ConnectionController>();
    setState(() => _connectingId = d.id);
    try {
      await conn.connect(d.id);
      if (mounted) Navigator.of(context).pop(d.id);
    } catch (_) {
      if (mounted) {
        setState(() => _connectingId = null);
        _showError();
      }
    }
  }

  void _showError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('連線失敗，請再試一次')),
    );
  }

  Future<void> _rename(SavedDevice d) async {
    final devices = context.read<DeviceController>();
    final alias = await showAliasDialog(context, initial: d.alias, isRename: true);
    if (alias != null && mounted) {
      await devices.rename(d.id, alias);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final devices = context.watch<DeviceController>();

    final saved = devices.devices;
    final scan = conn.scanResults;
    final connectedId = conn.connectedDeviceId;

    // RSSI lookup so saved rows can show live signal when nearby.
    final rssiById = <String, int>{for (final r in scan) r.id: r.rssi};

    // Nearby = scan hits not already in the saved list.
    final nearby = [
      for (final r in scan)
        if (!devices.isSaved(r.id)) r,
    ];

    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.82;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            color: AppColors.panel,
            border: Border(top: BorderSide(color: AppColors.line2)),
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grab handle (mockup `.handle`).
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.line2,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                _Header(scanning: conn.isScanning, onRescan: _rescan),
                if (!conn.isAdapterOn) const _AdapterOffNote(),

                // ---- saved devices --------------------------------------
                const _SectionLabel(
                  icon: Icons.bluetooth,
                  text: '已儲存裝置',
                ),
                if (saved.isEmpty)
                  const _EmptyHint('尚無已儲存裝置')
                else
                  for (final d in saved)
                    _DeviceRow(
                      alias: d.alias.isEmpty ? '未命名裝置' : d.alias,
                      aliasMuted: false,
                      meta: _savedMeta(d, rssiById[d.id]),
                      signalLevel: rssiById.containsKey(d.id)
                          ? signalLevelFromRssi(rssiById[d.id]!)
                          : 0,
                      isConnected: conn.isOnline && connectedId == d.id,
                      isConnecting: _connectingId == d.id,
                      onEdit: () => _rename(d),
                      onConnect: () => _connectSaved(d),
                    ),

                // ---- nearby scan ----------------------------------------
                _ScanSectionLabel(scanning: conn.isScanning),
                if (nearby.isEmpty)
                  _EmptyHint(
                    conn.isScanning ? '掃描中…' : '附近找不到裝置（確認電容已上電、藍牙開啟，並靠近一點）',
                  )
                else
                  for (final r in nearby)
                    _DeviceRow(
                      alias: r.name.isEmpty ? 'RCE-BATT 未命名' : r.name,
                      aliasMuted: true,
                      meta: '${_shortId(r.id)} · RSSI ${r.rssi} dBm',
                      signalLevel: signalLevelFromRssi(r.rssi),
                      isConnected: conn.isOnline && connectedId == r.id,
                      isConnecting: _connectingId == r.id,
                      onConnect: () => _connectNew(r),
                    ),

                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '顯示附近 BLE 裝置；認不出時可看訊號強度或靠近電容再掃',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: AppColors.muted),
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

// ---- meta / formatting helpers ------------------------------------------

String _savedMeta(SavedDevice d, int? rssi) {
  final parts = <String>[_shortId(d.id)];
  if (d.lastValue != null) parts.add('${d.lastValue!.toStringAsFixed(2)}V');
  final t = _relativeTime(d.lastSeen);
  if (t != null) parts.add(t == '剛剛' ? '剛剛' : '上次 $t');
  return parts.join(' · ');
}

/// Condense a BLE id (MAC / UUID) to "head…tail" like the mockup.
String _shortId(String id) {
  final s = id.replaceAll(':', '');
  if (s.length <= 9) return s;
  return '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
}

String? _relativeTime(DateTime? t) {
  if (t == null) return null;
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '剛剛';
  if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
  if (d.inHours < 24) return '${d.inHours} 小時前';
  return '${d.inDays} 天前';
}

// ---- sub-widgets ---------------------------------------------------------

/// Sheet header: title + rescan button (mockup `.devhead`).
class _Header extends StatelessWidget {
  const _Header({required this.scanning, required this.onRescan});

  final bool scanning;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '選擇裝置',
            style: TextStyle(
              fontSize: 16,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          // rescan pill (mockup `.rescan`).
          InkWell(
            onTap: scanning ? null : onRescan,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.panel2,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (scanning)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: AppColors.amber,
                      ),
                    )
                  else
                    const Icon(Icons.power_settings_new,
                        size: 13, color: AppColors.amber),
                  const SizedBox(width: 6),
                  Text(
                    scanning ? '掃描中…' : '重新掃描',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.amber,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section label with a leading icon (mockup `.devsec`).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 9),
      child: Row(
        children: [
          Icon(icon, size: 12, color: AppColors.amber),
          const SizedBox(width: 8),
          Text(text, style: _devsecStyle),
        ],
      ),
    );
  }
}

/// Nearby-scan section label with the pulsing scan dot (mockup `.scan-dot`).
class _ScanSectionLabel extends StatelessWidget {
  const _ScanSectionLabel({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 9),
      child: Row(
        children: [
          _ScanDot(active: scanning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              scanning
                  ? '附近掃描中…'
                  : '附近裝置',
              style: _devsecStyle,
            ),
          ),
        ],
      ),
    );
  }
}

const TextStyle _devsecStyle = TextStyle(
  fontSize: 10,
  letterSpacing: 2,
  color: AppColors.muted,
  fontWeight: FontWeight.w600,
);

/// Pulsing amber dot (mockup `@keyframes pulse`).
class _ScanDot extends StatefulWidget {
  const _ScanDot({required this.active});

  final bool active;

  @override
  State<_ScanDot> createState() => _ScanDotState();
}

class _ScanDotState extends State<_ScanDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ScanDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: widget.active
          ? Tween<double>(begin: 0.3, end: 1).animate(_c)
          : const AlwaysStoppedAnimation(0.45),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: AppColors.amber,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A device row (mockup `.drow`). Used for both saved + nearby entries.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.alias,
    required this.aliasMuted,
    required this.meta,
    required this.signalLevel,
    required this.isConnected,
    required this.isConnecting,
    required this.onConnect,
    this.onEdit,
  });

  final String alias;
  final bool aliasMuted;
  final String meta;
  final int signalLevel;
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback onConnect;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        border: Border.all(
          color: isConnected ? AppColors.good : AppColors.line,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          // icon tile (mockup `.dico`).
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.bg,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.battery_full, size: 19, color: AppColors.amber),
          ),
          const SizedBox(width: 12),
          // alias + meta (mockup `.dmain`).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              aliasMuted ? FontWeight.w600 : FontWeight.w700,
                          color: aliasMuted ? AppColors.muted : AppColors.text,
                        ),
                      ),
                    ),
                    if (onEdit != null) ...[
                      const SizedBox(width: 7),
                      InkWell(
                        onTap: onEdit,
                        child: const Icon(Icons.edit_outlined,
                            size: 14, color: AppColors.muted),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono.copyWith(
                    fontSize: 10.5,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (signalLevel > 0) ...[
            SignalBars(level: signalLevel),
            const SizedBox(width: 10),
          ],
          _ConnectButton(
            connected: isConnected,
            connecting: isConnecting,
            onTap: onConnect,
          ),
        ],
      ),
    );
  }
}

/// Connect / connected pill (mockup `.dbtn.go` / `.dbtn.on2`).
class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.connected,
    required this.connecting,
    required this.onTap,
  });

  final bool connected;
  final bool connecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (connected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: AppColors.good),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          '已連線',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: AppColors.good,
          ),
        ),
      );
    }
    return InkWell(
      onTap: connecting ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.amber,
          borderRadius: BorderRadius.circular(8),
        ),
        child: connecting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: AppColors.onAmber,
                ),
              )
            : const Text(
                '連線',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.onAmber,
                ),
              ),
      ),
    );
  }
}

/// Adapter-off banner shown inside the sheet (mockup `.warnbox` tone).
class _AdapterOffNote extends StatelessWidget {
  const _AdapterOffNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x12F6A821),
        border: Border.all(color: const Color(0x47F6A821)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.amber),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '藍牙未開啟，請先開啟藍牙再掃描',
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: AppColors.amber),
            ),
          ),
        ],
      ),
    );
  }
}

/// Muted placeholder when a section has no entries.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
        ),
      ),
    );
  }
}
