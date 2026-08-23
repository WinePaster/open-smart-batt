/// OpenSmartBatt — the home grid's editor (design 0046 P3, R19).
///
/// ## Dragging is here because a ruling overturned design 0034 N1
///
/// Design 0034 refused a drag-to-reorder module list for three reasons. Owner
/// ruling of 2026-08-06 (R19, "drag 體驗比較好") overturns it, and the design
/// doc §4.9 is explicit that ONE of those three reasons still stands and must
/// be carried across: **a free editor can produce a bad page, and the worst one
/// is an empty page.** That mattered less when the thing being edited was a
/// watchface; the home grid is the app's DEFAULT ENTRY POINT since R3, so an
/// empty one is a blank screen on launch.
///
/// Two guards, and the form of each is as ruled as its existence:
///
///  * **A floor.** At one tile the delete control is `onPressed: null` — grey,
///    inert. 🔴 NOT a control that accepts the tap and then explains itself:
///    design 0046 §4.7 ("state it with navigation, not words") applies to this
///    screen, and T-new-2b asserts that NO `SnackBar` and NO `AlertDialog`
///    appears. The greyed button is the whole message.
///  * **An escape hatch.** "Restore default layout" writes NULL rather than a
///    computed snapshot — see [SettingsController.setHomeLayout]. It is also the
///    accessible route out of a grid somebody has made unusable, which is why it
///    is a plain button and not a long-press or a swipe.
///
/// ## Instructions: in a dialog you asked for, nowhere else (design 0053)
///
/// This section used to be titled "No instructions anywhere", and it was the
/// code-side statement of design 0049 G5 / §3.7 and design 0046 §4.7 R11. The
/// owner ruling of 2026-08-09 overturns that for this screen
/// (「議題四 請推翻，以我現在的決定為準」): the editor now opens a tutorial
/// dialog on the first visit, and an amber `?` in the app bar brings it back
/// for ever after. `home_editor_tutorial.dart` is the content; design 0053 is
/// the ruling, and 0049 / 0046 carry dated notes pointing at it.
///
/// 🔴 The half that did NOT change, because it is a different claim:
///
///  * **No sentence appears on this page's surface.** No "drag to reorder"
///    label, no "at least one card is required" caption. The grab handle and
///    the greyed ✕ still say both.
///  * **No control explains itself after being pressed.** The floor is still a
///    disabled button, and T-new-2b still asserts that pressing it produces
///    neither a `SnackBar` nor a dialog. That assertion was NARROWED, not
///    deleted, when the tutorial arrived — 0053 §6 says why deleting it would
///    have thrown away the guard it was really holding.
///
/// The distinction the ruling draws: a reference you open, dismiss and can
/// re-summon is a different object from an interruption fired by a tap on a
/// control that will not work.
///
/// ## 🔴 Every tile on this page is FAKE (design 0051 §5, ruling 2026-08-09)
///
/// 「請堅持編輯主頁就是假資料 … 只有回到主頁才是真實資料」, and 「不用放提示
/// 文字：示範」— no watermark, no badge, nothing saying "demo".
///
/// It reads as a cosmetic ruling and is not. Two real defects were shipping:
///
///  1. **You could not tell the cards apart.** With nothing connected — the
///     commonest state — all eight module tiles collapsed to the same
///     compressed `--` box, so the screen for arranging cards by height showed
///     no heights.
///  2. **The speed and G cards were LIVE here.** They read the phone, not a
///     device, so the live check passed and the real cards mounted — starting
///     the GNSS receiver and the accelerometer from a layout editor, with the
///     drag ghost mounting a SECOND copy. `home_preview.dart` has the full
///     account.
///
/// The mechanism is a [HomePreview] handed to every [HomeTileView] on this
/// page, and nowhere else. See `home_preview.dart` for why it is a parameter
/// rather than a `previewMode` flag.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/display_modules.dart';
import '../widgets/dashed_border.dart';
import '../widgets/industrial_card.dart';
import 'home_editor_tutorial.dart';
import 'home_preview.dart';
import 'home_tiles.dart';

/// Edit the home grid. Writes on every change; "done" is just a way back.
class HomeEditorPage extends StatefulWidget {
  const HomeEditorPage({super.key});

  @override
  State<HomeEditorPage> createState() => _HomeEditorPageState();
}

class _HomeEditorPageState extends State<HomeEditorPage> {
  /// Null until the first frame has read the stored layout (or generated one).
  List<HomeTile>? _tiles;

