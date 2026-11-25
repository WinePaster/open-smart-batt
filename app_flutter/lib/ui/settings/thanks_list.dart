/// OpenSmartBatt — Settings → About → 感謝名單 (pro design 0109).
///
/// 🔴 THE NAMES ARE NOT IN THIS REPOSITORY, on purpose. Owner ruling
/// 2026-11-25: the thanks list must not reach GitHub, because a rider who later
/// asks to be taken off could not be — git history keeps every version. So the
/// list is a build-time asset, [kThanksListAsset], which `.gitignore` keeps out
/// of the index: the release build writes it (the Android CI from a repository
/// secret, the local iOS archive from the private generator), and a build from
/// source simply does not have it.
///
/// Without the file the About row is not drawn at all — never an empty page,
/// and never a placeholder name.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../config/app_config.dart';
import '../../theme/app_theme.dart';
import '../widgets/industrial.dart';

/// Where the build puts the list. Gitignored — see the library comment.
const String kThanksListAsset = 'assets/credits/thanks.json';

/// One rider on the list: the name as they reported under, and how many
/// reports they sent up to [ThanksList.asOf].
@immutable
class ThanksEntry {
  const ThanksEntry(this.name, this.reports);
  final String name;
  final int reports;
}

/// The list as the generator wrote it. The ORDER is the file's: digits, then
/// letters, then Chinese by stroke count — sorted once, off-device, because
/// Flutter has no stroke collation and a second sort here could only disagree.
@immutable
class ThanksList {
  const ThanksList({required this.asOf, required this.entries});

  /// The day the counts were taken (`YYYY-MM-DD`), printed under the list.
  final String asOf;
  final List<ThanksEntry> entries;

  /// `{"as_of": "2026-11-25", "entries": [["AK74", 33], …]}`. Null for
  /// anything that is not exactly that shape, or that has no entries — the
  /// caller then draws no row, which is the right failure for a credits page.
  static ThanksList? parse(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final asOf = m['as_of'];
      final list = m['entries'];
      if (asOf is! String || list is! List) return null;
      final entries = <ThanksEntry>[];
      for (final e in list) {
        if (e is! List || e.length != 2) return null;
        final name = e[0], n = e[1];
        if (name is! String || name.trim().isEmpty || n is! int || n < 1) {
          return null;
        }
        entries.add(ThanksEntry(name, n));
      }
      if (entries.isEmpty) return null;
      return ThanksList(asOf: asOf, entries: List.unmodifiable(entries));
    } on FormatException {
      return null;
    }
  }
}

/// Reads [kThanksListAsset] from [bundle], or null when the build has none.
Future<ThanksList?> loadThanksList(AssetBundle bundle) async {
  try {
    return ThanksList.parse(await bundle.loadString(kThanksListAsset));
  } catch (_) {
    // Missing asset (a build from source) or unreadable: no row.
    return null;
  }
}

/// The About row. Draws nothing until — and unless — the list loads.
class ThanksListRow extends StatefulWidget {
  const ThanksListRow({super.key});

  @override
  State<ThanksListRow> createState() => _ThanksListRowState();
}

class _ThanksListRowState extends State<ThanksListRow> {
  Future<ThanksList?>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= loadThanksList(DefaultAssetBundle.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<ThanksList?>(
      future: _load,
      builder: (context, snap) {
        final list = snap.data;
        if (list == null) return const SizedBox.shrink();
        return SettingsLinkRow(
          key: const ValueKey('settings-thanks'),
          icon: Icons.favorite_border,
          label: l10n.thanksListLabel,
          sub: l10n.thanksListCount(list.entries.length),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ThanksListPage(list: list))),
        );
      },
    );
  }
}

/// The page: a few lines to the riders, the names with their report counts,
/// and the date the counts were taken.
class ThanksListPage extends StatelessWidget {
  const ThanksListPage({super.key, required this.list});

  final ThanksList list;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final body = TextStyle(fontSize: 15, height: 1.8, color: c.text);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          l10n.thanksListLabel,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(15, 3, 15, 24),
            children: [
              IndustrialCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final p in [
                      l10n.thanksStory1,
                      l10n.thanksStory2(AppConfigScope.of(context).appName),
                      l10n.thanksStory3,
                      l10n.thanksStory4,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(p, style: body),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              IndustrialCard(
                child: Column(
                  children: [
                    for (var i = 0; i < list.entries.length; i++)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          border: i == list.entries.length - 1
                              ? null
                              : Border(bottom: BorderSide(color: c.line)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(list.entries[i].name,
                                  style:
                                      TextStyle(fontSize: 15, color: c.text)),
                            ),
                            Text(
                              l10n.thanksListReports(list.entries[i].reports),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: context.accent.accent,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text(
                  l10n.thanksListFootnote(list.asOf),
                  style:
                      TextStyle(fontSize: 12, height: 1.6, color: c.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
