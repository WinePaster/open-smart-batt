/// OpenSmartBatt — BLE transport service (flutter_blue_plus).
///
/// The single object that talks to the battery over BLE. Everything above it
/// (the State controllers) consumes only its streams + methods; everything
/// below it (wire encode/decode) is the pure-Dart `protocol/` layer.
///
/// Responsibilities (live HCI capture, PROTOCOL.md §2/§3):
///   * Scan filtered on the vendor service UUID 07b9fff0-… (no name filter).
///   * Connect, discover the write char 07b9ace3-… and notify char 07b9ace4-…
///   * Enable notifications (write 01 00 to the CCCD via `setNotifyValue`).
///   * Reassemble every notification chunk into ONE byte stream
///     ([FrameReassembler]) and decode telemetry ([TelemetryDecoder]).
///   * Drive a ~1 Hz keep-alive on a tick-counted schedule (PROTOCOL.md §2):
///     `!#` on tick 1 (+ every 5th tick for a power bank), `@` every 25th tick,
///     `#` otherwise — this is what makes the battery stream telemetry (and a
///     power bank stream SOC / port state).
///   * No MTU negotiation (connect with `mtu: null`); Write-Without-Response
///     only for every write/keep-alive.
///
/// SAFETY: only the documented release (mode 0x06 + auth) is proven-safe.
/// [switchMode] is generic by design (the protocol layer builds any mode); the
/// caller (controller/UI) is responsible for gating which mode codes are sent.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/log_entry.dart' show LogDirection;
import '../models/telemetry_sample.dart';
import '../protocol/protocol.dart';
import 'ble_models.dart';
import 'exec_gap_tracker.dart';
import 'notify_keepalive_pacer.dart';

/// Everything that belongs to ONE BLE link, keyed by the unit it talks to.
///
/// Nothing here is new state: every field was a `BleService` field and is
/// reproduced verbatim. What changed is that they are no longer SHARED. Each
/// one has per-device semantics that a single shared instance silently
/// violates the moment a second link exists:
///
///   * [reassembler] — one byte stream per link. Feeding two peripherals'
///     notifications into one buffer splices a frame boundary from A into a
///     frame from B; the reassembler resyncs on the next 0xB8, so the damage is
///     silent dropped frames rather than an error.
///   * [decoder] — folds successive frames into ONE accumulated sample (DVOL
///     needs the last-seen VADJ). Two units share one snapshot otherwise.
///   * [keepAliveTick] — the poll schedule is per-device by definition
///     (PROTOCOL.md §2): `!#` on tick 1, `@` every 25th, and for a power bank
///     `!#` every 5th. `!#` is the only source of thirteen selectors, so a
///     shared counter does not merely skew the cadence — it means some unit
///     never gets asked.
///   * [keepAliveInFlight] — the re-entrancy guard that stops a 1 Hz timer
///     queueing a write per stalled second. Shared, one unit's hung write eats
///     another unit's tick.
///   * [epoch] / [settingUp] — the FB-39 guard is "has a NEWER connect taken
///     over the state I am about to write". With one link per unit, connecting
///     a third device must not abandon the setups of the other two.
///   * [keepAliveFailures] / [keepAliveWriteFailed] — "this link's writes are
///     not getting out". Shared, one unit's silence is reported as another's.
///
/// Deliberately private. This is the shape multi-device needs, not multi-device
/// itself.
///
/// ⚠️ It used to say "and deliberately not concurrent: today [BleService]
/// creates at most one of these at a time", and that was not true: two of these
/// could be live on ONE physical link at once, each with its own [reassembler],
/// [decoder], keep-alive schedule and write histogram — exactly the doubling
/// the per-link fields were introduced to prevent between DIFFERENT units. The
/// route in was a `_LinkState` that had been dropped from [BleService._links]
/// without being torn down; it kept its subscriptions and kept running with
/// nothing pointing at it.
///
/// That route is closed (2026-08-14): a link now leaves the map only through
/// [BleService._dropAllLinks], which tears it down in the same breath. What is
/// still true, and is why every field below is per-link rather than shared, is
/// everything above this paragraph.
class _LinkState {
  _LinkState({
    required this.deviceId,
    required this.device,
    required MetadataParser parser,
  }) : decoder = TelemetryDecoder(parser: parser);

  /// BLE remote id — the map key, and the attribution stamped on this link's
  /// packet events. Survives [device] being cleared by teardown, because a
  /// torn-down link still has to be able to say whose data it holds.
  final String deviceId;

  /// Plugin handle. Nulled by teardown (which is what "not connected" means to
  /// the single-link getters), while the rest of this object survives.
  BluetoothDevice? device;

  BluetoothCharacteristic? writeChar;
  BluetoothCharacteristic? notifyChar;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;
  Timer? keepAlive;
  int keepAliveTick = 0;
  bool keepAliveInFlight = false;
  bool keepAliveWriteFailed = false;
  int keepAliveFailures = 0;

  /// When this link's keep-alive last WROTE successfully — the debounce zero
  /// point for the notify-driven pacer (design 0047 Phase 1). Successful
  /// writes only, deliberately: a failing write path must not push the next
  /// attempt further away, and the timestamp of a failure says nothing about
  /// how starved the device is.
  DateTime? lastKeepAliveOkAt;

  /// FB-20 instrument: how long each SUCCESSFUL keep-alive write took.
  ///
  /// Only failures used to carry a duration, so the corpus could see the right
  /// tail (>=5 s) and nothing else — the body of the distribution was inferred
  /// from the tick quantisation instead of measured. That inference cannot tell
  /// "every write takes ~4.2 s" (a connection-parameter story) from "most take
  /// 1 s and one in five runs to 4.9 s" (a retransmission story), and the two
  /// call for different fixes. A histogram costs nine ints per link and settles
  /// it from field captures we already ask for.
  int writeOkCount = 0;
  int writeMsTotal = 0;
  int writeMsMax = 0;
  final List<int> writeMsBuckets =
      List<int>.filled(BleService.writeStatsBucketsMs.length + 1, 0);
  int writeStatsReported = 0;

  bool settingUp = false;

  /// True while Android is still bouncing through its three connect attempts,
  /// so the drops BETWEEN those attempts are not reported as a lost link.
  ///
  /// This flag used to carry a second job it was never named for — filtering
  /// the value flutter_blue_plus replays into a fresh `connectionState`
  /// subscription — and [sawConnected] has taken that job over. See
  /// [BleService.linkActionFor] for what that cost us on iOS.
  bool retryingConnect = false;

  /// Whether this link has EVER been reported connected.
  ///
  /// FB-53. A link that has never been up cannot have gone down, which is the
  /// whole of the test that tells a real drop from the `disconnected`
  /// flutter_blue_plus replays into every new subscription. Written
  /// SYNCHRONOUSLY on the `connected` event, before setup is awaited — see
  /// [BleService._onConnectionState].
  bool sawConnected = false;

  /// When [connSub] was created — the zero point for the `sub=<n>ms` field of
  /// the `conn-state:` diagnostic line.
  ///
  /// The replayed value arrives on the first microtask after `listen()`, so it
  /// lands at 0 ms; a radio event cannot. Across the corpus every one of the
  /// 906 `connecting` → `disconnected` pairs was inside 1 ms, and the number
  /// that says so has to be in the log rather than reconstructed from two
  /// timestamps by whoever reads it.
  DateTime connSubAt = DateTime.now();

  final FrameReassembler reassembler = FrameReassembler();
  final TelemetryDecoder decoder;

  /// FB-39: invalidates a connection setup that a newer connect/disconnect has
  /// superseded, so a slow unit cannot bring the app online under an identity
  /// the user has already moved away from. See [ConnectEpoch].
  final ConnectEpoch epoch = ConnectEpoch();
}

/// What one `connectionState` event means for the link it arrived on.
///
/// Three outcomes, and the third is the one that did not exist before FB-53:
/// an event we deliberately do nothing about. It is still WRITTEN DOWN (see
/// [BleService.diagnostics]) — an ignore that leaves no trace is
/// indistinguishable from a listener that never fired.
enum LinkAction {
  /// `connected`: run the GATT setup.
  setup,

  /// A real drop of a link that really was up.
  teardown,

  /// Nothing to do — a transitional state, or the cached value the plugin
  /// replays into a subscription that has just been created.
  ignore,
}