  // ---------------------------------------------------------------------------
  // 🔴 Auto-scroll while dragging.
  //
  // Design 0049 §C5 left this out and said so: "`ReorderableListView` gives it
  // free, custom drag does not; the grid is short, so not now." That reasoning
  // was wrong about the symptom. It is not "you cannot reach a far row" — with
  // more than a screenful of cards you cannot REORDER AT ALL, because every
  // target you might drop on is off screen. Reported from TestFlight the day
  // 0.7.10 shipped:「當我有多個元件的時候，我需要拖動順序，那我整個編輯卡片的
  // 畫面需要捲動」.
  //
  // The mechanism: `Draggable.onDragUpdate` hands us the pointer in global
  // coordinates, we compare it against the grid's own viewport rect, and a
  // ticker walks the scroll offset while the pointer sits in an edge band. The
  // velocity is a FIELD rather than a closure capture — a timer that captured
  // it would keep the speed from the moment it started and ignore the finger
  // moving deeper into the band.
  // ---------------------------------------------------------------------------
  final ScrollController _scroll = ScrollController();
  final GlobalKey _gridKey = GlobalKey();
  Timer? _autoScrollTicker;
  double _autoScrollV = 0;

  /// Height of the band at each end of the viewport that pulls the list.
  static const double _kEdgeBand = 76;

  /// Pixels per tick at the very edge, and at the inner lip of the band.
  static const double _kMaxStep = 18;
  static const double _kMinStep = 4;

  void _onDragMoved(Offset globalPosition) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return _stopAutoScroll();
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = globalPosition.dy;

    double v = 0;
    if (y < top + _kEdgeBand) {
      // Proportional, so the list creeps near the lip and moves briskly at the
      // very edge — a fixed speed is either too slow to be useful or too fast
      // to aim with.
      final depth = ((top + _kEdgeBand) - y).clamp(0.0, _kEdgeBand);
      v = -(_kMinStep + (_kMaxStep - _kMinStep) * (depth / _kEdgeBand));
    } else if (y > bottom - _kEdgeBand) {
      final depth = (y - (bottom - _kEdgeBand)).clamp(0.0, _kEdgeBand);
      v = _kMinStep + (_kMaxStep - _kMinStep) * (depth / _kEdgeBand);
    }
    _autoScrollV = v;
    if (v == 0) return _stopAutoScroll();
    _autoScrollTicker ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _autoScrollTick() {
    if (!_scroll.hasClients || _autoScrollV == 0) return;
    final max = _scroll.position.maxScrollExtent;
    final next = (_scroll.offset + _autoScrollV).clamp(0.0, max);
    if (next == _scroll.offset) return; // already at an end
    _scroll.jumpTo(next);
  }

  void _stopAutoScroll() {
    _autoScrollTicker?.cancel();
    _autoScrollTicker = null;
    _autoScrollV = 0;
  }

  @override
  void initState() {
    super.initState();
    // Post-frame, exactly like `_maybeShowDisclaimer`: reading the marker is a
    // file lookup behind a `Future`, and `showDialog` needs a Navigator that
    // has finished its first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTutorial());
  }

  /// First visit only (design 0053, ruling M3).
  ///
  /// The checkbox inside starts checked, so the DEFAULT is "shown once" — but
  /// unchecking it clears the marker and the dialog comes back, which is the
  /// only reading under which the box is not decoration. Whatever happens, the
  /// `?` action re-opens it on demand.
  Future<void> _maybeShowTutorial() async {
    if (await kHomeEditorTutorialAck.acknowledged()) return;
    if (!mounted) return;
    await showHomeEditorTutorial(context);
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tiles ??= _initial();
  }

  List<HomeTile> _initial() {
    final settings = context.read<SettingsController>();
    final devices = context.read<DeviceController>();
    return List<HomeTile>.of(
      (HomeLayout.decode(settings.homeLayout) ??
              HomeLayout.defaultFor(devices.devices))
          // Same view the home page draws — editing a list that still holds
          // tiles the user cannot see would let them reorder invisible cards,
          // and would write those tiles straight back on save.
          //
          // ⚠️ The cost, stated because it is real: a tile filtered out here is
          // gone from storage after the next edit. Turn the G meter off, move a
          // card, turn it back on — the G tile does not return. That is why
          // [_showAddSheet] derives its phone-module entries from the enum and
          // offers back anything AVAILABLE but absent: the pruning is one-way,
          // so the menu has to be the way back. Losing the tile's POSITION is
          // acceptable; losing the tile is not.
          .renderedFor(
            devices.devices,
            settings.settings,
            gForceAvailable: context.read<GForceController>().available,
          )
          .tiles,
    );
  }

  Future<void> _persist() => context.read<SettingsController>().setHomeLayout(
    HomeLayout(_tiles!).encode(),
  );

  void _apply(List<HomeTile> next) {
    setState(() => _tiles = next);
    _persist();
  }

  void _remove(int index) => _apply(HomeGridOps.remove(_tiles!, index));

  void _toggleSpan(int index) => _apply(HomeGridOps.toggleSpan(_tiles!, index));

