# TWF status register (selector `0x20`)

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §8.4 TWF status flags, including the TWF **value** `0x20` / charging direction

> This is a subsection of **§8 Telemetry parsing**; the `b[n]` notation and the
> pack formula table live in [`telemetry-decoding.md`](telemetry-decoding.md).
>
> 🔑 **Read the naming-collision box below before anything else in this file.**
> The TWF *register* and one TWF *value* are both written `0x20`, and
> conflating them has already cost this project one retracted finding.
> ⚠️ **The same trap now exists for `0x21`** (added 2026-08-13): in this file
> `0x21` is a TWF **value**; elsewhere in the spec `0x21` is the **temperature
> selector**. They are unrelated.

---

### 8.4 TWF status flags (selector `0x20`)

The reference app tests individual bit positions of `b4` to set protection
booleans and a status message. **The exact bit→meaning mapping is unverified** —
see §10.

**Values observed on the wire** (baseline: whole-corpus re-walk 2026-07-30;
the `0x21` row was added 2026-08-13):

| `b4` | Seen on | Context |
|---|---|---|
| `0x00` | most units, most sessions | the normal/idle value |
| `0x01` | a unit at PVLT 9.84 V with a 1.75 V cell imbalance; also a unit at a wholly normal PVLT 13.25 V; and ~10 % of power-bank samples while discharging | see below |
| `0x20` | **power banks only** (`0x10 = 0x22`) — 2,769 frames; **0 frames across 14,857 battery/capacitor samples** (13,574 corpus + 1,283 added by a 2026-07-30 two-device capture) | **charging.** PVLT ≈3.8–4.2 V is the SINGLE-CELL voltage, SVLT ≈9.0 V is the PD charging INPUT — not a 12 V pack in trouble |
| **`0x21`** | one power bank, **exactly 1 frame** (2026-08-13) | bit 0 **and** bit 5 set together. The frame sits on the `0x20` → `0x01` boundary, at the poll where a charge terminated at a full pack. It is complete inside a single RX line and its XOR checks, so it is not a re-sync artefact |

⚠️ **A further 84 `0x20` frames sit in sessions with no `0x10` attribution.**
Walked frame by frame, all 84 are power banks (PVLT ≈ 4 V, SVLT ≈ 9 V). They are
listed separately rather than folded in, because "unattributed" is exactly the
condition that produced the misreading described below.

Only **two** of the eight bits have ever been non-zero — bit 0 and bit 5 — but
**all four combinations of those two bits have now been observed**: `0x00`,
`0x01`, `0x20` and `0x21`. The other six bits are still untested.

> 🔴 **Value list corrected 2026-08-13 — `0x21` is the fourth value.** The
> paragraph above previously read:
>
> > Only **two** of the eight bits have ever been non-zero — bit 0 and bit 5 (the
> > observed values are `0x00`, `0x01` and `0x20`). Most of the field is untested.
>
> That was a statement about the corpus, and the corpus grew: a power-bank
> capture taken across charge → charge-terminates-at-full carries one frame with
> `b4` = `0x21`, between the last `0x20` frame and the first `0x01` frame.
> **This corrects the list of values seen. It does not change what any bit
> means** — the bit-semantics text in this section is untouched, and the counts
> in the direction tables below, which were computed before this capture, still
> stand as written.

> ⚠️ 🔲 **Hypothesis, ONE physical unit — bit 5 = charging, bit 0 = pack full.**
> Four captures on the **same** power bank, same day, same build, with the port
> state annotated by the reporter, put a value in each cell of a 2×2 table: idle
> below full → `0x00`; idle at full → `0x01`; charging below full → `0x20`;
> charging at full → `0x21`. Two of the four close the same boundary from
> opposite directions, and were analysed independently of one another:
>
> * from the **discharge** side, the capture's only `0x01` → `0x00` transition
>   lands **1 ms** from the SOC field's 100 → 99 step — same poll burst, adjacent
>   frame. Pairing the two fields frame by frame agrees on **5,010 of 5,011**
>   samples; the single disagreement is that 1 ms boundary itself.
> * from the **charge** side, the sequence `0x20` → `0x21` → `0x01` at the moment
>   charging stopped on a full pack. The existence of a `0x21` frame was written
>   down as a prediction *before* this capture was examined.
>
> **It is still one unit, so this is not a finding.** Under this project's
> landing rule a bit meaning needs several independent units or vendor-side
> corroboration; nothing in this box amends the bit semantics stated above, and
> no client should act on it. Bit 0 in particular already has counterexamples on
> other classes (see the coverage gaps below) — if this reading is right at all,
> it is class-dependent.

