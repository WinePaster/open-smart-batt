/// OpenSmartBatt — one device's page (design 0046 P1, R21).
///
/// Everything about ONE unit, and the only place controls live (design 0046 R4,
/// inheriting design 0034 §6): connected, this is the dashboard — the same
/// [DashboardPage] the app used to open on, watchface and protection card
/// included. Not connected, it is the FULL failure report: the FB-52 stalled
/// copy, the FB-53 give-up copy, the advice card and its retry button.
///
/// 🔑 That second half is why this page exists at all. Design 0046 R21 moved the
/// per-device status onto the list as ONE WORD, and a one-word status with
/// nowhere to go is FB-53 rebuilt — "the app stopped trying and the only clue
/// was that the spinner had gone". The words come from
/// `connection_failure.dart`, which is the SAME source the dashboard's own
/// disconnected state reads, so the two screens cannot drift into disagreeing
/// about what one error code means.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/dashboard_page.dart';
import '../history/device_history_section.dart';
import '../widgets/one_screen_report.dart';
import 'connection_failure.dart';
import 'save_device_flow.dart';

/// May FB-75's automatic connect resolve [savedId] to something we can see?
///
/// A top-level function, and a pure one, because the platform is the whole
/// question: on the host that runs the tests `Platform.isIOS` is false, so a
/// method that read it directly would make the iOS branch — the only branch
/// with a failure mode — the one branch no test could reach.
///
/// [useNameKey] is `Platform.isIOS` at the call site, and carries the same
/// meaning it has in [rebindSavedDeviceId]: iOS hands out a per-install NSUUID
/// that has to be matched against live scan results, Android keeps a stable MAC
/// that needs no resolving at all.
@visibleForTesting
bool autoConnectTargetVisible({
  required bool useNameKey,
  required String savedId,
  required String savedName,
  required Map<String, String> candidates,
}) {
  if (!useNameKey) return true;
  final target = rebindSavedDeviceId(
    savedId: savedId,
    savedName: savedName,
    candidates: candidates,
    useNameKey: true,
  );
  // 🔴 Not "did rebinding return something": it FALLS BACK to the saved id when
  // it cannot resolve, so a bare null-check would pass on exactly the case this
  // guard exists for. The question is whether the id it returned belongs to a
  // unit that is in front of us right now.
  return candidates.containsKey(target);
}

/// The per-device page, pushed from the devices tab.
///
/// 🔴 Stateful for ONE reason (design 0046 Step 8c): it has to tell
/// [GpsSpeedController] that it is on screen. The GNSS gate's condition 3 is
/// "a surface that can carry a speed card is visible", and before design 0046
/// the only such surface was a TAB, which the shell could report. This page is
/// a PUSHED ROUTE — while it is up, the shell's tab is 裝置, so a tab-derived
/// flag would hold the gate shut for exactly as long as the user is looking at
/// the page that shows speed. The card would sit on "waiting for a fix"
/// forever, with no error anywhere, and the user would blame their GPS.
class DeviceDetailPage extends StatefulWidget {
  const DeviceDetailPage({
    super.key,
    required this.deviceId,
    this.fallbackName = '',
    this.onOpenSettings,
  });

  /// 🔴 Which unit the user is LOOKING at — a different question from which
  /// unit is connected, and the line between them is where FB-41/FB-42 filed
  /// one unit's telemetry under another's (fixed only in v0.6.13).
  ///
  /// ⚠️ AMENDED 2026-08-16 (design 0065 §3.8). This used to say the id is "a
  /// pure NAVIGATION parameter" that design 0046 §6 R-3 "forbids letting reach
  /// any data-attribution path: history rows, session numbers and export scope
  /// all key off the CONNECTED device". Two of those three are still exactly
  /// true; the sentence around them was too wide, and read literally it now
  /// forbids things this page is required to do. The precise rule:
  ///
  ///  * **WRITING / ATTRIBUTION keys off the CONNECTED unit, always.** The
  ///    `history.device_id` column and session numbers come from
  ///    [SessionContext], which only a link can begin. Nothing on this page
  ///    may write a row against the unit merely being looked at — that IS
  ///    R-3, and it is unchanged.
  ///  * **READING SCOPE keys off THIS id, and must.** Which unit's stored rows
  ///    to query, and which unit an export taken from this page covers, are
  ///    questions about the page, not about the link. Design 0022/0043 already
  ///    scope reads this way; design 0065 §0.6 rules that an export started
  ///    here covers this unit 「不管是不是連線他」.
  final String deviceId;

