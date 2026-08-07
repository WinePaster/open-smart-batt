/// OpenSmartBatt — the devices tab (design 0046 P1, R2 / R21 / R22).
///
/// A list of:
///   * 已儲存裝置 — saved units (editable alias, signal if nearby, a status
///     badge, 連線 / 已連線), and
///   * 附近掃描中 — live vendor-service (07b9fff0) scan results, filtered to the
///     RCE service, sorted by RSSI, with signal bars.
///
/// ## Why this is a TAB and no longer a bottom sheet
///
/// FB `2026.08.02/004` (林陳裕): "切換裝置會先跳回主頁面 3～4 秒，以為藍牙斷線".
/// The sheet popped itself the moment a connect returned, which dropped the user
/// onto the dashboard's empty state for the 3.1–5.3 s (independently measured
/// median 4.97 s) a device switch takes. Nothing was wrong with the link; the UI
/// simply left the only screen that could have said so. Design 0046 R22 ruled
/// fix C: **the UI stays on this page.** Hence the three `Navigator.pop()` calls
/// that used to live in `_connectSaved` / `_connectNew` / `_disconnect` are gone
/// rather than moved, and the row's own button flips to 已連線 in place.
///
/// ## The badge is a door, not a decoration (R21 / T-new-6)
///
/// A row carries ONE WORD of status, because this page is for scanning a list
/// and a paragraph per row turns it into a wall of text. The full report — the
/// FB-52 stalled copy, the FB-53 give-up copy, the advice card and its retry —
/// lives on [DeviceDetailPage], and the badge is what gets you there. It must
/// never be only a colour: FB-53's complaint was precisely that "the app stopped
/// trying, and the only clue was that the spinner had gone".
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
import 'connection_failure.dart';
import 'device_detail_page.dart';
import 'signal_bars.dart';

