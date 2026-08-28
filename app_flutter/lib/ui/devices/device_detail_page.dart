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

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../alerts/alert_event_banner.dart';
import '../alerts/alert_settings_page.dart';
import '../dashboard/dashboard_page.dart';
import '../history/device_history_tab.dart';
import '../widgets/one_screen_report.dart';
import 'connection_failure.dart';
import 'save_device_flow.dart';

/// Why FB-75's automatic connect did not fire, or null when nothing blocks it.
///
/// 🔴 FB-82. This exists because the feature used to fail SILENTLY: the owner
/// reported on v0.7.22 that opening a saved unit's page did not connect, and
/// nothing — not the screen, not the diagnostic log — could say which of the
/// gates below had refused. The report was answerable only by reading source
/// and guessing at a platform, which is the state this function ends.
///
/// 🔴 THE TENTH GATE IS GONE (FB-82 Q2, ruled 2026-08-17). It asked whether the
/// saved unit was in the CURRENT scan results, and on iOS it was the gate that
/// blocked the owner's report: opening this page stops the scan, so a page
/// entered before the list had discovered anything could never connect on that
/// trip. Three findings retired it, and all three are worth keeping written
/// down because the gate was added deliberately:
///
///   * the RETRY BUTTON on this very screen — and the connect button on the
///     saved list (`devices_page._connectSaved`) — never had this gate. Automatic
///     connection was refusing on a ground the button beside it ignores;
///   * a scan is not what iOS needs to connect. `flutter_blue_plus_darwin`
///     resolves a remoteId through `retrievePeripheralsWithIdentifiers`
///     (`FlutterBluePlusPlugin.m`, "check the devices iOS knowns about"), so a
///     still-valid NSUUID connects with nothing scanned at all — which is how
///     this app's own cold-start adoption and reconnect ladder already work;
///   * the feared FB-52/FB-53 regression — a spinner that ends in
///     `device_unreachable` — is bounded on both ends now. An id iOS no longer
///     knows fails IMMEDIATELY ("Peripheral not found"), and a failed FIRST
///     connect starts no ladder (FB-53: the ladder needs `reachedConnected` or
///     a prior attempt), so the worst case is one connect timeout ending in the
///     same honest failure card a user tap would have produced.
///
/// ⚠️ What did NOT move: refusing to guess between two units advertising the
/// same name. That safety never lived here — it is [rebindSavedDeviceId]'s
/// unique-match rule, and `connectToSaved` still applies it, so an ambiguous
/// name still falls back to the saved id rather than filing one power bank's
/// telemetry under the other's alias.
///
/// The gate ORDER is behaviour, not presentation: it is the order
/// [_DeviceDetailPageState._maybeAutoConnect] applied before this function
/// existed, and the first match is what gets reported. Reordering it would
/// change which reason a given phone logs.
///
/// The busy/retrying/armed trio, which used to share one `if`, is split into
/// three answers on purpose — "the link is busy" and "an iOS hand-off is still
/// outstanding" send whoever reads the log to different places.
///
/// Top-level and pure so that a unit test can state each gate directly: the
/// page reaches it from `didChangeDependencies`, where only a widget test with
/// a whole provider tree can arrive.
@visibleForTesting
String? autoConnectBlocker({
  required bool isSaved,
  required bool autoReconnect,
  required bool isOnline,
  required bool isBusy,
  required bool isRetrying,
  required bool isAutoConnectArmed,
  // 🔴 THIS UNIT'S error, and the only value the app can now supply is one:
  // [ConnectionController.lastErrorFor] is the sole per-unit reader and it will
  // not answer without an id. FB-86 is what this parameter's caller got wrong
  // for as long as the controller had a bare `lastError` getter to pass in.
  required String? lastError,
  // 🔴 THIS UNIT'S stall, on the same terms and for the same reason
  // ([ConnectionController.isSetupStalledFor]). It was the line the first half
  // of FB-86 left behind: `lastError` was scoped, this was not, and one global
  // input is all it takes for the gate to refuse on another unit's account.
  required bool isSetupStalled,
  required bool isAdapterOn,
}) {
  if (!isSaved) return 'device not saved';
  if (!autoReconnect) return 'auto-connect setting off';
  if (isOnline) return 'already online';
  if (isBusy) return 'link busy';
  if (isRetrying) return 'reconnect already pending';
  if (isAutoConnectArmed) return 'autoconnect hand-off armed';
  // The CODE travels, not just the word: `bluetooth_off` and `device_stale`
  // send a reader to different places, and this line is often the only record
  // that the page saw an error at all.
  if (lastError != null) return 'last error not cleared: $lastError';
  if (isSetupStalled) return 'setup stalled';
  if (!isAdapterOn) return 'bluetooth adapter not on';
  return null;
}

