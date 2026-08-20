/// OpenSmartBatt — the devices tab (design 0046 P1, R2 / R21 / R22; design 0055).
///
/// TWO SUB-TABS (design 0055 §4.5, ruled 2026-08-11):
///   * 已儲存 — saved units (editable alias, signal if nearby, a status badge,
///     連線 / 已連線), and
///   * 搜尋裝置 — live vendor-service (07b9fff0) scan results minus anything
///     already saved, sorted by RSSI, with signal bars and the show-all toggle.
///
/// ## Both sub-tabs read ONE scan (design 0055 §4.5)
///
/// The obvious reason to split a page in two is to stop doing the expensive half
/// while the cheap half is on screen, and that is explicitly NOT what this split
/// does. The scan belongs to [ConnectionController], not to a tab, and the saved
/// rows spend it: their signal bars and "is it nearby" all come out of the same
/// `scanResults` the scan tab lists. Switch it off behind the saved tab and the
/// saved rows go blind — so the radio stays on for both, and the power saving a
/// split would have bought is knowingly given up. Ruled 2026-08-11: 「都掃描啊
/// 共用同一個結果就好」.
///
/// W-3 is untouched by any of this: opening a DETAIL page still stops the scan.
///
/// ## Two rules the split cannot be shipped without (design 0055 §7.1)
///
/// A tab is a harder fold than a scroll, and both of these are the same failure —
/// something the user needs, on a surface they have no reason to look at:
///
///   1. **No saved devices ⇒ open on 搜尋裝置.** Otherwise a first run lands on
///      an empty list whose only remedy is on the tab they cannot see. (The
///      single-page version could not have this bug: the empty saved section had
///      the scan directly underneath it.)
///   2. **Naming a device switches to 已儲存.** Otherwise the row VANISHES from
///      the tab the user is looking at — which is, word for word, what a dealer
///      reported on 2026-08-11 as「新儲存的不會顯示」about the single-page build.
///      Shipping the split without this would make that complaint true.
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
/// 🔴 **PARTIALLY OVERTURNED 2026-08-21 — FB-92 / design 0075 (owner's ruling,
/// §8 Q1–Q5). The paragraph above is kept word for word because the harm it
/// describes is still real and still guarded against.** What changed is which
/// of R22's two readings it states. R22's text was "UI 留在裝置頁" and never
/// separated them; the owner picked the NARROW one (Q1): the rule is "do not
/// drop the user onto a screen that cannot show the connect is happening", not
/// "the screen must never move".
///
/// So `_connectSaved` / `_connectNew` now PUSH `DeviceDetailPage` — but only
/// after the link reaches `ready`, only for the unit that came up, and never on
/// a failure (Q3). The three `pop()` calls are still gone and `_disconnect`
/// still navigates nowhere at all. The FB `2026.08.02/004` screen cannot recur
/// through this door: there is no empty state to land in, because we do not
/// leave until there is telemetry to land on.
///
/// ⛔ And the red line that ships with it (design 0075 §3.3, §9): none of this
/// fixes 「連線一樣還是要點兩次」. That report has three independent causes and
/// the heaviest — FB-88, 2 of 6 cross-device switches — is untouched here.
///
/// ## The badge is a door, not a decoration (R21 / T-new-6)
///
/// A row carries ONE WORD of status, because this page is for scanning a list
/// and a paragraph per row turns it into a wall of text. The full report — the
/// FB-52 stalled copy, the FB-53 give-up copy, the advice card and its retry —
/// lives on [DeviceDetailPage], and the badge is what gets you there. It must
/// never be only a colour: FB-53's complaint was precisely that "the app stopped
/// trying, and the only clue was that the spinner had gone".
///
/// ## Every row is a door now (design 0055 §4.1)
///
/// R21's badge rule is intact. What 0055 overturned is the other half — that an
/// unsaved unit had no detail page to be a door TO — so the gesture is now the
/// same on all three kinds of row: **the row body looks at it, the button
/// connects it.** An unsaved row still carries no badge (§4.6: five to ten
/// nearby units each captioned 未連線 is noise, not status), so on those rows the
/// row body carries the whole responsibility the badge carries elsewhere.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../ble/ble.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'connection_failure.dart';
import 'device_detail_page.dart';
import 'save_device_flow.dart';
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

  /// Show the Settings tab, handed down from the shell.
  ///
  /// It is threaded rather than looked up because it must go through the
  /// shell's single `_setTab` entry point: [DeviceDetailPage] hosts the
  /// dashboard, whose stale-telemetry banner links to Settings, and the
  /// 2026-08-07 review found that exact callback writing `_tab` behind the GNSS
  /// gate's back — leaving the receiver running under the Settings page.
  ///
  /// 🔴 "Show", not "switch to": the shell's implementation also LEAVES the
  /// pushed [DeviceDetailPage] this page opens, because switching the tab
  /// underneath a route the user is still looking at is indistinguishable from
  /// the control being dead. Do not replace it with a bare tab switch — see
  /// `main.dart`'s `_openSettingsFromDetail`.
  final VoidCallback? onOpenSettings;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

/// Sub-tab index. Named rather than bare `0` / `1` because two rules in the
/// library comment are stated in terms of WHICH tab, and `animateTo(0)` in the
/// middle of a save flow does not say "go back to the list you just added to".
enum _Tab { saved, scan }

/// What ended a wait for `ready` (FB-92 / design 0075 §6.2, plan B3).
///
/// The wait exists because `await connectToSaved()` returns at T1 — GATT
/// `connected`, 0.54 s after the tap in the wire capture — and the link is not
/// usable until T2 (`ready`, T0+2.01 s; `2026.08.17-001.md` §2.4). Navigating
/// on the `await` would land the user on a detail page that is still drawing
/// `_OfflineBody` for another 1.5–2.0 s, which is design 0075's rejected plan
/// B2 ("two spinners, in two places").
///
/// 🔴 EVERY MEMBER EXCEPT [ready] MEANS "STAY ON THE LIST". They are named
/// apart anyway because they are not the same event to a reader of a log or of
/// this code: [failed] and [stalled] have something to say to the user,
/// [abandoned] and [timedOut] deliberately do not. `ready` is the ONLY value
/// that may reach a `Navigator.push`.
enum _ConnectOutcome {
  /// `isOnline` came up AND it is this unit's link (design 0075 C2).
  ready,

  /// `lastErrorFor(id)` answered (design 0075 C4) — including the radio-level
  /// codes, which answer for every id because they are true of every id.
  failed,

  /// `isSetupStalledFor(id)` latched: three connections that came up and said
  /// nothing (FB-52). This is the case a bare "wait for ready" never returns
  /// from, and C1 exists for it.
  stalled,

  /// The controller stopped working on this unit (it switched target, the user
  /// disconnected / left the tab / started another row's connect, or the
  /// attempt simply died with nobody retrying it). Nothing failed loudly; there
  /// is simply nothing left to wait for. See
  /// [_DevicesPageState._readyOutcomeFor]'s backstop.
  abandoned,

  /// The belt-and-braces cap. See [_DevicesPageState.readyWaitDeadline].
  timedOut,
}

