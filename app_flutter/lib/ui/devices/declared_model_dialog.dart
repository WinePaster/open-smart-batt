/// OpenSmartBatt — "tell us what this is" (design 0066).
///
/// A form the OWNER fills in about their own unit. Everything in it is optional,
/// nothing in it is validated, and nothing in it changes a single pixel anywhere
/// else in the app.
///
/// ## Three rules that look like omissions and are not
///
///   1. **Every field can be left blank** (§3.1). A user who does not know which
///      capacitor generation they own must be able to say so by saying nothing.
///      Force a choice and the column fills up with coin flips, which is worse
///      than empty because it looks like data.
///   2. **The capacity is FREE TEXT** (§3.3) with four suggestion buttons that
///      are not a whitelist. Somebody typing `40B19L` is the only way we will
///      ever learn whether the dealer's "40Ah" was a capacity or a JIS case
///      code — the wire cannot answer it (`battery-config-registers.md` red
///      line) and that is why the question is still open.
///   3. **A wire mismatch is a HINT and never a block** (§3.6). It has two
///      causes — the user tapped the wrong thing, or they are holding hardware
///      whose device-type byte we have never seen — and the second is the most
///      valuable thing this form could possibly surface. Refusing the save would
///      throw it away.
///
/// ## 🔴 And the one it is built around
///
/// Nothing here writes [ProductClass] (§3.5). See `declared_device_model.dart`
/// for the three incidents that make that a rule.
///
/// ## Touch targets
///
/// Every chip is at least 40×40 dp and every one of them is measured by
/// `declared_model_test.dart`. Not a style preference: 2026-08-13's report
/// (「請問是否可以直接更改名稱？」) was about a control that worked perfectly and
/// was 14×14 dp, and `devices_page.dart` records that as the SECOND time. A form
/// made of twenty small targets is the third time waiting to happen.
library;

import 'package:flutter/material.dart';

import 'package:open_smart_batt/l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';

/// Minimum side of every tappable thing in this dialog, in dp.
///
/// Material asks for 48 and HIG for 44; 40 is the floor `devices_page.dart`
/// settled on for a control that has to share a row, and this form reuses it so
/// there is ONE number to move if it is ever raised.
const double kDeclaredTapTarget = 40;

/// Show the declaration form for one saved unit.
///
/// [initial] pre-fills it. [wireClass] and [wireDeviceType] drive the §3.6 hint
/// only — pass [ProductClass.unknown] / null and no hint is ever shown, which is
/// the correct behaviour for a unit that has never been on the link.
///
/// Resolves to the declaration to store — possibly [DeclaredModel.none], which
/// means "the user cleared it" and must be SAVED, not treated as a cancel — or
/// null if the user cancelled.
Future<DeclaredModel?> showDeclaredModelDialog(
  BuildContext context, {
  DeclaredModel initial = DeclaredModel.none,
  ProductClass wireClass = ProductClass.unknown,
  int? wireDeviceType,
}) {
  return showDialog<DeclaredModel>(
    context: context,
    barrierColor: const Color(0xD904060A),
    // Explicitly false, for the reason written out in `alias_dialog.dart`: a
    // barrier tap pops null, null is how the caller spells "declined", and this
    // form is long enough that a stray tap costs the user everything they typed.
    barrierDismissible: false,
    builder: (_) => _DeclaredModelDialog(
      initial: initial,
      wireClass: wireClass,
      wireDeviceType: wireDeviceType,
    ),
  );
}

class _DeclaredModelDialog extends StatefulWidget {
  const _DeclaredModelDialog({
    required this.initial,
    required this.wireClass,
    required this.wireDeviceType,
  });

  final DeclaredModel initial;
  final ProductClass wireClass;
  final int? wireDeviceType;

  @override
  State<_DeclaredModelDialog> createState() => _DeclaredModelDialogState();
}

