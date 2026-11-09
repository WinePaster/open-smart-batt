/// OpenSmartBatt — the "open this full screen" entry, as one widget.
///
/// 🔴 This app has been told FOUR times that an entry drawn as a bare glyph does
/// not exist: **FB-70** (a 14x14 control the reporter could not hit), **FB-103**,
/// **FB-107** (「切換電壓跟電流趨勢的 icon 很不明顯 可以在按鈕旁邊放切換兩個字嗎？」)
/// and **FB-108** (the history chart's own expander). The settled shape is
/// therefore fixed here rather than re-decided per surface:
///
///  * a VISIBLE label, never a tooltip alone;
///  * [Icons.fullscreen], the same glyph the home tab uses;
///  * at least 40x40 of tap target on both axes — FB-70's actual bill.
///
/// ⚠️ `history_screen.dart` keeps its own copy, deliberately and for now: that
/// one also MEASURES itself (`_expandButtonWidth`) because its width is the left
/// half of the footnote row's symmetry, and pulling that responsibility in here
/// would make this widget answer a question only that row asks. What must not
/// drift is the WORDING and the GLYPH — `fullscreen_entry_label_test.dart` pins
/// the two strings to each other.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class FullscreenEntryButton extends StatelessWidget {
  const FullscreenEntryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  static const double _font = 11.5;
  static const double _glyph = 18;
  static const double _gap = 3;
  static const double _padH = 7;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        // The 18 px glyph plus this padding clears 40 vertically; the label
        // alone clears it horizontally.
        padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DefaultTextStyle.of(context).style.copyWith(
                      fontSize: _font,
                      fontWeight: FontWeight.w600,
                      color: context.colors.text,
                    ),
              ),
            ),
            const SizedBox(width: _gap),
            Icon(Icons.fullscreen, size: _glyph, color: context.colors.text),
          ],
        ),
      ),
    );
  }
}