/// The two refusals that are also said ON SCREEN (FB-82 Q4, ruled 2026-08-17).
///
/// 🔴 Seven of the nine gates stay SILENT, and that is the ruling, not an
/// omission. `already online` / `link busy` / `reconnect already pending` /
/// `autoconnect hand-off armed` describe a screen that is visibly already doing
/// something; `device not saved` is design 0055's deliberate manual flow;
/// `bluetooth adapter not on` has its own prompt already. `auto-connect setting
/// off` was left blank ON PURPOSE — whether to remind someone of a switch they
/// themselves turned off is a product judgement, and the ruling reserved it as
/// its own future line rather than letting it ride in on this one.
///
/// ⚠️ What these two say is NOT "why the connection failed" — the screen has
/// already answered that. When either fires, [connectionFailureCopy] is already
/// drawing a specific card: the stalled title with "close the app fully and
/// reopen it", or the give-up card branched on the error code. The gap is
/// narrower and it is about THIS VISIT: the user opened the page expecting
/// FB-75's automatic connect, and because the PREVIOUS attempt's `lastError` or
/// stall latch was never cleared, no attempt was made at all. What they are
/// looking at is an OLD failure, with nothing anywhere saying so.
///
/// Keyed off [autoConnectBlocker]'s own answer rather than re-deriving the gate
/// state, so the screen and the diagnostic log can never disagree about which
/// gate refused. `A26` pins every gate against this mapping for that reason.
@visibleForTesting
enum AutoConnectSkipNotice {
  /// `last error not cleared: <code>` — the code itself is deliberately NOT
  /// repeated to the user. It is already in the card above, branched into an
  /// instruction; a bare `device_unreachable` under it would be the same fact
  /// twice, once in a form nobody can act on.
  lastError,

  /// `setup stalled`.
  setupStalled,
}