class _DeclaredModelDialogState extends State<_DeclaredModelDialog> {
  // 🔴 Held as SEPARATE nullable fields rather than as one [DeclaredModel],
  // because every one of them has to be un-settable by tapping the selected
  // chip again, and `DeclaredModel.copyWith` follows the `x ?? this.x`
  // convention that cannot express a clear. The value object is assembled once,
  // in [_submit].
  late DeclaredCategory? _category = widget.initial.category;
  late String? _model = widget.initial.model;
  // design 0069. INDEPENDENT of [_model] — the whole point of the change is that
  // an owner can answer both "which battery" and "under our lid?" at once.
  late bool _retrofit = widget.initial.retrofitLid;
  late String? _region = widget.initial.region;
  late String? _label = widget.initial.label;
  late final TextEditingController _capacity =
      TextEditingController(text: widget.initial.capacity ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.initial.note ?? '');

  @override
  void dispose() {
    _capacity.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _isCarBattery => _category == DeclaredCategory.carBattery;
  /// 🔴 Was `_model == kRetrofitLidModel` until design 0069. The lid is its own
  /// answer now, and gated on the category for the same reason `region` and
  /// `label` are: a flag left over from a category the user moved away from is
  /// an artefact of the form, not something anybody said.
  bool get _isRetrofit =>
      _retrofit && _category == DeclaredCategory.motorcycleBattery;

  /// The declaration as it currently stands, WITHOUT a timestamp — what the
  /// live mismatch hint is computed from.
  DeclaredModel get _draft => DeclaredModel(
        category: _category,
        model: _model,
        // Gated on the category rather than merely cleared when it changes:
        // these three are answers to a question only the car battery asks, and
        // a stored `region=jp` on a power bank would be an artefact of the form,
        // not something anybody said.
        region: _isCarBattery ? _region : null,
        label: _isCarBattery ? _label : null,
        // 🔴 `''` is normalised to null HERE, not only in `toMap()`. A user who
        // focuses the field, types nothing and saves must leave null behind, and
        // the value that reaches the caller has to already say so — otherwise
        // the object in memory and the row on disk disagree about whether an
        // answer exists, and only one of them is ever tested.
        capacity: _isCarBattery ? _blank(_capacity.text) : null,
        note: _blank(_note.text),
        retrofitLid: _isRetrofit,
      );

  static String? _blank(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  void _pickCategory(DeclaredCategory c) {
    setState(() {
      if (_category == c) {
        // Tapping the selected one again clears it — the only way to retract an
        // answer without cancelling the whole dialog.
        _category = null;
      } else {
        _category = c;
      }
      // The second level answered a DIFFERENT question a moment ago. Carrying
      // `7.5Ah-A` across to 汽車電容 would store an answer nobody gave.
      _model = null;
      _region = null;
      _label = null;
      _retrofit = false;
      _capacity.clear();
    });
  }

  void _clearAll() {
    setState(() {
      _category = null;
      _model = null;
      _region = null;
      _label = null;
      _retrofit = false;
      _capacity.clear();
      _note.clear();
    });
  }

  /// 🔴 An emptied form pops [DeclaredModel.none] — NOT null. Cancel and clear
  /// are different answers, and collapsing them would rebuild, one layer up, the
  /// bug `alias_dialog.dart` fixed on 2026-08-11: a filled-looking button that
  /// silently does nothing. Clearing has to be able to REACH the database, or a
  /// user who mis-declared last week can never take it back.
  void _submit() {
    final draft = _draft;
    Navigator.of(context).pop(
      draft.isEmpty
          ? DeclaredModel.none
          : draft.copyWith(declaredAt: DateTime.now()),
    );
  }

  String _mismatchText(AppLocalizations l10n, DeclaredMismatch m) =>
      switch (m) {
        DeclaredMismatch.expectedCapacitor => l10n.declaredMismatchCapacitor,
        DeclaredMismatch.expectedBattery => l10n.declaredMismatchBattery,
        DeclaredMismatch.expectedPowerBank => l10n.declaredMismatchPowerBank,
        DeclaredMismatch.expectedFlagship => l10n.declaredMismatchFlagship,
      };

  String _categoryLabel(AppLocalizations l10n, DeclaredCategory c) =>
      switch (c) {
        DeclaredCategory.motorcycleCapacitor =>
          l10n.declaredCategoryMotorcycleCapacitor,
        DeclaredCategory.carCapacitor => l10n.declaredCategoryCarCapacitor,
        DeclaredCategory.motorcycleBattery =>
          l10n.declaredCategoryMotorcycleBattery,
        DeclaredCategory.carBattery => l10n.declaredCategoryCarBattery,
        DeclaredCategory.powerBank => l10n.declaredCategoryPowerBank,
      };

  /// Slug → the words on the chip.
  ///
  /// 📌 The eleven battery entries return their slug through l10n keys that hold
  /// the SAME STRING in both locales. They are catalogue part numbers, not
  /// sentences (`docs/devices/motorcycle-battery.md`), and `7.5Ah-A` translated
  /// into anything is a different battery.
  String _modelLabel(AppLocalizations l10n, String slug) => switch (slug) {
        'gen1' => l10n.declaredGenerationGen1,
        'gen2' => l10n.declaredGenerationGen2,
        'flagship' => l10n.declaredGenerationFlagship,
        kRetrofitLidModel => l10n.declaredModelRetrofitLid,
        '6.0A' => l10n.declaredModel60A,
        '6.0B' => l10n.declaredModel60B,
        '9.0A' => l10n.declaredModel90A,
        '5.0Ah-B' => l10n.declaredModel50AhB,
        '7.5Ah-B' => l10n.declaredModel75AhB,
        '10.0Ah-B' => l10n.declaredModel100AhB,
        '5.0Ah-A' => l10n.declaredModel50AhA,
        '7.5Ah-A' => l10n.declaredModel75AhA,
        '10.0Ah-A' => l10n.declaredModel100AhA,
        '12.5Ah-A' => l10n.declaredModel125AhA,
        '17.5Ah-A' => l10n.declaredModel175AhA,
        // R1: the list will go stale, and a slug added to the constant table
        // without a string is a bug — but showing the slug beats showing
        // nothing, which is what a `null!` would do on the user's phone.
        _ => slug,
      };

  String? _groupLabel(AppLocalizations l10n, String? id) => switch (id) {
        'oldGen' => l10n.declaredGroupOldGen,
        'newGenB' => l10n.declaredGroupNewGenB,
        'newGenA' => l10n.declaredGroupNewGenA,
        // 🔴 `'retrofit'` was a fourth group here until design 0069; the lid is
        // a checkbox of its own now, below the model list.
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mismatch = declaredWireMismatch(
      declared: _draft,
      wireClass: widget.wireClass,
      wireDeviceType: widget.wireDeviceType,
    );
    final groups =
        _category == null ? const <DeclaredModelGroup>[] : declaredModelGroups(_category!);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      backgroundColor: context.colors.panel,
      child: ConstrainedBox(
        // Wider than the alias dialog's 300 because this one carries rows of
        // chips rather than one field, and taller-but-narrower turns a five-way
        // choice into five lines of one.
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.declaredTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.colors.text,
                      ),
                    ),
                  ),
                  // Retracting everything in one tap. Without it a user who
                  // wants to withdraw a wrong declaration has to un-tap each
                  // chip and empty two fields, and the likely outcome is that
                  // they leave the wrong answer in place.
                  _TapTarget(
                    key: const ValueKey('declared-clear'),
                    onTap: _clearAll,
                    child: Text(
                      l10n.declaredClear,
                      style: TextStyle(
                          fontSize: 12, color: context.colors.muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l10n.declaredBody,
                style: TextStyle(
                    fontSize: 11.5, height: 1.6, color: context.colors.muted),
              ),
              // §3.5's promise, said out loud. A user who suspects that picking
              // the wrong entry will break their dashboard will not pick at all.
              Text(
                l10n.declaredNotDisplayed,
                style: TextStyle(
                    fontSize: 11, height: 1.6, color: context.colors.muted),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SectionLabel(l10n.declaredSectionCategory,
                          optional: l10n.declaredOptional),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          for (final c in DeclaredCategory.values)
                            _Chip(
                              key: ValueKey('declared-category-${c.storageKey}'),
                              label: _categoryLabel(l10n, c),
                              selected: _category == c,
                              onTap: () => _pickCategory(c),
                            ),
                        ],
                      ),
                      if (mismatch != null) ...[
                        const SizedBox(height: 9),
                        _Hint(_mismatchText(l10n, mismatch)),
                      ],
                      if (groups.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionModel,
                            optional: l10n.declaredOptional),
                        for (final g in groups) ...[
                          if (_groupLabel(l10n, g.id) case final heading?) ...[
                            const SizedBox(height: 6),
                            Text(
                              heading,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: context.colors.muted),
                            ),
                            const SizedBox(height: 5),
                          ],
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              for (final m in g.models)
                                _Chip(
                                  key: ValueKey('declared-model-$m'),
                                  label: _modelLabel(l10n, m),
                                  selected: _model == m,
                                  onTap: () => setState(
                                      () => _model = _model == m ? null : m),
                                ),
                            ],
                          ),
                        ],
                      ],
                      // 🔑 design 0069, and it is the whole change: the lid is
                      // its OWN question, sitting beside the model list rather
                      // than inside it. One chip, one column, still countable —
                      // what it stopped being is mutually exclusive with
                      // "which battery is this".
                      //
                      // Only under 機車電池 (owner ruling 2026-08-19): every lid
                      // report to date is a bike battery (`08.08/004`, unit
                      // 300051), and offering it under 行動電源 would collect
                      // combinations that mean nothing.
                      if (_category == DeclaredCategory.motorcycleBattery) ...[
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionRetrofit,
                            optional: l10n.declaredOptional),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            _Chip(
                              key: const ValueKey('declared-retrofit'),
                              label: l10n.declaredModelRetrofitLid,
                              selected: _retrofit,
                              onTap: () =>
                                  setState(() => _retrofit = !_retrofit),
                            ),
                          ],
                        ),
                        // 🔴 A PROMPT, NOT A SECOND BOX (owner, 2026-08-19).
                        // 0069 Q1 answered "which battery is under the lid?" by
                        // re-labelling the note field the moment the chip was
                        // ticked — one box, but the section under the user's
                        // finger changed its title and its hint mid-form, which
                        // reads as "my note went somewhere else". The question
                        // is still worth asking, so it is asked HERE, where the
                        // answer that triggers it lives, and the note below is
                        // left exactly as it was.
                        if (_isRetrofit) ...[
                          const SizedBox(height: 6),
                          Text(
                            l10n.declaredRetrofitNotePrompt,
                            style: TextStyle(
                                fontSize: 10.5,
                                height: 1.5,
                                color: context.colors.muted),
                          ),
                        ],
                      ],
                      if (_isCarBattery) ...[
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionRegion,
                            optional: l10n.declaredOptional),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            for (final r in kDeclaredRegions)
                              _Chip(
                                key: ValueKey('declared-region-$r'),
                                label: r == 'jp'
                                    ? l10n.declaredRegionJp
                                    : l10n.declaredRegionEu,
                                selected: _region == r,
                                onTap: () => setState(
                                    () => _region = _region == r ? null : r),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionLabel,
                            optional: l10n.declaredOptional),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            for (final lb in kDeclaredLabels)
                              _Chip(
                                key: ValueKey('declared-label-$lb'),
                                label: lb == 'orange'
                                    ? l10n.declaredLabelOrange
                                    : l10n.declaredLabelPurple,
                                selected: _label == lb,
                                // ⛔ Deliberately does NOT touch the capacity
                                // field, in either direction. `car-battery.md`
                                // :154-161 overturned the one-to-one mapping on
                                // 2026-07-30, so auto-filling 50 from 橘標 would
                                // manufacture the very correlation this form was
                                // built to measure (§3.3).
                                onTap: () => setState(
                                    () => _label = _label == lb ? null : lb),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionCapacity,
                            optional: l10n.declaredOptional),
                        _Field(
                          key: const ValueKey('declared-capacity'),
                          controller: _capacity,
                          hint: l10n.declaredCapacityHint,
                          // 🔴 NO `keyboardType: number`, NO inputFormatters,
                          // NO validator. `40B19L` has to be typeable — it is
                          // the entire point of the field (§3.3).
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            for (final s in kDeclaredCapacitySuggestions)
                              _Chip(
                                key: ValueKey('declared-capacity-$s'),
                                label: s,
                                selected: _capacity.text.trim() == s,
                                onTap: () => setState(() {
                                  _capacity.text =
                                      _capacity.text.trim() == s ? '' : s;
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          l10n.declaredCapacityFreeText,
                          style: TextStyle(
                              fontSize: 10.5,
                              height: 1.5,
                              color: context.colors.muted),
                        ),
                      ],
                      // The general note. ONE box, always the same box: it
                      // does not move, change title or change hint for any
                      // answer above it (owner, 2026-08-19). Still one column,
                      // still never two boxes writing it — the lid question is
                      // a prompt beside its chip, not a second field.
                      if (_category != null) ...[
                        const SizedBox(height: 14),
                        _SectionLabel(l10n.declaredSectionNote,
                            optional: l10n.declaredOptional),
                        _Field(
                          key: const ValueKey('declared-note'),
                          controller: _note,
                          hint: l10n.declaredNoteHint,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // §3.9, ruled 2026-08-17. PLAIN TEXT — no link, no `url_launcher`,
              // no constant.
              //
              // 🔑 Not politeness: it is the third road. §3.1 lets every field be
              // blank and §3.6 refuses to block a save, and both of those say
              // "do not guess". This says where to go instead — which matters
              // because the form asks users to tell 一代 from 二代 and 橘標 from
              // 紫標, distinctions our OWN corpus only has because a dealer said
              // so out loud. Without it we would be assuming the user knows.
              Text(
                l10n.declaredHelpLine,
                style: TextStyle(
                    fontSize: 11, height: 1.5, color: context.colors.muted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _DialogButton(
                      label: l10n.commonCancel,
                      filled: false,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _DialogButton(
                      key: const ValueKey('declared-save'),
                      label: l10n.devicesAliasSave,
                      filled: true,
                      onTap: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section heading plus the standing reminder that the section may be skipped.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {required this.optional});

  final String label;
  final String optional;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text),
            ),
          ),
          const SizedBox(width: 6),
          // On EVERY section, not just the ones we expect people to skip. A
          // section without the word reads as the required one.
          Text(
            optional,
            style: TextStyle(fontSize: 10.5, color: context.colors.muted),
          ),
        ],
      ),
    );
  }
}