class _DevicesPageState extends State<DevicesPage>
    with SingleTickerProviderStateMixin {
  /// BLE id of the row whose connect is in flight (drives the row spinner).
  ///
  /// 🔴 FB-92 / design 0075 §6.1 MOVED WHERE THIS IS CLEARED, and the move is
  /// the whole of that half of the report. It used to be dropped the moment
  /// `await connectToSaved()` returned — GATT `connected`, ~0.5 s — while the
  /// link needed another 1.5–2.0 s to reach `ready`. For that window the button
  /// had already turned back into a live 連線, i.e. the screen was telling the
  /// user to press it again, and `2026.08.18-008.md` §3.3 mechanism ③ is
  /// exactly that: the dealer pressed again 1.0–1.1 s after `connected` and
  /// killed the link that was forming (one episode took four taps).
  ///
  /// It is now held for the whole of [_awaitReady], so the spinner runs to the
  /// same instant the navigation does — and `_ConnectButton` keeps `onTap:
  /// null` for all of it. That is design 0075 §6.1 falling out of §6.2 rather
  /// than being implemented twice; see the note on [_awaitReady].
  String? _connectingId;

  /// The unit [_readyWaiter] is waiting on, or null when nothing is waiting.
  ///
  /// Kept beside the completer rather than inside it because
  /// [_onConnectionChanged] fires on EVERY controller notification and has to
  /// ask "is this about the unit we asked for?" before it may answer — C2.
  String? _readyWaitId;

  /// Completed exactly once, by [_settleReadyWait], with whatever ended the
  /// wait. Null when no connect is in flight.
  Completer<_ConnectOutcome>? _readyWaiter;

  /// C1's last resort. See [readyWaitDeadline].
  Timer? _readyDeadline;

  /// Has the controller been seen actually working on [_readyWaitId] yet?
  ///
  /// 🔴 The phase flag, and the wait is WRONG without it. The backstop in
  /// [_readyOutcomeFor] says "nothing is running any more, stop waiting" — and
  /// for the first instants of a wait, nothing is running YET. The link-state
  /// stream is asynchronous, so `connect()` can return before `connecting` has
  /// been delivered to the controller: read `isBusy` at that moment and it is
  /// false, which is indistinguishable from the state the backstop is there to
  /// catch. Waiting for one observation of activity is what separates "not
  /// started" from "over".
  bool _readyWaitSawWork = false;

  /// Hard cap on the wait for `ready` (design 0075 C1).
  ///
  /// 🔴 C1 names two terminating conditions — `lastErrorFor` and
  /// `isSetupStalledFor` — and a third, `connectedDeviceId` moving off this
  /// unit, falls out of C2. This timer is for the state NONE of them cover: a
  /// link that sits at `connected` and never advances, with the stall latch not
  /// yet at [ConnectionController.maxSetupFailures] (it needs THREE silent
  /// connections) and no error filed because nothing has failed yet. That is
  /// the literal shape of FB-51/FB-52, and without this the spinner would run
  /// until the app was killed — which is the defect v0.6.15 shipped a fix for
  /// and which this page must not reintroduce by a side door.
  ///
  /// 20 s, against a measured device switch of 3.1–5.3 s (independent median
  /// 4.97 s) and a `connected → ready` gap of 1.5–2.0 s: roughly four times the
  /// worst thing ever measured, so a healthy-but-slow link is never cut short.
  /// Hitting it is NOT reported as a failure — nothing failed, we simply stop
  /// promising a page. The row's badge still reads `working` off the controller
  /// and goes on saying 連線中, so the screen does not go quiet.
  static const Duration readyWaitDeadline = Duration(seconds: 20);

  /// When false (default) the nearby list shows only RCE devices; the toggle
  /// reveals all nearby BLE devices.
  bool _showAllNearby = false;

  /// Captured in [initState] so [dispose] can stop the scan without touching
  /// the (possibly deactivated) element tree.
  ConnectionController? _conn;

  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _conn = context.read<ConnectionController>();
    // FB-92: the connect flow no longer ends at its own `await` (see
    // [_awaitReady]), so this page needs to hear the controller change its mind
    // even while nothing is rebuilding it. `context.watch` in `build` cannot
    // serve: the wait has to be answered from a callback that runs whether or
    // not a frame happens to be scheduled, and it must survive the widget being
    // rebuilt for an unrelated reason.
    _conn!.addListener(_onConnectionChanged);
    // Rule 1 (design 0055 §7.1): with nothing saved, the saved tab is an empty
    // list whose only remedy lives on the tab the user cannot see. Open on the
    // scan instead.
    //
    // Read once, at construction, and never corrected afterwards: this decides
    // where the user LANDS, and a list that re-aims itself under a finger
    // because a save landed is worse than one that opened on the wrong tab.
    // `AppServices.create` awaits `devices.load()` before the first frame, so
    // this is the real saved count and not an empty pre-load one.
    final hasSaved = context.read<DeviceController>().devices.isNotEmpty;
    _tabs = TabController(
      length: _Tab.values.length,
      vsync: this,
      initialIndex: (hasSaved ? _Tab.saved : _Tab.scan).index,
    );
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
      // C3 (design 0075 §6.2): the user left this tab while a connect was in
      // flight. Whatever they went to do, having a device page shove itself in
      // front of it two seconds later is the R22 harm with a different target —
      // the screen moving on its own after the user has moved on. Drop the
      // pending navigation; the connect itself is NOT cancelled, because they
      // asked for the link and only stopped watching it happen.
      _abandonReadyWait();
    }
  }

  @override
  void dispose() {
    // 🔴 FIRST, and before anything else can await: settle the pending wait and
    // kill its timer. `_connectSaved` is suspended on that completer, and a
    // completer that is never completed leaves the continuation — which ends in
    // `Navigator.push` — parked forever on a State that no longer has an
    // element. Every path out of [_awaitReady] re-checks `mounted`, so the
    // resumed continuation returns without touching the tree; this line is what
    // makes it resume at all. The timer has to go with it or the widget test
    // binding reports a pending timer after teardown, which is the same defect
    // wearing a diagnostic.
    _abandonReadyWait();
    _conn?.removeListener(_onConnectionChanged);
    // Best-effort stop; controller tolerates a no-op when not scanning.
    _conn?.stopScan();
    _tabs.dispose();
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


  // ==========================================================================
  // FB-92 — wait for `ready`, THEN open the unit's own page (design 0075 B3)
  // ==========================================================================
  //
  // 🔴 THIS IS A DELIBERATE PARTIAL REVERSAL OF design 0046 R22, ruled by the
  // owner on 2026-08-21 (design 0075 §8 Q1–Q5). R22's words were "the UI stays
  // on this page", and 0075 §2 found that sentence carries two readings that
  // the original ruling never separated. The owner picked the NARROW one: what
  // R22 forbids is dropping the user onto a screen that cannot show them the
  // connect is still happening. FB `2026.08.02/004` (林陳裕) is that screen —
  // the sheet popped on the `await` and left the dashboard's EMPTY STATE up for
  // the 3.1–5.3 s a switch takes, which is indistinguishable from a dead link.
  //
  // Three things make this not that:
  //
  //   1. We do not leave until the link is `ready`, so the page that appears
  //      has telemetry on it. There is no empty state to sit in.
  //   2. Until then the user is on the list, watching a spinner on the row they
  //      pressed. R22's complaint was a screen that said nothing; this one is
  //      never silent.
  //   3. A connect that FAILS never navigates at all (Q3). This is the part
  //      §3.4 made non-negotiable: FB-88 is unfixed and takes out 2 of 6
  //      cross-device switches (33%), so "navigate on the attempt" would push
  //      a third of switches into a detail page showing 連錯機器 and make the
  //      "two taps" complaint worse rather than better.
  //
  // ⛔ AND THE RED LINE THAT COMES WITH IT (design 0075 §3.3 / §9): this does
  // NOT fix "連線一樣還是要點兩次". That report has three independent causes and
  // the heaviest, FB-88, is untouched here. Nothing shipped off this code may be
  // described as fixing it.

  /// Decide, from the controller alone, whether the wait on [id] is over.
  ///
  /// Returns null while it is still legitimately in progress. Pure with respect
  /// to this State: [_onConnectionChanged] and [_awaitReady] both ask it, so
  /// "has it already happened?" and "has it just happened?" cannot answer
  /// differently — the race that would otherwise hang the spinner is a `ready`
  /// that lands between the `await connect()` returning and the completer being
  /// installed.
  ///
  /// 🔴 ORDER IS LOAD-BEARING. Failure is asked BEFORE success, because
  /// FB-88's `wrong_device` is filed while a link is up: we connected, read the
  /// unit's own address off `0x38` and it belonged to somebody else
  /// (`connection_controller.dart` `_setError('wrong_device', …)`). Ask
  /// `isOnline` first and that lands as a success — a detail page opened onto
  /// the wrong capacitor, which is the exact confusion design 0068 exists to
  /// prevent.
  _ConnectOutcome? _readyOutcomeFor(String id, ConnectionController conn) {
    // C4: per-unit, ALWAYS. `lastErrorUnattributed` is whatever the controller
    // last recorded about anything, and design 0075 §4 B2 measured the gap it
    // gets wrong at 20 ms — a `wrong_device` filed just after our `await`
    // returned, against a unit that is not this row. `lastErrorFor` answers for
    // radio-level codes (`bluetooth_off` and friends) under any id, which is
    // correct: those are true of every unit. FB-86/FB-87 ① also make it answer
    // under the SAVED id after an iOS rebind, so this holds on the path where
    // the id we dialled is not the id the user is looking at.
    if (conn.lastErrorFor(id) != null) return _ConnectOutcome.failed;
    // C1: three connections that came up and never spoke (FB-52). The wire
    // capture that produced [ConnectionController.maxSetupFailures] ran
    // fourteen minutes and never recovered on its own, so this is a terminal
    // answer and not a slow one.
    if (conn.isSetupStalledFor(id)) return _ConnectOutcome.stalled;
    // C2: `isOnline` alone is not enough and never was — it is `_link == ready`
    // and says nothing about WHOSE link. Press 連線 on row B while row A is
    // coming up and an `isOnline`-only test opens B's page off A's link.
    if (conn.isOnline && conn.connectedDeviceId == id) {
      return _ConnectOutcome.ready;
    }
    // C1's third exit, and it is not defensive noise: `connectedDeviceId` falls
    // back to `_desiredDeviceId`, so it stays on this unit through connecting,
    // through `connected`, and through the whole backoff ladder between
    // retries. It only stops being this unit when the controller has genuinely
    // moved on — `disconnect()` (which nulls the target), a connect to another
    // row, or an iOS rebind that landed on a different id. Any of those means
    // there is nothing left to wait for.
    //
    // ⚠️ The rebind case deliberately ends as [abandoned] rather than [ready]:
    // after `connectToSaved` rebinds, the live link belongs to the DIALLED id
    // and this row is keyed by the saved one, so the row itself does not flip
    // to 已連線 either (`isConnected: conn.isOnline && connectedId == d.id`, see
    // `_savedList`). Navigating to a page for an id that is not the one online
    // would be the only thing on screen claiming otherwise. Pre-existing gap,
    // matched rather than widened; it belongs to whoever re-keys the record.
    if (conn.connectedDeviceId != id) return _ConnectOutcome.abandoned;
    // 🔴 THE BACKSTOP, AND design 0075 §6.2 DOES NOT LIST IT. C1 names two
    // terminating conditions, `lastErrorFor` and `isSetupStalledFor`, and there
    // is a real, reachable state in which NEITHER of them ever becomes true and
    // the doc's version of this method therefore spins forever:
    //
    //   the user has turned 自動重連 off, and a link reaches `connected` and
    //   then drops before `ready`.
    //
    //   * No error is filed. `connect()` returned long ago — the drop arrives
    //     on the link-state stream, and a stream event has nothing to throw.
    //   * No retry is armed. `_scheduleReconnect` is gated on
    //     `_settings.autoReconnect` (`connection_controller.dart` ~:2240, and
    //     again inside the timer callback ~:2716), so with the setting off
    //     `isRetrying` stays false.
    //   * The stall latch does not fire. That needs
    //     [ConnectionController.maxSetupFailures] = 3 consecutive silent
    //     connections; this is the FIRST.
    //
    // ⇒ both of C1's conditions are false, forever, and the spinner never
    // stops. That is precisely the screen v0.6.15 shipped a fix for, arriving
    // through a door design 0075 did not check. So the wait also ends when
    // nothing is running any more: no live/settling link, no armed retry, no
    // outstanding iOS hand-off.
    //
    // ⚠️ Biased towards stopping, deliberately. The backoff ladder has a gap
    // between a timer firing and the connect it starts reaching `connecting`,
    // and a notification landing inside that gap ends the wait early. The cost
    // of being wrong there is that the user stays on the list with a stopped
    // spinner and a badge that still says what is happening — which is exactly
    // the behaviour this page had before FB-92. The cost of the opposite bias
    // is an infinite spinner, which is a defect with a report number.
    final working = conn.isBusy || conn.isRetrying || conn.isAutoConnectArmed;
    if (working) {
      // Impure on purpose, and the only write in this method: the observation
      // has to be made wherever the controller is being read, and both callers
      // read it here.
      _readyWaitSawWork = true;
      return null;
    }
    if (_readyWaitSawWork) return _ConnectOutcome.abandoned;
    return null;
  }

  /// Hold here until [id]'s link is usable, or until something says it will not
  /// be.
  ///
  /// This is the "small state machine" design 0075 §7 asks for, and the reason
  /// it is not simply a longer `await`: `connectToSaved` returns at GATT
  /// `connected` and there is no future anywhere in the app that completes at
  /// `ready`. The signal only exists as [ConnectionController] notifications,
  /// so the wait has to be assembled from one — hence the completer, the
  /// listener installed in [initState], and the cap.
  ///
  /// 📌 §6.1 FALLS OUT OF THIS, it is not implemented separately. The row
  /// spinner is `_connectingId == d.id`, the callers hold `_connectingId` for
  /// the whole of this future, and `_ConnectButton` already refuses taps while
  /// it is showing (`onTap: connecting ? null : onTap`). So "the spinner runs
  /// to `ready` and the button stays locked" — 0075 §6.1, i.e. the fix for
  /// `2026.08.18-008.md` §3.3 mechanism ③ — is a property of this method
  /// rather than a second change to the button.
  Future<_ConnectOutcome> _awaitReady(String id) {
    // Only ever one wait. A second tap on another row settles the first as
    // [abandoned] (C3), which unparks that caller so it can notice the spinner
    // is no longer its own and return without navigating.
    _abandonReadyWait();
    final conn = context.read<ConnectionController>();
    // The race named on [_readyOutcomeFor]: in the fake-BLE tests, and on a
    // warm link in the field, `ready` can already be true by the time the
    // `await` unwinds. Installing a completer first would wait for a
    // notification that has already been sent.
    final settled = _readyOutcomeFor(id, conn);
    if (settled != null) return Future<_ConnectOutcome>.value(settled);
    final waiter = Completer<_ConnectOutcome>();
    _readyWaiter = waiter;
    _readyWaitId = id;
    _readyDeadline = Timer(
        readyWaitDeadline, () => _settleReadyWait(_ConnectOutcome.timedOut));
    return waiter.future;
  }

  /// Every controller notification, filtered down to "is our wait over?".
  ///
  /// Cheap on purpose — this runs on every telemetry-driven rebuild the
  /// controller announces, which at `ready` is one every keep-alive tick, and
  /// the first line makes it a null check in the ordinary case.
  void _onConnectionChanged() {
    final id = _readyWaitId;
    if (id == null) return;
    final conn = _conn;
    if (conn == null) return;
    final settled = _readyOutcomeFor(id, conn);
    if (settled != null) _settleReadyWait(settled);
  }

  /// Finish the wait exactly once, and leave nothing running.
  ///
  /// Deliberately does NOT call `setState` or touch the tree: it is reached
  /// from [dispose] and from a [ChangeNotifier] callback that can fire during
  /// another widget's build. The awaiting caller resumes in a microtask and
  /// does the UI work there, where `mounted` means something.
  void _settleReadyWait(_ConnectOutcome outcome) {
    _readyDeadline?.cancel();
    _readyDeadline = null;
    _readyWaitSawWork = false;
    final waiter = _readyWaiter;
    _readyWaiter = null;
    _readyWaitId = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(outcome);
  }

  /// "The user is no longer asking for this." C3's single entry point.
  void _abandonReadyWait() => _settleReadyWait(_ConnectOutcome.abandoned);

  /// The LAST gate before a `Navigator.push` — C2 re-asked at the instant of
  /// leaving, plus C3.
  ///
  /// Re-asking C2 here rather than trusting [_ConnectOutcome.ready] is what C6
  /// is: on the unsaved path the naming dialog sits between the two, and a user
  /// can stand on that dialog for a minute while the unit goes out of range.
  /// The outcome is a fact about a moment that has passed; this is a fact about
  /// now.
  bool _mayNavigateAfterConnect(String id, ConnectionController conn) {
    if (!mounted) return false;
    // C3: they walked away. `active` is the shell's "this is the tab on screen"
    // flag, and this page stays MOUNTED behind every other tab (see
    // [DevicesPage.active]) — so without this check the push would land on top
    // of whatever tab they actually went to.
    if (!widget.active) return false;
    // C3: they opened something themselves while we were waiting — a row's
    // detail page, the settings sheet. Pushing on top of it takes away a screen
    // they chose in favour of one they did not.
    //
    // ⚠️ A dialog makes this false too (`showDialog` pushes a route), which is
    // why the unsaved path calls this only AFTER `promptAndSaveDevice` has
    // returned and its route is gone. Checked here rather than by a flag
    // because a flag only knows about the pushes this class makes.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    // C2, once more, at the moment that matters.
    return conn.isOnline && conn.connectedDeviceId == id;
  }

  /// Connect to a saved device, then open ITS page once the link is usable.
  ///
  /// 🔴 The old contract was "connect and stay here, always" (design 0046 R22,
  /// fix C) and the `Navigator.pop()` FB `2026.08.02/004` was about is still
  /// gone — nothing here pops. What FB-92 adds is a PUSH, and only on the one
  /// outcome R22 was never about: a link that is up and carrying telemetry. The
  /// long argument is on the section banner above; the short one is that the
  /// user asked for this unit and the only screen that can show it to them is
  /// its own page.
  ///
  /// Reading order matters more than usual here, so the four conditions are
  /// marked in place: C1 termination, C2 whose link, C3 still wanted, C4
  /// per-unit error.
  Future<void> _connectSaved(SavedDevice d) async {
    final conn = context.read<ConnectionController>();
    // C3: whatever we were waiting on, the user has just asked for something
    // else. Settle it before the spinner moves so the older caller cannot come
    // back and navigate over the top of this one.
    _abandonReadyWait();
    setState(() => _connectingId = d.id);
    try {
      await conn.connectToSaved(d);
      // A refused connect RETURNS rather than throws — `bluetooth_off` and
      // `permission_denied` are answers, not exceptions (the radio being off is
      // not an error condition of ours), so the completion is only treated as
      // success when the controller has no complaint to make.
      if (!mounted) return;
      // C4: this unit's error, not the last error there was. The snackbar below
      // still reads it unattributed on purpose (see [_showError]) — that is
      // about the ATTEMPT, which after a rebind was filed under an id this
      // method does not hold. The DECISION is per-unit; the WORDING is not.
      //
      // 🔴 AFTER the await, never during it. On the iOS rebind path
      // `connectToSaved` files a failure under the SAVED id and only then calls
      // `connect()` again, whose first act is to clear it — so a reader that
      // sampled `lastErrorFor` across that seam would see a failure that the
      // very next statement retracts, and would stop a connect that is still
      // going. Everything this method and [_awaitReady] read is sampled once
      // the whole of `connectToSaved` has returned, which is the only point at
      // which the controller is a reliable witness about this attempt.
      if (conn.lastErrorFor(d.id) != null) {
        setState(() => _connectingId = null);
        _showError();
        return;
      }
      // The link is at GATT `connected` and unusable for another 1.5–2.0 s.
      // Hold the spinner (§6.1) and the row here until it is usable, or until
      // C1 says it never will be.
      final outcome = await _awaitReady(d.id);
      if (!mounted) return;
      // C3: a second row took the spinner while we waited. It owns the clear
      // and it owns the navigation; this call has nothing left to do. Asked
      // BEFORE the clear, or this would wipe the other row's spinner on its way
      // out.
      if (_connectingId != d.id) return;
      setState(() => _connectingId = null);
      if (outcome != _ConnectOutcome.ready) {
        // C1: stop turning, say what happened, STAY. Q3 (design 0075 §8): a
        // connect that failed must not carry the user anywhere — with FB-88
        // unfixed that is 2 of 6 cross-device switches, and being left on the
        // list is what lets them simply press the next row.
        //
        // Silent when there is nothing to say: [_ConnectOutcome.abandoned] and
        // [timedOut] are not failures, and a snackbar reading "connection
        // failed" over a link that is still coming up would be a lie the badge
        // immediately contradicts.
        if (conn.lastErrorFor(d.id) != null) _showError();
        return;
      }
      if (!_mayNavigateAfterConnect(d.id, conn)) return;
      await _openDetail(d.id, fallbackName: d.name);
    } catch (_) {
      if (mounted) {
        setState(() {
          if (_connectingId == d.id) _connectingId = null;
        });
        _showError();
      }
    }
  }

  /// Connect to a freshly-discovered device, name it, THEN open its page.
  ///
  /// The alias prompt used to belong to the sheet's host, reached by popping
  /// with the new id. With no pop there is no host to hand it to, so the two
  /// facts the prompt needs are captured here instead — see the comments on
  /// each; both predate this page and neither may be dropped in the move.
  ///
  /// 🔵 THE PROMPT STAYS, AND IT STAYS HERE (design 0075 §6.3, owner's Q4 ⇒
  /// (c), 2026-08-21). The tempting simplification — move the naming onto the
  /// detail page, which has its own 尚未儲存 row — was ruled out with Q5's "the
  /// detail page does not change by one line". So the rhythm is three beats:
  /// spinner (2–5 s) → dialog → page. That is longer than anyone would design
  /// from scratch and it is C8: a known, accepted cost, not an oversight to be
  /// trimmed by a later reader.
  ///
  /// ⚠️ Recorded because it bears on how this is judged: that dialog's measured
  /// field conversion is 0 of 42 (何先生, `2026.08.18/008`). Keeping it is a
  /// decision to keep prompting, not evidence that prompting works — and 0/42
  /// is equally not evidence that it does not, since an interface problem and a
  /// willingness problem look identical from here.
  Future<void> _connectNew(DiscoveredDevice d) async {
    final conn = context.read<ConnectionController>();
    _abandonReadyWait(); // C3, as in _connectSaved
    setState(() => _connectingId = d.id);
    try {
      await conn.connect(d.id);
      if (!mounted) return;
      // Same as _connectSaved: a refused connect returns instead of throwing,
      // and C4 makes the test per-unit.
      if (conn.lastErrorFor(d.id) != null) {
        setState(() => _connectingId = null);
        _showError();
        return;
      }
      final outcome = await _awaitReady(d.id);
      if (!mounted) return;
      if (_connectingId != d.id) return; // C3: another row took over
      setState(() => _connectingId = null);
      if (outcome != _ConnectOutcome.ready) {
        // C1 + Q3: no `ready`, no dialog, no page. The prompt is not shown
        // either — asking someone to name a unit we could not bring up is
        // asking them to file a link that does not exist.
        if (conn.lastErrorFor(d.id) != null) _showError();
        return;
      }
      // 🔴 The prompt itself now lives in `save_device_flow.dart` — the detail
      // page can connect too (design 0055), and a prompt that only one of the
      // two entrances runs is a "save" the other entrance cannot reach.
      final saved = await promptAndSaveDevice(context, d.id);
      if (!mounted) return;
      // C6: re-ask C2 now the dialog is gone. Between the two lines above a
      // user can sit on that dialog indefinitely, and a unit that dropped out
      // of range while they were typing must not produce a page about a link
      // that no longer exists.
      if (!_mayNavigateAfterConnect(d.id, conn)) {
        // 🔴 …and rule 2 (design 0055 §7.1) comes back the moment we are not
        // leaving. C7 retires `_revealSavedTab()` from the SUCCESS path,
        // because a tab switch that is covered by a detail page in the next
        // frame is a switch nobody sees, and `_openDetail` already performs it
        // on the way back (see its tail). It cannot be retired from THIS path:
        // here the user stays on 搜尋裝置, and a device they just named has
        // this instant vanished from the tab they are looking at — word for
        // word the 2026-08-11 dealer report 「新儲存的不會顯示」, which the
        // sub-tab split is only allowed to exist because it avoids.
        if (saved) _revealSavedTab();
        return;
      }
      // C5: 跳過 lands here too, and that is the point of it. Declining to name
      // a unit says "do not remember this", not "do not show me this" —
      // binding the two would turn 跳過 into a cancel the user never asked for.
      await _openDetail(d.id, fallbackName: d.name);
    } catch (_) {
      if (mounted) {
        setState(() {
          if (_connectingId == d.id) _connectingId = null;
        });
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
  ///
  /// 🔴 THE ONE PLACE ON THIS PAGE THAT READS THE ERROR UNATTRIBUTED (FB-86),
  /// and the two callers above with it. This snackbar is not about a row — it is
  /// about the connect the user just asked for and this method just awaited, and
  /// on the saved path the id that connect actually dialled may have been
  /// REBOUND (`connectToSaved` → `rebindSavedDeviceId`), so the id in hand is
  /// not the id the failure was filed under. The rows themselves are scoped:
  /// see `lastErrorFor` at the two badge call sites.
  void _showError() {
    final l10n = AppLocalizations.of(context);
    final code = context.read<ConnectionController>().lastErrorUnattributed;
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
      // design 0068 (C): we connected, read the unit's own address off the wire
      // and it was somebody else's. Same wording as the failure card.
      'wrong_device' => l10n.devicesConnectFailedWrongDevice,
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

  /// Delegated to `save_device_flow.dart` (2026-08-13) now that the device's
  /// own page carries the same entrance. See [promptAndRenameDevice].
  Future<void> _rename(SavedDevice d) =>
      promptAndRenameDevice(context, deviceId: d.id, currentAlias: d.alias);

  /// design 0066 §3.7 — "設定型號", beside 重新命名 (owner's placement).
  ///
  /// Same condition as the rename it sits next to: SAVED devices only. Not a
  /// restriction inherited by habit — an unsaved unit has no row for the seven
  /// columns to be written into.
  Future<void> _declareModel(SavedDevice d) =>
      promptAndDeclareModel(context, deviceId: d.id);

  /// Drop the live link — and, again, stay on this page (R22).
  ///
  /// 🔴 UNTOUCHED BY FB-92, deliberately (design 0075 §7). When a row is live
  /// this button reads 中斷, and 中斷 is the user saying they are done with the
  /// unit — answering it with that unit's page is the opposite of what they
  /// asked for. R22 survives here in full.
  ///
  /// The one line FB-92 does add is a cancellation: pressing 中斷 while some
  /// connect is still coming up is as clear a change of mind as C3 models
  /// anywhere else, and `disconnect()` nulls the controller's target, so
  /// without this the pending wait would end as [_ConnectOutcome.abandoned] a
  /// beat later anyway. Saying it here makes the intent legible instead of
  /// incidental.
  Future<void> _disconnect() async {
    _abandonReadyWait();
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
                style: const TextStyle(color: AppSemantics.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 🔴 `connectedDeviceId`, NOT `isOnline` (2026-08-11, reproduced by the
    // owner on v0.7.13: "刪除儲存的裝置就不見了　我沒辦法在附近裝置找回他").
    //
    // `isOnline` is `_link == ready` and nothing else, so deleting during
    // `connecting` / `connected` / `disconnecting` left the LINK UP. A BLE
    // peripheral does not advertise while it is connected, so the unit was
    // then invisible to every scan — deleted from the list and unfindable in
    // it, which is exactly what the report describes.
    //
    // It also could not be recovered: the only control that releases a link is
    // the row's own 中斷 button, and that row is the one just deleted. The
    // not-yet-`ready` window is not an edge case either — it is the whole of
    // FB-51/FB-52 ("connected but never ready"), i.e. precisely the state a
    // user is most likely to give up on and delete the device from.
    //
    // `connectedDeviceId` falls back to `_desiredDeviceId`, so this also covers
    // a link that is between retries; `disconnect()` clears that target and
    // sets `_manualDisconnect`, so auto-reconnect cannot pull it straight back
    // up under a record that no longer exists.
    if (conn.connectedDeviceId == d.id) {
      await conn.disconnect();
    }
    // FB-87 ②: and tell the controller the record is going, or its error and
    // stall latch outlive it — the dashboard's placeholder reads them
    // unattributed and would keep reporting a device that is no longer in the
    // app. `disconnect()` above deliberately does not do this: dropping a link
    // is not the same statement as deleting the device.
    conn.forgetDevice(d.id);
    await devices.remove(d.id);
    // Re-scan so the just-removed device pops back into the nearby list once it
    // resumes advertising (a just-disconnected device needs a few seconds).
    if (mounted) await _rescan();
  }

  /// Rule 2 (design 0055 §7.1): a unit that was just named belongs on the tab
  /// that now holds it. Without this the row disappears from the tab the user is
  /// looking at, and the split would manufacture the very complaint it was
  /// designed around — see the library comment.
  void _revealSavedTab() {
    if (_tabs.index != _Tab.saved.index) _tabs.animateTo(_Tab.saved.index);
  }

  /// The full report for one unit (R21): everything this list deliberately does
  /// not have room for.
  ///
  /// [fallbackName] is the advertised name, and it has to travel WITH the push:
  /// the first thing this does is stop the scan, so an unsaved unit's only name
  /// stops being reachable the moment the page it is needed on appears
  /// (design 0055 §4.2).
  Future<void> _openDetail(String deviceId, {String fallbackName = ''}) async {
    // C3 (FB-92): whatever this page was waiting to open, it is not opening it
    // now. Reached both ways — a row tapped DURING a connect (the user chose a
    // screen, and a second push landing on top of it two seconds later is the
    // R22 harm), and the FB-92 path itself, where the wait has already settled
    // and this is a no-op. One line covers both because "a detail page is being
    // opened" is the same fact either way.
    _abandonReadyWait();
    // 🔴 The scan is NOT stopped here, and that is the fix rather than the bug
    // (ruled 2026-08-12). W-3 — "reading one device must not leave the radio
    // scanning" — is a rule about a WINDOW, and stating it here stated it about
    // a CALL SITE instead: correct only while this was the only way in. It is
    // not. The shell pushes the same page from a home tile and from the app-bar
    // pill, and neither knows a list is scanning behind it.
    //
    // [DeviceDetailPage] reports its own visibility now — as it already did to
    // the GNSS and G-force gates, which is the same window under a different
    // name — and [ConnectionController.setDetailVisible] pauses and resumes the
    // scan off that. `_wantScan` carries this tab's intent across the gap, so
    // the list comes back scanning without this method saying anything.
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceDetailPage(
        deviceId: deviceId,
        fallbackName: fallbackName,
        onOpenSettings: widget.onOpenSettings,
      ),
    ));
    if (!mounted) return;
    // Rule 2 again, for the OTHER entrance. The detail page can name a unit too
    // (its 尚未儲存 row), and a save that happened up there lands in a list down
    // here that the user is not looking at: they would pop back to the scan tab
    // and find the row they just named gone from it. Same rule, same reason —
    // stated twice because there are two ways in, not because one call site
    // covers both.
    if (context.read<DeviceController>().isSaved(deviceId)) _revealSavedTab();
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

    // 🔴 The unit we are LINKED TO, when neither list would otherwise hold it.
    //
    // Owner, 2026-08-12, on v0.7.14: 「我先連線一個電池裝置　然後我沒有儲存
    // 然後我跳到主頁再回去　我就沒辦法再搜尋裝置看到他了」.
    //
    // Decline the alias prompt and the unit is connected with no saved record,
    // so 已儲存 cannot list it. It survives on the 搜尋裝置 tab only because the
    // scan results that produced it are still in memory — and leaving this tab
    // calls `stopScan`, coming back calls `startScan`, and `startScan` OPENS by
    // clearing the roster. A connected peripheral does not advertise, so the
    // fresh scan can never re-find it. Both tabs are then empty of it, the home
    // page has no tile for an unsaved unit either, and the only thing left on
    // screen that knows the link exists is the app-bar pill.
    //
    // Nor can the user recover: 中斷 is the ONLY control that releases a link
    // and it lives on the missing row, and 儲存 lives behind the detail page
    // that same row is the door to. Same family as the 2026-08-11 delete bug
    // (see `_removeDevice`) — there the fix was to release a link the user did
    // not want; here the link is one they DO want, so the row comes back
    // instead.
    //
    // Keyed on `connectedDeviceId`, not `isOnline`, for the delete fix's exact
    // reason: it falls back to `_desiredDeviceId`, so a unit stuck in
    // connecting / between retries — the whole of FB-51/FB-52 — is covered too.
    final pinnedId = connectedId != null &&
            !devices.isSaved(connectedId) &&
            !scan.any((r) => r.id == connectedId)
        ? connectedId
        : null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(scanning: conn.isScanning, onRescan: _rescan),
              if (!conn.isAdapterOn)
                _AdapterOffNote(
                  // D.2: distinguish "permission denied" (deep-link Settings)
                  // from "radio off" (toggle Bluetooth).
                  unauthorized: conn.isAdapterUnauthorized,
                  onOpenSettings: conn.openBluetoothSettings,
                ),
            ],
          ),
        ),
        // 🔴 The adapter note sits ABOVE the tabs, not inside one of them. "The
        // radio is off" is not news about a list — it is the reason both lists
        // are empty, and a copy of it per tab would be two chances to disagree.
        _SubTabs(
          controller: _tabs,
          savedCount: saved.length,
          // The pinned row counts: the badge is what makes "there is something
          // over there" legible from the tab the user is standing on, and a
          // connected unit is the last thing that should be invisible from it.
          scanCount: nearby.length + (pinnedId == null ? 0 : 1),
          scanning: conn.isScanning,
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _savedList(saved, rssiById, conn, connectedId, working, l10n),
              _scanList(
                  nearby, hiddenCount, pinnedId, conn, connectedId, working,
                  l10n),
            ],
          ),
        ),
      ],
    );
  }

  Widget _savedList(
    List<SavedDevice> saved,
    Map<String, int> rssiById,
    ConnectionController conn,
    String? connectedId,
    bool working,
    AppLocalizations l10n,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
      children: [
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
                setupStalled: conn.isSetupStalledFor(d.id),
                // FB-86: this row's OWN error, not whatever the controller last
                // recorded. `isCurrentDevice` above already returns 未連線 for
                // a row that is not the current unit, so nothing on screen
                // changes — but the value reaching this badge is now scoped by
                // the controller rather than by the guard beside it.
                lastError: conn.lastErrorFor(d.id),
              ),
              onOpenDetail: () =>
                  unawaited(_openDetail(d.id, fallbackName: d.name)),
              onEdit: () => _rename(d),
              onDeclare: () => _declareModel(d),
              onDelete: () => _removeDevice(d),
              onDisconnect: _disconnect,
              onConnect: () => _connectSaved(d),
            ),
      ],
    );
  }

  Widget _scanList(
    List<DiscoveredDevice> nearby,
    int hiddenCount,
    String? pinnedId,
    ConnectionController conn,
    String? connectedId,
    bool working,
    AppLocalizations l10n,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 22),
      children: [
        // This toggle used to sit at the very bottom of the sheet — below the
        // saved list and below the fold when devices were saved. A user whose
        // unit was filtered out never learned that anything had been hidden. It
        // belongs directly under the section it filters, and since design 0055
        // that section IS this tab: it filters the scan and nothing else, so it
        // has no business being on screen while the saved list is.
        Center(
          child: TextButton(
            onPressed: () => setState(() => _showAllNearby = !_showAllNearby),
            child: Text(
              _showAllNearby
                  ? l10n.devicesShowRceOnly
                  : (hiddenCount > 0
                      ? l10n.devicesShowAllWithHidden(hiddenCount)
                      : l10n.devicesShowAll),
              style: TextStyle(fontSize: 12, color: context.accent.accent),
            ),
          ),
        ),
        // The linked-but-unsaved unit, ABOVE the scan and outside every filter
        // that applies to it (see `pinnedId` in [build] for the report). It is
        // not a scan hit — it is the reason there is no scan hit — so the
        // vendor toggle must not be able to hide it and the RSSI column has
        // nothing to put in it.
        if (pinnedId != null)
          _DeviceRow(
            alias: unsavedDeviceTitle(
                id: pinnedId, advertisedName: conn.connectedDeviceName),
            aliasMuted: true,
            // 🔴 No RSSI, and no bars. There is no advertisement to measure
            // while the link is up, and inventing a number here would make the
            // one row on this page whose signal reading is a guess look exactly
            // like the ones that are measured.
            meta: '${shortDeviceId(pinnedId)} · ${l10n.devicesLinkedNoAdvert}',
            signalLevel: 0,
            isConnected: conn.isOnline,
            isConnecting:
                _connectingId == pinnedId || (!conn.isOnline && working),
            // 🔴 This row DOES carry a badge, and §4.6 is not bent by it. That
            // rule bans 未連線 on five-to-ten nearby rows because a wall of
            // "no" is noise; there is exactly one of these and it is the only
            // row on the page that can say 連線中 / 沒有回應. FB-53's lesson
            // applies to it and not to them.
            badge: connectionBadgeFor(
              isCurrentDevice: true,
              isOnline: conn.isOnline,
              working: working || _connectingId == pinnedId,
              setupStalled: conn.isSetupStalledFor(pinnedId),
              lastError: conn.lastErrorFor(pinnedId),
            ),
            onOpenDetail: () => unawaited(_openDetail(pinnedId,
                fallbackName: conn.connectedDeviceName)),
            onDisconnect: _disconnect,
            onConnect: () => _connectNew(DiscoveredDevice(
                id: pinnedId, name: conn.connectedDeviceName, rssi: 0)),
          ),
        if (nearby.isEmpty && pinnedId == null)
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
              meta: '${shortDeviceId(r.id)} · RSSI ${r.rssi} dBm',
              signalLevel: signalLevelFromRssi(r.rssi),
              isConnected: conn.isOnline && connectedId == r.id,
              isConnecting: _connectingId == r.id,
              // Still NO BADGE (design 0055 §4.6): five to ten nearby units each
              // captioned 未連線 is noise, and 0046's "the list is for scanning"
              // holds. But there IS a detail route now — the reason there wasn't
              // ("an unsaved unit has no layout or history for a page to show")
              // stopped being true at design 0051, which left the detail page
              // with nothing to configure: connected it is the dashboard, and
              // not connected it is the failure report, and an unsaved unit has
              // both of those just the same. §4.1.
              onOpenDetail: () =>
                  unawaited(_openDetail(r.id, fallbackName: r.name)),
              onDisconnect: _disconnect,
              onConnect: () => _connectNew(r),
            ),
      ],
    );
  }
}