/// Owns the one BLE connection and exposes telemetry + control.
///
/// Single-connection model: connecting while already connected first tears the
/// previous link down. Not safe to share across isolates.
///
/// Per-link state lives in [_LinkState], keyed by device id, and [_links] holds
/// **0 or 1** entry. The keying is structural groundwork, not a capability: it
/// is what stops the singleton assumptions listed on [_LinkState] from having
/// to be found again later, one silent regression at a time.
///
/// ⚠️ THE MAP HOLDING ONE ENTRY IS NOT THE SAME AS ONE LINK BEING LIVE, and
/// this doc used to conflate them: it said "`connect()` still awaits
/// `disconnect()` first, and no caller can ask for a second concurrent link".
/// The first clause is true and the second never followed from it. What holds:
///
///   * ✅ Two `connected` events on ONE link cannot start two setups.
///     [_setupConnection] writes [_LinkState.settingUp] before its first
///     `await`, and refuses again once `_state` is [BleLinkState.ready].
///   * ✅ A `connect()` awaited to completion before the next one leaves one
///     link: the second call's `disconnect()` tears the first down.
///   * ✅ Two `connect()` calls for the same id, the second arriving while the
///     first is still inside its opening `await disconnect()`, ALSO leave one
///     live link — since 2026-08-14. They still both get past `disconnect()`
///     (which only ever looks at [_current], and only clears the handle AFTER
///     the platform answers); what changed is what happens to the link the
///     later call displaces. See [_dropAllLinks] and [_installLink].
///
/// THE DEFECT THAT FIXED, kept because the shape of it is the reason the map
/// is written in exactly one place now. The third case used to leave TWO live
/// links: `connect()` opened with a bare `_links.clear()`, and that line
/// dropped the earlier entry without cancelling the `connectionState` and
/// notify subscriptions it owned. The orphan kept its own reassembler,
/// decoder, keep-alive timer, tick counter and write histogram, and nothing
/// above the transport could see it, because every single-connection getter
/// here reports the one link in [_links].
///
/// The window was as long as a platform disconnect takes, not a scheduling
/// hair: a field capture (batch 2026.08.13/001) holds two connect requests
/// 1.9 s apart followed by eighteen minutes in which one connection ran two
/// GATT setups, wrote every inbound chunk to the log twice, fed two decoders
/// into one telemetry stream (CSV `samples` 2.48x that unit's own baseline)
/// and closed with two keep-alive write histograms carrying different totals.
///
/// The invariant that replaces the claim, and the one to hold this class to:
/// **a link that is not in [_links] has been torn down.** It is stated as one
/// rule rather than a fix to one line because the line was never the point —
/// any other way out of the map would have had the same consequence.
/// `test/double_gatt_setup_test.dart` pins both halves: the guards that always
/// held, and the reproduction, which now asserts the remedy.
class BleService {
  BleService({
    CommandBuilder commands = const CommandBuilder(),
    MetadataParser parser = const NoopMetadataParser(),
  }) {
    _commands = commands;
    _parser = parser;
    // One persistent listener turns plugin scan results into [DiscoveredDevice].
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
  }

  late final CommandBuilder _commands;

  /// Device-metadata parser handed to every link's decoder (stateless; the open
  /// build's is a no-op). Held rather than pre-applied because a decoder is now
  /// built per link instead of once per service.
  late final MetadataParser _parser;

  /// Live links by device id. **0 or 1 entry today** (see the class doc).
  ///
  /// An entry OUTLIVES its teardown, and that is deliberate: `disconnect()` has
  /// to be able to invalidate a setup that is mid-await even after the plugin
  /// handle was cleared — precisely the window the FB-39 guard exists for. The
  /// entry is dropped by the next `connect()` or by `dispose()`.
  ///
  /// ⚠️ "Torn down" and "dropped" are different things, and the implication
  /// runs ONE way: torn down but still in the map is the normal resting state
  /// (previous paragraph), while **dropped without being torn down is the fault
  /// this class was carrying** — a `_LinkState` still holding live
  /// subscriptions, a keep-alive timer and its own decoder, with nothing left
  /// pointing at it. So this map is written in exactly two places, and one of
  /// them calls the other: [_dropAllLinks] (removal, tears down what it
  /// removes) and [_installLink] (insertion, via [_dropAllLinks]). Anything
  /// that reaches for `_links.clear()` or `_links[x] = y` again re-opens it.
  final Map<String, _LinkState> _links = <String, _LinkState>{};

  /// The link the single-connection getters report on. Survives teardown for
  /// the same reason the decoder used to: `currentSample` must keep returning
  /// the last values after a drop, not go blank.
  _LinkState? _current;

  /// Reported by [currentSample] before any link has ever existed. Held rather
  /// than built per call so repeated reads keep returning the same instance,
  /// as a service-lifetime decoder used to.
  final TelemetrySample _noTelemetry = TelemetrySample.empty();

  StreamSubscription<List<ScanResult>>? _scanSub;

  /// Human-readable reason for the most recent disconnect (flutter_blue_plus
  /// [DisconnectReason]: code + description), or null if none/unknown. Surfaced
  /// so the controller can log WHY a link dropped (supervision timeout vs a
  /// peripheral-initiated close), which is what on-device disconnect debugging
  /// needs. Cross-platform.
  String? _lastDisconnect;

  /// The most recent disconnect reason (see [_lastDisconnect]).
  String? get lastDisconnect => _lastDisconnect;

  /// Execution-gap instrument (design 0047 Phase 0). Ticked by the keep-alive
  /// callback, asked on every inbound BLE event; its line goes out on
  /// [diagnostics] because the captures that need it are exactly the ones that
  /// arrive with the raw-packet log off. Service-level, not per-link: it
  /// measures the isolate, and the isolate is shared. Reset at teardown so
  /// idle time between links is never reported as a gap.
  final ExecGapTracker _execGap = ExecGapTracker();

  /// Ask [_execGap] about one inbound event and publish its line, if any.
  void _checkExecGap(String endedBy) {
    final line = _execGap.onEvent(endedBy, DateTime.now());
    if (line != null) _diagnostics.add(line);
  }

  /// Notify-driven keep-alive pacing (design 0047 Phase 1). Service-level like
  /// [_execGap] and for the same reason: it describes the isolate's execution
  /// regime (backgrounded on iOS), not any one link. Inactive by default and
  /// on every platform whose monitor strategy does not opt in — Android's
  /// keep-alive stays timer-driven under the foreground service, unchanged.
  final NotifyKeepAlivePacer _pacer = NotifyKeepAlivePacer();

  /// Switch the keep-alive between timer-driven (default, foreground) and
  /// notify-driven (iOS background window). Idempotent; the closing summary
  /// line goes to [diagnostics] like every other transport instrument.
  ///
  /// The ONLY caller is `ConnectionController`, gated on
  /// `MonitorService.pacesKeepAliveInBackground` — which is how "Android never
  /// takes this path" is enforced structurally rather than by a platform check
  /// buried here.
  void setNotifyDrivenKeepAlive(bool active) {
    final line = _pacer.setActive(active, DateTime.now());
    if (line != null) _diagnostics.add(line);
  }

  /// Whether keep-alives currently ride the notify path. Test-visible so the
  /// platform dispatch can be asserted directly.
  @visibleForTesting
  bool get notifyDrivenKeepAlive => _pacer.active;

  // Cached guids (cheap, but build once).
  static final Guid _serviceGuid = Guid(Gatt.serviceUuid);
  static final Guid _writeGuid = Guid(Gatt.writeCharUuid);
  static final Guid _notifyGuid = Guid(Gatt.notifyCharUuid);

  /// Keep-alive cadence (~1 Hz). The battery streams telemetry as long as it
  /// keeps receiving a poll token; exact cadence is not protocol-critical.
  static const Duration keepAliveInterval = Duration(seconds: 1);

  /// Upper edges (ms) of the keep-alive write-duration histogram; a final
  /// open-ended bucket catches everything at or past the last edge. Chosen to
  /// straddle [keepAliveWriteTimeout]: the question FB-20 leaves open is where
  /// the body of the distribution sits, not how far the tail goes.
  static const List<int> writeStatsBucketsMs = [
    100, 250, 500, 1000, 2000, 3000, 4000, 5000
  ];

  /// Emit the histogram every N successful writes. 60 is about a minute on a
  /// healthy link and about five minutes on the slowest unit measured, so the
  /// line is rare enough not to crowd the packet log it shares.
  static const int writeStatsEvery = 60;

  /// Write timeout for a keep-alive poke.
  ///
  /// flutter_blue_plus defaults to 15 s, which is 15 poll periods — a stalled
  /// write sat there long past the point the tick was useful, and the error
  /// only surfaced once the app resumed. A few periods is enough to tell
  /// "this write is not coming back" without being trigger-happy.
  static const Duration keepAliveWriteTimeout = Duration(seconds: 5);

  /// No inbound frame for this long, while the link still reports ready, means
  /// telemetry has stalled — the readouts on screen are stale even though the
  /// connection looks healthy. Observed cause: Android suspending the app
  /// (screen off / background), where RX and TX stop together for minutes and
  /// then flush a backlog. Deliberately several poll periods so a momentary gap
  /// does not flap the indicator.
  static const Duration telemetryStallThreshold = Duration(seconds: 8);

  /// Pure keep-alive scheduler (PROTOCOL.md §2). Selects which poll token to
  /// write for a given 1-based [tick] and whether the connected unit is a power
  /// bank (device-type 0x22, from decoded telemetry). Extracted as a static pure
  /// function so the schedule is unit-testable without a live connection.
  ///
  /// Order (per PROTOCOL.md §2 — the metadata poll is checked BEFORE the
  /// power-bank extended poll, so a tick that is both %25 and %5 sends `@`):
  ///   * tick == 1          -> `!#` (0x21 0x23) — every device, once.
  ///   * %25 == 0            -> `@`  (0x40) — slow metadata (all devices).
  ///   * power bank & %5==0  -> `!#` — continuous SOC / port refresh.
  ///   * otherwise           -> `#`  (0x23).
  static List<int> keepAliveTokenFor(
    CommandBuilder commands, {
    required int tick,
    required bool isPowerBank,
  }) {
    if (tick <= 1) return commands.extendedPoll();
    if (tick % 25 == 0) return commands.slowMetadataPoll();
    if (isPowerBank && tick % 5 == 0) return commands.extendedPoll();
    return commands.keepAlive();
  }

  /// Per-platform connect tuning (D.4). Android's `connectGatt` fails fast on a
  /// stale handle and frequently bounces on the FIRST attempt, so a few retries
  /// at a generous timeout are appropriate. iOS's `connectPeripheral` has NO
  /// native timeout (it waits forever) and a stale/uncached NSUUID never
  /// resolves, so we use a SINGLE attempt at a SHORT timeout — that way a stale
  /// saved id surfaces an error in seconds instead of 3×20s = 60s of frozen
  /// spinner. Both are pure functions of the platform for unit-testing.
  static const Duration androidConnectTimeout = Duration(seconds: 20);
  static const Duration iosConnectTimeout = Duration(seconds: 8);