/// The devices tab's body (sits inside the app shell's [Scaffold]).
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.active, this.onOpenSettings});

  /// Whether this tab is the one on screen.
  ///
  /// Whether this page is the visible tab.
  ///
  /// 🔴 `required`, not defaulted. It used to default to `true`, which reads as
  /// harmless and is not: this page lives in an `IndexedStack`, so it stays
  /// MOUNTED on every other tab. A caller that forgets the argument gets a BLE
  /// scan running from app start until the process dies — the exact defect this
  /// parameter was added to fix, restored silently by an omission rather than
  /// by an edit. Making it required means the compiler asks the question.
  final bool active;

  /// Switch to the Settings tab, handed down from the shell.
  ///
  /// It is threaded rather than looked up because it must go through the
  /// shell's single `_setTab` entry point: [DeviceDetailPage] hosts the
  /// dashboard, whose stale-telemetry banner links to Settings, and the
  /// 2026-08-07 review found that exact callback writing `_tab` behind the GNSS
  /// gate's back — leaving the receiver running under the Settings page.
  final VoidCallback? onOpenSettings;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
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
    // Begin scanning as soon as the page is ON SCREEN. D.1: startScan awaits
    // the adapter and surfaces adapter-off / unauthorized as real errors (via
    // the controller's lastError + the adapter note below) rather than throwing
    // out of this post-frame callback.
    if (widget.active) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_startScan()));
    }
  }

  @override
  void didUpdateWidget(DevicesPage old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      unawaited(_startScan());
    } else {
      _conn?.stopScan();
    }
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

  /// Connect to a saved device — and STAY HERE (design 0046 R22, fix C).
  ///
  /// 🔴 The `Navigator.pop()` that used to close this on success is deliberately
  /// absent. It is the whole of FB `2026.08.02/004`: popping handed the user
  /// back to the dashboard's empty state for the several seconds a switch takes,
  /// and an empty state is indistinguishable from a dropped link. The row's
  /// button becoming 已連線 is the confirmation instead — on the page the user
  /// was already looking at.
  Future<void> _connectSaved(SavedDevice d) async {
    final conn = context.read<ConnectionController>();
    setState(() => _connectingId = d.id);
    try {
      await conn.connectToSaved(d);
      // A refused connect RETURNS rather than throws — `bluetooth_off` and
      // `permission_denied` are answers, not exceptions (the radio being off is
      // not an error condition of ours), so the completion is only treated as
      // success when the controller has no complaint to make.
      if (!mounted) return;
      setState(() => _connectingId = null);
      if (conn.lastError != null) _showError();
    } catch (_) {
      if (mounted) {
        setState(() => _connectingId = null);
        _showError();
      }
    }
  }

  /// Connect to a freshly-discovered device, then name it WITHOUT leaving.
  ///
  /// The alias prompt used to belong to the sheet's host, reached by popping
  /// with the new id. With no pop there is no host to hand it to, so the two
  /// facts the prompt needs are captured here instead — see the comments on
  /// each; both predate this page and neither may be dropped in the move.
  Future<void> _connectNew(DiscoveredDevice d) async {
    final conn = context.read<ConnectionController>();
    final devices = context.read<DeviceController>();
    final tele = context.read<TelemetryController>();
    setState(() => _connectingId = d.id);
    try {
      await conn.connect(d.id);
      if (!mounted) return;
      // Same as _connectSaved: a refused connect returns instead of throwing.
      if (conn.lastError != null) {
        setState(() => _connectingId = null);
        _showError();
        return;
      }
      setState(() => _connectingId = null);
      if (devices.isSaved(d.id)) return; // already named elsewhere
      // Capture the stable advertised name now (D.3): on iOS the saved id is a
      // volatile NSUUID, so the name is what rebinds the record after a
      // reinstall.
      final advName = conn.connectedDeviceName;
      // Seed the persisted product class with whatever has resolved so far
      // (design 0001 §5 Phase 5); the connection controller keeps it current
      // afterwards.
      final initialClass = conn.isPowerBank ? conn.resolvedClass : conn.packLabel;
      final alias = await showAliasDialog(context);
      if (alias == null || !mounted) return;
      await devices.saveNew(d.id, alias,
          name: advName, lastValue: tele.pvlt, productClass: initialClass);
    } catch (_) {
      if (mounted) {
        setState(() => _connectingId = null);
        _showError();
      }
    }
  }

  /// Say WHY the connect failed, not just that it did.
  ///
  /// FB-44's third symptom is the one the classifier alone does not fix: the
  /// controller has known the difference between "the radio is off" and "this
  /// saved id no longer resolves" since `connectFailureError`, but every one of
  /// them arrived here as the same sentence — "connection failed, please try
  /// again". Telling someone to retry, when what they have to do is switch
  /// Bluetooth on, is the wrong instruction, which is the whole complaint.
  ///
  /// Unknown codes (a raw platform exception, `reconnect_exhausted`,
  /// `autoconnect_timeout`) keep the generic line on purpose: a wrong specific
  /// instruction is worse than a vague correct one, and this is the branch that
  /// catches everything we have not classified yet.
  void _showError() {
    final l10n = AppLocalizations.of(context);
    final code = context.read<ConnectionController>().lastError;
    final message = switch (code) {
      'bluetooth_off' => l10n.devicesConnectFailedBluetoothOff,
      'bluetooth_unauthorized' =>
        l10n.devicesConnectFailedBluetoothUnauthorized,
      'permission_denied' => l10n.devicesConnectFailedPermission,
      'device_stale' => l10n.devicesConnectFailedStale,
      // FB-53: the connect ran its budget out with nothing answering. Told to
      // scan again — the `device_stale` instruction this used to collapse into
      // — the user finds the unit is not in the scan either, and learns
      // nothing. Telling them to go and check it is nearby and switched on is
      // an instruction that can actually succeed.
      'device_unreachable' => l10n.devicesConnectFailedUnreachable,
      _ => l10n.devicesConnectFailed,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // The specific lines are longer and carry an instruction; 1.6 s is not
        // enough to read one. The generic line keeps its original duration.
        duration: Duration(
            milliseconds: code == null || message == l10n.devicesConnectFailed
                ? 1600
                : 3200),
        content: Text(message),
      ),
    );
  }

  Future<void> _rename(SavedDevice d) async {
    final devices = context.read<DeviceController>();
    final alias =
        await showAliasDialog(context, initial: d.alias, isRename: true);
    if (alias != null && mounted) {
      await devices.rename(d.id, alias);
    }
  }

  /// Drop the live link — and, again, stay on this page (R22).
  Future<void> _disconnect() async {
    await context.read<ConnectionController>().disconnect();
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
            child: Text(l10n.commonCancel,
                style: TextStyle(color: ctx.colors.muted)),
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

  /// The full report for one unit (R21): everything this list deliberately does
  /// not have room for.
  Future<void> _openDetail(SavedDevice d) async {
    // 🔴 Stop scanning for the duration, and start again on the way back.
    //
    // [active] cannot express this: the shell derives it from the TAB, and the
    // tab is still 裝置 while a detail route sits on top of it. So without this
    // the scan ran for the whole time the user was reading a device page — the
    // old bottom sheet stopped on `dispose` the moment it closed, and the
    // promotion to a tab quietly took that away.
    //
    // It is also the same window the GNSS gate calls "a detail page is open".
    // Having one of them treat it as "somebody is looking" while the other left
    // a radio running is the kind of disagreement that only shows up as battery.
    _conn?.stopScan();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceDetailPage(
        deviceId: d.id,
        onOpenSettings: widget.onOpenSettings,
      ),
    ));
    if (!mounted || !widget.active) return;
    unawaited(_startScan());
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

    final working = conn.isBusy || conn.isRetrying;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
      children: [
        _Header(scanning: conn.isScanning, onRescan: _rescan),
        if (!conn.isAdapterOn)
          _AdapterOffNote(
            // D.2: distinguish "permission denied" (deep-link Settings) from
            // "radio off" (toggle Bluetooth).
            unauthorized: conn.isAdapterUnauthorized,
            onOpenSettings: conn.openBluetoothSettings,
          ),

        // ---- saved devices ------------------------------------------------
        _SectionLabel(
          icon: Icons.bluetooth,
          text: l10n.devicesSavedCount(saved.length),
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
              // One word of status, and it is a link. See the library comment:
              // a badge that only changes colour is the FB-53 failure again.
              badge: connectionBadgeFor(
                isCurrentDevice: connectedId == d.id,
                isOnline: conn.isOnline,
                working: working || _connectingId == d.id,
                setupStalled: conn.isSetupStalled,
                lastError: conn.lastError,
              ),
              onOpenDetail: () => unawaited(_openDetail(d)),
              onEdit: () => _rename(d),
              onDelete: () => _removeDevice(d),
              onDisconnect: _disconnect,
              onConnect: () => _connectSaved(d),
            ),

        // ---- nearby scan --------------------------------------------------
        _ScanSectionLabel(scanning: conn.isScanning),
        // This toggle used to sit at the very bottom of the sheet — below the
        // saved list and below the fold when devices were saved. A user whose
        // unit was filtered out never learned that anything had been hidden. It
        // belongs directly under the section it filters.
        Center(
          child: TextButton(
            onPressed: () => setState(() => _showAllNearby = !_showAllNearby),
            child: Text(
              _showAllNearby
                  ? l10n.devicesShowRceOnly
                  : (hiddenCount > 0
                      ? l10n.devicesShowAllWithHidden(hiddenCount)
                      : l10n.devicesShowAll),
              style: const TextStyle(fontSize: 12, color: AppColors.amber),
            ),
          ),
        ),
        if (nearby.isEmpty)
          // "Nothing nearby" and "nothing nearby that looks like ours" are
          // different facts, and the second one has an action. The old copy
          // asserted the first even when N devices were being hidden — telling
          // the user to check the device is powered on while its entry sat one
          // tap away.
          _EmptyHint(
            conn.isScanning
                ? l10n.devicesScanning
                : (hiddenCount > 0
                    ? l10n.devicesNearbyNoneVendor(hiddenCount)
                    : l10n.devicesNearbyNotFound),
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
              // No badge and no detail route: an unsaved unit has no saved row
              // to hold a layout or a history, so there is no detail page for
              // it to be a door to.
              onDisconnect: _disconnect,
              onConnect: () => _connectNew(r),
            ),
      ],
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
      parts.add(
          l10n.devicesMetaLastSeen(l10n.relativeMinutesAgo(diff.inMinutes)));
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

