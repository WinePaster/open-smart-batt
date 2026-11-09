# Power banks — register map (device-type `0x22`)

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved ~~so every cross-reference in this document
> set (and in the app source) still resolves~~ 🔵 **2026-09-07: that is still
> true of `§9.1` — it is still this file and still names what it always named —
> but it is no longer the whole story, because one section has since left this
> file under a number of its own.** The index maps `§` to file.
>
> **Covers:** §9.1 Power-bank register map
>
> ⛔ **`0x4B` `b7` — the port and protocol flags — is NOT covered here any
> more.** It became **§9.2** on 2026-09-07 and lives in
> [`power-bank-port-flags.md`](power-bank-port-flags.md). A reference meaning
> *the port-flag byte specifically* should say **§9.2**; a reference meaning
> *the power-bank register map* stays **§9.1** and needs no change.

> ⚠️ Despite the numbering, **§9.1 is not a subsection of §9** — and neither is
> §9.2. §9 is the corrections table, in
> [`corrections-and-glossary.md`](corrections-and-glossary.md); §9.1 is this
> register map; §9.2 is the port-flag byte, in
> [`power-bank-port-flags.md`](power-bank-port-flags.md). §9.1's number is
> inherited from the original document and is kept so existing `§9.1` references
> (including in the app source) resolve; **§9.2 was allocated on 2026-09-07**,
> on the same one-file-one-`§` pattern the rest of this document set uses.

> 📏 **Size self-report (`wc -l -c`, 2026-09-07 — after the §9.2 split *and*
> after the Type-A section followed it later the same day):** this file is
> **~~320 lines / 23,061 B~~ 306 lines / 22,819 B**. The struck figure was
> correct between the two moves. It was **857 lines / 58,491 B** immediately
> before the first split. Thresholds are **1,000 lines / 100,000 B**, and **no
> exemption covers this file**. Re-measure rather than quoting this line — it is
> a snapshot, not a current value.

---

## 9.1 Power-bank register map (device-type `0x22`)

Everything below was decoded from this project's own captures during 2026-07-29,
cross-checked against the vendor app's own on-screen readings where a screenshot
was taken at the same minute. Baseline: whole-corpus re-walk 2026-07-30.

> ⚠️ **Two power-bank captures overlap.** One session set is byte-identical to,
> and another is a prefix of, a longer capture of the same unit. Counts below are
> **de-duplicated**; a naive union double-counts 46 bursts.

| Selector | LEN | Layout | Confidence |
|---|---|---|---|
| `0x49` | 4 | `[u16 mV][u16 mA]` — the **charge**-side pair. The mV field is the **PORT** voltage (the same quantity as `0x37`) | ✅ direction established; current field decoded. mV field identified but **not decoded by this app** |
| `0x4A` | 4 | `[u16 mV][u16 mA]` — the **discharge**-side pair. The mV field is the **CELL** voltage (the same quantity as `0x19`) | ✅ |
| `0x4B` | 5 | `[u16 design capacity mAh][u8 SOC %][u8 port flags][u8 ?]` | ✅ for the first three fields |
| `0x4C` | 2 | `3c0a`, **constant in 691 of 691 frames** across 3 physical units and 2 phones | 🚫 not decoded — nothing varies, so nothing can be inferred |

### Direction: `0x49` vs `0x4A`

The current field of exactly one of the two is non-zero at any time.

* **432 of 433** de-duplicated bursts are mutually exclusive.
* The single exception is a transition sample: the next burst is pure charging,
  with the `0x49` current climbing 0 → 2 → 36 mA.
* **No burst has ever had both currents zero** (0 of 715).
* An independent capture — second physical unit, second phone — reproduced this
  212 of 212.
* **A fifth physical unit, on a third phone, reproduced it at scale**
  (2026-08-05): **36,152** complete `0x10`+`0x49`+`0x4A`+`0x4B` bursts over
  10 h 32 m at 1 Hz, with **36,145 mutually exclusive**, **7** carrying both
  currents non-zero (0.02 % — every one inside the second a direction changes,
  at 2–5 mA), and **0** carrying both at zero.
  🔑 **This is the second physical unit on the CHARGING side.** Until it, the
  corpus covered discharging on three units but charging on only one, which is
  why the app's source carried a caveat saying so. Both halves now clear the
  multi-unit bar.

⇒ **Publish a magnitude and a direction; do not publish a signed current.**
Whether the current is *measured* at the cell or at the port is **not
established**, so the two are not interchangeable with a pack's signed `0x2E`.
(That is a separate question from *which existing voltage each mV field copies*,
which is settled immediately below — knowing where the voltage is sensed says
nothing about where the current is.)