  void _add(HomeTile tile) => _apply(HomeGridOps.add(_tiles!, tile));

  /// A tile was dropped ON another tile: they change places, each keeping its
  /// own span (design 0049 Q1).
  void _onDropOnTile(int from, int to) =>
      _apply(HomeGridOps.swap(_tiles!, from, to));

  /// A tile was dropped on a full-width line between blocks: it starts a band
  /// of its own there.
  ///
  /// 🔑 It KEEPS its own span (design 0049's promise), so a half dropped here
  /// begins a new two-column band on the LEFT rather than being widened. The
  /// shape button is the width control; a drop is a placement.
  void _onDropOnLine(int from, int at) => _apply(
    HomeGridOps.moveTo(
      _tiles!,
      from,
      at,
      column: _tiles![from].span == HomeSpan.half ? HomeColumn.left : null,
    ),
  );

  /// A tile was dropped on the tail of a column: it joins that column at the
  /// bottom and becomes a `half`.
  ///
  /// Dropping into a half-width position is an unambiguous statement of what
  /// width the card should be, so it is not asked for twice (design 0049 §3.3).
  void _onDropInColumn(int from, int at, HomeColumn column) =>
      _apply(HomeGridOps.moveTo(_tiles!, from, at, column: column));

  // ---------------------------------------------------------------------------
  // Appearance (design 0054)
  // ---------------------------------------------------------------------------

  /// One card's shell and view, through the same [_apply] / [_persist] funnel
  /// every other edit uses. There is no second write path.
  void _setTileStyle(int index, {required CardShell shell, String? view}) {
    final next = List<HomeTile>.of(_tiles!);
    next[index] = next[index].withStyle(shell: shell, view: view);
    _apply(next);
  }

  /// The shell of every card at once — SHELL ONLY.
  ///
  /// 🔴 Views are deliberately not included, and cannot be: a view slug means
  /// something only inside its own module's vocabulary, so "apply `big` to
  /// everything" has no referent on seven of the nine cards.
  ///
  /// This is a batch OPERATION rather than a global setting, which is the whole
  /// reason it is cheap. A global "default shell" would need a precedence rule
  /// against the per-card value, and a second source of truth for what a card
  /// looks like is how design 0041 happened.
  void _applyShellToAll(CardShell shell) => _apply([
    for (final t in _tiles!) t.withStyle(shell: shell, view: t.view),
  ]);

  // ---------------------------------------------------------------------------
  // The preview (design 0051 §5)
  // ---------------------------------------------------------------------------

  /// Frozen at the first build, and that is the point.
  ///
  /// The trend buffer is 180 synthetic points; rebuilding it on every setState
  /// would be wasteful, but the real reason it is a field is that a preview
  /// whose curve changed while you dragged a card would be read as live data.
  /// [_previewNow] freezes the clock for the same reason — "3 天前" must not
  /// tick over to "4 天前" mid-edit.
  late final DateTime _previewNow = DateTime.now();
  final Map<ProductClass, LiveTrendBuffer> _previewTrends = {};

  /// The fake data for one tile.
  ///
  /// The CLASS follows the tile's own device (design 0051 §5.4): a power bank's
  /// readouts grid and trend chart carry different content from a pack's, so a
  /// preview that faked everything as a battery would show the wrong card to
  /// the users most likely to be confused by it. A tile bound to no device — a
  /// phone module — has no class and does not need one.
  ///
  /// [live] is true for the FIRST device-summary tile only: one link can be up
  /// at a time today, so exactly one live card and the rest cached is what the
  /// real page looks like. It also gets both shapes on screen, and they differ
  /// in height (the cached one carries an age line).
  HomePreview _previewFor(HomeTile tile, {required bool live}) {
    final devices = context.read<DeviceController>();
    final settings = context.read<SettingsController>().settings;
    final id = tile.deviceId;
    final cls = id == null
        ? ProductClass.unknown
        : (devices.deviceFor(id)?.productClass ?? ProductClass.unknown);
    return buildHomePreview(
      shellClass: cls,
      live: live,
      tempUnit: settings.tempUnit,
      speedUnit: settings.speedUnit,
      now: _previewNow,
      trend: _previewTrends.putIfAbsent(
        cls,
        () => buildPreviewTrend(cls, _previewNow),
      ),
    );
  }

