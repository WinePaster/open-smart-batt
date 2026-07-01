/// OpenSmartBatt — RSSI signal-strength bars (mockup `.sig` `.sig i`).
///
/// Four ascending bars; bars at-or-below [level] light up [AppColors.good],
/// the rest stay the neutral `line2` color. Pure presentation widget.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Maps an RSSI (dBm) to a 1..4 bar level. Larger (closer to 0) is stronger.
int signalLevelFromRssi(int rssi) {
  if (rssi >= -55) return 4;
  if (rssi >= -67) return 3;
  if (rssi >= -78) return 2;
  return 1;
}

/// Four-bar signal indicator (mockup `.sig`). [level] is 0..4 (0 = none lit).
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.level});

  /// Number of lit bars, 0..4.
  final int level;

  // Bar heights mirror the mockup (5 / 8 / 11 / 15 px).
  static const List<double> _heights = [5, 8, 11, 15];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 15,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_heights.length, (i) {
          final lit = (i + 1) <= level;
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
            child: Container(
              width: 3,
              height: _heights[i],
              decoration: BoxDecoration(
                color: lit ? AppColors.good : context.colors.line2,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