/// Which on-screen notice, if any, one [autoConnectBlocker] answer earns.
///
/// Top-level and pure for [autoConnectBlocker]'s reason: the page reaches it
/// from `didChangeDependencies`, and a unit test can state the gate directly.
@visibleForTesting
AutoConnectSkipNotice? autoConnectSkipNotice(String? blocker) {
  if (blocker == null) return null;
  // A PREFIX, because that gate carries the error code with it ("last error not
  // cleared: device_stale") and the code is the part that varies.
  if (blocker.startsWith('last error not cleared')) {
    return AutoConnectSkipNotice.lastError;
  }
  if (blocker == 'setup stalled') return AutoConnectSkipNotice.setupStalled;
  return null;
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

  /// Which sub-tab is showing — 0 live, 1 history (design 0079 Q1).
  ///
  /// 🔴 **Page state, not route state.** Leaving the page and coming back
  /// starts on `live` again, deliberately: the tab is a view of one unit, not a
  /// preference about units in general, and a page that reopened on whichever
  /// tab was last used somewhere else would make the same tap land in two
  /// different places.
  int _tabIndex = 0;

  /// Set the first time [_tabIndex] reaches 1, and never cleared.
  ///
  /// 🔴 **T-1: nothing is queried until the tab is opened.** This is the single
  /// largest thing design 0079 buys, and it is the reason the page does not use
  /// a `TabBarView` — that widget builds the neighbouring page to support the
  /// swipe, which would run the history queries for every user who never asked
  /// for them. Today's block queries on EVERY detail-page open, for every unit,
  /// offline ones included.
  bool _historyMounted = false;

  /// Incremented on each switch INTO the history tab — design 0079 T-3.
  ///
  /// Handed to [DeviceHistoryTab.activationEpoch], where it forces a re-query
  /// past the P-4 cache. That is FB-84's fix: "opening it does not refresh it"
  /// becomes false when opening it is an event that can be observed.
  int _historyEpoch = 0;

  /// How many rows this unit has, over ALL time — the number on the history
  /// tab's label (design 0079 Q3).
  ///
  /// 🔴 **`null` means UNKNOWN and renders NOTHING.** Zero means "this unit has
  /// never recorded anything" and renders `0`. They are different facts and the
  /// label must not conflate them: a `0` shown while the count is still in
  /// flight would tell the user the history is empty, and they would believe it
  /// and not look.
  int? _historyCount;

  /// One-shot latch for [_loadHistoryCount] — [didChangeDependencies] re-runs
  /// on every inherited change, and this is a database query.
  bool _historyCountAsked = false;

  /// One-shot latch for [_maybeAutoConnect] (FB-75). At most one automatic
  /// attempt per page instance — [didChangeDependencies] re-runs whenever an
  /// inherited widget changes, and a page that re-fired on every locale change
  /// or theme rebuild would be a connect loop, not a convenience.
  bool _autoConnectTried = false;

  /// Which skip reasons this page instance has already written (FB-82).
  ///
  /// 🔴 Not a counter and not "log every time": [didChangeDependencies] re-runs
  /// on every notification from the two controllers this page watches, so an
  /// unguarded line would write the same sentence tens of times per visit and
  /// bury the one that matters. At most one line per DISTINCT reason keeps the
  /// output bounded by the gate list (ten), while still recording a gate that
  /// only starts blocking part-way through the visit.
  final Set<String> _loggedSkips = <String>{};

  /// The refusal this visit has to SAY, or null (FB-82 Q4). See
  /// [AutoConnectSkipNotice] for why only two of the nine qualify.
  ///
  /// Recomputed on every [_maybeAutoConnect], not latched: the whole claim is
  /// "no automatic attempt was made on this visit", and the moment the gate
  /// clears and the attempt fires, that sentence stops being true. Assigning it
  /// from `didChangeDependencies` needs no `setState` — a build always follows.
  AutoConnectSkipNotice? _skipNotice;

  /// Whether ANY connection attempt has been seen while this page instance was
  /// up — ours, or the user's own press of the retry button.
  ///
  /// 🔴 It exists to stop the notice from coming BACK. A manual retry clears
  /// `lastError`, so the gate opens, and if that retry then fails the gate
  /// closes again — at which point "this visit made no automatic attempt" is
  /// still literally true and completely wrong to show: the user pressed a
  /// button and is looking at its result. Telling them nothing was tried reads
  /// as the screen denying what they just did.
  bool _attemptSeen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gps = context.read<GpsSpeedController>();
    _gforce = context.read<GForceController>();
    _conn = context.read<ConnectionController>();
    _setVisible(true);
    _maybeAutoConnect();
    _loadHistoryCount();
  }

  /// The one query this page makes without being asked (design 0079 Q3).
  ///
  /// 🔴 **It is a COUNT, and that distinction is the whole justification.**
  /// Until 2026-08-21 opening any detail page ran THREE queries including one
  /// that pulled a thousand minute windows (design 0079 S0). This is one
  /// aggregate over `idx_history_device_ts`. The page went from three-with-a-
  /// thousand-rows to one COUNT — the badge is not a new cost, it is what is
  /// left after removing a much larger one.
  ///
  /// 🔴 **Range `all`, not the range the tab will open on.** The label has to
  /// be truthful before the tab exists, and "does this unit have records" is
  /// not a question about today. A count that said `0` because nothing was
  /// recorded since midnight would be the exact misreading this badge exists to
  /// prevent — it is here to answer design 0065 §4's objection to the cheap
  /// fix: 「他得先跳過去才知道是空的」.
  ///
  /// ⚠️ **Read once, on arrival, and never refreshed.** Sit on this page while
  /// the unit records and the number stays as it was. That is a deliberate
  /// floor, not an oversight: it answers "is there anything in there", a
  /// question whose answer does not change on the timescale of a page visit.
  /// The tab's own contents ARE refreshed on every arrival (T-3).
  void _loadHistoryCount() {
    if (_historyCountAsked) return;
    _historyCountAsked = true;
    final tele = context.read<TelemetryController>();
    unawaited(
      tele.historyStats(since: null, deviceId: widget.deviceId).then((stats) {
        if (!mounted) return;
        setState(() => _historyCount = stats.count);
      }).catchError((Object _) {
        // 🔴 Swallowed, and the count stays null ⇒ the label stays bare. A
        // failed count is UNKNOWN, and the one thing it must not become is a
        // confident `0`. Nothing else on this page depends on it.
      }),
    );
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
  ///     attempt every time its page is opened ⇒ hence `isSetupStalledFor`;
  ///   * `lastError != null` means the user is looking at a failure report with
  ///     a retry button on it. Retrying it for them, without being asked, is
  ///     how a page starts arguing with the person reading it.
  ///
  /// 🔴 FB-82 Q2 (ruled 2026-08-17): what it does NOT gate on any more is
  /// whether the unit is in the current scan results. That gate is the one that
  /// blocked the owner's own report on an iPhone, and it made this feature
  /// stricter than the retry button beside it. See [autoConnectBlocker] for the
  /// three findings that retired it. The rule this leaves is simple and is the
  /// ruling itself: **automatic connection does exactly what a user tap does**
  /// — one attempt, the same `connectToSaved`, the same failure card.
  void _maybeAutoConnect() {
    // Neither of these two is a REFUSAL, so neither is logged: the first says
    // the attempt already happened (whoever wanted the story has `connect → X`
    // to read), the second only occurs before this page has dependencies at all.
    if (_autoConnectTried) return;
    final conn = _conn;
    if (conn == null) return;

    // FB-82 Q4: an attempt is under way, or was. See [_attemptSeen] — this is
    // read before the gates because `isBusy` is itself one of them, and the
    // answer wanted here is "something is being tried", not "which gate won".
    if (conn.isBusy || conn.isRetrying) _attemptSeen = true;

    // Saved units only: there is no "the device you asked for" for a unit
    // nobody has named, and design 0055 gives unsaved ones an explicit
    // connect-then-name flow that must stay user-driven.
    final saved = context.read<DeviceController>().deviceFor(widget.deviceId);
    final blocker = autoConnectBlocker(
      isSaved: saved != null,
      // The user turned automatic connection off. That the setting is named for
      // RE-connection is exactly the confusion this feature came from, so it is
      // read as the one switch that governs "the app may connect on its own".
      autoReconnect: context.read<SettingsController>().autoReconnect,
      isOnline: conn.isOnline,
      isBusy: conn.isBusy,
      isRetrying: conn.isRetrying,
      isAutoConnectArmed: conn.isAutoConnectArmed,
      // 🔴 FB-86, AND THE WHOLE OF IT. This line used to read the controller's
      // single error field with no attribution at all, three hundred lines above
      // an `_OfflineBody` that gated the same field on `mine` — so a failed
      // connect to A blocked THIS page from ever trying B, while B's own failure
      // card was correctly suppressed and the screen said nothing but "not
      // connected". The controller now answers per unit and there is no way to
      // ask it otherwise; see [ConnectionController.lastErrorFor].
      lastError: conn.lastErrorFor(widget.deviceId),
      // 🔴 FB-86, SECOND HALF — and the line that proves the first half was not
      // enough. When `lastError` above was scoped, this one was left global, so
      // A's stall went on doing exactly what A's error had stopped doing:
      // blocking THIS unit's automatic connect while this unit's own stalled
      // card was suppressed. The latch has always known whose run it is
      // (`_setupFailuresDeviceId`); it just could not be asked.
      isSetupStalled: conn.isSetupStalledFor(widget.deviceId),
      isAdapterOn: conn.isAdapterOn,
    );
    if (blocker != null) {
      // FB-82: say so, once per distinct reason. Before this the page simply
      // did nothing, and no export could tell which gate had refused.
      if (_loggedSkips.add(blocker)) {
        conn.noteAutoConnectSkipped(blocker, deviceId: widget.deviceId);
      }
      // FB-82 Q4: and for two of the nine, say it on the SCREEN as well. The
      // log is for whoever reads an export afterwards; this is for the person
      // in front of the phone right now, who was promised an automatic connect.
      //
      // 🔴 STILL NO `mine` GATE — RE-JUDGED TWICE UNDER FB-86 (2026-08-17), and
      // the reason is no longer the one Q4 gave.
      //
      // ⛔ SUPERSEDED, recorded so it is not re-derived: Q4 omitted the gate
      // because "in the cross-device case there is no failure card, so this
      // notice is the only explanation on screen". That premise is GONE. It
      // depended on the card being suppressed while the gate still refused, and
      // both halves of that — `lastError`, then the stall latch — are now scoped
      // to the unit, so the gate no longer refuses on another unit's account at
      // all. An intermediate re-judgement kept the sentence alive for the stall
      // branch alone; that too is now obsolete.
      //
      // 🔑 THE STANDING REASON. Both notices key off [autoConnectBlocker]'s
      // answer, and both of its per-unit inputs are read for THIS page's unit —
      // `lastErrorFor(deviceId)` and `isSetupStalledFor(deviceId)`, the very
      // same two values `_OfflineBody` passes to [connectionFailureCopy]. So
      // whenever either notice fires, the matching card is already on screen BY
      // CONSTRUCTION, rather than because two widgets independently remembered
      // to apply the same rule. Adding `mine` could therefore do only one thing:
      // hide a notice whose card is showing. Two reachable cases where it would:
      //
      //   * a RADIO-level code, which belongs to no unit — `mine` says nothing
      //     about it, and the card renders it whatever the controller's target;
      //   * a stall on a unit the controller no longer targets. `disconnect()`
      //     nulls `_desiredDeviceId`, but the latch is deliberately kept until a
      //     `ready` (it is the unit's fact, not the link's), so the card shows
      //     and `mine` is false.
      //
      // ⇒ no gate, on either branch. A26–A32 are unchanged by this reasoning;
      // A36 pins the second case.
      _skipNotice = _attemptSeen ? null : autoConnectSkipNotice(blocker);
      return;
    }

    _skipNotice = null;
    _attemptSeen = true;
    _autoConnectTried = true;
    // Post-frame for `_setVisible`'s reason: this notifies listeners, and
    // `didChangeDependencies` runs inside the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // `saved!` is safe: a null blocker is only reachable with `isSaved: true`,
      // which is this object being non-null.
      unawaited(conn.connectToSaved(saved!).catchError((Object _) {}));
    });
  }

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
    if (!mounted || conn.lastErrorFor(widget.deviceId) != null) return;
    await promptAndSaveDevice(context, widget.deviceId);
  }

  /// The only writer of [_tabIndex].
  ///
  /// 🔑 Centralised for the reason `main.dart`'s `_setTab` is (commit
  /// `430330e`): two call sites assigning the index directly is how one of them
  /// ends up skipping the bookkeeping beside it — here, the mount latch and the
  /// epoch. There is one caller today; the rule is for the second one.
  void _selectTab(int next) {
    if (next == _tabIndex) return;
    setState(() {
      _tabIndex = next;
      if (next == 1) {
        _historyMounted = true;
        _historyEpoch++;
      }
    });
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
        // 🔴 Design 0079 Q2 — AppBar's `bottom`, 40 dp, and that costs the live
        // readings a whole row. Design 0065 §4 rejected this layout for that
        // very reason and the reason was never refuted; it was outweighed. What
        // was NOT accepted is the 34 dp version that would have saved 6 px: the
        // tap target shrinks with it, and FB-70 has just finished paying for a
        // control nobody could hit.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kDetailTabBarHeight),
          child: _DetailTabBar(
            index: _tabIndex,
            onChanged: _selectTab,
            historyCount: _historyCount,
          ),
        ),
      ),
      // 🔴 A `Stack` of `Offstage`, not a `TabBarView` and not an `IndexedStack`.
      //
      //  * **Not `TabBarView`**: it builds the neighbouring page for the swipe,
      //    which defeats T-1 (nothing queried until the tab is opened) — and
      //    the swipe itself is refused on its own grounds, see [_DetailTabBar].
      //  * **Not `IndexedStack`**: it lays out every child and paints one, so
      //    the dashboard would go on being measured at telemetry rate behind
      //    the history tab. `Offstage` skips layout AND paint while keeping the
      //    State, which is the combination wanted here.
      //
      // ⚠️ **What `Offstage` does NOT skip is BUILD.** The live half watches
      // `TelemetryController`, so it still rebuilds several times a second
      // while the user reads history — cheaper than today (no layout, no
      // paint), but not free, and NOT MEASURED. See design 0079 §6 R9.
      //
      // `TickerMode` because `Offstage` alone does not stop animations: the
      // offline body's `ConnectionPulseIcon` would keep ticking behind a tab
      // nobody is looking at.
      body: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: _tabIndex != 0,
            child: TickerMode(
              enabled: _tabIndex == 0,
              child: _liveBody(
                live: live,
                saved: saved,
                deviceId: deviceId,
              ),
            ),
          ),
          // T-1: absent from the tree entirely until the tab is first chosen.
          if (_historyMounted)
            Offstage(
              offstage: _tabIndex != 1,
              child: TickerMode(
                enabled: _tabIndex == 1,
                child: DeviceHistoryTab(
                  deviceId: deviceId,
                  live: live,
                  activationEpoch: _historyEpoch,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The live half — design 0065's page body, moved rather than rewritten.
  ///
  /// 🔑 Every branch, every comment and every argument below is what
  /// `build` returned before design 0079; extracting it is what keeps S1
  /// reviewable as "the container changed, the contents did not".
  Widget _liveBody({
    required bool live,
    required SavedDevice? saved,
    required String deviceId,
  }) {
    return live
          ? Column(
              children: [
                // 🔵 design 0080 P3 — the event banner (§5, 「詳情頁事件橫幅」).
                //
                // 🔴 ABOVE the dashboard and OUTSIDE its ListView, and drawn for
                // an unsaved unit exactly as for a saved one (ruling Q3 /
                // §0.2.1). Outside because a raised warning must not be
                // something the user has to scroll to find — the whole premise
                // of design 0080 is that people are not looking at the screen —
                // and one level up from the four dashboard bodies because
                // `pack_view`, `power_bank_view`, `unidentified_view` and
                // `class_pending_view` would otherwise each need their own copy
                // of it. It renders nothing when nothing is raised, which is
                // what makes one placement serve all four.
                //
                // ⚠️ Not in the OFFLINE branch below: with no link there are no
                // frames, the evaluator was cleared on disconnect (§3.3.2), and
                // a banner there could only be re-stating something we stopped
                // observing.
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 3, 15, 0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: AlertEventBanner(deviceId: deviceId),
                    ),
                  ),
                ),
                if (saved == null) _UnsavedNotice(deviceId: deviceId),
                Expanded(
                  child: DashboardPage(
                    deviceId: deviceId,
                    onOpenSettings: widget.onOpenSettings,
                  ),
                ),
              ],
            )
          : _OfflineBody(
              deviceId: deviceId,
              fallbackName: widget.fallbackName,
              onConnectUnsaved: _connectAndName,
              // FB-82 Q4. Passed DOWN rather than re-derived here: whether this
              // visit made an automatic attempt is a fact about the page's own
              // one-shot latch, and nothing in the controller records it.
              skipNotice: _skipNotice,
            );
  }
}

