/// OpenSmartBatt — PLAN heights for the home grid's auto-fill
/// (design 0106 §6.3, 版 1b, algorithm (c)).
///
/// ## What a plan height is, and why it is not the card's live height
///
/// Design 0084 Q1 rejected a masonry because a card's REAL height changes with
/// the link (a chart is 427 px connected and 102 px waiting), so placing cards
/// by what they measure now would rearrange the page every time a unit
/// connects — and because the editor draws SAMPLE data, it could never show
/// where a card will land. Owner overturned Q1 on 2026-11-15 (0106 Q-A1)
/// under a condition this file is the implementation of:
///
/// * a card is measured ONCE with the editor's own sample data
///   ([buildHomePreview]), at the real column width and text scale;
/// * the result is cached under (card, width, text scale, units) and reused
///   until one of those changes;
/// * live data, connecting and disconnecting are not in the key, so they can
///   never move a card;
/// * the editor plans with the same function at the same width, so it shows
///   exactly where each card lands.
///
/// The first frame for a key that is not cached yet draws the fallback
/// placement (every height counted as 1 — plain alternation) while the cards
/// are measured offstage; the next frame draws the real placement. That one
/// frame happens when the layout, the width or the text size changes — never
/// while the page is just showing data.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/state.dart';
import '../../theme/app_theme.dart';
import 'home_preview.dart';
import 'home_tiles.dart';

/// Fixed clock for plan previews: a preview drawn "now" would change its own
/// text (ages, axis labels) from one measurement to the next.
final DateTime kHomePlanNow = DateTime(2026, 1, 1, 12);

/// Process-wide plan-height cache: probe key → height.
///
/// Static rather than per-widget so the editor, opened from the home page,
/// finds the heights the home page already measured.
abstract final class HomePlanCache {
  static final Map<String, double> _heights = {};

  static double? get(String key) => _heights[key];
  static void put(String key, double height) => _heights[key] = height;

  @visibleForTesting
  static void clear() => _heights.clear();

  @visibleForTesting
  static int get length => _heights.length;
}

/// The two widths a planned block needs: a half column and the full width.
class HomePlanWidths {
  const HomePlanWidths({required this.full, required this.half});

  /// [contentWidth] is the width a full-width card is drawn at.
  factory HomePlanWidths.forContent(double contentWidth) => HomePlanWidths(
        full: contentWidth,
        half: (contentWidth - kHomeColumnGap) / 2,
      );

  final double full;
  final double half;

  /// The narrowest half column an `auto` card is drawn in at the user's
  /// default text size — `narrow_tile_layout_test.dart`'s `kTight`, the
  /// cruellest slot the phone cards are tested in (a 320 pt phone, halved).
  static const double autoHalfMinWidth = 150;

  /// design 0106 §6.4 (Q-S2): too narrow for an `auto` half at this text size
  /// ⇒ [HomeLayout.place] draws every `auto` half full. A 320 pt phone at the
  /// default size, or any phone with enlarged text, lands here; a card the
  /// user set to half is still drawn half.
  bool narrowFor(BuildContext context) =>
      half < autoHalfMinWidth * math.max(1.0, AppTheme.userTextScale(context));
}

/// Draws [builder] with the tiles PLACED by [HomeLayout.place] from plan
/// heights, measuring whatever is not cached yet offstage.
class HomePlanned extends StatefulWidget {
  const HomePlanned({
    super.key,
    required this.tiles,
    required this.widths,
    required this.builder,
  });

  /// The tiles as they will be drawn (already filtered by `renderedFor`).
  final List<HomeTile> tiles;
  final HomePlanWidths widths;
  final Widget Function(BuildContext context, List<HomeTile> placed) builder;

  @override
  State<HomePlanned> createState() => _HomePlannedState();
}

