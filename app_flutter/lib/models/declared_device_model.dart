/// OpenSmartBatt — what the USER says their device is (design 0066).
///
/// PURE Dart (no Flutter imports). The l10n layer turns these slugs into words;
/// nothing here is ever shown as-is except the motorcycle-battery model names,
/// which are catalogue part numbers rather than sentences.
///
/// ## 🔴 The one rule this file exists to keep (design 0066 §3.5)
///
/// **A value in here NEVER touches [ProductClass].** The wire decides the class
/// — deterministically, from `0x10 b4`, since design 0007 — and a user's answer
/// is stored in its own columns beside it, never merged into it.
///
/// The reason is not tidiness. `docs/feedback-triage/discipline.md` records
/// three separate incidents (FB-23 / FB-33 / FB-32) that are all ONE failure
/// mode: a piece of state kept in two places, updated in one of them. Fold a
/// declaration into `product_class` and three months from now nobody can tell
/// which rows were MEASURED and which were TYPED — and telling those apart is
/// the entire purpose of collecting this. Hence also the corollary the UI has to
/// honour: **a declared value gates nothing and displays nothing.** A user who
/// picks the wrong entry must not end up looking at a different screen, because
/// then their next bug report describes a screen we cannot reproduce.
///
/// ## Why the field exists at all (design 0066 §1.2)
///
/// The wire answers "which of three classes", and that is all it answers. Of the
/// eleven distinctions we actually care about — bike vs car capacitor, gen 1 vs
/// gen 2, bike vs car battery, battery vs retrofit lid, old vs new catalogue
/// naming, JP vs EU case, orange vs purple label, nominal capacity, … — exactly
/// ONE (flagship, `0x18` vs `0x17`) is visible on the wire. The other ten have
/// been established, when at all, by asking the owner in a chat window. This
/// turns that chat into a field.
library;

import 'product_class.dart';

/// The five things a user can say their unit is (design 0066 §3.2, first level).
///
/// Deliberately NOT a superset or subset of [ProductClass]: `powerBank` is the
/// only name the two enums share, and even there they are answering different
/// questions ("what did the byte say" vs "what does the owner call it"). Keeping
/// the vocabularies separate is what stops a later refactor from "simplifying"
/// them into one field.
enum DeclaredCategory {
  motorcycleCapacitor('motorcycle-capacitor'),
  carCapacitor('car-capacitor'),
  motorcycleBattery('motorcycle-battery'),
  carBattery('car-battery'),
  powerBank('power-bank');

  const DeclaredCategory(this.storageKey);

  /// Stable slug for SQLite and for the export preamble.
  ///
  /// A hyphenated slug rather than the enum [name], because this value is
  /// written into files that are read months later by `grep` — and unlike
  /// `ProductClass.storageKey`, which only ever round-trips through our own
  /// database, this one is part of a wire format we publish.
  final String storageKey;

  /// Inverse of [storageKey]. An unknown or absent slug reads back as null —
  /// "the user has not answered", which is a legitimate and common state — and
  /// never as a guess.
  static DeclaredCategory? fromStorageKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final c in DeclaredCategory.values) {
      if (c.storageKey == key) return c;
    }
    return null;
  }
}

/// One second-level group of model options (design 0066 §3.2).
///
/// A GROUP rather than a flat list because the motorcycle battery line has four
/// of them and they are mutually exclusive answers to "which catalogue are you
/// holding": old naming, new naming B (65 mm), new naming A (87 mm), retrofit
/// lid. Flattening them would put `9.0A` and `7.5Ah-A` side by side, and those
/// two are THE SAME PHYSICAL BATTERY under two catalogue revisions — the owner
/// explicitly rejected showing both names at once (§4), because a user holding
/// one of them would first have to learn that fact.
class DeclaredModelGroup {
  const DeclaredModelGroup({required this.id, required this.models});

  /// Group id, used as the l10n key suffix. Null on a category whose options
  /// need no heading (the capacitor generations are one flat list of three).
  final String? id;

  /// Model slugs, in menu order.
  final List<String> models;
}

/// The retrofit smart lid — a bike battery somebody fitted our lid to.
///
/// 🔑 A BRANCH with a slug of its own, not a free-text note (design 0066 §3.2).
/// A note cannot be counted: field reports spell it 改上蓋 / 智慧上蓋 / 上蓋H2,
/// and a `SELECT count(*)` over free text finds none of them reliably. As a slug
/// it is countable, and the free-text box that appears NEXT TO it still carries
/// the detail. It gets no model list because it has no catalogue slot to have
/// one — it is somebody else's battery under our lid.
const String kRetrofitLidModel = 'retrofit-lid';