/// Page header: title + rescan button (mockup `.devhead`).
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
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: context.colors.panel2,
                border: Border.all(color: context.colors.line),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
  // 🔴 Built EAGERLY, not `late final … = AnimationController(…)`. While
  // `active` is false nothing in `build` touches the field, so the lazy form
  // was first evaluated inside `dispose()` — which creates a Ticker, which
  // looks up `TickerMode` on an element that is already deactivated, which
  // trips a framework assertion. It survived unnoticed in the bottom sheet
  // because no test ever disposed that sheet with the scan idle.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
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

/// A device row (mockup `.drow` / `.lrow`). Used for both saved + nearby.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.alias,
    required this.aliasMuted,
    required this.meta,
    required this.signalLevel,
    required this.isConnected,
    required this.isConnecting,
    required this.onConnect,
    this.badge,
    this.onOpenDetail,
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

  /// One-word status, saved rows only (R21). Null on a nearby (unsaved) row.
  final ConnectionBadge? badge;

  /// Where [badge] leads. Non-null exactly when [badge] is.
  final VoidCallback? onOpenDetail;

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDisconnect;
  final bool isVendor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border.all(
          color: isConnected ? AppColors.good : context.colors.line,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // A saved row opens its detail page; an unsaved one connects (there is
        // no detail page for a unit with no saved record). Inner
        // edit/delete/connect buttons absorb their own taps.
        onTap: onOpenDetail ??
            (isConnected || isConnecting ? null : onConnect),
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
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: const Icon(Icons.battery_full,
                    size: 19, color: AppColors.amber),
              ),
              const SizedBox(width: 12),
              // alias + meta + badge (mockup `.dmain`).
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
                              fontWeight: aliasMuted
                                  ? FontWeight.w600
                                  : FontWeight.w700,
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
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusSm),
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
                    if (badge != null) ...[
                      const SizedBox(height: 5),
                      _StatusBadge(
                        badge: badge!,
                        label: connectionBadgeLabel(l10n, badge!),
                        onTap: onOpenDetail,
                      ),
                    ],
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