class _HomePlannedState extends State<HomePlanned> {
  final Map<ProductClass, LiveTrendBuffer> _trends = {};
  // Stable per probe key: a rebuild before the post-frame read must not swap
  // in fresh keys whose elements have not been laid out yet.
  final Map<String, GlobalKey> _keys = {};
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final probes = homePlanProbes(context, widget.tiles, widget.widths,
        trends: _trends);
    final placed = HomeLayout.place(
      widget.tiles,
      halfHeight: (i) => HomePlanCache.get(probes.halfKey(i) ?? ''),
      fullHeight: (i) => HomePlanCache.get(probes.fullKey(i) ?? ''),
      narrow: widget.widths.narrowFor(context),
    );
    final child = widget.builder(context, placed);
    final missing = probes.missing;
    if (missing.isEmpty) return child;
    for (final p in missing) {
      _keys.putIfAbsent(p.key, GlobalKey.new);
    }
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted) return;
        var any = false;
        for (final e in _keys.entries.toList()) {
          final size = e.value.currentContext?.size;
          if (size == null) continue;
          HomePlanCache.put(e.key, size.height);
          _keys.remove(e.key);
          any = true;
        }
        if (any) setState(() {});
      });
    }
    return Stack(
      children: [
        child,
        Offstage(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in missing)
                  SizedBox(
                    key: _keys[p.key],
                    width: p.width,
                    child: HomeTileView(tile: p.tile, preview: p.preview),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One card to measure.
class HomePlanProbe {
  const HomePlanProbe(this.key, this.tile, this.width, this.preview);
  final String key;
  final HomeTile tile;
  final double width;
  final HomePreview preview;
}

/// The probe keys for a tile list, and which of them are not cached yet.
class HomePlanProbes {
  HomePlanProbes(this._half, this._full, this.missing);
  final Map<int, String> _half;
  final Map<int, String> _full;
  final List<HomePlanProbe> missing;

  String? halfKey(int i) => _half[i];
  String? fullKey(int i) => _full[i];
}

/// Work out which cards need a plan height: every half at [widths].half, and
/// every `auto`-sized half also at full width (the narrow-column rule).
///
/// The preview mirrors the editor's: the device's saved class, the FIRST
/// device card drawn live, the user's units, a fixed clock. The key carries all
/// of it plus the width and text scale — and nothing that live data can change.
HomePlanProbes homePlanProbes(
  BuildContext context,
  List<HomeTile> tiles,
  HomePlanWidths widths, {
  Map<ProductClass, LiveTrendBuffer>? trends,
}) {
  final devices = context.read<DeviceController>();
  final settings = context.read<SettingsController>().settings;
  final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
  final firstDeviceCard =
      tiles.indexWhere((t) => t.kind == HomeTileKind.deviceCard);
  final half = <int, String>{};
  final full = <int, String>{};
  final missing = <HomePlanProbe>[];
  final seen = <String>{};
  // Only measure what can change a placement: half heights in a run that has
  // at least one engine-placed card, and the full height of an engine-sized
  // half (the narrow-column rule). A layout the user arranged by hand — every
  // layout stored before 版 1b — needs no measurement at all.
  final needHalf = <int>{};
  for (var i = 0; i < tiles.length;) {
    if (tiles[i].span != HomeSpan.half) {
      i++;
      continue;
    }
    var j = i;
    while (j < tiles.length && tiles[j].span == HomeSpan.half) {
      j++;
    }
    final run = [for (var k = i; k < j; k++) k];
    if (run.any((k) =>
        tiles[k].columnBy == TileSource.auto ||
        tiles[k].sizeBy == TileSource.auto)) {
      needHalf.addAll(run);
    }
    i = j;
  }
  for (var i = 0; i < tiles.length; i++) {
    final t = tiles[i];
    if (t.span != HomeSpan.half || !needHalf.contains(i)) continue;
    final id = t.deviceId;
    final cls = id == null
        ? ProductClass.unknown
        : (devices.deviceFor(id)?.productClass ?? ProductClass.unknown);
    final live = i == firstDeviceCard;
    final base = '${t.kind.slug}|${t.module?.name}|${t.view}|${t.shell.slug}|'
        '${cls.name}|$live|${settings.tempUnit.name}|${settings.speedUnit.name}|'
        '${scale.toStringAsFixed(3)}';
    HomePreview? preview;
    HomePreview p() => preview ??= buildHomePreview(
          shellClass: cls,
          live: live,
          tempUnit: settings.tempUnit,
          speedUnit: settings.speedUnit,
          now: kHomePlanNow,
          trend: trends?.putIfAbsent(
              cls, () => buildPreviewTrend(cls, kHomePlanNow)),
        );
    void want(Map<int, String> into, double w) {
      final key = '$base@${w.toStringAsFixed(1)}';
      into[i] = key;
      if (HomePlanCache.get(key) == null && seen.add(key)) {
        missing.add(HomePlanProbe(key, t, w, p()));
      }
    }

    want(half, widths.half);
    if (t.sizeBy == TileSource.auto) want(full, widths.full);
  }
  return HomePlanProbes(half, full, missing);
}

/// Plan heights at half width for every tile of [tiles], as if each were
/// half — what 一鍵整理 pairs by. Null for a card never measured at that width.
List<double?> homePlanHalfHeights(
  BuildContext context,
  List<HomeTile> tiles,
  HomePlanWidths widths,
) {
  final asHalf = [for (final t in tiles) t.copyWith(span: HomeSpan.half)];
  final probes = homePlanProbes(context, asHalf, widths);
  return [
    for (var i = 0; i < tiles.length; i++)
      HomePlanCache.get(probes.halfKey(i) ?? ''),
  ];
}