### The two mV fields: `0x49` reads the PORT, `0x4A` reads the CELL ✅

*Added 2026-08-05.* Both registers are `[u16 mV][u16 mA]`, and until now only
their current halves had been characterised. Pairing each register with the
frames from **its own burst** identifies the voltage halves:

| Same-burst pairing | median difference | within ±30 mV |
|---|---|---|
| `0x49`.mV − `0x37` (port voltage) | **+4 mV** | 90.8 % (n = 36,145) |
| `0x4A`.mV − `0x19` (cell voltage) | **+4 mV** | 99.9 % (n = 36,145) |
| `0x49`.mV − `0x19` — **deliberately mis-paired control** | **+1,634 mV** | 0.0 % |

The control row is the point: a wrong pairing is off by three orders of
magnitude, so the +4 mV agreements are not an artefact of "all these numbers are
voltages". Re-run over the whole corpus, **five physical units**:

| Unit | `0x49` ↔ `0x37`: n / within ±30 mV | `0x4A` ↔ `0x19`: n / within ±30 mV |
|---|---|---|
| 1 | 36,145 / 90.8 % | 36,145 / 99.9 % |
| 2 | 101 / 92.1 % | 101 / 98.0 % |
| 3 | 347 / 91.1 % | 347 / 99.1 % |
| 4 | 41 / 95.1 % | 41 / 100.0 % |
| 5 | 164 / 85.4 % | 164 / 95.7 % |

✅ **Verified, five units — this clears the multi-unit bar.** The 5–15 % tail on
the `0x49` column is sampling skew, not disagreement: `0x37` free-runs at about
0.21 s while a poll burst arrives once a second, so same-burst pairing can pick
up a `0x37` reading as much as half a second stale. The `0x4A` column has no such
tail because `0x19` rides the poll burst itself.

⚠️ **What this does and does not say.** It establishes **which existing reading
each mV field duplicates** — nothing more. It is *not* a statement about where
the current is measured; the "not established" note above still stands, and
these two questions must not be collapsed into one.

🔲 **A recorded opportunity, deliberately not acted on.** `0x49`'s mV arrives in
the **same burst** as `0x4B`, whereas `0x37` — the port voltage a client
displays — free-runs on its own cadence. design 0035's status line concedes that
§4.5's same-burst coupling of the port voltage was never implemented, and books
it as an accepted deviation. If `0x49`'s mV *is* the port voltage, that deviation
could be closed by reading it instead. **This is noted, not decided**: the app
still reads only `f.u16(6)` (the current) from `0x49`, and changing that needs a
ruling of its own.

### `0x4B` — capacity and state of charge

* **Design capacity** = `b4b5`, big-endian. `0x2710` = 10000 on a unit rated
  10000 mAh; 691 of 691 frames agree. It is a nameplate constant, not a reading.
* **SOC** = `b6`, read directly as a percentage. A capture read 94 at the same
  minute the unit's own display showed 94 %, and fell 94 → 63 over 5 h 00 m 39 s
  with **no reversal**.
  ⚠️ **That monotonicity is a discharge property, not a general one.** SOC rises
  again while charging (observed 69→73, 69→70, 95→97) — as it should.
* **`b8` is NOT a temperature.** It was a candidate (it correlates with output
  power), but the vendor app displayed **33 °C** at a minute when `0x21` also read
  33 and `b8` read 47/48. Correlation with |current| is only r ≈ 0.5–0.7, one unit
  ran 33→73→67, and a single sample moved 29 → 65 → 28 within 8.9 s. **Not
  decoded.**
  * ⚠️ **Read that r ≈ 0.5–0.7 as an *un-lagged* figure, not as weak coupling.**
    On a 2026-08-13 capture (one unit, 186 same-burst `0x4B`+`0x4A`+`0x49`
    samples, median 4.96 s apart, driven through no-load → 5 V load → 12 V load →
    unload) the correlation between `b8` and the instantaneous cell-side power is
    **r = 0.695** — inside the band recorded above. (⚠️ Not the identical
    quantity: the r ≈ 0.5–0.7 above is against |current|, this one against
    cell-side power. They land in the same range; they are not the same fit.)
    Pass the power through a one-pole low-pass first and it climbs to
    **r = 0.980** at α = 0.05,
    i.e. **τ ≈ 99 s**; it falls away on either side (α = 0.1 → 0.952,
    α = 0.02 → 0.747), so the time constant is pinned rather than fitted.
    ⇒ Whatever `b8` is, it is a **slow variable, not an instantaneous reading**,
    and the low correlation above is what an instantaneous fit to a lagged signal
    looks like.
  * ⛔ **This changes how a number is read; it decodes nothing.** `b8` stays
    **undecoded**, and "NOT a temperature" above is untouched — that verdict rests
    on the vendor-app comparison and the 33→73→67 unit, neither of which this
    capture touches. One unit, one capture: **not a multi-unit result.**