  /// The advertised name, for a device with no saved record (design 0055 §4.2).
  ///
  /// 🔴 Passed IN rather than looked up. This page's own `didChangeDependencies`
  /// is downstream of the list stopping the scan (W-3), so by the time it could
  /// read `scanResults` the entry it needs may be gone — and for an unsaved unit
  /// the advertised name is the only human-readable thing there is. Looking it
  /// up here would work in a test, where the scan stream is whatever the test
  /// last pushed, and fail on a phone.
  final String fallbackName;

  /// Handed on to [DashboardPage] for its stale-telemetry banner. See
  /// [DevicesPage.onOpenSettings] for why it is threaded rather than derived.
  final VoidCallback? onOpenSettings;

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  /// Captured rather than read in [dispose]: by then this element is detached
  /// and `context.read` is no longer legal.
  GpsSpeedController? _gps;

  /// Same capture, same reason — this page is gate condition 3's pushed-route
  /// half for BOTH streams (design 0042 §3.4, design 0045 §3.5).
  GForceController? _gforce;

  /// Third listener of the same signal (W-3, ruled 2026-08-12): the BLE scan.
  ///
  /// It used to be told by whoever pushed this page, which worked only while
  /// the devices list was the only thing that could. See
  /// [ConnectionController.setDetailVisible].
  ConnectionController? _conn;