  /// The escape hatch (§4.9). NULL, not a snapshot — so a device saved next
  /// week still appears by itself.
  Future<void> _restoreDefaults() async {
    await context.read<SettingsController>().setHomeLayout(null);
    if (!mounted) return;
    setState(() => _tiles = _initial());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tiles = _tiles!;
    // The floor. One tile left ⇒ nothing may remove it.
    // 🔵 design 0084 S4: every element of this list is now a real card, so the
    // count is just the length. It used to have to exclude the stored gaps —
    // "structure, not content" — and that distinction is gone with them.
    final canDelete = tiles.length > 1;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          l10n.homeEditTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: context.colors.text,
          ),
        ),
        // 🔴 AMBER, not `colors.muted` (design 0053).
        //
        // The entry point to this very page is an 18 px muted `Icons.tune` on
        // the home grid, and the field result of that choice is on record from
        // 2026-08-07:「主頁不是會有個主頁編輯的功能嗎…沒有這個功能呢」 — the
        // user concluded the feature did not exist. A help affordance nobody
        // finds is the same defect, one screen further in.
        //
        // The bar had a title and zero actions before this, so nothing had to
        // move to make room.
        actions: [
          IconButton(
            tooltip: l10n.homeEditTutorialTitle,
            onPressed: () => showHomeEditorTutorial(context),
            // On the ICON, not on the IconButton. `IconButton.color` reaches
            // the glyph through an `IconTheme`, so the `Icon` widget itself
            // still reports `color: null` — which means a test asserting the
            // colour would have to assert the button's property and would then
            // pass even if the icon overrode it. The thing that paints is the
            // thing that carries the value.
            icon: Icon(
              Icons.help_outline,
              size: 19,
              color: context.accent.accent,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            children: [
              Expanded(child: _grid(tiles, canDelete: canDelete)),
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 4, 15, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _showAddSheet(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l10n.homeEditAddCard),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _restoreDefaults,
                        child: Text(
                          l10n.homeEditRestoreDefaults,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The grid: full-width bands and two-column bands, with a drop line between
  /// every pair of them and a tail slot at the foot of every column
  /// (design 0049 §3.2, rewritten for design 0084 S4).
  ///
  /// 🔴 The tail slot is the old `_EmptySlot`, and it keeps its job.
  /// Design 0049 Q2 made the unoccupied half of a row ALWAYS visible because it
  /// is the only thing on this page that says "something can go here", and §3.7
  /// forbids saying it in words. What changed is what it is: it used to be a
  /// stored tile, and it is now the foot of a column — which is also what makes
  /// Q2's「可以不等長」 reachable, since dropping into the tail of the shorter
  /// column is how a user makes it the longer one.
  Widget _grid(List<HomeTile> tiles, {required bool canDelete}) {
    final blocks = HomeLayout.blocksOf(tiles);
    // Which device tile gets the LIVE shape: the first one, because at most one
    // link is up at a time. Computed over the flat list rather than per band,
    // so it does not move when a card is dragged into a different column.
    final firstDeviceCard = tiles.indexWhere(
      (t) => t.kind == HomeTileKind.deviceCard,
    );

    Widget cell(int i) => _EditorCell(
      index: i,
      tile: tiles[i],
      preview: _previewFor(tiles[i], live: i == firstDeviceCard),
      canDelete: canDelete,
      onDelete: () => _remove(i),
      onToggleSpan: () => _toggleSpan(i),
      onEditStyle: () => _showStyleSheet(
        context,
        i,
        _previewFor(tiles[i], live: i == firstDeviceCard),
      ),
      onDropOnTile: _onDropOnTile,
      onDragMoved: _onDragMoved,
      onDragStopped: _stopAutoScroll,
    );

    return ListView(
      key: _gridKey,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 10),
      children: [
        for (var b = 0; b <= blocks.length; b++) ...[
          // The line BEFORE band `b`; the last one is "past the end", which is
          // how a drop below everything is expressed.
          _DropLine(
            at: b < blocks.length ? blocks[b].start : tiles.length,
            onDrop: _onDropOnLine,
          ),
          if (b < blocks.length)
            if (blocks[b].full case final int i)
              cell(i)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (c, (side, members)) in [
                    (HomeColumn.left, blocks[b].left),
                    (HomeColumn.right, blocks[b].right),
                  ].indexed)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: c == 0 ? 0 : kHomeColumnGap / 2,
                          right: c == 0 ? kHomeColumnGap / 2 : 0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final i in members) cell(i),
                            _ColumnTail(
                              // One PAST this band's last tile, so the card
                              // lands inside this band rather than after the
                              // full-width tile that ends it.
                              at: blocks[b].end,
                              column: side,
                              onDrop: _onDropInColumn,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
        ],
      ],
    );
  }

  /// What can be added.
  ///
  /// 🔴 The protection card is not in this menu, and no code excludes it: the
  /// menu is built from [DisplayModule.values] plus one entry per saved device,
  /// and there is no `DisplayModule` for controls (design 0034 §6). T-new-1's
  /// structural guarantee, paying out.
  ///
  /// Per-device modules are offered only where the class HAS them (design 0034
  /// §4.3, "unavailable is not offered") — a power bank is not offered a DVOL
  /// card. PHONE modules are the exception in both directions: they read no
  /// device, so they appear once with no device attached, and only while their
  /// own switch is on (an unavailable card would be permanently blank).
  ///
  /// 🔴 Two things here are written the way they are because of design 0045,
  /// and both are the kind of defect this project keeps shipping — one in a
  /// CALLER, one in a hardcoded list:
  ///
  ///  1. The per-device loop excludes phone modules via
  ///     [DisplayModule.isPhoneModule], an exhaustive switch, NOT the
  ///     `m != DisplayModule.speed` it used to be. That comparison silently let
  ///     the next phone module through, and the next one arrived: the G meter
  ///     would have been offered as `G meter · <battery name>`, a card bound to
  ///     a unit that has nothing to do with it.
  ///  2. The standalone speed entry asks `phoneModuleAvailable(speed, …)`, NOT
  ///     `ridingSelectable`. It used to ask `ridingSelectable`, which was the
  ///     same expression by coincidence; design 0045 Q3 widened that to
  ///     "speed on OR G available", and inheriting it here would have offered a
  ///     speed tile to someone who only turned the G meter on. A speed tile
  ///     mounts a `SpeedCard`, which opens the GNSS gate — so the coincidence
  ///     would have become a location leak on a second route.
  ///
  /// 🔴 **The G meter IS offered here**, and this paragraph used to say the
  /// opposite — "deliberately NOT offered … adding it would be inventing a
  /// ruling" — while the code fifty lines below has offered it since
  /// 2026-08-08. Two comments in one file contradicting each other is the exact
  /// shape CLAUDE.md's split-the-file rule names, and it survived because the
  /// stale one was the SUMMARY and the true one was buried in the loop.
  ///
  /// What actually happened: the phone-module entries were a hand-written list
  /// containing `speed` alone, so a rider who finished the G calibration had no
  /// way to put the card back — absent from this menu, and already pruned out
  /// of the stored layout by [_initial]. Reported 2026-08-08:「我現在 G 值表
  /// 校準完成；我的主頁沒有 G 值表」. The list is derived from the enum now.
  ///
  /// Design 0051 removes the other half of the old sentence as well: the
  /// `riding` watchface no longer carries either phone module, so this grid is
  /// the ONLY place they can be placed at all.
  /// The per-card appearance sheet (design 0054 §7).
  ///
  /// ## Why tapping the card, and not a third icon
  ///
  /// The control row is `[handle] … [span] [✕]`, and a 1×1 tile's top edge is
  /// already half icons. The card BODY, meanwhile, is an [AbsorbPointer] whose
  /// tap does nothing — an idle gesture on the biggest target on the screen. So
  /// the gesture goes there.
  ///
  /// ⚠️ This does NOT reopen design 0049 Q4, which refused a LONG-PRESS to ENTER
  /// edit mode from the home page. Both halves differ: this is a tap, and it is
  /// inside a screen the user reached by pressing 編輯主頁. Nothing on the home
  /// page itself gains a gesture (S-R4: the style is chosen in the editor and
  /// nowhere else — the direct reason design 0040 removed the readouts card's
  /// own mode toggle).
  ///
  /// ## Why the thumbnails are real cards
  ///
  /// Design 0041's failure was a user CHOOSING and then discovering the choice
  /// changed nothing. Colour swatches would reproduce it exactly: the difference
  /// would again be invisible until after the decision. These are the same
  /// widget the grid draws, with the same fake data, scaled — so the comparison
  /// happens before the tap rather than after it.
  ///
  /// ## Why the view row is sometimes missing
  ///
  /// It lists exactly [cardViewSlugs] for this tile's module, and is omitted
  /// below two entries. That is mechanism ① of §1.1: a user cannot select a view
  /// their card does not implement, because it is not on the screen. A picker
  /// holding one option is worse than no picker.
  void _showStyleSheet(BuildContext context, int index, HomePreview preview) {
    final l10n = AppLocalizations.of(context);
    final tile = _tiles![index];
    final module = tile.module;
    final views = module == null ? const <String>[] : cardViewSlugs(module);

    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xB804060A),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // Read back from the page's list rather than from a copy: `_apply`
          // has already written, so this is the same single source of truth the
          // grid draws from.
          final current = _tiles![index];
          final selectedView =
              current.view ?? (views.isEmpty ? null : views.first);
          return SafeArea(
            child: Material(
              color: sheetContext.colors.panel,
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(18),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(15, 14, 15, 20),
                children: [
                  Text(
                    l10n.homeStyleTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: sheetContext.colors.text,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SheetSectionLabel(text: l10n.homeStyleShellSection),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final s in CardShell.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 9),
                            child: _StyleThumb(
                              label: cardShellLabel(l10n, s),
                              selected: current.shell == s,
                              tile: current.withStyle(
                                shell: s,
                                view: current.view,
                              ),
                              preview: preview,
                              onTap: () {
                                _setTileStyle(
                                  index,
                                  shell: s,
                                  view: current.view,
                                );
                                setSheetState(() {});
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (views.length >= 2) ...[
                    const SizedBox(height: 14),
                    _SheetSectionLabel(text: l10n.homeStyleViewSection),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final v in views)
                            Padding(
                              padding: const EdgeInsets.only(right: 9),
                              child: _StyleThumb(
                                label: cardViewLabel(l10n, module!, v),
                                selected: selectedView == v,
                                tile: current.withStyle(
                                  shell: current.shell,
                                  view: v,
                                ),
                                preview: preview,
                                onTap: () {
                                  _setTileStyle(
                                    index,
                                    shell: current.shell,
                                    view: v,
                                  );
                                  setSheetState(() {});
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () {
                      _applyShellToAll(current.shell);
                      setSheetState(() {});
                    },
                    child: Text(
                      l10n.homeStyleApplyShellToAll,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final devices = context.read<DeviceController>().devices;
    final settings = context.read<SettingsController>().settings;
    final gForceAvailable = context.read<GForceController>().available;

    final entries = <(String, HomeTile)>[
      for (final d in devices)
        (d.alias.isEmpty ? d.id : d.alias, HomeTile.device(d.id)),
      for (final d in devices)
        for (final m in DisplayModule.values)
          if (!m.isPhoneModule &&
              // 🔴 design 0050 D3.
              //
              // `forClass` is null when the unit has no class, and that is the
              // whole point: this menu used to hand back the battery's entire
              // card set for a device nobody had identified — which is how a
              // capacitor came to be offered 分串電壓 (reported 2026-08-08).
              //
              // No `!isDataGated` here any more (design 0059). It kept `cells`
              // out of this menu for fear of "a card that can never render",
              // but on THIS surface that card does not exist: a module tile
              // whose body is null draws `HomeWaitingTile` (`home_tiles.dart`),
              // the same honest `--` every module card shows while the unit is
              // offline. And the only class this gate ever offers `cells` to is
              // the battery, whose DVOL (`0x24`) streams ungated every second
              // (`telemetry-decoding.md` §8.2) — connected, the card has data.
              // The gate itself stays declared in the registry: the DASHBOARD
              // still shows the card only once data arrives.
              (DisplayModules.forClass(d.productClass)?.has(m) ?? false))
            (
              '${homeModuleLabel(l10n, m)} · ${d.alias.isEmpty ? d.id : d.alias}',
              HomeTile.module(m, deviceId: d.id),
            ),
      // 🔴 EVERY phone module, derived from the enum — not a hand-written list.
      //
      // It was hand-written, and it listed `speed` only. So a rider who
      // finished the G-meter calibration had no way to put the card back:
      // absent from this menu, and already pruned out of the stored layout by
      // [_initial] on any visit made while it was still unavailable. Reported
      // 2026-08-08:「我現在 G 值表校準完成；我的主頁沒有 G 值表」.
      //
      // Deriving it means the NEXT phone module is offered the day it exists,
      // rather than the day somebody remembers this list.
      for (final m in DisplayModule.values)
        if (m.isPhoneModule &&
            phoneModuleAvailable(
              m,
              settings,
              gForceAvailable: gForceAvailable,
            ) &&
            !_tiles!.any((t) => t.module == m))
          (homeModuleLabel(l10n, m), HomeTile.module(m)),
    ];

    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xB804060A),
      builder: (sheetContext) => SafeArea(
        // `Material` rather than a bare `Container`: a `ListTile` paints its
        // background and ink splash onto the nearest Material ancestor, and a
        // decorated box in between hides both (framework assertion).
        child: Material(
          color: sheetContext.colors.panel,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 22),
            children: [
              for (final (label, tile) in entries)
                ListTile(
                  dense: true,
                  leading: Icon(
                    tile.module == null
                        ? Icons.battery_full
                        : homeModuleIcon(tile.module!),
                    size: 18,
                    color: context.accent.accent,
                  ),
                  title: Text(label, style: const TextStyle(fontSize: 13)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _add(tile);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line between two rows: drop here to make a row of your own.
///
/// The visual is a hairline; the HIT AREA is 44 pt (design 0049 R3, Apple HIG).
/// A target you can see but cannot reliably hit is worse than no target.
class _DropLine extends StatefulWidget {
  const _DropLine({required this.at, required this.onDrop});

  /// Flat index this line inserts BEFORE, in the list as it is now.
  final int at;

  final void Function(int from, int at) onDrop;

  @override
  State<_DropLine> createState() => _DropLineState();
}

class _DropLineState extends State<_DropLine> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) {
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.onDrop(d.data, widget.at);
      },
      builder: (context, candidate, _) => SizedBox(
        height: candidate.isEmpty ? 6 : 44,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _over ? 3 : 1,
            decoration: BoxDecoration(
              color: _over ? context.accent.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// One cell of the editor grid: a tile with its controls, or an empty slot.
///
/// The cell is BOTH a drag source (from the handle) and a drop target (the
/// whole cell). Which operation a drop performs is decided by what is under it:
/// an empty slot pairs, a real tile swaps.
class _EditorCell extends StatefulWidget {
  const _EditorCell({
    required this.index,
    required this.tile,
    required this.preview,
    required this.canDelete,
    required this.onDelete,
    required this.onToggleSpan,
    required this.onEditStyle,
    required this.onDropOnTile,
    required this.onDragMoved,
    required this.onDragStopped,
  });

  final int index;
  final HomeTile tile;

  /// The fake data this cell draws with — REQUIRED, not optional. Making it
  /// nullable here would leave a route back to live cards on this page, and the
  /// live card is the thing that starts the GNSS receiver (design 0051 §5).
  final HomePreview preview;

  final bool canDelete;
  final VoidCallback onDelete;
  final VoidCallback onToggleSpan;

  /// Open the appearance sheet — fired by a tap on the card BODY, which was an
  /// idle gesture until design 0054. See `_showStyleSheet`.
  final VoidCallback onEditStyle;

  final void Function(int from, int to) onDropOnTile;

  /// Pointer moved during a drag, in global coordinates — drives the page's
  /// auto-scroll. See `_HomeEditorPageState._onDragMoved`.
  final void Function(Offset globalPosition) onDragMoved;
  final VoidCallback onDragStopped;

  @override
  State<_EditorCell> createState() => _EditorCellState();
}

class _EditorCellState extends State<_EditorCell> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) {
        if (d.data == widget.index) return false;
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.onDropOnTile(d.data, widget.index);
      },
      builder: (context, _, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: _over ? context.accent.accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // 🔴 The handle is the ONLY drag source. Making the
                  // whole cell draggable would fight the ListView for
                  // every vertical swipe, and design 0049 Q4 ruled out
                  // the other way round it (a long-press edit mode).
                  Draggable<int>(
                    data: widget.index,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    onDragUpdate: (d) => widget.onDragMoved(d.globalPosition),
                    // Both, because they are different endings: one is a
                    // drop on a target, the other a release over nothing.
                    // Missing either leaves the list scrolling by itself.
                    onDragEnd: (_) => widget.onDragStopped(),
                    onDraggableCanceled: (_, _) => widget.onDragStopped(),
                    feedback: _DragGhost(tile: widget.tile),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: colors.muted,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: colors.muted,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onToggleSpan,
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      widget.tile.span == HomeSpan.full
                          ? Icons.crop_16_9
                          : Icons.crop_square,
                      color: colors.muted,
                    ),
                  ),
                  IconButton(
                    // 🔴 The floor (§4.9). Inert, not "tap and be told".
                    onPressed: widget.canDelete ? widget.onDelete : null,
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    color: AppSemantics.danger,
                    disabledColor: colors.muted.withValues(alpha: 0.35),
                  ),
                ],
              ),
              // The real tile, so what is being arranged is what will be
              // seen — at the width it will be seen at, which the grid
              // now provides.
              //
              // 🔴 The [AbsorbPointer] stays exactly as it was: the card's
              // OWN controls must remain inert here. It absorbs by
              // claiming the hit itself, so this [GestureDetector] — its
              // ancestor — still receives the tap, and design 0054 spends
              // that previously-idle gesture on the appearance sheet.
              // Dragging is unaffected: the drag source is the handle
              // alone, and a tap cannot start one.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onEditStyle,
                child: AbsorbPointer(
                  child: HomeTileView(
                    tile: widget.tile,
                    preview: widget.preview,
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

/// The foot of one column: drop here to join that column (design 0084 S4).
///
/// 🔴 This is design 0049 Q2's slot, doing the same job in the new model. It is
/// the only thing on this page that says "something can go here", §3.7 forbids
/// saying it in words, and so it has to be legible as a shape — which is why it
/// is ALWAYS visible rather than appearing during a drag.
///
/// 🔑 It is also what makes 「可以不等長」 reachable: dropping into the tail of
/// the shorter column is how a user gives one column three cards and the other
/// one. In the old model there was exactly one slot per row and it could only
/// ever hold a pair.
class _ColumnTail extends StatefulWidget {
  const _ColumnTail({
    required this.at,
    required this.column,
    required this.onDrop,
  });

  /// Flat index to insert at — one past this band's last tile, so the card
  /// lands inside the band.
  final int at;

  final HomeColumn column;

  final void Function(int from, int at, HomeColumn column) onDrop;

  @override
  State<_ColumnTail> createState() => _ColumnTailState();
}

class _ColumnTailState extends State<_ColumnTail> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => DragTarget<int>(
    onWillAcceptWithDetails: (_) {
      setState(() => _over = true);
      return true;
    },
    onLeave: (_) => setState(() => _over = false),
    onAcceptWithDetails: (d) {
      setState(() => _over = false);
      widget.onDrop(d.data, widget.at, widget.column);
    },
    builder: (context, _, _) => _EmptySlot(highlighted: _over),
  );
}

/// The dotted shape a [_ColumnTail] draws. Quiet enough not to read as a broken
/// card: a dotted hairline, no fill, no label.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot({required this.highlighted});

  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 18),
      child: CustomPaint(
        // Shared with the tutorial's diagram (design 0053) — see
        // `widgets/dashed_border.dart` for why the picture may not have its
        // own dash pattern.
        painter: DashedBorderPainter(
          color: highlighted ? context.accent.accent : context.colors.line,
          radius: AppTheme.radiusMd,
        ),
        child: const SizedBox(height: 86, width: double.infinity),
      ),
    );
  }
}

/// What follows the finger: a NAME, not a card.
///
/// Deliberately small and translucent — the thing being judged during a drag is
/// the TARGET, not the payload — and since design 0051 that is enforced by what
/// it draws rather than by a `SizedBox(width: 150)` around a full card.
///
/// 🔴 Two reasons it stopped being a [HomeTileView]:
///
///  1. **It was a second LIVE card.** Dragging a speed tile mounted a second
///     `SpeedCard`, and both pushed the same uncounted boolean GNSS gate — so
///     the release could leave the stream open. A chip has no card in it at
///     all, which is a stronger guarantee than "the chip is given fake data".
///  2. **A real card does not fit.** 150 px is a third of a phone; once the
///     editor started drawing real card bodies (design 0051), the readouts grid
///     overflowed it by 61 px — a striped RenderFlex bar following the finger.
///     Widening the ghost would defeat its own purpose.
class _DragGhost extends StatelessWidget {
  const _DragGhost({required this.tile});

  final HomeTile tile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final m = tile.module;
    final label = m != null
        ? homeModuleLabel(l10n, m)
        : (tile.kind == HomeTileKind.addDevice
              ? l10n.homeAddFirstDevice
              : l10n.devicesUnnamed);
    return Opacity(
      opacity: 0.9,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: context.colors.panel,
            border: Border.all(color: context.accent.accent),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                m == null ? Icons.battery_full : homeModuleIcon(m),
                size: 15,
                color: context.accent.accent,
              ),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: context.colors.text,
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

/// A row label in the appearance sheet.
class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text.toUpperCase(), style: AppTextStyles.cardHeading(context)),
  );
}

/// One choice in the appearance sheet: THE CARD ITSELF, shrunk.
///
/// 🔴 Not a swatch, not an icon, not a name alone. Design 0041's defect was a
/// user selecting something and only then finding out it changed nothing; an
/// abstract chip would put the discovery after the decision again. Here both
/// candidates are on screen, drawn by the same widget the grid uses, with the
/// same fake data — so "these two look identical" is answerable before the tap.
///
/// The mechanics are the mockup's `transform: scale(.42)` on one shared DOM: the
/// card is laid out at a realistic full-tile width and then scaled down, rather
/// than laid out small. Laying it out small would exercise the card's own
/// narrow-width branches (FittedBox scale-down, ellipsis) and show a rendering
/// the user will never see.
class _StyleThumb extends StatelessWidget {
  const _StyleThumb({
    required this.label,
    required this.selected,
    required this.tile,
    required this.preview,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final HomeTile tile;
  final HomePreview preview;
  final VoidCallback onTap;

  /// The width the card is LAID OUT at before scaling — a full-width tile on a
  /// mid-size phone.
  static const double _layoutWidth = 330;
  static const double _thumbWidth = 126;
  static const double _thumbHeight = 82;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        width: _thumbWidth + 14,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: selected ? context.accent.accent : colors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRect(
              child: SizedBox(
                width: _thumbWidth,
                height: _thumbHeight,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  maxWidth: _layoutWidth,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Transform.scale(
                    scale: _thumbWidth / _layoutWidth,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: _layoutWidth,
                      // Nothing inside a thumbnail is tappable — the tap belongs
                      // to the choice, not to the card being illustrated.
                      child: IgnorePointer(
                        child: HomeTileView(tile: tile, preview: preview),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? context.accent.accent : colors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact card wrapper the editor reuses for its own chrome.
///
/// Referenced so `industrial_card.dart` stays this file's only card source; the
/// editor never invents a second card style.
typedef HomeEditorCard = IndustrialCard;