### `0x4B` `b7` — port and protocol flags

🔵 **Moved 2026-09-07 — this section is now `§9.2`, in
[`power-bank-port-flags.md`](power-bank-port-flags.md).** It was **586 of this
file's 857 lines** (69 %), and the file was 143 lines from this project's
1,000-line ceiling with no exemption covering it. ⚠️ **The move was a size
split, not a revision — not a word of the section changed**, and it kept its
heading, so a title-anchored reference such as 〈`0x4B` `b7` — port and protocol
flags〉 still lands on it.

What is over there: the observed-value list, the bit table (bits 0–5), the two
2026-09-04 notes on bit 5 (why the label is no longer "PD", and the ±1,024 mV
misread), the bit-3 A/B and the 2026-09-03 pre-negotiation window, the bit-3 /
bit-4 pairing, `b7 = 0x00` as the boost rail off together with its five spurious
single-poll frames, and the four refuted readings of bit 0.

🔵 **A second section followed it the same day.** *Naming the Type-A path
without a Type-A bit* ✅ — the bit-1-clear-plus-discharging elimination rule,
29,114 / 0 across three units — was **left behind in the first pass and moved to
`§9.2` later on 2026-09-07**, again a size split with not a word of its body
changed. It belongs with the port flags: its opening sentence is *"after the
four refutations above"*, and those refutations are in `§9.2`. Keeping the two
apart cost **two cross-file pointers whose only job was to undo the split**, and
both are now gone. ⚠️ A title-anchored reference such as
`power-bank.md`〈Naming the Type-A path without a Type-A bit〉 **no longer
resolves** — it is now
[`power-bank-port-flags.md`](power-bank-port-flags.md)〈Naming the Type-A path
without a Type-A bit〉. The heading itself is unchanged.

📌 **The elimination rule is what names the Type-A path**, so the pending-items
rows below that mention "the elimination rule" now point across to `§9.2` for
its evidence — the rows themselves stayed here, see the note above that table.

⚠️ **`§9.1` did not change meaning.** It is still this file, so every existing
`§9.1` reference — including the ones in the app source — still resolves to
exactly what it always named. `§9.2` is **new**: use it when you mean the
port-flag byte *specifically*.

📌 **The pending-items table stayed here** (below), and it still collects the
open questions of both sections.

### Class-dependent layouts that catch people out

* **`0x4A`** — a pack-side reading of the same 4 bytes (§8.2) gives
  `3.955 / 1.081` for a payload that actually means **3955 mV and 1081 mA**. Both
  numbers look reasonable. This is the single most dangerous row in this document.
* **`0x21`** — LEN 1 on packs, **LEN 2 on power banks** (6,118 frames, `b5`
  constant `0xe2`). `b4` decodes as temperature identically on all three classes;
  **`b5` is not decoded.**
* **`0x37`** — on a power bank this is the USB **port** voltage, not a pack rail.
  Do not difference it against `0x19` (§8.4).

### `0x47` — per-cell voltages, pre-scaled (battery only)

`4 × big-endian u16`, in **mV, already scaled by the device** — so it needs no
VADJ. Only ever seen on device-type `0x02`.

#### ⚠️ `0x47` and `0x24` are **not** two views of one number

Earlier revisions of this section stated the identity
`0x47_mV = trunc(0x24_raw × VADJ)` and cited "20 of 20 exact". **That rule holds
on four units and fails completely on a fifth**, so it is not a property of the
protocol. Whole-corpus re-check, each `0x47` frame paired with the `0x24` frame
nearest in time:

| Capture | fw | VADJ | `mV = trunc(raw×VADJ)` | `raw = trunc(mV/VADJ)` |
|---|---|---|---|---|
| 4 car-class batteries (2026-07-29 ×2, 2026-07-30 ×2) | 1.02 / 1.03 | 20.10 / 20.30 / 20.36 / 20.46 | **24 / 24 ✅** | 0 / 24 |
| motorcycle-class battery (2026-07-30) | **1.00** | **20.00** | **0 / 20 ❌** | **20 / 20 ✅** |