/// The two sub-tabs, with live counts (design 0055 §4.5).
///
/// The counts are not decoration: they are what makes "there is nothing here"
/// legible from the OTHER tab, which is the whole hazard a split introduces.
class _SubTabs extends StatelessWidget {
  const _SubTabs({
    required this.controller,
    required this.savedCount,
    required this.scanCount,
    required this.scanning,
  });

  final TabController controller;
  final int savedCount;
  final int scanCount;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TabBar(
      controller: controller,
      labelColor: context.accent.accent,
      unselectedLabelColor: context.colors.muted,
      indicatorColor: context.accent.accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: context.colors.line,
      labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      tabs: [
        Tab(
          height: 44,
          child: _TabLabel(text: l10n.devicesTabSaved, count: savedCount),
        ),
        Tab(
          height: 44,
          child: _TabLabel(
            text: l10n.devicesTabScan,
            count: scanCount,
            leading: _ScanDot(active: scanning),
          ),
        ),
      ],
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.text, required this.count, this.leading});

  final String text;
  final int count;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 7)],
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: context.colors.panel2,
            border: Border.all(color: context.colors.line),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: context.colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

// ---- meta / formatting helpers ------------------------------------------

String _savedMeta(SavedDevice d, int? rssi, AppLocalizations l10n) {
  final parts = <String>[shortDeviceId(d.id)];
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
          // Flexible, not a bare Text: the title and the rescan pill are the
          // only two children of a `spaceBetween` Row, so a title that does not
          // fit has nowhere to go and the Row overflows. That overflow draws
          // the debug stripes ONLY in a debug build — in release it is a silent
          // clip, which is how it survived to 2026-08-14 unnoticed (measured at
          // 37 px on a 320 pt surface). Widths here are not hypothetical:
          // `main.dart` multiplies the system text scale by
          // `AppTheme.baseTextScale = 1.15` and does NOT cap it, so a user at
          // 2.0 renders this at 2.3×, and `Select device` / `Rescan` are wider
          // than the Chinese strings.
          Flexible(
            child: Text(
              l10n.devicesSheetTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w700,
                color: context.colors.text,
              ),
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
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: context.accent.accent,
                      ),
                    )
                  else
                    Icon(Icons.power_settings_new,
                        size: 13, color: context.accent.accent),
                  const SizedBox(width: 6),
                  Text(
                    scanning ? l10n.devicesScanning : l10n.devicesRescan,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.accent.accent,
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
        decoration: BoxDecoration(
          color: context.accent.accent,
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
    this.onDeclare,
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

  /// design 0066 §3.7. Saved rows only, like [onEdit].
  final VoidCallback? onDeclare;

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
          color: isConnected ? AppSemantics.good : context.colors.line,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
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
                    child: Icon(Icons.battery_full,
                        size: 19, color: context.accent.accent),
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
                                  color: context.accent.accent,
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.radiusSm),
                                ),
                                child: Text('RCE',
                                    style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        color: context.accent.onAccent)),
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
                    onTap:
                        isConnected ? (onDisconnect ?? onConnect) : onConnect,
                  ),
                ],
              ),
              // 🔴 A ROW OF LABELLED BUTTONS, on its own line (ruled
              // 2026-08-13). This used to be two bare glyphs wedged in beside
              // the alias: a 14 px `Icons.edit_outlined` in `muted`, wrapped in
              // an `InkWell` with NO padding and NO constraints — a 14×14 dp
              // target, no tooltip, no label — and 7 px later the DELETE key.
              //
              // A community report on 2026-08-13 asked whether renaming was
              // possible at all: 「目前如果要更改名稱，刪除再重新設定！請問是否
              // 可以直接更改名稱？」. It always was — `DeviceRepo.updateAlias`,
              // `DeviceController.rename` and the rename dialog have all
              // shipped for months. What the reporter could not find was the
              // pencil, and the thing they found instead was the bin 7 px to
              // its right.
              //
              // This is the SECOND time the same failure mode has shipped; see
              // `home_page.dart`'s `onEdit` for 2026-08-07's ("沒有這個功能呢",
              // about an 18 px grey `Icons.tune`). The conclusion recorded
              // there is the one applied here: A CONTROL NOBODY FINDS IS A
              // CONTROL THAT DOES NOT EXIST, and the honest fix is to give it a
              // word, not a louder glyph.
              //
              // Why its own line rather than beside the alias: on a 320 pt
              // phone the alias row's free width is ~107 dp once the icon tile,
              // the signal bars and the connect pill have taken theirs — enough
              // for two 14 px glyphs and nothing else. That measurement is what
              // produced the glyphs in the first place. The full card width is
              // ~264 dp, which fits both words with room between them.
              //
              // And they sit at OPPOSITE ENDS (`spaceBetween`) instead of 7 px
              // apart, because one of them is destructive and the report we are
              // answering is most likely a mis-tap of exactly that one.
              //
              // 🔴 A [Wrap], not a [Row] — changed 2026-08-17 when design 0066
              // added a THIRD action ("型號") between the two. `main.dart`
              // MULTIPLIES the system text scale by `AppTheme.baseTextScale` and
              // never clamps it, and three words do not fit a 320 pt card the
              // way two did. A `Row` of three loose [Flexible]s caps each at a
              // third of the card, which at that width ellipsises 重新命名 down
              // to 重新… — and a control whose WORD has been clipped is the FB-70
              // failure mode wearing a longer label, since the word is the whole
              // reason the glyphs were replaced.
              //
              // `WrapAlignment.spaceBetween` keeps the wide-screen behaviour
              // intact: on one line the three sit exactly where a `spaceBetween`
              // Row put them, so RENAME and the destructive REMOVE are still at
              // opposite ends (`devices_page_test` measures that gap). When they
              // do not fit, REMOVE drops to a second line at full width instead
              // of being shortened — a longer card, not a clipped word.
              if (onEdit != null || onDeclare != null || onDelete != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onEdit != null)
                      _RowAction(
                        icon: Icons.edit_outlined,
                        label: l10n.devicesAliasRenameTitle,
                        onTap: onEdit!,
                      ),
                    // design 0066 §3.7: the owner placed it beside 重新命名, and
                    // it sits BETWEEN the two so that the destructive one keeps
                    // the far edge to itself — the 2026-08-13 report this row
                    // was rebuilt for was most likely a mis-tap of that one.
                    if (onDeclare != null)
                      _RowAction(
                        icon: Icons.category_outlined,
                        label: l10n.declaredRowAction,
                        onTap: onDeclare!,
                      ),
                    if (onDelete != null)
                      _RowAction(
                        icon: Icons.delete_outline,
                        label: l10n.devicesRemove,
                        danger: true,
                        onTap: onDelete!,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A per-row action: a word, an icon, and a target you can actually hit.
///
/// 🔴 The minimum height is 40 dp on purpose — both platforms' accessibility
/// guidance puts the floor there (Material 48, HIG 44), and what this replaces
/// was an unpadded [InkWell] around a 14 px [Icon], i.e. 14×14 dp. See the
/// comment at its call site for the report that produced it.
///
/// The [label] is the accessible name too: it is real [Text], so a screen
/// reader announces "重新命名" rather than the icon's nothing, and the [Tooltip]
/// carries the same word for a long-press. Nobody has to press it to find out.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Draws in [AppSemantics.danger]. Set on removal — the word alone is not much
  /// of a warning next to a button that only renames something.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppSemantics.danger : context.colors.muted;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          // 🔴 No `alignment:` — a [Container] with one wraps its child in an
          // [Align], which EXPANDS to the incoming constraints. Under the
          // caller's loose [Flexible] that made this button exactly half the
          // card wide, so the two ended up edge to edge with a zero gap: the
          // 7 px crowding this whole change is about, rebuilt at 372 px.
          constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            border: Border.all(
              color: danger
                  ? AppSemantics.danger.withValues(alpha: 0.45)
                  : context.colors.line,
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              // Flexible + ellipsis. The caller is a [Wrap] since 2026-08-17, so
              // this button now sizes to its own content and only meets this
              // clamp when ONE label alone is wider than the whole card — a
              // large accessibility font on a narrow phone. Before that the
              // caller capped it at half the row; the clamp is kept because the
              // failure it prevents (an overflow stripe, silent in release) is
              // unchanged, and a shortened word still says more than the glyph
              // this replaced.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
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
      ConnectionBadge.connected => AppSemantics.good,
      // 🔴 Harder to get right than the connection pill: the badge's fill AND
      // border are both derived from this one colour (see `_badgeChip`), so an
      // accent-driven `connecting` would make the whole capsule identical to
      // `connected` — text aside. Fixed status colours only (design 0064).
      ConnectionBadge.connecting => AppSemantics.warn,
      ConnectionBadge.notAnswering => AppSemantics.warn,
      ConnectionBadge.failed => AppSemantics.danger,
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
            // Flexible + ellipsis, matching the `meta` line one row up in the
            // same Column — that one already had `maxLines: 1` and this one did
            // not, which is what an omission looks like rather than a choice.
            // `mainAxisSize.min` asks for the intrinsic width but cannot create
            // it: this pill sits in the row's middle column, squeezed between
            // the signal bars and the connect button, and a long status word
            // overflowed by 80 px on a 320 pt surface (2026-08-14). Truncating
            // to `Reconnec…` is the honest failure — the untruncated version
            // silently clipped the chevron too, so the control stopped looking
            // like something you could tap.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
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
            border: Border.all(color: AppSemantics.danger),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Text(
            l10n.devicesDisconnect,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppSemantics.danger,
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
          color: context.accent.accent,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: connecting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: context.accent.onAccent,
                ),
              )
            : Text(
                l10n.devicesConnect,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: context.accent.onAccent,
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
        // Was `const Color(0x12F6A821)` / `0x47F6A821` — the amber spelled out
        // in hex, invisible to every search for `AppColors.`. Design 0064
        // keeps this frame on the FIXED warning tone; the danger was never
        // that it would stop following the accent, it is that the next person
        // copies a bare hex for a BRAND surface and nothing ever finds it.
        // Alpha written as the original byte over 255 so "the value did not
        // change" is arithmetic rather than trust.
        color: AppSemantics.warn.withValues(alpha: 0x12 / 255),
        border:
            Border.all(color: AppSemantics.warn.withValues(alpha: 0x47 / 255)),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppSemantics.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // NOTE: a dedicated "enable Bluetooth permission in Settings"
              // string for the unauthorized case is a pending l10n addition;
              // until then we reuse the adapter-off copy and lean on the
              // Settings deep-link pill to signal the actionable path.
              l10n.devicesAdapterOff,
              style: const TextStyle(
                  fontSize: 11, height: 1.5, color: AppSemantics.warn),
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
                  // Same frame, same fixed amber: this pill is outlined and
                  // labelled in the warning box's own colour, so it reads as
                  // part of the frame rather than as an action in the app's
                  // accent. Themed, the box would be two colours.
                  border: Border.all(
                      color: AppSemantics.warn.withValues(alpha: 0x47 / 255)),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.settings,
                        size: 13, color: AppSemantics.warn),
                    const SizedBox(width: 6),
                    Text(
                      l10n.navSettings,
                      style:
                          const TextStyle(fontSize: 11, color: AppSemantics.warn),
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