/// One word of status, and the way to the rest of it (R21 / T-new-6).
///
/// 🔴 It is an [InkWell], not a coloured [Container]. Design 0046 §3.1: "the
/// badge must not be the only way out — FB-53's lesson is precisely that the app
/// stopped trying and the only clue was that the spinner had gone." Tapping it
/// lands on the device's own page, where the full copy and the retry button are.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.badge,
    required this.label,
    this.onTap,
  });

  final ConnectionBadge badge;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (badge) {
      ConnectionBadge.connected => AppColors.good,
      ConnectionBadge.connecting => AppColors.amber,
      ConnectionBadge.notAnswering => AppColors.amber,
      ConnectionBadge.failed => AppColors.danger,
      ConnectionBadge.offline => context.colors.muted,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.chevron_right, size: 11, color: color),
          ],
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: AppColors.danger),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.amber,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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

/// Adapter-off / unauthorized banner (mockup `.warnbox` tone). D.2: when
/// [unauthorized] the message points at the OS Settings (the Bluetooth
/// *permission* was denied — a radio toggle won't help) and exposes a deep-link
/// pill via [onOpenSettings]; otherwise it's the plain "turn on Bluetooth" note.
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
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppColors.amber),
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
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: context.colors.panel2,
                  border: Border.all(color: const Color(0x47F6A821)),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.settings,
                        size: 13, color: AppColors.amber),
                    const SizedBox(width: 6),
                    Text(
                      l10n.navSettings,
                      style:
                          const TextStyle(fontSize: 11, color: AppColors.amber),
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