/// Capacitor generations, shared by the bike and car capacitor lines.
///
/// The wire cannot separate the first two at all (same `0x10` payload, same BLE
/// name `RCE-SCAP_II`), which is why they are here. `flagship` IS separable
/// (`0x18`, three units, 2026-08-01) and is offered anyway — the point is to
/// collect the answer, and having one checkable entry among three is what makes
/// §3.6's hint worth anything.
const List<String> kCapacitorGenerations = <String>['gen1', 'gen2', 'flagship'];

/// Second-level options for [category], in menu order.
///
/// An empty list means "this category has no model list": the car battery asks
/// three other questions instead (§3.3), and the power bank asks nothing.
List<DeclaredModelGroup> declaredModelGroups(DeclaredCategory category) {
  switch (category) {
    case DeclaredCategory.motorcycleCapacitor:
    case DeclaredCategory.carCapacitor:
      return const [DeclaredModelGroup(id: null, models: kCapacitorGenerations)];
    case DeclaredCategory.motorcycleBattery:
      // Transcribed from the two catalogue sheets in
      // `docs/devices/motorcycle-battery.md`. The A/B suffix is case THICKNESS
      // (87 mm / 65 mm), not a revision — which is why the two new-naming groups
      // are separate headings rather than one list of eight.
      return const [
        DeclaredModelGroup(id: 'oldGen', models: ['6.0A', '6.0B', '9.0A']),
        DeclaredModelGroup(
            id: 'newGenB', models: ['5.0Ah-B', '7.5Ah-B', '10.0Ah-B']),
        DeclaredModelGroup(
          id: 'newGenA',
          models: ['5.0Ah-A', '7.5Ah-A', '10.0Ah-A', '12.5Ah-A', '17.5Ah-A'],
        ),
        DeclaredModelGroup(id: 'retrofit', models: [kRetrofitLidModel]),
      ];
    case DeclaredCategory.carBattery:
    case DeclaredCategory.powerBank:
      return const [];
  }
}

/// Every model slug [category] accepts, flattened — for validation and tests.
List<String> declaredModelsFor(DeclaredCategory category) =>
    [for (final g in declaredModelGroups(category)) ...g.models];

/// Car-battery case standards (design 0066 §3.2). JP / EU differ in the case and
/// the terminals and nothing that reaches the wire (`todo.md:648`).
const List<String> kDeclaredRegions = <String>['jp', 'eu'];

/// Car-battery label colours. A sticker; likewise invisible to the wire.
const List<String> kDeclaredLabels = <String>['orange', 'purple'];

/// Suggested capacities for the car battery — SUGGESTIONS, never a whitelist.
///
/// 🔑 The field is free text on purpose (design 0066 §3.3). `todo.md:647`
/// suspects that the "40Ah" in the dealer's description is not a capacity at all
/// but a JIS case code (`40B19L`), and there is no other way to find out: the
/// wire registers that look like capacity are under a standing red line
/// (`battery-config-registers.md`) precisely because nobody could confirm what
/// they mean. If somebody types `40B19L` we have our answer; if a hundred people
/// tap 40 we have the other one. A dropdown would have destroyed the question.
const List<String> kDeclaredCapacitySuggestions = <String>[
  '40',
  '48',
  '50',
  '60',
];

/// Why a declaration and the wire disagree — or null when they do not, or when
/// there is nothing to compare (design 0066 §3.6).
///
/// 🔴 **A HINT, NEVER A BLOCK.** The caller must show this and save anyway. A
/// mismatch has two causes and we cannot tell them apart from here: the user
/// tapped the wrong entry, or they are holding hardware whose device-type byte
/// this build has never seen. The second is the single most valuable thing this
/// whole feature could surface, and refusing the save would throw it away and
/// leave the user with a form they cannot submit.
enum DeclaredMismatch {
  /// A capacitor was declared and the byte says otherwise.
  expectedCapacitor,

  /// A battery was declared and the byte says otherwise.
  expectedBattery,

  /// A power bank was declared and the byte says otherwise.
  expectedPowerBank,

  /// `flagship` was declared and the unit is a `0x17`, not a `0x18`.
  ///
  /// Checkable ONLY while the unit is on the link: [ProductClass] folds both
  /// capacitor generations into one value (deliberately — see
  /// `product_class.dart`), so this needs the raw byte, and `saved_devices` does
  /// not keep one. Off the link the check is silently skipped, which is the
  /// honest outcome: we have no evidence, so we say nothing.
  expectedFlagship,
}