  /// Number of connect attempts to make on [isIOS]. iOS = 1 (no native
  /// timeout, retrying only multiplies the freeze); Android = 3 (connect-bounce
  /// recovery).
  static int connectAttemptsFor({required bool isIOS}) => isIOS ? 1 : 3;

  /// What to do with a `connectionState` event, given what the link has seen.
  /// Pure and static for the same reason [connectAttemptsFor] and
  /// `reconnectBackoff` are: the policy is the thing worth testing, and a
  /// decision table that needs a radio to exercise is a decision table nobody
  /// checks.
  ///
  /// FB-53. What this replaces was one line — `if (link.retryingConnect)
  /// return;` — doing two jobs under one name. [_LinkState.retryingConnect]
  /// means "Android is mid-bounce, do not report the bounces". It was ALSO the
  /// only filter on the value flutter_blue_plus replays into a brand-new
  /// `connectionState` subscription: 1.36.8 builds that stream with
  /// `newStreamWithInitialValue` over a cache it only ever writes
  /// (`bluetooth_device.dart:334-348`, `flutter_blue_plus.dart:447`), so the
  /// first thing every subscriber receives — on the first microtask after
  /// `listen()`, before `device.connect()` has even taken the plugin's global
  /// mutex — is the cached state, which on a cold connect is `disconnected`.
  ///
  /// On Android `connectAttemptsFor` is 3, the flag is true, and the replayed
  /// value was swallowed. On iOS it is 1, the flag is false, and the replayed
  /// value was read as a real drop that tore down the connection still being
  /// built — every single connect, one millisecond in. The corpus holds 906
  /// `link: connecting` → `link: disconnected` pairs, 906 of them inside 1 ms;
  /// `2026.08.03/004` contributes 53 of them, plus a cold start where the user
  /// waited 15.3 s for a device sitting on the desk while three phantom drops
  /// each burned a rung of the backoff ladder.
  ///
  /// [sawConnected] is the fact `retryingConnect` was standing in for, and it
  /// says the same thing on both platforms — which is the point. Android's
  /// behaviour was only ever correct by the accident of `attempts == 3`; state
  /// the invariant instead of relying on a constant to keep implying it.
  static LinkAction linkActionFor(
    BluetoothConnectionState s, {
    required bool sawConnected,
    required bool retryingConnect,
  }) {
    if (s == BluetoothConnectionState.connected) return LinkAction.setup;
    if (s != BluetoothConnectionState.disconnected) return LinkAction.ignore;
    // Android's retry window still wins on its own terms: mid-bounce drops are
    // this method's caller's business only after the loop gives up.
    if (retryingConnect) return LinkAction.ignore;
    return sawConnected ? LinkAction.teardown : LinkAction.ignore;
  }

  /// Our own service-discovery timeout — deliberately SHORTER than the 15 s
  /// flutter_blue_plus applies internally.
  ///
  /// The point is to be the one who notices. With no timeout of our own, the
  /// plugin's fires first and arrives as an exception out of a stream listener,
  /// which is why a field capture holds 101 `Uncaught:` lines. Owning the
  /// timeout lets us retry once and write a readable line instead.
  ///
  /// 8 s is now MEASURED, not guessed. It used to say "an ESTIMATE, not a
  /// measured optimum ... revisit once enough field captures exist"; they do.
  ///
  /// Every successful discovery leaves `link: connected` → `GATT dump:` in the
  /// capture log, and that interval IS the discovery time. 168 of them across
  /// the corpus, deduplicated by absolute timestamp because a rolling log
  /// re-exports the same event under several batch numbers. The 89 from
  /// `<=0.6.12` are the ones worth quoting: this timeout did not exist yet, so
  /// they are NOT censored at 8 s.
  ///
  ///     p50 1.26 s | p90 4.83 s | p95 6.21 s
  ///     <=2 s 74.2% | <=5 s 91.0% | <=8 s 96.6% | <=12 s 98.9% | <=15 s 98.9%
  ///
  /// So raising it buys almost nothing: 8 -> 10 s recovers 0.00 pp (no
  /// successful discovery ever landed between 8 and 10 s), 8 -> 12 s recovers
  /// 2.25 pp for four extra seconds on every attempt that is going to fail
  /// anyway. Only three samples exceeded 8 s (10.08, 10.99, 21.03 s) and the
  /// last is not real — it outruns the plugin's own 15 s, so it can only be an
  /// iOS-backgrounded capture whose Dart timers were frozen.
  ///
  /// ⚠️ Read that as "8 s is not the problem", NOT as "discovery is reliable".
  /// `2026.08.03/003` holds thirteen consecutive connections on one phone where
  /// discovery never answered at all — 26 attempts, 0 successes, healed only by
  /// restarting the app. A threshold cannot fix a call that never returns; see
  /// `docs/feedback-analysis/2026.08.03-003.md`.
  ///
  /// The other constraint is unchanged and still binding: it has to be under
  /// the plugin's 15 s or it never fires, and the plugin's arrives as an
  /// exception out of a stream listener — which is why one field capture holds
  /// 101 `Uncaught:` lines.
  static const Duration discoverTimeout = Duration(seconds: 8);

  /// Service-discovery attempts. **One** — FB-51, design 0031 §4.2.
  ///
  /// It was two, on the reasoning that a capture had shown discovery failing and
  /// then succeeding, so one shot throws away a link that was about to work.
  /// That reasoning was measured and did not survive: the second attempt cannot
  /// do what it claims. [withTimeoutRetry] abandons the first call without
  /// CANCELLING it, and `discoverServices` holds flutter_blue_plus's `"global"`
  /// FIFO mutex — one lock for every GATT operation on every device, not one per
  /// device — until its own 15 s expires. So attempt 2 spends its whole 8 s
  /// queued in `mtx.take()` and never reaches the platform at all.
  ///
  /// The field logs show precisely that shape. In `2026.08.03/003` attempt 2
  /// failed 8.001–8.002 s after attempt 1 in eleven of twelve rounds, with no
  /// variance worth the name — the signature of a wait on a lock, not of a radio
  /// being asked anything. Across the corpus a second attempt rescued 5 setups
  /// against 51 that failed anyway.
  ///
  /// So the retry is now the RECONNECT, not a second call on a link whose
  /// discovery is already wedged: one attempt, then [_setupConnection] drops the
  /// link for real (see the `catch` there) and the controller's backoff decides
  /// whether to come back. That also halves the round — 8 s instead of 16 s.
  ///
  /// ⚠️ Do not put this back to 2 without reading design 0031 §4.2. The other
  /// half of the fix — giving the plugin the deadline via
  /// `discoverServices(timeout:)`, so its own `finally` releases the mutex — is
  /// deliberately NOT done yet: it moves the CCCD path that FB-45 shares, and it
  /// changes the exception type the whole corpus greps for.
  static int discoverAttemptsFor({required bool isIOS}) => 1;

  /// How long to wait for the "you are disconnected" confirmation when tearing
  /// down a link whose GATT setup just failed.
  ///
  /// flutter_blue_plus defaults to 35 s. On a failure path that is nonsense:
  /// nothing downstream needs the confirmation, and the user is already looking
  /// at a spinner. 5 s is the number this app already uses for "a BLE operation
  /// that has not come back is not coming back" ([keepAliveWriteTimeout]);
  /// reusing that judgement beats minting a second one.
  static const Duration setupFailureDisconnectTimeout = Duration(seconds: 5);

  /// Our own CCCD-enable timeout — again SHORTER than the plugin's 15 s.
  ///
  /// FB-45. `b64c5b5` (v0.6.13) gave service discovery a timeout and a retry
  /// and left the line under it bare, so `setNotifyValue(true)` still inherited
  /// the plugin's 15 s. Two field captures show the same shape to the tenth of
  /// a second — `2026.07.31/005` session 66 on 0.6.12 and `2026.08.01/007`
  /// session 14 on 0.6.13: connected, GATT dump fine, frames ALREADY arriving
  /// (the peripheral was still notifying from the previous subscription), then
  /// exactly 15.0 s later the CCCD write gives up and the link is dropped.
  /// `ready` is never published, so the dashboard stays empty while history
  /// keeps filling — the user's words were "history shows connected, the main
  /// screen never comes up".
  ///
  /// 5 s, because this is a WRITE and not a discovery. Enabling notifications
  /// is one two-byte CCCD write — an ATT round trip on the order of a
  /// connection interval — whereas discovery walks the whole GATT table. The
  /// app already has a considered number for "a write that has not come back is
  /// not coming back": [keepAliveWriteTimeout], 5 s, several poll periods.
  /// Reusing that judgement is better than minting a second one.
  ///
  /// ⚠️ Like [discoverTimeout] this is an ESTIMATE, not a measured optimum. No
  /// capture holds a CCCD enable that was slow and then SUCCEEDED, so there is
  /// no distribution to fit — only the failures (15.0 s, twice) and two hard
  /// constraints: it must be under the plugin's 15 s or it never fires, and
  /// [notifyAttempts] × this must keep the whole setup budget under what it
  /// replaces. Revisit once a field capture can measure a successful one.
  static const Duration notifyTimeout = Duration(seconds: 5);

