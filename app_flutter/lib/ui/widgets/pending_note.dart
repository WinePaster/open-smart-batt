/// OpenSmartBatt — "pending" info note.
///
/// A muted info-icon + text row used inside a card when a value cannot be shown
/// yet because the wire data needed to compute it has not arrived / is not yet
/// decoded (e.g. DVOL awaiting VADJ scaling, USB port-status frame layout).
/// Colors/metrics come from [AppTheme] only — no hard-coded hex.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A single-line-ish muted note with a leading info icon, top-aligned so long
/// text wraps cleanly next to the icon.
class PendingNote extends StatelessWidget {
  const PendingNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 14, color: context.colors.muted),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.6,
              color: context.colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}
