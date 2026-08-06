/// OpenSmartBatt — "how old is this reading" in one short phrase.
///
/// 📦 Was `_relativeTime`, private to `ui/dashboard/disconnected_state.dart`.
/// Hoisted by design 0046 because the home page's device cards need exactly the
/// same phrase, and a second copy is how "3 分鐘前" on one screen becomes
/// "3 minutes" on another.
///
/// 🔴 THIS IS NOT EXPLANATORY TEXT, and design 0046 §4.7's "state it with
/// navigation rather than words" discipline explicitly does not reach it. A
/// timestamp is the PROVENANCE of a number: FB-43 is a power bank's single-cell
/// 3.79 V presented as a pack's main voltage, and the general form of that
/// mistake is showing a stored reading as if it were current. Every offline
/// value on the home page carries one (T-new-3), and no tidying pass may take
/// it away.
///
/// Resolution is deliberately coarse — anything under a minute is "just now".
/// The dashboard's stale banner keeps its own seconds-resolution helper because
/// it appears after 8 seconds, where "just now" would be useless.
library;

import 'package:open_smart_batt/l10n/app_localizations.dart';

/// Coarse relative-time label (e.g. "Just now / 2 minutes ago / 2 days ago").
///
/// [now] is injectable so a test can state an age instead of sleeping.
String relativeTime(AppLocalizations l10n, DateTime? t, {DateTime? now}) {
  if (t == null) return l10n.relativeNever;
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return l10n.relativeJustNow;
  if (d.inMinutes < 60) return l10n.relativeMinutesAgo(d.inMinutes);
  if (d.inHours < 24) return l10n.relativeHoursAgo(d.inHours);
  return l10n.relativeDaysAgo(d.inDays);
}