/// The §3.6 mismatch note. Deliberately not [AppSemantics.danger] and
/// deliberately not beside the save button: it is an observation, not an error,
/// and the save it sits above is going to succeed.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('declared-mismatch'),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border.all(color: AppSemantics.warn.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11, height: 1.5, color: context.colors.text),
      ),
    );
  }
}

/// A selectable chip with a target you can actually hit.
class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _TapTarget(
      onTap: onTap,
      selected: selected,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? context.accent.onAccent : context.colors.text,
        ),
      ),
    );
  }
}

/// The one place [kDeclaredTapTarget] is applied, so no control in this dialog
/// can be added without it.
class _TapTarget extends StatelessWidget {
  const _TapTarget({
    super.key,
    required this.child,
    required this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        // 🔴 No `alignment:` — see `devices_page.dart`'s `_RowAction`: a
        // [Container] with one wraps its child in an [Align] that expands to the
        // incoming constraints, which inside a [Wrap] would make every chip the
        // full width of the dialog.
        constraints: const BoxConstraints(
          minHeight: kDeclaredTapTarget,
          minWidth: kDeclaredTapTarget,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? context.accent.accent : context.colors.panel2,
          border: Border.all(
            color: selected ? Colors.transparent : context.colors.line,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        // Centre WITHOUT an `alignment:` — a [Row] sized to its child keeps the
        // box hugging the text while still centring it vertically inside the
        // 40 dp minimum.
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [child],
        ),
      ),
    );
  }
}

/// A plain free-text field. No formatter, no validator, by design (§3.3).
class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(fontSize: 13, color: context.colors.text),
      cursorColor: context.accent.accent,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.all(11),
      ),
    );
  }
}

/// Dialog action button — the same shape as `alias_dialog.dart`'s, kept a
/// private copy rather than shared because the two dialogs are free to diverge
/// and a shared one would make each of them a constraint on the other.
class _DialogButton extends StatelessWidget {
  const _DialogButton({
    super.key,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        constraints: const BoxConstraints(minHeight: kDeclaredTapTarget),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? context.accent.accent : context.colors.panel2,
          border: Border.all(
            color: filled ? Colors.transparent : context.colors.line,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: filled ? context.accent.onAccent : context.colors.muted,
          ),
        ),
      ),
    );
  }
}