  /// CCCD-enable attempts. Two, for the same reason discovery gets two: the
  /// captures show a link that is otherwise healthy — services discovered,
  /// notifications flowing — thrown away on a single stuck write. 2 × 5 s is
  /// still a THIRD less wall clock than the single 15 s it replaces.
  static const int notifyAttempts = 2;

  /// Connect timeout to use on [isIOS].
  static Duration connectTimeoutFor({required bool isIOS}) =>
      isIOS ? iosConnectTimeout : androidConnectTimeout;

  /// Run [action] under [timeout], retrying up to [attempts] times, reporting
  /// each failure through [onFailure] and rethrowing the last one if none
  /// succeed.
  ///
  /// Extracted so the two GATT-setup steps share ONE policy rather than two
  /// copies that can drift, and so the policy itself is testable without a live
  /// peripheral — which is the whole reason FB-45 survived FB-23's fix: the
  /// retry lived inside `_discoverServices` and could not be applied to
  /// anything else without being written out again.
  ///
  /// Every failure is logged, including the ones a later attempt recovers from:
  /// a capture where setup fails once and then succeeds looks identical to one
  /// that succeeded first time unless the failures are written down.
  static Future<T> withTimeoutRetry<T>(
    Future<T> Function() action, {
    required Duration timeout,
    required int attempts,
    required void Function(int attempt, int of, Object error) onFailure,
  }) async {
    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        return await action().timeout(timeout);
      } catch (e) {
        lastErr = e;
        onFailure(attempt, attempts, e);
      }
    }
    throw lastErr!;
  }

  // ---- outbound streams ----
  final StreamController<TelemetrySample> _telemetry =
      StreamController<TelemetrySample>.broadcast();
  final StreamController<DeviceMetadata> _deviceMetadata =
      StreamController<DeviceMetadata>.broadcast();
  final StreamController<BleLinkState> _link =
      StreamController<BleLinkState>.broadcast();
  final StreamController<List<DiscoveredDevice>> _scan =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final StreamController<BlePacketEvent> _packets =
      StreamController<BlePacketEvent>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();

  BleLinkState _state = BleLinkState.disconnected;
  final Map<String, DiscoveredDevice> _scanSeen = {};

  /// Decoded telemetry snapshots — one per inbound register update.
  Stream<TelemetrySample> get telemetry => _telemetry.stream;

  /// Device-metadata snapshots. On the open build the
  /// injected parser is [NoopMetadataParser], so this stream never emits and the
  /// value stays [EmptyDeviceMetadata]. A closed build injects a real parser.
  Stream<DeviceMetadata> get deviceMetadata => _deviceMetadata.stream;

  /// Connection lifecycle.
  Stream<BleLinkState> get linkState => _link.stream;

  /// Deduplicated scan results (filtered on the vendor service).
  Stream<List<DiscoveredDevice>> get scanResults => _scan.stream;

  /// Raw TX/RX wire events for the diagnostics packet log (DEFAULT OFF — the
  /// controller decides whether to subscribe/persist).
  Stream<BlePacketEvent> get packets => _packets.stream;

  /// One-line transport diagnostics for the ALWAYS-ON event log.
  ///
  /// FB-53. Deliberately not [packets]: that stream is the raw-packet log,
  /// which is off by default, and the captures that most need explaining are
  /// exactly the ones that arrive with it off. The controller forwards this
  /// straight onto its event path, the same one `link: ready` uses — the
  /// precedent is `_logUnrecognisedDeviceType`, for the same reason.
  ///
  /// Volume is a few lines per connection, not per frame.
  Stream<String> get diagnostics => _diagnostics.stream;

  /// Adapter (radio) on/off/unauthorized state.
  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  /// Opt into CoreBluetooth state restoration (design 0060 §3.8 / FB-67).
  ///
  /// 🔴 CALL SITE IS LOAD-BEARING, and there is exactly one that works:
  /// `bootstrap()`, after `WidgetsFlutterBinding.ensureInitialized()` and
  /// BEFORE `AppServices.create`. The plugin passes
  /// `CBCentralManagerOptionRestoreIdentifierKey` only at the moment it
  /// CONSTRUCTS the `CBCentralManager`, behind a one-shot
  /// `if (self.centralManager == nil)` guard, and it constructs it lazily on the
  /// first platform call that is not `setLogLevel`/`setOptions`. Ours is
  /// `ConnectionController`'s constructor subscribing to [adapterState], which
  /// makes `getAdapterState` — so anything after that point is silently a no-op.
  /// It is also why this must NOT move into `AppServices.create`: 37 test suites
  /// build one, and none of them have a platform to answer.
  ///
  /// That laziness is also what makes restoration work at all after a background
  /// wake: `willRestoreState:` cannot be delivered until the manager exists, and
  /// the plugin hooks nothing into app launch — so Dart must touch FBP on every
  /// launch. It already does, on the same line as above.
  ///
  /// BOTH named arguments are passed explicitly. They both default, so passing
  /// one resets the other; `showPowerAlert: true` is the plugin's own default
  /// and is written out so "we did not change that one" is visible in source
  /// rather than inferred from an absence.
  ///
  /// Android is unaffected — the plugin documents the option as iOS/macOS only —
  /// so there is deliberately no platform branch to keep in step.
  static Future<void> enableStateRestoration() =>
      FlutterBluePlus.setOptions(showPowerAlert: true, restoreState: true);

  /// Current link state (latest value of [linkState]).
  BleLinkState get currentState => _state;

  /// Latest accumulated telemetry snapshot (folds prior frames).
  TelemetrySample get currentSample => _current?.decoder.sample ?? _noTelemetry;

  /// Latest accumulated engineering metadata (opaque; empty on the open build).
  DeviceMetadata get currentDeviceInfo =>
      _current?.decoder.deviceMetadata ?? const EmptyDeviceMetadata();

  /// Remote id of the connected/connecting device, or null.
  String? get connectedDeviceId => _current?.device?.remoteId.str;

  /// Advertised name of the connected device (e.g. "RCE-SCAP_II"), or ''.
  String get connectedDeviceName => _current?.device?.platformName ?? '';

  /// True while a scan is in progress.
  bool get isScanning => FlutterBluePlus.isScanningNow;

  /// Live scanning flag stream.
  Stream<bool> get scanning => FlutterBluePlus.isScanning;

  // ---------------------------------------------------------------------------
  // Permissions / adapter
  // ---------------------------------------------------------------------------

  /// Requests the runtime permissions BLE needs. On Android 12+ the critical
  /// pair is BLUETOOTH_SCAN + BLUETOOTH_CONNECT; pre-12 devices fall back to
  /// location for scanning. Returns true when scanning + connecting are allowed.
  Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true; // iOS prompts on first BLE use.

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locationOk =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    // On Android 12+, bluetoothScan/Connect are the source of truth. On <12 the
    // plugin reports those as granted and gates scanning on location instead.
    return (scanOk && connectOk) || locationOk;
  }

  /// Request POST_NOTIFICATIONS (Android 13+) for the ongoing notification of
  /// the Android foreground service — the thing that stops the OS freezing this
  /// process (and with it the 1 Hz keep-alive) once the screen goes off.
  ///
  /// Deliberately returns void and never throws: the caller must not gate the
  /// foreground service on the outcome. Denying it hides the notification but
  /// leaves monitoring — and the BLE link — running.
  Future<void> ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await Permission.notification.request();
    } catch (_) {
      // No plugin channel (tests) or an OEM that rejects the request.
    }
  }

  /// True if the Bluetooth adapter is currently on.
  Future<bool> isAdapterOn() async {
    if (await FlutterBluePlus.isSupported == false) return false;
    return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Start scanning. We deliberately do NOT pass `withServices`: many devices
  /// (incl. this hardware) do not advertise their 128-bit service UUID in the
  /// advertisement packet, so an OS-level service filter would hide them. We
  /// scan everything and filter in [_onScanResults] (keep named devices and any
  /// that DO advertise the vendor service). Results arrive on [scanResults].
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (FlutterBluePlus.isScanningNow) return;
    // D.1: on iOS the CBCentralManager transitions `.unknown` → `.poweredOn`
    // asynchronously (a few hundred ms after first init, and only once the
    // permission dialog is resolved). Calling startScan before the adapter is
    // on throws a FlutterBluePlusException — so wait (bounded) for `on` first.
    await _awaitAdapterOn(const Duration(seconds: 6));
    _scanSeen.clear();
    _scan.add(const []);
    // D.1: do NOT swallow the "Bluetooth must be turned on" / unauthorized
    // failure — let it propagate so the controller can surface a real UI error
    // (and distinguish off vs unauthorized via the adapter state).
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidScanMode: AndroidScanMode.lowLatency,
    );
  }

  /// Wait until the Bluetooth adapter reports `on`, bounded by [timeout]. On
  /// timeout we fall through (the subsequent startScan will throw the
  /// FlutterBluePlusException the caller surfaces).
  Future<void> _awaitAdapterOn(Duration timeout) async {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) return;
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(timeout);
    } on TimeoutException {
      // Fall through — startScan will throw and the controller reports it.
    }
  }

  /// Deep-link to the OS app-settings page (D.2): used when Bluetooth
  /// permission is `unauthorized` so the user can grant it. Returns true if the
  /// settings page was opened.
  Future<bool> openBluetoothSettings() => openAppSettings();

  /// Stop an in-progress scan.
  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  void _onScanResults(List<ScanResult> results) {
    var changed = false;
    for (final r in results) {
      final id = r.device.remoteId.str;
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      // Vendor if it advertises our service UUID (most precise) OR its name
      // carries a vendor token. See [looksLikeVendorName] for why this is a
      // token-prefix match rather than `startsWith` or `contains`.
      final isVendor =
          r.advertisementData.serviceUuids.contains(_serviceGuid) ||
              looksLikeVendorName(name);
      final existing = _scanSeen[id];
      if (existing == null ||
          existing.rssi != r.rssi ||
          existing.name != name ||
          existing.isVendor != isVendor) {
        _scanSeen[id] = DiscoveredDevice(
          id: id,
          name: name,
          rssi: r.rssi,
          isVendor: isVendor,
        );
        changed = true;
      }
    }
    if (changed) {
      // RCE (vendor) devices first, then by signal strength.
      final list = _scanSeen.values.toList()
        ..sort((a, b) {
          if (a.isVendor != b.isVendor) return a.isVendor ? -1 : 1;
          return b.rssi.compareTo(a.rssi);
        });
      _scan.add(list);
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connect to [deviceId], discover the GATT characteristics, enable notify,
  /// and begin streaming telemetry + keep-alives. Tears down any prior link
  /// first. Emits [BleLinkState] transitions on [linkState].
  Future<void> connect(String deviceId,
      {Duration? timeout, bool autoConnect = false}) async {
    // FB-39: open a new epoch BEFORE anything else, so a setup already awaiting
    // for the previous device abandons itself instead of publishing `ready`
    // over the top of this one. `disconnect()` opens another; both invalidate
    // the same older work, and opening twice is harmless.
    //
    // Per-link now, so the sweep is over every link that exists. With one link
    // that is the same single bump it always was; with several it is still the
    // right rule for THIS call, because a manual connect is a request to be on
    // one unit — it is `disconnect()` below, not the epoch, that decides how
    // many links survive.
    _invalidateAllLinks();
    await disconnect();
    await stopScan();

    final device = BluetoothDevice.fromId(deviceId);
    final link = _LinkState(
        deviceId: deviceId, device: device, parser: _parser);

    // A fresh connect starts from a clean slate. Dropping the entries is what
    // the old `_reassembler.reset(); _decoder.reset(); _settingUp = false;`
    // did — a new [_LinkState] simply cannot carry the previous unit's buffer,
    // accumulated sample or half-finished setup into this one.
    //
    // This line used to read `_links.clear()`, and the `await disconnect()`
    // above was trusted to have already torn down whatever it dropped. It had
    // not, whenever a second `connect()` overtook the first inside that await:
    // the entry vanished and its owner kept streaming. [_installLink] makes
    // the two inseparable.
    //
    // ⚠️ NOTHING BETWEEN HERE AND THE `listen()` BELOW MAY `await`. The
    // displacement and this link's own subscription have to land in one
    // synchronous frame, or a concurrent `connect()` fits between them and we
    // are back to a live link nobody can reach. See [_dropAllLinks].
    _installLink(link);
    _current = link;
    _setState(BleLinkState.connecting);

    // Stamp the subscription's own zero point BEFORE creating it: the first
    // value it delivers arrives one microtask later, and `sub=0ms` in the
    // `conn-state:` line is what identifies it as the plugin's replayed cache
    // value rather than anything the radio said.
    link.connSubAt = DateTime.now();
    link.connSub =
        device.connectionState.listen((s) => _onConnectionState(link, s));

    if (autoConnect) {
      // Seamless reconnect: register a PENDING connection and let the OS
      // (CoreBluetooth on iOS) reconnect the moment the peripheral reappears.
      // connect() returns immediately here — the connectionState listener above
      // drives setup once actually connected. mtu must be null with autoConnect;
      // there is no timeout and no app-level retry loop (the OS holds it). Used
      // only for re-connecting a link that was previously healthy (a dropped,
      // known-good device), never for a first connect to a possibly-stale id.
      link.retryingConnect = false;
      try {
        await device.connect(mtu: null, autoConnect: true);
      } catch (e) {
        await _teardown(link, emitDisconnected: true);
        rethrow;
      }
      return;
    }

    // D.4: platform-gate the retry. Android BLE frequently fails the FIRST
    // connect attempt (connects then immediately disconnects) and fails fast on
    // a stale handle, so retrying a few times lets the user tap only once. iOS
    // has no native connect timeout and a stale NSUUID never resolves, so a
    // single short-timeout attempt surfaces the error in seconds instead of
    // multiplying the freeze. Suppress teardown on transient drops during the
    // (Android) retry window — and ONLY that. FB-53: this flag no longer
    // doubles as the filter on the plugin's replayed subscription value, which
    // is why iOS (attempts = 1) is no longer defenceless against it. See
    // [linkActionFor].
    final isIOS = Platform.isIOS;
    final attempts = connectAttemptsFor(isIOS: isIOS);
    final effTimeout = timeout ?? connectTimeoutFor(isIOS: isIOS);
    link.retryingConnect = attempts > 1;
    Object? lastErr;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        // mtu:null => no MTU negotiation (work within the default ATT MTU 23).
        await device.connect(mtu: null, timeout: effTimeout);
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        if (attempt < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
    }
    link.retryingConnect = false;
    if (lastErr != null) {
      await _teardown(link, emitDisconnected: true);
      throw lastErr;
    }
  }

  /// Open a new epoch on every link that exists, invalidating any setup already
  /// mid-await. See [ConnectEpoch] and the note in [_links] on why an entry
  /// outlives its own teardown.
  void _invalidateAllLinks() {
    for (final link in _links.values) {
      link.epoch.begin();
    }
  }

  /// Take every entry out of [_links], tearing each one down on the way out.
  ///
  /// **The only removal path**, and the reason it exists is the invariant on
  /// [_links]: a link that leaves the map still owns its `connectionState` and
  /// notify subscriptions, its keep-alive timer, its reassembler, decoder, tick
  /// counter and write histogram — and nothing above the transport can reach it
  /// any more, so if the removal does not tear it down, nothing ever will.
  /// Removal and teardown are one statement here so they cannot drift apart
  /// again the way `_links.clear()` had drifted from `await disconnect()`.
  ///
  /// `emitDisconnected: false` because a displaced link is not a link-state
  /// transition anyone should see: [connect] publishes `connecting` in the same
  /// frame, and [dispose] is closing the stream. A drop is bookkeeping; the
  /// user-visible drop is [disconnect]'s.
  ///
  /// ⚠️ SYNCHRONOUS WHERE IT MATTERS. Everything that has to happen before the
  /// caller yields — the map write, and both `cancel()` calls inside
  /// [_teardown] — has happened by the time this returns; only *waiting* for
  /// the cancels to complete is deferred into the returned future. That is why
  /// [_installLink] can leave the future alone while [dispose], which is about
  /// to close the streams [_teardown] writes to, awaits it.
  Future<void> _dropAllLinks() {
    final dropped = _links.values.toList(growable: false);
    _links.clear();
    return Future.wait<void>(<Future<void>>[
      for (final link in dropped)
        // Teardown must not be able to abort the loop or surface as an
        // unhandled async error on the fire-and-forget path; a cancel that
        // fails still leaves the link out of the map and the timer stopped.
        _teardown(link, emitDisconnected: false).catchError(
            (Object e) => _emitEvent('link teardown failed: $e', link: link)),
    ]);
  }

  /// Make [link] the only entry of [_links], tearing down whatever it displaces.
  ///
  /// **The only insertion path**, so that "a link entered the map" and "the
  /// links it replaced were torn down" are the same event.
  ///
  /// ⚠️ THE TRAP, and the reason this does NOT ask the platform to disconnect
  /// what it displaces: the displaced link and the new one are typically THE
  /// SAME PHYSICAL CONNECTION to the same unit — that is how a doubled GATT
  /// setup arises at all, two `connect()` calls for one id. A `disconnect` on
  /// the way out would therefore drop the connection the new link is being
  /// built on, turning a data-doubling bug into a connectivity one.
  /// [_teardown] is safe to reuse here precisely because it touches nothing
  /// below Dart: it cancels THIS app's subscriptions and timers and forgets the
  /// handle. It also does not disable notifications on the peripheral, and must
  /// not — the new link wants them left on.
  ///
  /// What that leaves open is stated rather than hidden: if the displaced link
  /// belonged to a DIFFERENT unit and its `device.connect()` was still in
  /// flight, nothing here releases that peripheral. Releasing it is
  /// [disconnect]'s job, which [connect] awaits before it gets here; the race
  /// that can slip a link past it is the same one this method closes on the
  /// Dart side, and closing the Dart side is what the ruling asked for.
  void _installLink(_LinkState link) {
    // Deliberately not awaited: this method must not yield (see the ⚠️ in
    // [connect]), and everything order-sensitive in [_dropAllLinks] has already
    // run by the time it returns.
    unawaited(_dropAllLinks());
    _links[link.deviceId] = link;
  }

  Future<void> _onConnectionState(
      _LinkState link, BluetoothConnectionState s) async {
    // Phase 0 instrument, before anything can await: a backlogged event
    // delivered on thaw must be measured against the last pre-suspension tick.
    _checkExecGap('conn-state');
    // Capture WHY the link dropped (A: cross-platform disconnect diagnostics)
    // before anything decides what to do about it, and before a teardown can
    // clear the device handle. Reading it first is also what lets the reason
    // into the diagnostic line below — and the reason is itself evidence about
    // which kind of event this is. A real drop carries its own; a replayed
    // cache value carries the PREVIOUS drop's reason, or none at all
    // (`2026.08.03/004` 20:33:00.278 — a peripheral this install had never
    // connected to, reporting a disconnect with no code).
    final reason = link.device?.disconnectReason;
    final action = linkActionFor(s,
        sawConnected: link.sawConnected, retryingConnect: link.retryingConnect);
    _logConnectionState(link, s, reason, action);
    if (s == BluetoothConnectionState.disconnected) {
      _lastDisconnect = reason == null
          ? null
          : 'code=${reason.code} ${reason.description ?? ''}'.trim();
    }
    if (action == LinkAction.setup) {
      // Synchronously, and BEFORE the await. `_setupConnection` holds this
      // frame for the whole GATT budget (8 s discovery + 2 × 5 s CCCD enable),
      // and a genuine drop inside that window has to still read as a drop. Set
      // after the await, this flag would swallow one for up to ~18 s — which is
      // the very window FB-51 exists to shorten.
      link.sawConnected = true;
      await _setupConnection(link);
    } else if (action == LinkAction.teardown) {
      await _teardown(link, emitDisconnected: true);
    }
  }

  /// One always-on line per connection-state event (FB-53 / P2 instrument):
  ///
  ///     conn-state: <state> reason=<code|null> sub=<n>ms decision=<action>
  ///
  /// It carries three things no other line in a field capture can:
  ///
  ///   * `sub` — how old the `connectionState` subscription was when the event
  ///     landed. The plugin's replayed cache value arrives on the first
  ///     microtask, so it reads 0 ms; a radio event cannot.
  ///   * `decision` — including `ignore`, which by construction changes no
  ///     other state and would otherwise leave the log looking like the
  ///     listener never fired at all.
  ///   * `reason` — the disconnect code as it stood BEFORE teardown cleared
  ///     the handle.
  ///
  /// It is also the acceptance test for this whole fix: on the shipped build
  /// the count of `decision=teardown` lines with `sub=0ms` should be zero,
  /// against 906 in the corpus that produced the diagnosis.
  ///
  /// On [diagnostics], never [_emitEvent]: the latter goes to the raw-packet
  /// log, which is off by default and therefore absent from the field.
  void _logConnectionState(_LinkState link, BluetoothConnectionState s,
      DisconnectReason? reason, LinkAction action) {
    final sub = DateTime.now().difference(link.connSubAt).inMilliseconds;
    _diagnostics.add('conn-state: ${s.name} reason=${reason?.code ?? 'null'} '
        'sub=${sub}ms decision=${action.name}');
  }

  /// Discover services under [discoverTimeout], retrying once — two attempts of
  /// 8 s still bound the wait tighter than the single 15 s they replace.
  ///
  /// Each timeout is logged: a capture where discovery fails and then succeeds
  /// looks identical to one where it succeeded first time, unless the failures
  /// are written down.
  Future<List<BluetoothService>> _discoverServices(
          _LinkState link, BluetoothDevice device) =>
      withTimeoutRetry(
        device.discoverServices,
        timeout: discoverTimeout,
        attempts: discoverAttemptsFor(isIOS: Platform.isIOS),
        onFailure: (attempt, of, e) => _emitEvent(
            'service discovery attempt $attempt/$of failed: '
            '${gattSetupFailureReason(e)}',
            link: link),
      );

  /// Enable notifications under [notifyTimeout], retrying once — FB-45.
  ///
  /// The line this replaces was `await notify.setNotifyValue(true);`, bare, and
  /// it is the other half of the fault FB-23 fixed: an unowned timeout on a
  /// stream-listener code path, whose failure the app could only report after
  /// the plugin had already decided how long to wait.
  Future<void> _enableNotify(
          _LinkState link, BluetoothCharacteristic notify) =>
      withTimeoutRetry(
        () => notify.setNotifyValue(true),
        timeout: notifyTimeout,
        attempts: notifyAttempts,
        // The exception text is kept verbatim: `fbp-code: 1 | Timed out after
        // 15s` is the string eleven collected batches were grepped for, and the
        // prefix is what finally says WHICH setup step produced it.
        onFailure: (attempt, of, e) =>
            _emitEvent('notify enable attempt $attempt/$of failed: $e',
                link: link),
      );

  Future<void> _setupConnection(_LinkState link) async {
    final device = link.device;
    if (device == null || link.settingUp || _state == BleLinkState.ready) {
      return;
    }
    // FB-39: everything below this line writes state OTHER callers can also
    // reach, so it must not run if a newer connect has taken over while we were
    // awaiting. The epoch is this link's own, so a future third connect can
    // invalidate this setup without touching an unrelated link's.
    final epoch = link.epoch.current;
    link.settingUp = true;
    _setState(BleLinkState.connected);

    try {
      final services = await _discoverServices(link, device);
      // Superseded: a newer connection now owns the shared fields. Abandon
      // QUIETLY — no state change, and above all no teardown, which would tear
      // down the link the user actually asked for.
      if (!link.epoch.isCurrent(epoch)) return;
      link.writeChar = null;
      link.notifyChar = null;

      // Prefer characteristics under the vendor service, but fall back to a
      // full sweep — the service linkage is inferred, not byte-fixed.
      for (final svc in services) {
        final preferred = svc.uuid == _serviceGuid;
        for (final c in svc.characteristics) {
          if (c.uuid == _writeGuid && (link.writeChar == null || preferred)) {
            link.writeChar = c;
          }
          if (c.uuid == _notifyGuid && (link.notifyChar == null || preferred)) {
            link.notifyChar = c;
          }
        }
      }

      // Diagnostic: dump the full GATT table (svc/char UUID + properties) to the
      // capture log. Confirmed the metadata burst (VADJ 0x30 / dealer 0x27) rides
      // the single notify char ace4 — there is NO second notify channel
      // (PROTOCOL.md §10.2), so we subscribe to ace4 only.
      _dumpGatt(link, services);

      final notify = link.notifyChar;
      if (link.writeChar == null || notify == null) {
        throw StateError(
            'GATT characteristics not found (write=${link.writeChar != null}, '
            'notify=${notify != null})');
      }

      // Subscribe BEFORE the first write (PROTOCOL.md §2). setNotifyValue(true)
      // writes the CCCD enable value [0x01, 0x00].
      final mySub = notify.onValueReceived.listen((c) => _onNotify(link, c));
      link.notifySub = mySub;
      await _enableNotify(link, notify);

      // Second guard: the CCCD write is the other await this method spans.
      if (!link.epoch.isCurrent(epoch)) {
        // Reclaim only OUR subscription. If a newer setup has already replaced
        // the field, cancelling would silence the live device.
        if (identical(link.notifySub, mySub)) link.notifySub = null;
        await mySub.cancel();
        return;
      }

      _startKeepAlive(link);
      _setState(BleLinkState.ready);
    } catch (e) {
      // FB-23: do NOT rethrow. The only caller is a `connectionState` stream
      // listener, so a rethrow reaches no handler — it just becomes an
      // `Uncaught:` line, which is all the field capture ever showed. Write a
      // readable reason instead and let the disconnect drive the normal
      // reconnect path.
      _emitEvent('gatt setup failed: ${gattSetupFailureReason(e)}', link: link);
      if (link.epoch.isCurrent(epoch)) {
        await _releaseAfterSetupFailure(link, device);
        await _teardown(link, emitDisconnected: true);
      }
    } finally {
      link.settingUp = false;
    }
  }

  /// Actually drop the link after a failed GATT setup — FB-51 (e), design 0031.
  ///
  /// [_teardown] never did this. It cancels subscriptions and sets
  /// `link.device = null`, and `connect()`'s opening `await disconnect()` bails
  /// on `if (device == null) return` — which is the field it was just handed.
  /// So NOTHING in this app ever asked the platform to drop a link whose setup
  /// had failed. `2026.08.03/003` is what that looks like from outside: thirteen
  /// connections, no `ready`, no frames, for fourteen minutes, and the only
  /// thing that recovered it was the user killing the app — which is also the
  /// only thing that tears down the CBCentralManager.
  ///
  /// `queue: false` is REQUIRED here, not a tuning choice. The default takes the
  /// same `"global"` mutex the abandoned discovery is still holding, so the
  /// cancel would queue behind the very call it is cancelling and wait out the
  /// plugin's 15 s. flutter_blue_plus documents the flag for exactly this:
  /// "skipping to the front of the fbp operation queue, which is useful to
  /// cancel an in-progress connection attempt".
  ///
  /// Failure is swallowed on purpose: this runs on the way out of a path that
  /// has already failed, and every caller's next move is [_teardown] regardless.
  Future<void> _releaseAfterSetupFailure(
      _LinkState link, BluetoothDevice device) async {
    try {
      await dropLink(device);
    } catch (e) {
      _emitEvent('setup-failure disconnect failed: $e', link: link);
    }
  }

  /// The platform call [_releaseAfterSetupFailure] makes, on its own so a test
  /// can stand in for it — a real `disconnect` needs a radio, and the thing
  /// worth locking down is that the failure path does not rethrow.
  ///
  /// ⚠️ The two arguments are the whole point and neither is a default:
  /// `queue: false` skips the mutex the abandoned discovery still holds, and the
  /// timeout replaces a 35 s wait nobody is left to care about.
  @visibleForTesting
  Future<void> dropLink(BluetoothDevice device) => device.disconnect(
        queue: false,
        timeout: setupFailureDisconnectTimeout.inSeconds,
      );

  /// Handle a notification chunk from [link]'s notify characteristic.
  void _onNotify(_LinkState link, List<int> chunk) {
    // Phase 0 instrument: a notify is the event most likely to end a
    // suspension window once a background mode exists, and today it is what
    // bounds the window from the app side. One line per gap — the first
    // backlogged chunk re-ticks the tracker, so the rest stay quiet.
    _checkExecGap('notify');
    // Phase 1 (design 0047 §3.2): while backgrounded on iOS this notify IS the
    // execution window — ride it with a keep-alive write when the last
    // successful one is a full interval old, so the device keeps streaming
    // without the frozen timer. The in-flight check is the same re-entrancy
    // rule the timer path obeys (and keeps the paced-send count honest); the
    // pacer's own debounce is what turns a thawed backlog into ONE send
    // (FB-53 / R2). `_sendKeepAlive` still ticks [_execGap] first, so the
    // Phase 0 "Dart executed" heartbeat semantics are identical on both paths.
    if (!link.keepAliveInFlight &&
        _pacer.shouldSend(
            lastWriteOk: link.lastKeepAliveOkAt, now: DateTime.now())) {
      unawaited(_sendKeepAlive(link));
    }
    _packets.add(BlePacketEvent(LogDirection.rx, List<int>.unmodifiable(chunk),
        deviceId: link.deviceId));
    final frames = link.reassembler.addBytes(chunk);
    final now = DateTime.now();
    final infoBefore = link.decoder.deviceMetadata;
    var emitted = false;
    for (final f in frames) {
      if (!f.checksumOk) continue;
      final before = link.decoder.sample;
      final after = link.decoder.ingest(f, at: now);
      if (!identical(before, after)) {
        emitted = true;
      }
    }
    if (emitted) {
      // 🔴 FB-88 / design 0078 (M1-b): stamp WHOSE frame this is on the way
      // out. This is the ONE place a telemetry sample leaves this service, and
      // `link` — the per-device state the whole class is keyed by — is right
      // here. Publishing without it is what flattened a per-device transport
      // into an anonymous stream, and an anonymous stream is what let a
      // torn-down link's frames be measured against the NEXT unit's identity
      // yardstick: the controller's design 0068 (C) guard, which is FB-25's
      // fix, then dropped a perfectly good link as `wrong_device`. Two field
      // teardowns, 49 ms and 3,240 ms wide, are the window (`2026.08.18/008`).
      //
      // ⚠️ Stamped with `copyWith` here rather than carried inside the decoder
      // on purpose. The decoder is per link but knows nothing about ids, and
      // the instance it accumulates is the SAME object `currentSample` hands
      // out — mutating identity into it would put a transport fact inside the
      // decode. `copyWith` leaves the accumulation untouched and gives the
      // stream its own stamped view.
      _telemetry.add(link.decoder.sample.copyWith(deviceId: link.deviceId));
    }
    // Device-metadata side-channel. On the open build
    // the Noop parser never changes it, so this never fires.
    if (!identical(infoBefore, link.decoder.deviceMetadata)) {
      _deviceMetadata.add(link.decoder.deviceMetadata);
    }
  }

  /// Emit a diagnostic note line into the packet log (an EVT row), attributed to
  /// [link] when there is one.
  void _emitEvent(String message, {_LinkState? link}) {
    _packets.add(BlePacketEvent(LogDirection.event, const [],
        note: message, deviceId: link?.deviceId));
  }

  /// Dump every service/characteristic (UUID + property flags) to the log, so a
  /// second notify channel is visible. Diagnostic only.
  void _dumpGatt(_LinkState link, List<BluetoothService> services) {
    _emitEvent('GATT dump: ${services.length} service(s)', link: link);
    for (final svc in services) {
      for (final c in svc.characteristics) {
        final p = c.properties;
        final flags = [
          if (p.read) 'R',
          if (p.write) 'W',
          if (p.writeWithoutResponse) 'w',
          if (p.notify) 'N',
          if (p.indicate) 'I',
        ].join();
        _emitEvent('GATT svc=${svc.uuid.str} char=${c.uuid.str} [$flags]',
            link: link);
      }
    }
  }

  /// Disconnect the current device and reset state.
  Future<void> disconnect() async {
    // FB-39: bump before the early return too. A disconnect requested while a
    // setup is mid-await must invalidate it even when the plugin handle has
    // already been cleared — that is exactly the window the guard exists for,
    // and it is why a [_LinkState] outlives its own teardown.
    _invalidateAllLinks();
    final link = _current;
    final device = link?.device;
    if (link == null || device == null) return;
    _setState(BleLinkState.disconnecting);
    try {
      await device.disconnect();
    } catch (_) {
      // Ignore: teardown still proceeds via the connectionState callback.
    }
    await _teardown(link, emitDisconnected: true);
  }

  /// Fold one successful write's duration into [link]'s histogram, and emit the
  /// running summary every [writeStatsEvery] writes.
  ///
  /// Cumulative rather than per-window: the last line of a session is then the
  /// whole session, which is what an offline reader wants. Reading two lines
  /// and subtracting is still possible; reconstructing a total from windows
  /// that a disconnect may have truncated is not.
  void _recordWriteDuration(_LinkState link, int ms) {
    link.writeOkCount++;
    link.writeMsTotal += ms;
    if (ms > link.writeMsMax) link.writeMsMax = ms;
    var i = 0;
    while (i < writeStatsBucketsMs.length && ms >= writeStatsBucketsMs[i]) {
      i++;
    }
    link.writeMsBuckets[i]++;
    if (link.writeOkCount % writeStatsEvery == 0) _emitWriteStats(link);
  }

  /// One greppable line: `keep-alive write ms: n=… avg=… max=… [<100:0 …]`.
  void _emitWriteStats(_LinkState link) {
    if (link.writeOkCount == 0 ||
        link.writeOkCount == link.writeStatsReported) {
      return;
    }
    link.writeStatsReported = link.writeOkCount;
    final b = StringBuffer();
    for (var i = 0; i < link.writeMsBuckets.length; i++) {
      if (i > 0) b.write(' ');
      final edge = i < writeStatsBucketsMs.length
          ? '<${writeStatsBucketsMs[i]}'
          : '>=${writeStatsBucketsMs.last}';
      b.write('$edge:${link.writeMsBuckets[i]}');
    }
    final avg = (link.writeMsTotal / link.writeOkCount).round();
    _emitEvent(
        'keep-alive write ms: n=${link.writeOkCount} avg=$avg '
        'max=${link.writeMsMax} [$b]',
        link: link);
  }

  Future<void> _teardown(_LinkState link,
      {required bool emitDisconnected}) async {
    // Any GATT setup still in flight for this link abandons at its next
    // checkpoint (FB-39's epoch, see [_setupConnection]). Cancelling
    // subscriptions is not sufficient on its own, because a setup that has not
    // reached them yet will simply create them again: it resumes with a
    // `services` list fetched before the link died, subscribes notify, starts
    // the keep-alive and publishes `ready` — a link that was torn down, back
    // on its feet with nothing pointing at it. That is the second half of the
    // 2026-08-13 double-setup fault; the drop path closes the map side of it
    // (see [_dropAllLinks]) and this line closes the time side.
    //
    // Every other caller wanted this too and only got it by accident: a real
    // disconnect arriving mid-setup used to let that setup finish and re-arm a
    // dead handle, and `disconnect()` had to bump the epoch itself beforehand
    // to prevent the same thing.
    link.epoch.begin();
    // Flush the histogram before the link goes quiet: a session shorter than
    // writeStatsEvery would otherwise report nothing at all, and short sessions
    // are exactly the ones a slow unit produces.
    _emitWriteStats(link);
    link.keepAlive?.cancel();
    link.keepAlive = null;
    link.keepAliveTick = 0;
    // The tick source above just stopped; without this, the idle stretch until
    // the next connection's events would read as an execution gap.
    _execGap.reset();
    // A dead link has no notify path to pace. Closing the window here (rather
    // than waiting for the controller to observe the disconnect) also puts the
    // `bg-keepalive:` summary next to the teardown lines that explain it. The
    // controller re-arms on the next `ready` if the app is still backgrounded.
    setNotifyDrivenKeepAlive(false);
    // BOTH cancels are STARTED here, in this method's synchronous prefix, and
    // awaited together at the bottom. Cancelling a subscription stops delivery
    // to it at the moment `cancel()` is called, not when its future completes,
    // so starting both before the first yield is what lets [_dropAllLinks] be
    // safe to call without awaiting: a link removed from `_links` is deaf
    // before the caller's frame ends. `await`-ing the first cancel here — as
    // this method used to — would have pushed the connectionState cancel one
    // microtask past the removal, which is one microtask of a link that is
    // dropped and still listening.
    final notifyCancelled = link.notifySub?.cancel();
    link.notifySub = null;
    link.keepAliveWriteFailed = false;
    final connCancelled = link.connSub?.cancel();
    link.connSub = null;
    link.writeChar = null;
    link.notifyChar = null;
    // Clears "connected" for the getters, but keeps the object: the decoder
    // behind `currentSample` and the epoch behind `disconnect()` both have to
    // survive this, exactly as the service-level fields used to.
    link.device = null;
    link.settingUp = false;
    link.reassembler.reset();
    await notifyCancelled;
    await connCancelled;
    if (emitDisconnected) {
      _setState(BleLinkState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  void _startKeepAlive(_LinkState link) {
    link.keepAlive?.cancel();
    link.keepAliveTick = 0;
    // Tick immediately so telemetry starts without waiting a full second. The
    // first tick sends `!#`, which every device answers with device-type/SOC.
    unawaited(_sendKeepAlive(link));
    link.keepAlive = Timer.periodic(keepAliveInterval, (_) {
      unawaited(_sendKeepAlive(link));
    });
  }

  Future<void> _sendKeepAlive(_LinkState link) async {
    // Phase 0 instrument: this callback runs at 1 Hz while a link is up, so it
    // is the "Dart is executing" heartbeat the gap is measured against. Before
    // every early return, deliberately — a guarded tick still proves the
    // isolate ran.
    _execGap.tick(DateTime.now());
    if (link.writeChar == null) return;
    // Re-entrancy guard. The timer fires every second but a write can hang far
    // longer — when Android suspends the app (screen off / background) BOTH
    // directions stall for minutes, then everything resumes at once. Without
    // this guard each stalled second queued another write, so a 2.5-minute
    // freeze piled up ~150 of them and they all landed on resume.
    //
    // Per link: the guard means "THIS link already has a write out". Shared, a
    // hung write on one unit would swallow every other unit's tick, and the
    // tick schedule below is exactly the thing that must not be skipped.
    if (link.keepAliveInFlight) return;
    link.keepAliveInFlight = true;
    link.keepAliveTick++;
    // Whether the connected unit is a power bank is read from the LATEST decoded
    // telemetry (device-type 0x22); it flips true once the tick-1 `!#` elicits
    // the 0x10 frame, after which the every-5th `!#` schedule kicks in — so both
    // inputs to the schedule have to come from THIS link, not from whichever
    // unit answered most recently.
    final token = keepAliveTokenFor(
      _commands,
      tick: link.keepAliveTick,
      isPowerBank: link.decoder.sample.isPowerBank,
    );
    final sw = Stopwatch()..start();
    try {
      await _writeTo(link, token, timeout: keepAliveWriteTimeout);
      // Debounce zero point for the notify-driven pacer (design 0047 Phase 1).
      // Stamped on success only — see [_LinkState.lastKeepAliveOkAt].
      link.lastKeepAliveOkAt = DateTime.now();
      _recordWriteDuration(link, sw.elapsedMilliseconds);
      // Recovery is as diagnostic as the failure: it bounds how long the app
      // was actually unable to poll, which a lone failure line cannot.
      if (link.keepAliveWriteFailed) {
        _emitEvent(
            'keep-alive write recovered after '
            '${link.keepAliveFailures} consecutive failure(s)',
            link: link);
        link.keepAliveWriteFailed = false;
        link.keepAliveFailures = 0;
      }
    } catch (e) {
      // A failed keep-alive usually means the link dropped; the connectionState
      // callback handles teardown. Surface it once to the diagnostic log — a
      // silent catch here previously hid a write-mode bug that suppressed the
      // metadata burst.
      link.keepAliveFailures++;
      if (!link.keepAliveWriteFailed) {
        link.keepAliveWriteFailed = true;
        // The elapsed time separates "the device rejected it" (fails fast) from
        // "nothing came back" (runs to the timeout) — the 2026-07-27 stalls were
        // the latter, and only the duration says so.
        _emitEvent(
            'keep-alive write failed after ${sw.elapsedMilliseconds}ms: $e',
            link: link);
      }
    } finally {
      link.keepAliveInFlight = false;
    }
  }

  /// Consecutive keep-alive write failures outstanding; 0 when healthy.
  ///
  /// Exposed rather than invented: this counter already existed and was only
  /// ever written to the diagnostic log. It is the honest explanation for a
  /// device class
  /// that never resolves — `0x10` answers the 1 Hz `#` poll, so a poll that
  /// cannot be written is never answered, while notifications subscribed
  /// earlier keep streaming and the link still reports ready (PROTOCOL.md
  /// §10.2). Surfacing it lets the UI say "connection unstable, retrying"
  /// instead of the useless "cannot determine device type".
  ///
  /// It also settles what NOT to build: re-sending `!#` on a stall was the
  /// original proposal, but `!#` is itself a write, so in the only case that
  /// needs it the resend fails too.
  int get keepAliveFailures => _current?.keepAliveFailures ?? 0;

  /// True while the keep-alive write path is known to be broken.
  bool get keepAliveWriteFailed => _current?.keepAliveWriteFailed ?? false;

  // ---------------------------------------------------------------------------
  // Outbound commands
  // ---------------------------------------------------------------------------

  /// Write raw bytes to the write characteristic. Throws [StateError] if not
  /// connected.
  ///
  /// The write char (ace3) advertises **Write (with response, 0x08)** but NOT
  /// Write-Without-Response (0x04). Forcing `withoutResponse: true` throws on
  /// flutter_blue_plus, which silently killed every keep-alive `#` (so the
  /// device never got the poke that triggers the connect metadata burst — VADJ /
  /// serial). Pick the mode from the characteristic's actual properties.
  Future<void> writeCommand(List<int> bytes, {Duration? timeout}) =>
      _writeTo(_current, bytes, timeout: timeout);

  /// Write to ONE link's write characteristic. [writeCommand] is this with the
  /// current link filled in; the keep-alive passes its own link so a tick can
  /// never be delivered to a unit other than the one it was scheduled for.
  Future<void> _writeTo(_LinkState? link, List<int> bytes,
      {Duration? timeout}) async {
    final c = link?.writeChar;
    if (c == null) {
      throw StateError('writeCommand: not connected / write char unresolved');
    }
    // Use Write-Without-Response only when the char actually supports it;
    // ace3 does not, so fall back to Write (with response).
    final woResp = c.properties.writeWithoutResponse;
    await c.write(
      bytes,
      withoutResponse: woResp,
      timeout: (timeout ?? const Duration(seconds: 15)).inSeconds,
    );
    _packets.add(BlePacketEvent(LogDirection.tx, List<int>.unmodifiable(bytes),
        deviceId: link!.deviceId));
  }

  /// Switch mode (PROTOCOL.md §6.2): writes the mode sub-frame ++ auth
  /// sub-frame in one 15-byte write. [cb] is the device's dealer-derived echo
  /// (selector 0x27) and [pwSum] the cut-off password char-code checksum — both
  /// per-device runtime inputs, never hardcoded.
  ///
  /// SAFETY: the caller must gate which [mode] values are sent, and the gate is
  /// per CLASS, not per code — the code spaces do not overlap (see [ModeArg]).
  /// ⚠️ This sentence used to read "only the documented release (mode 0x06 +
  /// auth) is proven safe", which was wrong twice over: the release writes
  /// `0x00`, and `0x06` is a super-capacitor's self-check. Corrected
  /// 2026-08-28 with the rest of that misread (see [ModeArg.capacitorSelfCheck]).
  Future<void> switchMode(int mode,
      {required int cb, required int pwSum}) async {
    final creds = AuthCredentials(cb: cb, pwSum: pwSum);
    await writeCommand(_commands.switchMode(mode, creds));
  }

  /// Verify-auth standalone (live HCI capture): the 9-byte auth frame
  /// the reference app sends ~2 s before a bundled mode+auth.
  Future<void> sendAuth({required int cb, required int pwSum}) async {
    final creds = AuthCredentials(cb: cb, pwSum: pwSum);
    await writeCommand(_commands.auth(creds));
  }

  /// Set warning thresholds in physical units (PROTOCOL.md §8.3 write inverse).
  ///
  /// [trailing] is the frame's 4th byte (observed UT / under-temp). When
  /// null (the default) we **preserve the last-read UT byte** from telemetry
  /// (selector 0x2B, §10.2) instead of forcing 0x00 — so a user editing OV/UV/OT
  /// does not silently clobber the device's under-temp setting.
  Future<void> setThresholds({
    required double ovVolts,
    required double uvVolts,
    required double otCelsius,
    int? trailing,
  }) async {
    await writeCommand(_commands.thresholds(
      ovVolts: ovVolts,
      uvVolts: uvVolts,
      otCelsius: otCelsius,
      trailing: trailing ?? currentSample.warnUtByte ?? 0x00,
    ));
  }

  /// Set warning thresholds from raw register bytes. [trailing] null preserves
  /// the last-read UT byte (see [setThresholds]).
  Future<void> setThresholdsRaw(int ovByte, int uvByte, int otByte,
      {int? trailing}) async {
    await writeCommand(_commands.thresholdsRaw(ovByte, uvByte, otByte,
        trailing: trailing ?? currentSample.warnUtByte ?? 0x00));
  }

  /// Send one scheduled keep-alive token on demand (advances the tick counter).
  /// No-op when nothing is connected, as it always was — the old body returned
  /// early on a null write characteristic.
  ///
  /// Also the resume liveness probe's opening move (design 0039 §3.1): back in
  /// the foreground, the app cannot tell a healthy link from one the OS
  /// reclaimed while it was suspended, because that path produces no disconnect
  /// event. Asking is the only way to find out, and waiting up to a second for
  /// the next tick wastes the part of the window the user is watching.
  ///
  /// Deliberately still subject to [_LinkState.keepAliveInFlight] like any
  /// other tick: if a write from before the suspension is still hanging, this
  /// returns without sending, the probe sees no telemetry and the link is
  /// dropped — which is the right answer. A hung write IS the symptom.
  Future<void> pokeKeepAlive() async {
    final link = _current;
    if (link == null) return;
    await _sendKeepAlive(link);
  }

  // ---------------------------------------------------------------------------

  void _setState(BleLinkState s) {
    if (_state == s) return;
    _state = s;
    _link.add(s);
  }

  /// Release all resources. The service is unusable afterwards.
  Future<void> dispose() async {
    // Awaited, unlike the [connect] path: the cancels have to be complete
    // before the controllers [_teardown] writes to are closed below.
    await _dropAllLinks();
    _current = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await _telemetry.close();
    await _deviceMetadata.close();
    await _link.close();
    await _scan.close();
    await _packets.close();
    await _diagnostics.close();
  }
}