/// Compare a declaration against what the wire said. Pure.
///
/// [wireClass] is the persisted / resolved [ProductClass]; [wireDeviceType] is
/// the raw `0x10 b4` byte when the unit is live, else null. [ProductClass.unknown]
/// never produces a mismatch — an unclassified unit is precisely the case where
/// the user's answer is worth more than ours.
DeclaredMismatch? declaredWireMismatch({
  required DeclaredModel declared,
  required ProductClass wireClass,
  int? wireDeviceType,
}) {
  final category = declared.category;
  if (category == null) return null;
  if (wireClass != ProductClass.unknown) {
    switch (category) {
      case DeclaredCategory.motorcycleCapacitor:
      case DeclaredCategory.carCapacitor:
        if (wireClass != ProductClass.supercapacitor) {
          return DeclaredMismatch.expectedCapacitor;
        }
      case DeclaredCategory.motorcycleBattery:
      case DeclaredCategory.carBattery:
        if (wireClass != ProductClass.smartBattery) {
          return DeclaredMismatch.expectedBattery;
        }
      case DeclaredCategory.powerBank:
        if (wireClass != ProductClass.powerBank) {
          return DeclaredMismatch.expectedPowerBank;
        }
    }
  }
  // Reached only once the category agrees (or could not be judged). Checking the
  // generation of a unit whose class is already wrong would stack two hints for
  // one mistake, and the first one is the actionable half.
  if (declared.model == 'flagship' &&
      wireDeviceType != null &&
      wireDeviceType != kSuperCapacitorGen3DeviceType) {
    return DeclaredMismatch.expectedFlagship;
  }
  return null;
}

/// What the user said about one unit — the seven columns of design 0066 §3.1,
/// carried as one value.
///
/// 🔴 ONE OBJECT rather than seven fields on [SavedDevice], and the reason is
/// `copyWith`. Every field here is nullable and every one of them must be
/// CLEARABLE — "I picked orange last week and I am no longer sure" has to be
/// expressible, or the data quietly ratchets. Dart's `x ?? this.x` cannot say
/// that, so seven independent fields would have needed seven `clearX` flags;
/// this project already documents that trap twice (`gCalibration`,
/// `clearAccentTheme`). With a value object, clearing is just [none].
class DeclaredModel {
  const DeclaredModel({
    this.category,
    this.model,
    this.region,
    this.label,
    this.capacity,
    this.note,
    this.declaredAt,
  });

  /// Nothing declared. What every pre-v20 row reads back as, and what the user
  /// gets by clearing the form.
  static const DeclaredModel none = DeclaredModel();

  /// First level (§3.2). Null = not answered.
  final DeclaredCategory? category;

  /// Second-level slug, or [kRetrofitLidModel]. Null = not answered, which is
  /// explicitly allowed: R1 accepts that the list will go stale, and a user with
  /// next year's hardware can still record the category.
  final String? model;

  /// Car battery only: `jp` / `eu`.
  final String? region;

  /// Car battery only: `orange` / `purple`.
  final String? label;

  /// Free text (§3.3). Never parsed, never used to derive anything.
  final String? capacity;

  /// Free note; on the retrofit-lid branch the UI relabels it but the column is
  /// the same one — two columns holding "a sentence the user typed" is how they
  /// start disagreeing.
  final String? note;

  /// When the form was last saved. R2's handle on "which cohort filled this in".
  final DateTime? declaredAt;

  /// True when the user has said nothing at all.
  ///
  /// [declaredAt] is deliberately NOT counted: a timestamp with no content is a
  /// record of someone opening a dialog, not of an answer, and treating it as
  /// content would make an empty declaration indistinguishable from a real one
  /// in the export count.
  bool get isEmpty =>
      category == null &&
      (model == null || model!.isEmpty) &&
      (region == null || region!.isEmpty) &&
      (label == null || label!.isEmpty) &&
      (capacity == null || capacity!.isEmpty) &&
      (note == null || note!.isEmpty);

  bool get isNotEmpty => !isEmpty;

  /// 🔴 Nullable arguments here MEAN "clear it", unlike the `x ?? this.x`
  /// convention everywhere else in this codebase — see the class comment. Only
  /// the fields named in a call are touched; everything else is copied through
  /// by being passed explicitly at the call site, which is exactly the friction
  /// that keeps a partial edit from silently wiping a neighbouring answer.
  DeclaredModel copyWith({
    DeclaredCategory? category,
    String? model,
    String? region,
    String? label,
    String? capacity,
    String? note,
    DateTime? declaredAt,
  }) =>
      DeclaredModel(
        category: category ?? this.category,
        model: model ?? this.model,
        region: region ?? this.region,
        label: label ?? this.label,
        capacity: capacity ?? this.capacity,
        note: note ?? this.note,
        declaredAt: declaredAt ?? this.declaredAt,
      );

