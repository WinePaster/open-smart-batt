/// design 0106 Phase 1 — how the device page hands a secondary link's values
/// to the dashboard below it, and how a control asks for the primary.
///
/// 🔑 The rule every reader follows: `DeviceLiveScope.sourceOf(context)` first;
/// when it is null, read `TelemetryController` / `ConnectionController` exactly
/// as before. The page installs a scope with a non-null source ONLY for a unit
/// live on a secondary link (or frozen mid-hand-over), so with one link — and
/// in every surface that is not the device page — nothing reads differently.
library;

import 'package:flutter/widgets.dart';

import '../../state/state.dart';

/// Asks for [DeviceLiveScope.source]'s unit to become the primary before a
/// write. Returns true once it is (and the caller may send), false if the user
/// declined or the hand-over did not complete.
typedef EnsurePrimary = Future<bool> Function(
    BuildContext context, String action);

class DeviceLiveScope extends InheritedNotifier<Listenable> {
  const DeviceLiveScope({
    super.key,
    required this.source,
    this.ensurePrimary,
    required super.child,
  }) : super(notifier: source);

  /// The unit's live values when they do NOT come from the primary link; null
  /// when they do (or there is no link) — then readers use the controllers.
  final DeviceLiveSource? source;

  /// Installed by the device page; see [ensurePrimaryFor].
  final EnsurePrimary? ensurePrimary;

  static DeviceLiveScope? _scope(BuildContext context, bool listen) => listen
      ? context.dependOnInheritedWidgetOfExactType<DeviceLiveScope>()
      : context.getInheritedWidgetOfExactType<DeviceLiveScope>();

  /// The secondary/frozen source for this subtree, or null (⇒ primary path).
  static DeviceLiveSource? sourceOf(BuildContext context, {bool listen = true}) =>
      _scope(context, listen)?.source;
}

/// Gate every write behind this (design 0106 §2.5, ruling T1).
///
/// With no scope source the subtree is already drawing the primary link (or a
/// surface that never had a secondary), so it returns true at once and the
/// write proceeds exactly as before Phase 1.
Future<bool> ensurePrimaryFor(BuildContext context, {required String action}) {
  final scope = DeviceLiveScope._scope(context, false);
  final ensure = scope?.ensurePrimary;
  if (scope?.source == null || ensure == null) return Future<bool>.value(true);
  return ensure(context, action);
}
