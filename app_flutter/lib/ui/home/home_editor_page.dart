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
/// ## No instructions anywhere
///
/// There is no "drag to reorder" line and no "at least one card is required".
/// The grab handle and the greyed delete say both, and §4.7's whole point is
/// that a sentence explaining our own UI is a sign the UI did not do its job.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import '../dashboard/display_modules.dart';
import '../widgets/industrial_card.dart';
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
        const Duration(milliseconds: 16), (_) => _autoScrollTick());
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
          .renderedFor(devices.devices, settings.settings,
              gForceAvailable: context.read<GForceController>().available)
          .tiles,
    );
  }

  Future<void> _persist() =>
      context.read<SettingsController>().setHomeLayout(
            HomeLayout(_tiles!).encode(),
          );

  void _apply(List<HomeTile> next) {
    setState(() => _tiles = next);
    _persist();
  }

  void _remove(int index) => _apply(HomeGridOps.remove(_tiles!, index));

  void _toggleSpan(int index) =>
      _apply(HomeGridOps.toggleSpan(_tiles!, index));

  void _add(HomeTile tile) => _apply(HomeGridOps.add(_tiles!, tile));

  /// A tile was dropped ON another tile: they change places, each keeping its
  /// own span (design 0049 Q1).
  void _onDropOnTile(int from, int to) =>
      _apply(HomeGridOps.swap(_tiles!, from, to));

  /// A tile was dropped on the line between rows: it becomes a row of its own.
  void _onDropOnLine(int from, int rowIndex) =>
      _apply(HomeGridOps.moveToOwnRow(_tiles!, from, rowIndex));

  /// A tile was dropped in an empty half-slot: it pairs with that slot's
  /// partner and becomes a half.
  void _onDropInSlot(int from, int slot) =>
      _apply(HomeGridOps.moveIntoSlot(_tiles!, from, slot));

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
    // The floor. One REAL tile left ⇒ nothing may remove it. Empty slots do
    // not count: they are structure, not content, and a grid holding one card
    // plus its gap is still a grid with one card.
    final canDelete = tiles.where((t) => !t.isEmpty).length > 1;

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

  /// The grid: rows of one full tile or two half slots, with a drop line
  /// between every pair of rows (design 0049 §3.2).
  Widget _grid(List<HomeTile> tiles, {required bool canDelete}) {
    final rows = HomeLayout.rowsOf(tiles);
    // Flat index of each row's first tile, computed once — every drop callback
    // needs it, and recomputing it per widget is how the two drift.
    final starts = <int>[];
    var flat = 0;
    for (final r in rows) {
      starts.add(flat);
      flat += r.length;
    }

    return ListView(
      key: _gridKey,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 10),
      children: [
        for (var r = 0; r <= rows.length; r++) ...[
          _DropLine(rowIndex: r, onDrop: _onDropOnLine),
          if (r < rows.length)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < rows[r].length; c++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(left: c == 0 ? 0 : 6),
                      child: _EditorCell(
                        index: starts[r] + c,
                        tile: rows[r][c],
                        canDelete: canDelete,
                        onDelete: () => _remove(starts[r] + c),
                        onToggleSpan: () => _toggleSpan(starts[r] + c),
                        onDropOnTile: _onDropOnTile,
                        onDropInSlot: _onDropInSlot,
                        onDragMoved: _onDragMoved,
                        onDragStopped: _stopAutoScroll,
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
  /// The G meter is deliberately NOT offered here. Design 0045 places it on the
  /// `riding` watchface and says nothing about the home grid; adding it would
  /// be inventing a ruling.
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
              // 🔴 design 0050 D3 + the data gate.
              //
              // `forClass` is null when the unit has no class, and that is the
              // whole point: this menu used to hand back the battery's entire
              // card set for a device nobody had identified — which is how a
              // capacitor came to be offered 分串電壓 (reported 2026-08-08).
              //
              // `!isDataGated` is the second half: `cells` only draws when DVOL
              // actually arrives, so offering it unconditionally lets someone
              // add a card that can never render. A permanent empty card is
              // worse than no card (`watchfaces.dart`).
              (DisplayModules.forClass(d.productClass)?.has(m) ?? false) &&
              !(DisplayModules.forClass(d.productClass)?.isDataGated(m) ??
                  true))
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
            phoneModuleAvailable(m, settings,
                gForceAvailable: gForceAvailable) &&
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
                    color: AppColors.amber,
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
  const _DropLine({required this.rowIndex, required this.onDrop});

  final int rowIndex;
  final void Function(int from, int rowIndex) onDrop;

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
        widget.onDrop(d.data, widget.rowIndex);
      },
      builder: (context, candidate, _) => SizedBox(
        height: candidate.isEmpty ? 6 : 44,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _over ? 3 : 1,
            decoration: BoxDecoration(
              color: _over ? AppColors.amber : Colors.transparent,
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
    required this.canDelete,
    required this.onDelete,
    required this.onToggleSpan,
    required this.onDropOnTile,
    required this.onDropInSlot,
    required this.onDragMoved,
    required this.onDragStopped,
  });

  final int index;
  final HomeTile tile;
  final bool canDelete;
  final VoidCallback onDelete;
  final VoidCallback onToggleSpan;
  final void Function(int from, int to) onDropOnTile;
  final void Function(int from, int slot) onDropInSlot;

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
        if (widget.tile.isEmpty) {
          widget.onDropInSlot(d.data, widget.index);
        } else {
          widget.onDropOnTile(d.data, widget.index);
        }
      },
      builder: (context, _, _) => widget.tile.isEmpty
          ? _EmptySlot(highlighted: _over)
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: _over ? AppColors.amber : Colors.transparent,
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
                          onDragUpdate: (d) =>
                              widget.onDragMoved(d.globalPosition),
                          // Both, because they are different endings: one is a
                          // drop on a target, the other a release over nothing.
                          // Missing either leaves the list scrolling by itself.
                          onDragEnd: (_) => widget.onDragStopped(),
                          onDraggableCanceled: (_, _) =>
                              widget.onDragStopped(),
                          feedback: _DragGhost(tile: widget.tile),
                          childWhenDragging: Opacity(
                            opacity: 0.3,
                            child: Icon(Icons.drag_indicator,
                                size: 18, color: colors.muted),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(Icons.drag_indicator,
                                size: 18, color: colors.muted),
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
                          color: AppColors.danger,
                          disabledColor: colors.muted.withValues(alpha: 0.35),
                        ),
                      ],
                    ),
                    // The real tile, so what is being arranged is what will be
                    // seen — at the width it will be seen at, which the grid
                    // now provides. Inert while editing: a tap here is a drag
                    // that has not started yet.
                    AbsorbPointer(child: HomeTileView(tile: widget.tile)),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The unoccupied half of a row. Always visible (design 0049 Q2).
///
/// It is the only thing on this page that says "something can go here", and
/// §3.7 forbids saying it in words — so it has to be legible as a shape. Quiet
/// enough not to read as a broken card: a dotted hairline, no fill, no label.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot({required this.highlighted});

  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 18),
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: highlighted ? AppColors.amber : context.colors.line,
          radius: AppTheme.radiusMd,
        ),
        child: const SizedBox(height: 86, width: double.infinity),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
            metric.extractPath(d, (d + 5).clamp(0, metric.length)), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

/// What follows the finger. Deliberately small and translucent — the thing
/// being judged during a drag is the TARGET, not the payload.
class _DragGhost extends StatelessWidget {
  const _DragGhost({required this.tile});

  final HomeTile tile;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.85,
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 150,
          child: AbsorbPointer(child: HomeTileView(tile: tile)),
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