/// Height of the detail page's sub-tab row.
///
/// 🔴 **40, and the 6 px below it are not available.** Design 0079 Q2 weighed a
/// 34 dp row and refused it: the tab is the tap target, and FB-70 is the entry
/// that cost this project a user who deleted and re-added a device because a
/// 14x14 control could not be hit. Material's own minimum is 48; 40 is already
/// the floor this codebase uses for icon buttons (`device_history_section.dart`
/// gives refresh and export `minWidth: 40, minHeight: 40` for the same reason).
const double kDetailTabBarHeight = 40;

/// Live / History, for one device (design 0079 Q1).
///
/// 🔴 **THERE IS NO `TabBarView` BEHIND THIS, AND THAT IS DELIBERATE.** A
/// reviewer who finds a `TabBar` driving an index by hand will reach for the
/// paired widget; do not. Two independent reasons, either sufficient:
///
///  1. **Swipe would fight the chart.** `HistoryTrendCard` reads a horizontal
///     drag to scrub between data points (FB-94 / design 0076), and design 0076
///     §2 already records that a diagonal start is lost to the scrolling host
///     because whichever axis crosses the touch slop first wins the arena. A
///     page-level horizontal drag adds a second competitor for the same gesture
///     — on a control that shipped three days ago and whose feel nobody has
///     tested on a device yet.
///  2. **`TabBarView` builds the neighbour** to make that swipe smooth, which
///     is precisely the query design 0079 exists to stop making.
///
/// ⚠️ Also no [TabController]: it exists to keep a bar and a view in sync, and
/// there is no view. An animation-driven controller here would be a second
/// source of truth for `_tabIndex` with nothing to synchronise.
class _DetailTabBar extends StatelessWidget {
  const _DetailTabBar({
    required this.index,
    required this.onChanged,
    this.historyCount,
  });