The fifth unit's failure is **structural, not a tolerance problem**: at
VADJ = 20.00 the expression `trunc(raw × 20.00)` can only produce multiples of
20, and that unit's `0x47` reports 3357 / 3337 / 3364 / 3299 / 3386 / 3389 … —
none of which is. Solving for the VADJ that *would* satisfy the forward rule over
its 20 pairs yields an **empty interval** (`[20.1159, 20.0061)`), so no
calibration value rescues it. The inverse rule instead pins VADJ to
`(19.9939, 20.0000]` — bracketing the device's own `0x30` reading exactly.

⇒ **The two registers are independent readings of the same cells at different
resolutions.** On the four car-class units `0x24` is evidently the source and
`0x47` a pre-scaled copy; on the motorcycle unit `0x47` carries real precision
that the 8-bit `0x24` discards (1 LSB = 20 mV there). Whether firmware version,
device class, or the integral VADJ is the discriminator is **not determined** —
one capture from a second fw-1.00 unit would settle it.

**For an implementer:** prefer `0x47` where present, never *derive* either
register from the other, and never present a `0x24`-derived cell voltage as
though it had `0x47`'s resolution.

⚠️ **It still does not replace `0x24`:** `0x24` streams at 1.9–2.9 frames/second
while `0x47` answers `!#` and nothing else (§2) — **once per `!#`, not once per
session.** In the 2026-07-30 capture five `!#` writes produced exactly five
`0x47` frames across 23 hours, and the one session that never received an `!#`
got none at all.

> A method note that cost a wrong conclusion once: on a unit whose voltage is
> moving, `0x47` must be compared against the `0x24` frame **nearest in time**,
> not merely the last one seen. Comparing across a 24-second gap on a charging
> battery produced a uniform +20 mV discrepancy that looked like a broken formula
> and was really one raw LSB of charge.

### ⚠️ Pending items in this section, in one place

Everything above is either evidenced or marked. This is the marked part —
collected here so an implementer does not have to reconstruct it from prose.

📌 **2026-09-07: "this section" now means §9.1 *and* §9.2.** The table was
deliberately **not** split when the port-flag section moved to
[`power-bank-port-flags.md`](power-bank-port-flags.md) — several rows below pair
a `b7` bit with a `0x49` / `0x4A` / `b8` observation, and cutting it in two would
put one open question in two files. The `b7` rows' evidence is in §9.2 —
🔵 **and so, since later the same day, is the elimination rule three of these
rows refer to** (〈Naming the Type-A path without a Type-A bit〉, moved to
[`power-bank-port-flags.md`](power-bank-port-flags.md)).