> ⚠️ **A TWF value is not constant for a session.** An earlier revision of this
> section said it was. It is not: a power bank moves between ~~`0x00`, `0x01` and
> `0x20`~~ **`0x00`, `0x01`, `0x20` and `0x21`** (🔴 fourth value added
> 2026-08-13, see the table above) within a single connection as its charge state
> changes. A 2026-07-28 capture is the strongest single data point available: two
units on one phone within the same minute — a faulty one (PVLT 9.84 V, far below
its class's 12.0 V UV threshold) reported `0x01` for all 557 frames, while a
healthy reference unit (PVLT 13.28 V) reported `0x00` for all 42. That is
suggestive of **bit 0 = under-voltage**, but it is **not sufficient**: an earlier
capture shows `0x01` on a unit sitting at a perfectly normal 13.25 V. Either the
bit means something else, or its meaning is class-dependent.

### TWF **value** `0x20` implies charging, on power banks (2026-07-29; arrow corrected 2026-08-01)

> 🔑 **Naming collision — read this before the rest of the subsection.** The TWF
> **register** is *selector* `0x20`. The TWF **value** `0x20` is a bit pattern
> carried in that register's `b4`. They are unrelated, and conflating them has
> already cost this project one retracted finding. **Everything below is about
> the value.** Where ambiguity is possible it is written **TWF = `0x20`** for the
> value and **selector `0x20`** for the register.

Direction cross-check over the power-bank corpus. One observation = one complete
poll burst, de-duplicated per physical unit; direction taken from the `0x49` /
`0x4A` current fields:

| TWF `b4` value | charging | discharging |
|---|---|---|
| `0x20` | **485** | **0** |
| `0x00` | 23 | 2,027 |
| `0x01` | 6 | 58 |

*(Whole-corpus re-walk 2026-08-01: 2,613 de-duplicated bursts across four
power-bank units, ~5× the 2026-07-29 baseline whose figures this table replaces.
14 bursts straddling a direction change, where both current fields are non-zero,
belong to neither column and are omitted.)*

**The implication that holds is TWF = `0x20` ⇒ charging** — 485 / 485, no
counterexample in the corpus (✅ verified). **The converse, charging ⇒ TWF =
`0x20`, is false:** **29** charging bursts carry `0x00` or `0x01` instead —
trickle charge (single-digit to ~60 mA) and the first burst or two of start-up
delay after a charger is connected.

**Strengthened 2026-08-05 — a second physical unit, at 20× the sample count.**
Until now the second-by-second alignment behind this implication came from a
single unit. A 10 h 32 m capture at 1 Hz on a **fifth power-bank unit** — the
first of them polled fast enough to test alignment at the sampling limit — gives:

| | bursts |
|---|---|
| TWF `b4` = `0x20` **and** `0x49` current > 0 | **9,293** |
| TWF `b4` = `0x00` **and** `0x49` current = 0 | **26,838** |
| **disagreeing** | **15** (0.04 %) |

All fifteen were read individually: every one sits either **within one second of
a charge starting or stopping**, or on the 2–5 mA measurement floor where the
current field itself has not yet resolved. ⇒ the alignment is exact to the limit
of the sampling rate, and the `0x20` ⇒ charging implication now rests on **two
physical units**, clearing the multi-unit bar.

> 🔴 **Superseded 2026-08-01 — the arrow was written backwards.** This paragraph
> previously read:
>
> > **The forward direction holds — charging ⇒ `0x20` — but the reverse does
> > not.** Eleven charging bursts report `0x00`: trickle charge (2–60 mA) and
> > about one burst of start-up delay after the charger is connected.
>
> Those eleven bursts are precisely counterexamples to *charging ⇒ `0x20`*, so
> the sentence contradicted its own next clause **and** its own table, which
> already showed `0x20` → 41 charging / 0 discharging — i.e. the `0x20` ⇒
> charging direction. This is a fix to the document's internal logic; the
> underlying measurement never changed, only grew.

> ⚠️ 🔲 **Not reproduced: a discharging burst carrying TWF = `0x20`.** An earlier
> revision of this subsection stated that an independent second-unit capture
> contained one, as a transition artefact, and concluded "`0x20` therefore does
> not prove charging". The 2026-08-01 whole-corpus re-walk finds **0 such bursts
> out of 2,613**. The claim is left standing rather than deleted — it may have
> come from unattributed or un-de-duplicated data, which is exactly the condition
> this section warns about below — but it currently has **no reproducible basis**
> and its original capture has not been relocated. **Status: unresolved.** Until
> then, keep writing this as a one-way implication and never as an equivalence.

⚠️ **TWF is therefore NOT usable as the direction signal.** Use the `0x49` /
`0x4A` current fields, which carry a magnitude. Deriving direction from this byte
would show "discharging" during trickle charge — that is what the 29
counterexamples above are.

**Guidance for implementers.** **Do not present any TWF bit as a fault, not even
a hedged one, until a controlled experiment settles it.**

This advice previously read: label it "suspected", show the raw byte, never
drive a destructive action. An implementation followed that guidance exactly —
and a dealer still concluded from the screen that a healthy power bank was
faulty while it charged normally. The hedge is not protection: a warning banner
on a dashboard is read as a verdict regardless of its wording, and the raw byte
shown beside it means nothing to a vehicle owner.

The failure ran deeper than wording. The rule was derived from a capture that
mixed several units with no per-device attribution, so a power bank's normal
4 V cell reading was taken for a 12 V pack collapsed to 4 V. **Before drawing any
conclusion from a byte, confirm which unit produced it.**

**Known coverage gaps** (both are reasons not to trust any single bit):

* A 2026-07-19 capacitor that the vendor app flagged as faulty reported `0x00`
  for the entire session.
* A 2026-07-28 battery with an unmistakable fault (a 1.75 V cell imbalance and a
  5.07 V terminal-to-string voltage gap) reported `0x01`, **not** `0x20`.

**A research lead, not a signal: `SVLT − PVLT`.** On the two packs whose state was
independently known, the gap between the string voltage (`0x37`) and the terminal
voltage (`0x19`) tracked that state:

| Unit | `SVLT − PVLT` | Independently known state |
|---|---|---|
| capacitor, healthy | −0.04 V | healthy |
| capacitor, 2026-07-19 | 3.11 V | vendor app showed a fault |
| battery, 2026-07-28 | **−0.040 V** | healthy reference (n = 42) |
| battery, 2026-07-28 | **5.07 V** | cell imbalance, deeply discharged (n = 557) |

**This is four units. It is not enough for a classifier, and this document
deliberately does not state a threshold.**

Stating one was tried and it was wrong in both directions. Measured across the
whole corpus (re-walk 2026-07-30), a ">3 V = suspect" rule would have:

* flagged **42.5 % of power-bank discharge bursts** (184/433) — every USB-PD
  output, where the port sits at 9–13 V above a single cell by design;
* flagged **91.9 % of power-bank charge bursts** (237/258) — but *not* the other
  8.1 %, which are 5 V slow charging. So it is not even consistently wrong.

Class medians, for scale:

| class | median `SVLT − PVLT` | n |
|---|---|---|
| capacitor | −0.04 V | 4,473 |
| battery | **−0.06 V** | 6,039 |
| **power bank** | **+1.45 V** (max **+9.49 V**) | 4,489 |

> 📌 The battery median was previously published as −0.09 V. That figure was
> computed over a sample that **included unattributed sessions** — and those
> sessions contain power-bank frames (§10.1). A section whose whole point is
> "confirm which unit produced the byte" had itself not done so. The clean,
> `0x10`-attributed value is −0.06 V.

**Treat this as a direction for a controlled experiment**, not as something to
render: capture a healthy pack parked long enough to rule out self-discharge, and
a faulty one under the same conditions. Until then, an implementation that shows
this to a user is repeating the TWF mistake with different arithmetic.

> Note the corollary for UI work: a device reporting an abnormal condition may do
> so *only* through registers that require the connect burst (`0x10`, `0x23`,
> `0x2B`, `0x96`). If the keep-alive write path is broken, none of them arrive
> and the client cannot tell "healthy" from "faulty" (see §10.2).