  /// The seven `saved_devices` columns (schema v20).
  ///
  /// 🔴 Empty strings are normalised to NULL on the way in. A user who focuses
  /// the capacity field, types nothing and saves must leave NULL behind: "" and
  /// NULL would then be two spellings of "no answer", and the day somebody runs
  /// `WHERE declared_capacity IS NULL` to count non-answers, half of them are
  /// missing. The migration writes NULL for the same reason (M7).
  Map<String, Object?> toMap() => {
        'declared_category': category?.storageKey,
        'declared_model': _blankToNull(model),
        'declared_region': _blankToNull(region),
        'declared_label': _blankToNull(label),
        'declared_capacity': _blankToNull(capacity),
        'declared_note': _blankToNull(note),
        'declared_at': declaredAt?.millisecondsSinceEpoch,
      };

  static DeclaredModel fromMap(Map<String, Object?> m) => DeclaredModel(
        category:
            DeclaredCategory.fromStorageKey(m['declared_category'] as String?),
        model: _blankToNull(m['declared_model'] as String?),
        region: _blankToNull(m['declared_region'] as String?),
        label: _blankToNull(m['declared_label'] as String?),
        capacity: _blankToNull(m['declared_capacity'] as String?),
        note: _blankToNull(m['declared_note'] as String?),
        declaredAt: m['declared_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['declared_at'] as num).toInt()),
      );

  static String? _blankToNull(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  /// Machine-stable `key=value` rendering for the export preamble (§3.8).
  ///
  /// Unknown fields are OMITTED rather than written as `-`: whether the whole
  /// block is present is already answered by the required `declared: count=`
  /// line above it, so an empty token here would carry no information and would
  /// read as a bug — the rule every other optional field in the preamble
  /// follows. Never localized; the reader is whoever receives the file.
  String get exportValue => [
        if (category != null) 'category=${category!.storageKey}',
        if (model != null && model!.isNotEmpty) 'model=$model',
        if (region != null && region!.isNotEmpty) 'region=$region',
        if (label != null && label!.isNotEmpty) 'label=$label',
        // 🔴 The capacity is FREE TEXT a user typed, so it can contain a space
        // and break the `key=value` split every ingest recipe does. Spaces
        // collapse to `_`; a value that was `40 B19L` still reads as one token
        // and is still recognisably what they typed.
        if (capacity != null && capacity!.isNotEmpty)
          'capacity=${_token(capacity!)}',
        // 🔴 The note IS exported, in full (owner ruling 2026-08-17).
        //
        // It shipped as `note=yes` on the reasoning that a note is free text
        // about the user's own vehicle and `save_device_flow.dart` withholds
        // the alias from the log for the same reason. ⚠️ **That precedent does
        // not exist** — the alias is exported, as `label=` in
        // `export_header.dart`. So the rule was withholding one thing a user
        // typed while emitting another, with nothing to tell them apart.
        //
        // 🔑 And it cost more than consistency: the retrofit-lid branch has NO
        // model list by design (there is no catalogue slot for a retrofit), so
        // its free text IS its content. With the note withheld we learned that
        // a unit was a retrofit and nothing whatever about what the retrofit
        // was — which is the one thing that branch exists to ask.
        //
        // Same `_token` as the capacity: a note can run to several lines, and a
        // newline would end the header line early and orphan the rest into
        // something an ingest recipe reads as a new key.
        if (note != null && note!.isNotEmpty) 'note=${_token(note!)}',
        if (declaredAt != null) 'at=${declaredAt!.toIso8601String()}',
      ].join('  ');

  static String _token(String s) => s.replaceAll(RegExp(r'\s+'), '_');

  @override
  bool operator ==(Object other) =>
      other is DeclaredModel &&
      other.category == category &&
      other.model == model &&
      other.region == region &&
      other.label == label &&
      other.capacity == capacity &&
      other.note == note &&
      other.declaredAt == declaredAt;

  @override
  int get hashCode =>
      Object.hash(category, model, region, label, capacity, note, declaredAt);

  @override
  String toString() => 'DeclaredModel(${exportValue.isEmpty ? '-' : exportValue})';
}