  /// One-shot latch for [_maybeAutoConnect] (FB-75). At most one automatic
  /// attempt per page instance — [didChangeDependencies] re-runs whenever an
  /// inherited widget changes, and a page that re-fired on every locale change
  /// or theme rebuild would be a connect loop, not a convenience.
  bool _autoConnectTried = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gps = context.read<GpsSpeedController>();
    _gforce = context.read<GForceController>();
    _conn = context.read<ConnectionController>();
    _setVisible(true);
    _maybeAutoConnect();
  }

  /// Open a SAVED unit's page ⇒ connect to it, once (FB-75, ruled 2026-08-14).
  ///
  /// 🔑 This is a NEW feature, not a repair. Nothing in this app has ever
  /// auto-connected: every `connect()` / `connectToSaved()` caller was a user
  /// tap, and the setting labelled 「自動重連」 only ever entered AFTER a link
  /// dropped (it needs `_desiredDeviceId`, which only `connect()` writes). A
  /// dealer read the label as "it should connect by itself", opened a saved
  /// unit's page, and reasonably asked why nothing happened.
  ///
  /// ⛔ It stays a one-shot with a hard gate list because the failure modes are
  /// all worse than the inconvenience it removes:
  ///
  ///   * the service is SINGLE-CONNECTION (`BleService._links` holds 0 or 1,
  ///     and `connect()` awaits `disconnect()` first) ⇒ auto-connecting from
  ///     B's page would silently tear down A's live link. Hence `isOnline`;
  ///   * two connects 1.9 s apart once ran GATT setup twice on one link and
  ///     doubled 18 minutes of telemetry (`ble_service.dart`, 2026.08.13/001)
  ///     ⇒ hence the latch plus `isBusy` / `isRetrying` / `isAutoConnectArmed`;
  ///   * a unit that cannot finish setup (FB-50: 42.4 % of connections in one
  ///     capture never reached `ready`) would otherwise get a fresh doomed
  ///     attempt every time its page is opened ⇒ hence `isSetupStalled`;
  ///   * `lastError != null` means the user is looking at a failure report with
  ///     a retry button on it. Retrying it for them, without being asked, is
  ///     how a page starts arguing with the person reading it.
  void _maybeAutoConnect() {
    if (_autoConnectTried) return;
    final conn = _conn;
    if (conn == null) return;

    // Saved units only: there is no "the device you asked for" for a unit
    // nobody has named, and design 0055 gives unsaved ones an explicit
    // connect-then-name flow that must stay user-driven.
    final saved = context.read<DeviceController>().deviceFor(widget.deviceId);
    if (saved == null) return;
    // The user turned automatic connection off. That the setting is named for
    // RE-connection is exactly the confusion this feature came from, so it is
    // read as the one switch that governs "the app may connect on its own".
    if (!context.read<SettingsController>().autoReconnect) return;
    if (conn.isOnline ||
        conn.isBusy ||
        conn.isRetrying ||
        conn.isAutoConnectArmed) {
      return;
    }
    if (conn.lastError != null) return;
    if (conn.isSetupStalled) return;
    if (!conn.isAdapterOn) return;
    if (!_resolvableOnThisPlatform(conn, saved)) return;

    _autoConnectTried = true;
    // Post-frame for `_setVisible`'s reason: this notifies listeners, and
    // `didChangeDependencies` runs inside the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(conn.connectToSaved(saved).catchError((Object _) {}));
    });
  }

  /// 🔴 The iOS half of FB-75, and the reason this feature is not simply "call
  /// connect on open".
  ///
  /// Opening this page STOPS the scan ([ConnectionController.setDetailVisible],
  /// W-3), while iOS identifies peripherals by a per-install NSUUID that has to
  /// be re-bound against live scan results ([rebindSavedDeviceId]). Come in from
  /// a home tile rather than from the devices list and that candidate set can be
  /// empty — so an unconditional auto-connect would replace today's honest
  /// "not connected + a button" with a spinner that ends in
  /// `device_unreachable`. That is precisely the direction FB-52 and FB-53 were
  /// fixed away from, and it would be a regression bought with a convenience.
  ///
  /// Android keeps a stable MAC, so there is nothing to resolve there.
  bool _resolvableOnThisPlatform(ConnectionController conn, SavedDevice saved) =>
      autoConnectTargetVisible(
        useNameKey: Platform.isIOS,
        savedId: saved.id,
        savedName: saved.name,
        candidates: {for (final r in conn.scanResults) r.id: r.name},
      );

  @override
  void dispose() {
    _setVisible(false);
    super.dispose();
  }

  /// Deferred to the end of the frame for `SpeedCard`'s reason: the setter
  /// notifies listeners, and both call sites run inside the build/teardown
  /// phase, where notifying would mark widgets dirty while they are being
  /// built. Post-frame callbacks fire in registration order, so a page that
  /// unmounts and remounts within one frame still ends on the right value.
  void _setVisible(bool v) {
    final gps = _gps;
    final gforce = _gforce;
    final conn = _conn;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gps?.setDetailVisible(v);
      gforce?.setDetailVisible(v);
      conn?.setDetailVisible(v);
    });
  }

  /// Connect an unsaved unit and then ask for its name (design 0055 §4.4).
  ///
  /// Lives on the State rather than in `_OfflineBody` for one reason: the
  /// connect it awaits is what replaces `_OfflineBody` with the dashboard. This
  /// element survives that swap; that one does not.
  Future<void> _connectAndName() async {
    final conn = context.read<ConnectionController>();
    try {
      await conn.connect(widget.deviceId);
    } catch (_) {
      return; // the controller recorded the reason; the page rebuilds on it
    }
    // A refused connect RETURNS rather than throws (bluetooth_off and friends
    // are answers, not exceptions) — so the error is checked, not just caught.
    if (!mounted || conn.lastError != null) return;
    await promptAndSaveDevice(context, widget.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    final deviceId = widget.deviceId;
    final devices = context.watch<DeviceController>();
    final conn = context.watch<ConnectionController>();
    final saved = devices.deviceFor(deviceId);
    final l10n = AppLocalizations.of(context);
    // 🔴 Ruled 2026-08-11 (design 0055 §4.2): NOT `devicesUnnamed`. This used to
    // read the alias of a saved record that, for an unsaved unit, does not
    // exist — so every nearby device was titled 未命名裝置, which names nothing
    // in a room that may hold six of them. Advertised name, else the id.
    final title = (saved?.alias.isNotEmpty ?? false)
        ? saved!.alias
        : unsavedDeviceTitle(id: deviceId, advertisedName: widget.fallbackName);

    // "This unit's live page" is `online AND it is this unit`. Reading only
    // `isOnline` would draw another device's telemetry under this one's name —
    // the same class of mistake as FB-41's session attribution.
    final live = conn.isOnline && conn.connectedDeviceId == deviceId;

    // The second line, best-first (design 0055 §4.2 / §7 Q2):
    //
    //   1. the unit's OWN MAC, once 0x38 has said it on THIS link — the only
    //      identifier that is the same string on both platforms, and on iOS the
    //      only real MAC obtainable at all;
    //   2. otherwise the platform id, abbreviated;
    //   3. …unless the title already IS that id, in which case repeating it
    //      says nothing and we say why there was nothing better instead.
    //
    // 🔴 `live` gates the MAC — it is the CONNECTED unit's address, and this
    // page can be open on a unit that is not the connected one.
    final wireMac = live ? conn.liveMac : null;
    final subtitle = wireMac != null && wireMac.isNotEmpty
        ? wireMac
        : (title == deviceId || title == shortDeviceId(deviceId)
              ? l10n.devicesNoAdvertisedName
              : shortDeviceId(deviceId));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
                height: 1.25,
              ),
            ),
            // The second line is what makes two units of the same model
            // distinguishable at all — they ship with identical advertised
            // names (a 2026-07-29 field capture: two power banks both
            // 'RCE_RSPB-01'), so the title alone cannot say which one this is.
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono(context).copyWith(
                fontSize: 10.5,
                color: context.colors.muted,
                height: 1.3,
              ),
            ),
          ],
        ),
        // 🔴 NO ICON ACTIONS. The 錶盤 button that design 0046 R20 put here was
        // removed on 2026-08-09 (design 0051, 「同意拿掉入口」) together with
        // `watchface_sheet.dart` and the Settings signpost. There is one
        // dashboard layout now, so there is nothing on this page to configure —
        // and an app bar action that opened a picker with one option would have
        // been worse than none. The evidence for "one option" is the corpus:
        // 11/11 usable captures carried `face=standard`.
        //
        // ⚠️ AMENDED 2026-08-13 — the rule above was written as "NO ACTIONS",
        // and one action is back. The amendment is deliberate and narrow:
        //
        //   * The rule's own reasons were (a) design 0046 §4.7, which bars
        //     "controls that only explain themselves after the fact", and
        //     (b) "there is nothing on this page to configure". A TEXT button
        //     is not (a) — it says what it does before you press it, which is
        //     the same distinction `_UnsavedNotice` below is built on ("A
        //     SENTENCE with a button, not an AppBar icon"). And (b) stopped
        //     being true: the page's TITLE is the thing this edits.
        //   * The report that forced it (2026-08-13):「目前如果要更改名稱，刪除
        //     再重新設定！請問是否可以直接更改名稱？」— a user who reached for
        //     DELETE-AND-RE-ADD because renaming looked impossible. Every home
        //     tile lands here (`home_tiles.dart`), and until today this page had
        //     no route to a rename at all.
        //   * The alternative considered and rejected: a `_UnsavedNotice`-shaped
        //     banner. It would be honest, but for a SAVED unit it is permanent —
        //     a strip of chrome above the dashboard for the whole life of the
        //     device, to host something used twice a year. A word in the bar
        //     costs no vertical space.
        //
        // Guarded on `saved != null`: there is no alias to change on a unit with
        // no record, and that case already has its own sentence-with-a-button.
        actions: [
          if (saved != null)
            TextButton(
              onPressed: () => unawaited(
                promptAndRenameDevice(
                  context,
                  deviceId: deviceId,
                  currentAlias: saved.alias,
                ),
              ),
              child: Text(
                l10n.devicesAliasRenameTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: context.colors.muted,
                ),
              ),
            ),
        ],
      ),
      body: live
          ? (saved == null
                ? Column(
                    children: [
                      _UnsavedNotice(deviceId: deviceId),
                      Expanded(
                        child: DashboardPage(
                          deviceId: deviceId,
                          onOpenSettings: widget.onOpenSettings,
                        ),
                      ),
                    ],
                  )
                : DashboardPage(
                    deviceId: deviceId,
                    onOpenSettings: widget.onOpenSettings,
                  ))
          : _OfflineBody(
              deviceId: deviceId,
              fallbackName: widget.fallbackName,
              onConnectUnsaved: _connectAndName,
            ),
    );
  }
}

