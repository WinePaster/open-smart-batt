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

---

### 8.4 TWF status flags (selector `0x20`)

The reference app tests individual bit positions of `b4` to set protection
booleans and a status message. **The exact bit→meaning mapping is unverified** —
see §10.

**Values observed on the wire** (baseline: whole-corpus re-walk 2026-07-30):

| `b4` | Seen on | Context |
|---|---|---|
| `0x00` | most units, most sessions | the normal/idle value |
| `0x01` | a unit at PVLT 9.84 V with a 1.75 V cell imbalance; also a unit at a wholly normal PVLT 13.25 V; and ~10 % of power-bank samples while discharging | see below |
| `0x20` | **power banks only** (`0x10 = 0x22`) — 2,769 frames; **0 frames across 14,857 battery/capacitor samples** (13,574 corpus + 1,283 added by a 2026-07-30 two-device capture) | **charging.** PVLT ≈3.8–4.2 V is the SINGLE-CELL voltage, SVLT ≈9.0 V is the PD charging INPUT — not a 12 V pack in trouble |

⚠️ **A further 84 `0x20` frames sit in sessions with no `0x10` attribution.**
Walked frame by frame, all 84 are power banks (PVLT ≈ 4 V, SVLT ≈ 9 V). They are
listed separately rather than folded in, because "unattributed" is exactly the
condition that produced the misreading described below.

Only **two** of the eight bits have ever been non-zero — bit 0 and bit 5 (the
observed values are `0x00`, `0x01` and `0x20`). Most of the field is untested.

> ⚠️ **A TWF value is not constant for a session.** An earlier revision of this
> section said it was. It is not: a power bank moves between `0x00`, `0x01` and
> `0x20` within a single connection as its charge state changes. A 2026-07-28 capture is the strongest single data point available: two
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