  final int index;
  final ValueChanged<int> onChanged;

  /// Rows this unit holds, all time. Null ⇒ unknown ⇒ no badge.
  final int? historyCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.line)),
      ),
      child: SizedBox(
        height: kDetailTabBarHeight,
        child: Row(
          children: [
            _DetailTab(
              label: l10n.deviceDetailTabLive,
              selected: index == 0,
              onTap: () => onChanged(0),
            ),
            _DetailTab(
              label: l10n.deviceDetailTabHistory,
              selected: index == 1,
              onTap: () => onChanged(1),
              count: historyCount,
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailTab extends StatelessWidget {
  const _DetailTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Optional figure rendered beside [label] (design 0079 Q3).
  ///
  /// 🔑 **Why a number and not a dot.** Both were drawn for the owner. A dot
  /// says "something is in there" and then has to be learnt — design 0046 §4.7
  /// bars controls that only explain themselves after the fact. The figure
  /// explains itself, and `0` is the answer to the question the dot cannot
  /// even ask.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final accent = context.accent.accent;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  // The full row is the target; the 2 px rule is the only part
                  // that moves, so an unselected tab still occupies its half of
                  // the bar rather than shrinking to its text.
                  color: selected ? accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Center(
              // A `Row`, not a `Text` with a suffix: the badge keeps its own
              // shape and colour, and a long label ellipsises without eating
              // the figure.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color:
                            selected ? context.colors.text : context.colors.muted,
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    _TabCount(count: count!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The figure on the history tab (design 0079 Q3).
class _TabCount extends StatelessWidget {
  const _TabCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    // 🔴 Grouped for the reader's locale, not `'$count'`. A dealer's unit can
    // hold six figures — `181440` is a fortnight of per-minute rows — and an
    // ungrouped run of digits in a 40 dp bar is a smear, not a number.
    final text = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(count);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          text,
          style: AppTextStyles.mono(context).copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: context.colors.muted,
          ),
        ),
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
    this.skipNotice,
  });

  final String deviceId;
  final String fallbackName;

  /// "This visit made no automatic attempt", when that is worth saying (FB-82
  /// Q4). Null for the other seven gates and whenever an attempt was made.
  final AutoConnectSkipNotice? skipNotice;

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

    // The controller's LINK state belongs to whichever unit it last worked on.
    // Attributing it to a row the user merely opened would put another device's
    // failure under this one's name, so the copy falls back to the plain idle
    // state unless this IS that unit.
    //
    // ⚠️ AMENDED (FB-86): `lastError` and the STALL LATCH are no longer among
    // them. Both used to be gated here by hand — `mine ? conn.lastError : null`
    // and `mine && conn.isSetupStalled` — and those hand-gates, correct as they
    // were, are exactly what the automatic-connect gate above did not copy. The
    // scoping moved into the controller, so these lines ask for this unit's
    // error and this unit's stall and get this unit's.
    //
    // What `mine` still guards is the SINGLE LINK: busy, retrying, armed. Those
    // are not per-unit facts being borrowed — `BleService._links` holds 0 or 1,
    // so there is one connect in flight in the whole app and the only question
    // is whether it is this unit's. They stop being singular the day design 0046
    // 交付二 lands, and not before.
    //
    // 📌 ONE VISIBLE CONSEQUENCE, and it is intended: a RADIO-level code
    // (`bluetooth_off` and friends — [radioLevelErrorCodes]) belongs to no unit
    // and so now reaches this page even when the controller's target is another
    // one. The old hand-gate hid it, which meant a page that was refusing to
    // auto-connect BECAUSE the radio is off — that gate never distinguished
    // either — said only "not connected". Reporting the radio on any unit's page
    // is not FB-41/FB-42's mistake: the radio is not one of the units.
    final mine = conn.connectedDeviceId == deviceId;
    final copy = connectionFailureCopy(
      l10n: l10n,
      lastError: conn.lastErrorFor(deviceId),
      working: mine && working,
      isBusy: mine && conn.isBusy,
      isRetrying: mine && retrying,
      autoConnectArmed: mine && conn.isAutoConnectArmed,
      setupStalled: conn.isSetupStalledFor(deviceId),
      setupFailures: conn.setupFailuresFor(deviceId),
      // design 0087 — scoped, like everything else on this page (FB-86).
      unreachableRun: conn.isUnreachableRunFor(deviceId),
      reachFailures: conn.reachFailuresFor(deviceId),
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
      // 🔴 OFFLINE IS STILL THE CASE THIS FEATURE EXISTS FOR (design 0065 Q4) —
      // the dealer wants a unit's history precisely when the unit is not in
      // front of him. What changed on 2026-08-21 is WHERE it is answered.
      //
      // ~~below: DeviceHistorySection(deviceId: deviceId, live: false)~~
      //
      // Design 0079 S1: the history is a TAB on this page, so an offline unit's
      // records are one tap away instead of a full screen of failure report
      // away. `OneScreenReport.below` is left in place as a parameter — it is
      // that widget's general capability, not something design 0065 invented,
      // and deleting it would cost the next caller a fresh argument about
      // centring — it is simply not passed here any more.
      //
      // 🔵 **2026-08-22 (design 0080 P2): the next caller arrived.** The alert
      // entry is drawn for an OFFLINE unit too, and that is deliberate rather
      // than incidental — thresholds are the one part of this feature that needs
      // no link. Layers ① and ③ (the owner's own numbers, and the class table)
      // are both answerable with the radio off, which is exactly the situation a
      // dealer sets limits in: the battery is on a shelf, not on the phone. Only
      // layer ② is missing, and the screen says so in as many words rather than
      // caching a stale `0x2B` to fill the gap (§7.5.2).
      //
      // ⚠️ Gated on `saved != null`. An unsaved unit that is also offline has
      // nothing to show and nothing to write: `_UnsavedNotice`'s naming button
      // is the only useful control on this screen, and a second row leading to
      // the same prompt would be two answers to one question.
      below: saved == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: AlertSettingsEntry(deviceId: deviceId),
                ),
              ),
            ),
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
        // 🔴 FB-82 Q4 — ADDED TO the report, never in place of it. The gate that
        // produces this notice is the one whose own comment reads "the page is
        // showing a failure report WITH a retry button; pressing it for the user
        // is the page arguing with them", and swapping that report out for this
        // sentence would be doing precisely what the gate exists to avoid. It
        // sits between the failure copy and the way out of it: what happened,
        // then what did NOT happen this time, then the button.
        if (skipNotice != null) ...[
          _AutoConnectSkipNotice(notice: skipNotice!),
          const SizedBox(height: 22),
        ],
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

/// "This visit did not try by itself, and here is why" (FB-82 Q4).
///
/// 🔴 Deliberately QUIETER than everything around it — no accent, no button, no
/// warning frame. It is a footnote to the failure report above it, and the
/// moment it competes with that report for attention it has become the thing
/// FB-75's `lastError` gate was written to prevent (see [autoConnectBlocker]).
/// The one action stays where it already was: the advice card's retry, or the
/// plain connect button, immediately below this.
///
/// Not a SnackBar, for [ConnectionAdviceCard]'s reason — the state it describes
/// lasts as long as the user stays on the page, and a 3.2 s toast shown once is
/// worth nothing to someone still reading at minute two.
class _AutoConnectSkipNotice extends StatelessWidget {
  const _AutoConnectSkipNotice({required this.notice});

  final AutoConnectSkipNotice notice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ConstrainedBox(
      // Same 320 as [ConnectionAdviceCard], which is the widget directly under
      // it in the common case. Two stacked cards of different widths would read
      // as two unrelated things.
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: context.colors.panel2,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.devicesAutoConnectSkippedTitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              // One sentence per gate, and the difference between them is the
              // only part worth reading — the same principle as
              // [connectionFailureCopy]'s "one title, three reasons".
              switch (notice) {
                AutoConnectSkipNotice.lastError =>
                  l10n.devicesAutoConnectSkippedLastError,
                AutoConnectSkipNotice.setupStalled =>
                  l10n.devicesAutoConnectSkippedStalled,
              },
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: context.colors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