/// "This one is not saved", and the way to change that (design 0055 §4.4).
///
/// 🔴 A SENTENCE with a button, not an AppBar icon. An icon cannot say what it
/// does before you press it, and design 0046 §4.7 exists to keep controls that
/// only explain themselves after the fact off these screens.
///
/// It also closes a hole that predates design 0055: cancel the alias prompt
/// after a connect and the unit stays connected but unsaved FOREVER, with no
/// route back to naming it short of disconnecting and reconnecting. That state
/// was unreachable-by-design when the only entrance was the connect itself; it
/// is ordinary now, so it gets a way out.
class _UnsavedNotice extends StatelessWidget {
  const _UnsavedNotice({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(15, 10, 15, 1),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        // Was `const Color(0x12F6A821)` / `0x73F6A821` — amber spelled out in
        // hex, which no search for `AppColors.` would ever have found. The
        // FRAME is a fixed warning tone (design 0064); the Save button inside
        // it is the app's ordinary filled action and keeps the accent. Alphas
        // as the original bytes over 255 so "the value did not change" is
        // arithmetic rather than trust.
        color: AppSemantics.warn.withValues(alpha: 0x12 / 255),
        border:
            Border.all(color: AppSemantics.warn.withValues(alpha: 0x73 / 255)),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.devicesUnsavedTitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                    color: context.colors.text,
                  ),
                ),
                Text(
                  l10n.devicesUnsavedBody,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.5,
                    color: context.colors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            onTap: () => unawaited(promptAndSaveDevice(context, deviceId)),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: context.accent.accent,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Text(
                l10n.devicesSave,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: context.accent.onAccent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The full report for a unit that is not (or not yet) live.
///
/// Layout mirrors the dashboard's own disconnected state on purpose — same
/// glyph, same title/body sizes, same advice card — because they render the same
/// facts and a second visual language for one state is how two screens start
/// disagreeing.
class _OfflineBody extends StatelessWidget {
  const _OfflineBody({
    required this.deviceId,
    required this.onConnectUnsaved,
    this.fallbackName = '',
  });

  final String deviceId;
  final String fallbackName;

  /// Connect a unit with no saved record, then ask for its name — owned by the
  /// page's State because a successful connect unmounts this widget. See
  /// [retry] below.
  final VoidCallback onConnectUnsaved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conn = context.watch<ConnectionController>();
    final devices = context.watch<DeviceController>();

    // One flag for "the app is working on it", covering both halves of the
    // cycle: the attempt itself (isBusy) and the backoff wait before the next
    // one (isRetrying). Either alone leaves a visible hole.
    final retrying = conn.isRetrying;
    final working = conn.isBusy || retrying;

    // The controller's error/stall state belongs to whichever unit it last
    // worked on. Attributing it to a row the user merely opened would put
    // another device's failure under this one's name, so the copy falls back to
    // the plain idle state unless this IS that unit.
    final mine = conn.connectedDeviceId == deviceId;
    final copy = connectionFailureCopy(
      l10n: l10n,
      lastError: mine ? conn.lastError : null,
      working: mine && working,
      isBusy: mine && conn.isBusy,
      isRetrying: mine && retrying,
      autoConnectArmed: mine && conn.isAutoConnectArmed,
      setupStalled: mine && conn.isSetupStalled,
      setupFailures: conn.setupFailures,
      reconnectAttempts: conn.reconnectAttempts,
    );

    final saved = devices.deviceFor(deviceId);

    void retry() {
      // `connectToSaved` rather than a bare `connect`: it carries the routing
      // seed, which is the difference between coming back to the same layout
      // and coming back to an unclassified one. The future is absorbed for
      // FB-44's reason — the controller has already recorded the reason in
      // `lastError`, and this widget rebuilds on it.
      //
      // 🔴 An UNSAVED unit takes the plain `connect` (design 0055 §4.3). Before
      // 0055 this method opened with `if (saved == null) return;` and the button
      // below disabled itself on the same condition — which was consistent right
      // up until unsaved units could reach this page at all, and then it was
      // just a page whose one action was greyed out with no explanation. There
      // is no routing seed to carry for a unit nobody has named; a first
      // connection never had one either.
      if (saved != null) {
        unawaited(conn.connectToSaved(saved).catchError((Object _) {}));
        return;
      }
      // 🔴 An unsaved unit's connect is followed by the naming prompt (design
      // 0055 §4.4) — and it is run from the PAGE, not from here. A successful
      // connect flips this page to its dashboard, which unmounts this widget;
      // driving the prompt from a context that the connect destroys is how the
      // alias gets typed and then dropped. The page's own State outlives the
      // switch, so it owns the sequence.
      onConnectUnsaved();
    }

    return OneScreenReport(
      // 🔴 OFFLINE IS THE CASE THIS FEATURE EXISTS FOR (design 0065 Q4). The
      // dealer who asked for it wants a unit's history precisely when the unit
      // is not in front of him — the car is elsewhere, the battery is out, the
      // link will not come up. A history block that appeared only on a working
      // connection would not have answered his report at all.
      //
      // It goes UNDER the failure report, not into it: the report keeps its
      // full screen and its centring (see [OneScreenReport]), so this is
      // something the user scrolls to rather than something competing with the
      // reason they cannot connect.
      //
      // `live: false` — by definition here, which is what withholds the wire
      // thresholds from the warning classification. See
      // [DeviceHistorySection.live].
      below: DeviceHistorySection(deviceId: deviceId, live: false),
      report: [
        ConnectionPulseIcon(working: mine && working),
        const SizedBox(height: 24),
        Text(
          copy.title,
          textAlign: TextAlign.center,
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
            copy.body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.7,
              color: context.colors.muted,
            ),
          ),
        ),
        const SizedBox(height: 26),
        if (copy.hasAdvice) ...[
          ConnectionAdviceCard(
            hint: copy.adviceHint!,
            retryLabel: l10n.disconnectedStalledRetry,
            onRetry: retry,
          ),
          const SizedBox(height: 26),
        ],
        // The plain way back onto the link when nothing has failed yet.
        // Present in EVERY state, advice card or not: this page is
        // reached from a list whose whole purpose is picking a unit to
        // watch, so "connect" must never require reading a paragraph
        // first.
        if (!copy.hasAdvice)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (mine && working) ? null : retry,
                icon: const Icon(Icons.bluetooth, size: 16),
                label: Text(l10n.devicesConnect),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