| Item | Status | The capture that would settle it |
|---|---|---|
| `0x4B` b7 **bit 0** | 🚫 **Unknown.** Four readings tested, **all four refuted** — including "Type-A active", killed 2026-08-04 by a capture where the bit was set 7/7 with both ports empty | Separate "A cable present" from "A load present" the way bit 1 was: both ports empty → let the rail time out → plug a Type-A cable with **nothing** on the far end → let the rail restart → record 25 s |
| `0x4B` b7 bit 0 = live "Type-A output path enabled" | 🔲 **Speculative**, one unit. Replaces the per-work-cycle model **retracted 2026-08-04** (`b7` changed twice inside 55 s with the rail continuously up). Re-checked 2026-08-05 on a fresh capture from the same unit: **119/119, no counterexample**~~, and the ~20 s window now has two clean measurements (**10.9 s** and **19.8 s**) rather than one~~ (🔴 2026-08-11: the fixed-delay window is withdrawn — see the bit 0 note in **§9.2**, [`power-bank-port-flags.md`](power-bank-port-flags.md) (~~above~~ until 2026-09-07); the on/off predictions themselves remain unbroken) | A second unit run through the same cable-vs-load script. ⚠️ Note this is no longer on the critical path for naming the Type-A output — that is done by elimination from bit 1 + direction, which needs no bit 0 reading at all |
| Which port carries the flow when **bit 1 is SET** | 🔲 bit 1 is *cable present*, so an idle C cable with the load on Type-A reads as Type-C — 46 frames in one batch are exactly that. The elimination rule only settles the bit-1-**clear** half | A capture with a C cable inserted and untouched while the load is moved between A and C, marked at each move |
| Charging with **bit 1 clear** | 🚫 **Never observed.** The elimination rule therefore says nothing about it, and the row keeps its feedback hook there | Any capture that produces it |
| Boost-rail auto-off delay | **32–37 s** after the last load is removed, four measurements, **one unit**. Model behaviour, not protocol | Same measurement on a second unit |
| `0x4B` b7 **bit 4** | **Unknown semantically**, but no longer unstructured (2026-08-05): **62** bursts, one physical unit, always as `0x12`. bit 3 and bit 4 are **mutually exclusive** (0 of 42,142) and **every ≥8 V charge sets exactly one** (2,042 of 2,042, three units). ⚠️ The **"firmware variant" reading is refuted** — the `0x12` unit emits `0x0a` too (35 vs 62) | A **second** unit emitting `0x12`. 🔲 Working hypothesis, not a finding: bit 3 / bit 4 = PD / non-PD input, which a labelled QuickCharge 9 V charge would test |
| `0x4B` **b8** | **Not decoded.** Ruled out as the displayed temperature | A capture with a known second thermal load |
| `0x4C` | **Not decoded.** 691/691 constant | Any capture where it varies |
| `0x21` **b5** on power banks | **Not decoded.** 6,118 frames, constant `0xe2` | Same |
| Where the power-bank current is measured (cell side or port side) | **Unknown** | A capture at a known port load with a simultaneous cell-current reference |
| `0x49` mV field | ~~**Not published.** Tracks PVLT, so decoding it again would just rename an existing number~~ 🔴 **Corrected 2026-08-05: it tracks the PORT voltage (`0x37`), not PVLT (`0x19`)** — five units, median +4 mV, against a mis-paired control at +1,634 mV (see the mV-fields section above). Still **not decoded by this app** | — (identified). 🔲 What is open is whether to *use* it: it is same-burst with `0x4B` where `0x37` free-runs, so it could close design 0035 §4.5's accepted deviation. Needs a ruling, not a capture |
| `0x4B` b7 **bit 5** — is the contract actually **PD**? | 🔲 **Open, and never tested.** The bit itself is evidenced **2,872/2,872** as *"output contract above 5 V"* (including 10 switches inside 8 unbroken connections in that batch's increment segment — **15 across 11** over the whole log), but **no capture in the corpus records the protocol the far end negotiated** — every observation is a voltage observation. ~~"PD output"~~ was narrowed on 2026-09-04 for that reason. 🔲 PPS stays possible and untested. ⚠️ The "10.2 V is not a PD step" argument is **withdrawn** — 140 of those 143 bursts are (9 V cluster value) + 1,024 mV, 128 of them isolated single samples | A **QC-only (non-PD)** load on the output port for **90 s**, with port and load written down. bit 5 set ⇒ the narrowed wording is right; bit 5 clear with `0x49` at ≈9 V ⇒ "PD" can go back. ⛔ Separate capture from the bit-3 row below — do not close both with one run |
| bit 3 reverse direction (PD charging ⇒ bit 3) | **Refuted**, 62 counterexamples (was "16"; corpus grew). Forward direction holds 221/221, and a 2026-08-04 matched-power A/B rules out power and voltage as the driver — 🔺 **strengthened 2026-09-04 to two units and ≈10×** (a 2026-09-03 capture of a second unit charging at **10.33 W with bit 3 clear**, 14 s before PD negotiation; non-PD ceiling ~~6.14 W~~ ⇒ **10.33 W**). ⛔ **Unrelated to the bit-5 narrowing of the same date** — bit 3 has a ground-truth-labelled instance, bit 5 has none. 🔑 **2026-08-05: the counterexamples are exactly the bit-4 frames** — this row and the bit-4 row are one question, not two | 🔲 A **labelled** non-PD 9 V (QuickCharge) charge. If bit 4 is what a non-PD fast charge looks like, both rows close together |
| Spurious single-poll `b7 = 0x00` | 🔲 **Hypothesis, one unit.** 5 frames in 36,152 bursts (0.014 %) read `0x00` with the rail demonstrably up and the same burst's `0x49` mV corrupted too. Does not affect the meaning of `0x00`; it means a lone `0x00` is not proof of it | The same 1 Hz, ≥2 A, 30-minute run on a second unit — then check `0x37`'s free-running series either side of every `0x00` |
| bit 1 = Type-C | **Holds, and now mechanistic (2026-08-04).** It follows the **cable/CC**, not the power: a C cable with nothing on the far end, at 19 mA, set it 9/9; removing only the load left it set 6/6. The earlier "79/84" figure was a mis-reading — the 5 outliers are a different, correctly-reported port state | — |

**Convention for this document: an item is either evidenced with its sample
size, or it appears in a table like this one. There is no third category.**

### Poll cadence

A power bank answers far more slowly than a pack. Median interval between
complete bursts is **4.95 s**, p90 **9.90 s**, worst observed 237 s — against
0.99 s for both batteries and capacitors.

⇒ **A client should expect the first `0x4A`/`0x4B` values to take about ten
seconds** (that is the p90, not an outlier) and should say so rather than
rendering a dash that looks like a fault.

> An earlier revision gave "7.98 s median TX interval" for the class. That was one
> session's median; twelve of the eighteen power-bank sessions are 4.95 s.
