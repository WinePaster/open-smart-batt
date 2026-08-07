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
          .renderedFor(devices.devices, settings.settings,
              gForceAvailable: context.read<GForceController>().available)
          .tiles,
    );
  }

  Future<void> _persist() =>
      context.read<SettingsController>().setHomeLayout(
            HomeLayout(_tiles!).encode(),
          );

  /// `onReorderItem` rather than `onReorder`: the latter hands back an index
  /// computed BEFORE the dragged row is removed, so every caller has to write
  /// the same `if (newIndex > oldIndex) newIndex -= 1` fixup — which is exactly
  /// the off-by-one this replacement exists to delete.
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final tiles = _tiles!;
      tiles.insert(newIndex, tiles.removeAt(oldIndex));
    });
    _persist();
  }

  void _remove(int index) {
    setState(() => _tiles!.removeAt(index));
    _persist();
  }

  void _toggleSpan(int index) {
    setState(() {
      final t = _tiles![index];
      _tiles![index] = t.copyWith(
          span: t.span == HomeSpan.full ? HomeSpan.half : HomeSpan.full);
    });
    _persist();
  }

  void _add(HomeTile tile) {
    setState(() => _tiles!.add(tile));
    _persist();
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
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            children: [
              Expanded(
                child: ReorderableListView.builder(
                  // Chosen over a hand-rolled drag layer for its built-in
                  // keyboard and TalkBack move semantics (§4.9): the escape
                  // hatch below is the accessible way OUT, this is the
                  // accessible way to rearrange.
                  padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
                  itemCount: tiles.length,
                  onReorderItem: _reorder,
                  itemBuilder: (context, i) => _EditorTile(
                    key: ValueKey('$i:${tiles[i]}'),
                    index: i,
                    tile: tiles[i],
                    canDelete: canDelete,
                    onDelete: () => _remove(i),
                    onToggleSpan: () => _toggleSpan(i),
                  ),
                ),
              ),
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

    final entries = <(String, HomeTile)>[
      for (final d in devices)
        (d.alias.isEmpty ? d.id : d.alias, HomeTile.device(d.id)),
      for (final d in devices)
        for (final m in DisplayModule.values)
          if (!m.isPhoneModule &&
              DisplayModules.forClass(d.productClass).has(m))
            (
              '${homeModuleLabel(l10n, m)} · ${d.alias.isEmpty ? d.id : d.alias}',
              HomeTile.module(m, deviceId: d.id),
            ),
      if (phoneModuleAvailable(DisplayModule.speed, settings,
          // Not consulted for `speed`; passed because the parameter is
          // required, which is what stops a caller silently defaulting it.
          gForceAvailable: false))
        (
          homeModuleLabel(l10n, DisplayModule.speed),
          const HomeTile.module(DisplayModule.speed),
        ),
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

/// One row of the editor: the tile as it will look, with a handle and a delete.
class _EditorTile extends StatelessWidget {
  const _EditorTile({
    super.key,
    required this.index,
    required this.tile,
    required this.canDelete,
    required this.onDelete,
    required this.onToggleSpan,
  });

  final int index;
  final HomeTile tile;
  final bool canDelete;
  final VoidCallback onDelete;
  final VoidCallback onToggleSpan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.drag_handle,
                      size: 18, color: context.colors.muted),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onToggleSpan,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  tile.span == HomeSpan.full
                      ? Icons.crop_16_9
                      : Icons.crop_square,
                  color: context.colors.muted,
                ),
              ),
              IconButton(
                // 🔴 The floor (§4.9). Inert, not "tap and be told" — see the
                // library comment and T-new-2b.
                onPressed: canDelete ? onDelete : null,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                color: AppColors.danger,
                disabledColor: context.colors.muted.withValues(alpha: 0.35),
              ),
            ],
          ),
          // The real tile, so what is being arranged is what will be seen.
          // Inert while editing: a tap here is a drag that has not started yet,
          // not a request to open a device page.
          AbsorbPointer(child: HomeTileView(tile: tile)),
        ],
      ),
    );
  }
}

/// A compact card wrapper the editor reuses for its own chrome.
///
/// Referenced so `industrial_card.dart` stays this file's only card source; the
/// editor never invents a second card style.
typedef HomeEditorCard = IndustrialCard;
