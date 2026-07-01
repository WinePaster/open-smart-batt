/// OpenSmartBatt — device-list bottom sheet (mockup screen 3, `.devwrap`).
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
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
  // Capture the stable advertised name now (D.3): on iOS the saved id is a
  // volatile NSUUID, so the name is what rebinds the record after a reinstall.
  final advName = host.read<ConnectionController>().connectedDeviceName;
  final alias = await showAliasDialog(host);
  if (alias == null || !host.mounted) return;
  await devices.saveNew(connectedNewId, alias,
      name: advName, lastValue: tele.pvlt);
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

  /// When false (default) the nearby list shows only RCE devices; the toggle
  /// reveals all nearby BLE devices.
  bool _showAllNearby = false;

  /// Captured in [initState] so [dispose] can stop the scan without touching
  /// the (possibly deactivated) element tree.
  ConnectionController? _conn;

  @override
  void initState() {
    super.initState();
    _conn = context.read<ConnectionController>();
    // Begin scanning as soon as the sheet appears. D.1: startScan now awaits
    // the adapter and surfaces adapter-off / unauthorized as real errors (via
    // the controller's lastError + the adapter note below) rather than throwing
    // out of this post-frame callback.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_startScan()));
  }

  @override
  void dispose() {
    // Best-effort stop; controller tolerates a no-op when not scanning.
    _conn?.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!mounted) return;
    await context.read<ConnectionController>().startScan();
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
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1600),
        content: Text(l10n.devicesConnectFailed),
      ),
    );
  }

  Future<void> _rename(SavedDevice d) async {
    final devices = context.read<DeviceController>();
    final alias = await showAliasDialog(context, initial: d.alias, isRename: true);
    if (alias != null && mounted) {
      await devices.rename(d.id, alias);
    }
  }

  /// Disconnect the live link, then close the sheet.
  Future<void> _disconnect() async {
    final conn = context.read<ConnectionController>();
    await conn.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  /// Remove a saved device after confirmation (also disconnects if it's live).
  Future<void> _removeDevice(SavedDevice d) async {
    final l10n = AppLocalizations.of(context);
    final devices = context.read<DeviceController>();
    final conn = context.read<ConnectionController>();
    final alias = d.alias.isEmpty ? d.id : d.alias;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.colors.panel,
        title: Text(l10n.devicesRemoveTitle,
            style: TextStyle(color: ctx.colors.text, fontSize: 16)),
        content: Text(l10n.devicesRemoveBody(alias),
            style: TextStyle(color: ctx.colors.muted, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel, style: TextStyle(color: ctx.colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.devicesRemove,
                style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (conn.isOnline && conn.connectedDeviceId == d.id) {
      await conn.disconnect();
    }
    await devices.remove(d.id);
    // Re-scan so the just-removed device pops back into the nearby list once it
    // resumes advertising (a just-disconnected device needs a few seconds).
    if (mounted) await _rescan();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    final devices = context.watch<DeviceController>();

    final saved = devices.devices;
    final scan = conn.scanResults;
    final connectedId = conn.connectedDeviceId;

    // RSSI lookup so saved rows can show live signal when nearby.
    final rssiById = <String, int>{for (final r in scan) r.id: r.rssi};

    // Nearby = scan hits not already in the saved list.
    final nearbyAll = [
      for (final r in scan)
        if (!devices.isSaved(r.id)) r,
    ];
    // Default: only RCE devices; toggle reveals everything.
    final nearby = _showAllNearby
        ? nearbyAll
        : [for (final r in nearbyAll) if (r.isVendor) r];
    final hiddenCount = nearbyAll.length - nearby.length;

    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.82;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: context.colors.panel,
            border: Border(top: BorderSide(color: context.colors.line2)),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(18)),
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
                      color: context.colors.line2,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                _Header(scanning: conn.isScanning, onRescan: _rescan),
                if (!conn.isAdapterOn)
                  _AdapterOffNote(
                    // D.2: distinguish "permission denied" (deep-link Settings)
                    // from "radio off" (toggle Bluetooth).
                    unauthorized: conn.isAdapterUnauthorized,
                    onOpenSettings: conn.openBluetoothSettings,
                  ),

                // ---- saved devices --------------------------------------
                _SectionLabel(
                  icon: Icons.bluetooth,
                  text: l10n.devicesSavedSection,
                ),
                if (saved.isEmpty)
                  _EmptyHint(l10n.devicesNoSaved)
                else
                  for (final d in saved)
                    _DeviceRow(
                      alias: d.alias.isEmpty ? l10n.devicesUnnamed : d.alias,
                      aliasMuted: false,
                      meta: _savedMeta(d, rssiById[d.id], l10n),
                      signalLevel: rssiById.containsKey(d.id)
                          ? signalLevelFromRssi(rssiById[d.id]!)
                          : 0,
                      isConnected: conn.isOnline && connectedId == d.id,
                      isConnecting: _connectingId == d.id,
                      onEdit: () => _rename(d),
                      onDelete: () => _removeDevice(d),
                      onDisconnect: _disconnect,
                      onConnect: () => _connectSaved(d),
                    ),

                // ---- nearby scan ----------------------------------------
                _ScanSectionLabel(scanning: conn.isScanning),
                if (nearby.isEmpty)
                  _EmptyHint(
                    conn.isScanning ? l10n.devicesScanning : l10n.devicesNearbyNotFound,
                  )
                else
                  for (final r in nearby)
                    _DeviceRow(
                      alias: r.name.isEmpty ? l10n.devicesUnknownName : r.name,
                      aliasMuted: true,
                      isVendor: r.isVendor,
                      meta: '${_shortId(r.id)} · RSSI ${r.rssi} dBm',
                      signalLevel: signalLevelFromRssi(r.rssi),
                      isConnected: conn.isOnline && connectedId == r.id,
                      isConnecting: _connectingId == r.id,
                      onDisconnect: _disconnect,
                      onConnect: () => _connectNew(r),
                    ),

                const SizedBox(height: 2),
                Center(
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllNearby = !_showAllNearby),
                    child: Text(
                      _showAllNearby
                          ? l10n.devicesShowRceOnly
                          : (hiddenCount > 0
                              ? l10n.devicesShowAllWithHidden(hiddenCount)
                              : l10n.devicesShowAll),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.amber),
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

// ---- meta / formatting helpers ------------------------------------------

String _savedMeta(SavedDevice d, int? rssi, AppLocalizations l10n) {
  final parts = <String>[_shortId(d.id)];
  if (d.lastValue != null) parts.add('${d.lastValue!.toStringAsFixed(2)}V');
  final t = d.lastSeen;
  if (t != null) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) {
      // "Just now" renders standalone (no "Last" prefix).
      parts.add(l10n.relativeJustNow);
    } else if (diff.inMinutes < 60) {
      parts.add(l10n.devicesMetaLastSeen(l10n.relativeMinutesAgo(diff.inMinutes)));
    } else if (diff.inHours < 24) {
      parts.add(l10n.devicesMetaLastSeen(l10n.relativeHoursAgo(diff.inHours)));
    } else {
      parts.add(l10n.devicesMetaLastSeen(l10n.relativeDaysAgo(diff.inDays)));
    }
  }
  return parts.join(' · ');
}

/// Condense a BLE id (MAC / UUID) to "head…tail" like the mockup.
String _shortId(String id) {
  final s = id.replaceAll(':', '');
  if (s.length <= 9) return s;
  return '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
}

// ---- sub-widgets ---------------------------------------------------------

/// Sheet header: title + rescan button (mockup `.devhead`).
class _Header extends StatelessWidget {
  const _Header({required this.scanning, required this.onRescan});

  final bool scanning;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            l10n.devicesSheetTitle,
            style: TextStyle(
              fontSize: 16,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w700,
              color: context.colors.text,
            ),
          ),
          // rescan pill (mockup `.rescan`).
          InkWell(
            onTap: scanning ? null : onRescan,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: context.colors.panel2,
                border: Border.all(color: context.colors.line),
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
                    scanning ? l10n.devicesScanning : l10n.devicesRescan,
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
          Text(text, style: _devsecStyle(context)),
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
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 9),
      child: Row(
        children: [
          _ScanDot(active: scanning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              scanning ? l10n.devicesNearbyScanning : l10n.devicesNearby,
              style: _devsecStyle(context),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle _devsecStyle(BuildContext context) => TextStyle(
      fontSize: 10,
      letterSpacing: 2,
      color: context.colors.muted,
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
    this.onDelete,
    this.onDisconnect,
    this.isVendor = false,
  });

  final String alias;
  final bool aliasMuted;
  final String meta;
  final int signalLevel;
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback onConnect;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDisconnect;
  final bool isVendor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border.all(
          color: isConnected ? AppColors.good : context.colors.line,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Tapping anywhere on the row connects (inner edit/delete/中斷 buttons
        // absorb their own taps); a connected row's row-tap is a no-op.
        onTap: isConnected || isConnecting ? null : onConnect,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
        children: [
          // icon tile (mockup `.dico`).
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: context.colors.bg,
              border: Border.all(color: context.colors.line),
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
                          color: aliasMuted
                              ? context.colors.muted
                              : context.colors.text,
                        ),
                      ),
                    ),
                    if (isVendor) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.amber,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('RCE',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: AppColors.onAmber)),
                      ),
                    ],
                    if (onEdit != null) ...[
                      const SizedBox(width: 7),
                      InkWell(
                        onTap: onEdit,
                        child: Icon(Icons.edit_outlined,
                            size: 14, color: context.colors.muted),
                      ),
                    ],
                    if (onDelete != null) ...[
                      const SizedBox(width: 7),
                      InkWell(
                        onTap: onDelete,
                        child: Icon(Icons.delete_outline,
                            size: 15, color: context.colors.muted),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono(context).copyWith(
                    fontSize: 10.5,
                    color: context.colors.muted,
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
            onTap: isConnected ? (onDisconnect ?? onConnect) : onConnect,
          ),
            ],
          ),
        ),
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
    final l10n = AppLocalizations.of(context);
    if (connected) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: AppColors.danger),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            l10n.devicesDisconnect,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppColors.danger,
            ),
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
            : Text(
                l10n.devicesConnect,
                style: const TextStyle(
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

/// Adapter-off / unauthorized banner shown inside the sheet (mockup `.warnbox`
/// tone). D.2: when [unauthorized] the message points at the OS Settings (the
/// Bluetooth *permission* was denied — a radio toggle won't help) and exposes a
/// deep-link pill via [onOpenSettings]; otherwise it's the plain "turn on
/// Bluetooth" note.
class _AdapterOffNote extends StatelessWidget {
  const _AdapterOffNote({
    this.unauthorized = false,
    this.onOpenSettings,
  });

  final bool unauthorized;
  final Future<void> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x12F6A821),
        border: Border.all(color: const Color(0x47F6A821)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // NOTE: a dedicated "enable Bluetooth permission in Settings"
              // string for the unauthorized case is a pending l10n addition;
              // until then we reuse the adapter-off copy and lean on the
              // Settings deep-link pill to signal the actionable path.
              l10n.devicesAdapterOff,
              style: const TextStyle(
                  fontSize: 11, height: 1.5, color: AppColors.amber),
            ),
          ),
          if (unauthorized && onOpenSettings != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: () => unawaited(onOpenSettings!.call()),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: context.colors.panel2,
                  border: Border.all(color: const Color(0x47F6A821)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.settings, size: 13, color: AppColors.amber),
                    const SizedBox(width: 6),
                    Text(
                      l10n.navSettings,
                      style: const TextStyle(fontSize: 11, color: AppColors.amber),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
          style: TextStyle(fontSize: 11.5, color: context.colors.muted),
        ),
      ),
    );
  }
}
