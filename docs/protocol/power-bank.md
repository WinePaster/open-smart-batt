# Power banks — register map (device-type `0x22`)

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §9.1 Power-bank register map

> ⚠️ Despite the numbering, **§9.1 is not a subsection of §9**. §9 is the
> corrections table, in
> [`corrections-and-glossary.md`](corrections-and-glossary.md); §9.1 is this
> register map. The numbering is inherited from the original document and is
> kept so existing `§9.1` references (including in the app source) resolve.

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
| `0x49` | 4 | `[u16 mV][u16 mA]` — the **charge**-side pair | ✅ direction established; current field decoded |
| `0x4A` | 4 | `[u16 mV][u16 mA]` — the **discharge**-side pair | ✅ |
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

⇒ **Publish a magnitude and a direction; do not publish a signed current.**
Whether the current is measured at the cell or at the port is **not established**,
so the two are not interchangeable with a pack's signed `0x2E`.

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

### `0x4B` `b7` — port and protocol flags

Observed values: `0x00`, `0x01`, **`0x02`**, `0x03`, `0x05`, `0x06`, `0x07`,
`0x0a`, `0x12`, `0x26` — over 703 de-duplicated `0x4B` frames. (An earlier note
listed "38" — that was decimal for `0x26`, listed twice under two radices.
**`0x38` has never occurred.**)

> **`0x02` added 2026-07-31.** It comes from a capture that had not been walked
> when this list was written: a 2026-07-30 power-bank capture, session 9,
> **7 frames**, 11:31:23 → 11:31:53. The
> value is **bit 1 alone**, and the unit is taking a charge — `0x49` reads
> 5,180–5,188 mV / **328 mA** with the `0x4A` current at 0, port voltage (`0x37`)
> 5.18 V, SOC (`b6`) 96 %, `0x21` 29 °C, `b8` = `0x30` throughout. ✅ own
> capture, XOR-clean. It shows bit 1 occurring **without** bit 0 and **without**
> bit 2, on a plain 5 V (non-PD) input. That is consistent with the bit-1 = Type-C
> reading below, but with n = 7 on one unit it **adds a value to the list rather
> than settling anything.**

> **Revised 2026-08-04 by a controlled capture.** One unit was run through a
> ten-step script in which **cables and loads were operated separately** — plug
> the cable with nothing on the far end, then add the load, then remove only the
> load, then remove the cable — with every step marked in the log as it
> happened. That is the first capture in the corpus where "a port is occupied"
> and "a port is delivering current" are independent variables. It settled
> bit 1, **refuted** the surviving reading of bit 0, and turned bit 2 from
> 689/691 into an exact equivalence. A **second** capture the same evening added
> the charging direction and refuted a replacement model for bit 0 that had been
> published a few hours earlier. The rows below are the post-revision state; all
> superseded text is kept, struck through, in the sections that follow.

> 🔴 **Superseded by the paragraph above (2026-08-04).** Kept because its
> measurements are still good evidence — only its conclusion ("adds an instance
> rather than settling anything") has been overtaken by the controlled captures.
>
> **Ground-truth-labelled observation added 2026-08-04 — no new values.** ✅ own
> capture, **Android 0.6.16**, raw log enabled, XOR-clean, on the corpus's
> long-serving power-bank unit. It is the **first observation in this section
> whose port and protocol come from the owner's own statement of what was plugged
> in**, rather than being read off the numbers afterwards.
>
> * **Charge segment — owner-stated Type-C PD charge.** `b7` = **`0x0a`**
>   (bit 1 + bit 3) on **21 of 21** frames, with `0x49` reading
>   **9.144–9.168 V × 418–438 mA**, `0x37` reading **9.14–9.16 V** over the same
>   frames, and SOC (`b6`) at 98 %. Both bits match the table below — bit 1 =
>   Type-C, bit 3 = PD input — with **zero counterexamples** in the segment.
> * **A second segment in the same batch — recorded, not interpreted.** SOC
>   100 %, input **5.096–5.152 V** at **0–35 mA**, and `0x4A` carrying an
>   **11–26 mA** discharge. `b7` = `0x05` ×18, `0x03` ×3, `0x02` ×1, `0x00` ×5.
>   **The accompanying note does not say which port this segment used**, so the
>   counts are recorded and nothing is concluded from them. `0x05` (bit 0 +
>   bit 2) is *compatible* with the bit 0 = "probably Type-A" and bit 2 = "output
>   active" readings below, but an unlabelled port makes it no test of either.
>
> This is the **same physical unit** that produced most of this table's evidence,
> so it **adds a ground-truth-labelled instance rather than settling anything.**
> The values list above is unchanged: `0x0a`, `0x05`, `0x03`, `0x02` and `0x00`
> were all already on it.

| Bit | Meaning | Evidence | Caveat |
|---|---|---|---|
| **bit 5** | **PD output** | 184/184, no counterexample. Same bit at port voltages from 9.05 V to 13.30 V ⇒ it tracks the protocol, not the voltage rail | — |
| **bit 3** | **PD input** | 221/221, plus a **matched-power A/B on one unit** (2026-08-04): PD in at 9.02–9.08 V / 662–678 mA ⇒ set **7/7**; non-PD in at 4.88–4.90 V / 1,177–1,185 mA ⇒ clear **6/6**. **Input power 6.07 W vs 5.77 W — 5 % apart**, so the bit is not tracking power | ⚠️ **One-way only** still stands as recorded: 16 charging bursts left it clear. 🔲 But see the note below — those may be non-PD 9 V chargers, in which case the caveat dissolves |
| **bit 2** | **boost rail is outputting** | **Exact equivalence, 52/52** in the controlled capture: set in all 41 samples with the rail up, clear in all 11 with it down. Corpus-wide, every `b7 = 0x00` frame has the port voltage at cell potential | The two former "689/691" counterexamples (15–31 mA next to a direction change) are **explained**: those are rail transitions, not exceptions |
| **bit 1** | **Type-C cable present (CC detect)** | **Not** "Type-C is delivering". A cable in the C port with **nothing on the far end**, drawing 19 mA, set the bit **9/9**; removing only the load and leaving the cable set it **6/6**. A Type-A-only session is 134/134 clear | The earlier "79/84" caveat: those five frames precede a rail restart, so they are a stale value rather than an error |
| **bit 4** | **unknown** | Appears only as `0x12` (bit1+bit4), **16** frames, on **one** unit | 🚫 Not decoded. Suspected firmware variant — notably, that is the unit that also failed name-based discovery. See the measurement below |
| **bit 0** | 🚫 **unknown — and specifically NOT "Type-A active"** | Set with **both ports physically empty**, 7/7, 19–22 mA, in a capture where the operator had pulled the Type-A cable 34 s earlier | ⚠️ See the refutation below. Do **not** drive a "Type-A device attached" indicator from it |

**On bit 3: the A/B that removes "power" and "voltage" as explanations**
(2026-08-04).

Until now bit 3 rested on 221/221 co-occurrence with PD charging, which cannot
separate *the protocol* from *the voltage* or *the power* — all three move
together on a normal charger. A capture on one unit ran both inputs back to
back through the **same port with the same cable**, and matched the power:

| | PD input | non-PD 5 V input |
|---|---|---|
| `b7` | **`0x0a`** (bit 1 + **bit 3**), 7/7 | **`0x02`** (bit 1 only), 6/6 |
| `0x49` port voltage | 9,024 – 9,084 mV | 4,884 – 4,896 mV |
| `0x49` charge current | 662 – 678 mA | 1,177 – 1,185 mA |
| **input power** | **6.07 W** | **5.77 W** |
| `0x20` (TWF) | `0x20` | `0x20` |
| bit 2 | clear | clear |

Power differs by 5 %, so **bit 3 is not a power threshold.**

🔲 **And this makes the "one-way only" caveat look like a charger-type
artefact rather than a protocol quirk.** The recorded counterexample is a unit
charging at **9.05 V** with bit 3 clear. If bit 3 tracked *voltage*, 9.05 V
would set it and those 16 bursts would be unexplainable. If it tracks the
*protocol*, they are exactly what a **non-PD 9 V fast charge** (QuickCharge and
similar) looks like. That is a hypothesis, not a finding — the charger type in
those captures was never recorded.

**The capture that would settle it:** a **QuickCharge 9 V (non-PD)** charger
into the same unit for 90 s. bit 3 clear with `0x49` reading ≈9 V ⇒ the caveat
can be lifted and bit 3 becomes two-way.

**On bit 4: a measurement that supports "firmware variant of bit 3" — and is not
proof of it** (2026-07-31).

The firmware-variant suspicion in the table above has until now been bare
suspicion, with nothing behind it but "only one unit does this". There is now a
measurement. `0x12` (bit 1 + bit 4) and `0x0a` (bit 1 + bit 3) describe the
**same physical state** — a ≈9 V PD charge over Type-C — and differ only in
which of the two bits carries it:

| `b7` | frames | port voltage `0x37` | `0x49` charge current | Units producing it |
|---|---|---|---|---|
| `0x0a` | 247 | 8.75 – 9.09 V | 508 – 1,791 mA | two device names, **neither** the `0x12` unit |
| `0x12` | 16 | 9.03 – 9.07 V on 15 frames; one frame at 4.40 V, mid-negotiation | 396 – 1,834 mA | **one unit** |

⚠️ **State the overlap accurately: it is near-total, not total.** `0x12`'s port
voltage sits inside `0x0a`'s window, but its charge current runs a little past
*both* ends — 396 mA below `0x0a`'s 508 mA floor and 1,834 mA above its 1,791 mA
ceiling. What the table shows is that **no measured quantity separates the two
states, while the device does**: every `0x12` frame in the corpus comes from one
physical power bank, and that unit has never emitted `0x0a`. That is what a
firmware variant would look like.

It is **not proof.** The two sets were captured at different times on different
hardware with no controlled variable; "same state" is read off the numbers, not
imposed. **The capture that would settle it: the same charger and cable into
both units, back to back, labelled as such.** No such capture exists.

*(Count corrected here from 15 to 16 frames. The difference is de-duplication of
overlapping cumulative exports, not a new observation.)*

**`b7 = 0x00` means the boost rail is off** (2026-08-04).

All 73 `0x00` frames in the corpus have the port voltage (`0x37`) sitting at
**3.62–4.05 V** — cell potential, i.e. the boost stage has stopped switching —
with the `0x4A` discharge current at 0. **The BLE link does not drop**: `0x37`
keeps arriving at 1 Hz throughout. So what a user experiences as "the power bank
turned itself off" is only the 5 V output shutting down; the radio stays up.

On the unit measured, that shutdown happens **32–37 s after the last load is
removed** (four measurements: 32, 35, 36, 37 s). This is a property of that
model, not of the protocol, but it bounds every port experiment: an unloaded
state can only be observed for about half a minute before `b7` collapses
to `0x00`.

Two short rail interruptions in the same capture — 2 s each, at the moment a
load was plugged and unplugged — did **not** clear `b7`. A 41 s interruption
did. The threshold is somewhere between.

**On bit 0: four readings tested, all four refuted. It is not decoded.**

*Refuted — "bit 0 = 5 V / non-fast-charge":* one capture holds `0x07` and `0x06`
**in the same session, 59 seconds apart, at an identical 5.16 V port voltage**
(15:49:34 → 15:50:33). The two values differ only in bit 0. A 5 V rail cannot
both set and clear the same bit.

*Refuted — "bit 0 = load below some threshold":* the current ranges overlap.
`0x07` bursts reach 268 mA while `0x06` bursts go down to 129 mA.

*Refuted — "bit 0 is a start-of-session settling artefact":* a Type-A-only
session held bit 0 for **136 consecutive bursts over 13 min 10 s, across two
separate connections**.

*Refuted 2026-08-04 — "bit 0 = Type-A port active":* the experiment this
document asked for was run. Three separate rail work-cycles began with the
Type-A port in three different physical states, and `b7` read `0x05` in all
three:

| Rail restart | Type-A port | Type-C port | `b7` | Samples |
|---|---|---|---|---|
| start of capture | **empty** | empty | `0x05` | 6/6 |
| mid-capture | **cable + earbud case attached** | empty | `0x05` | 6/6 |
| after a 19 s rail-off | **empty** — cable pulled 34 s earlier | empty | `0x05` | **7/7**, 19–22 mA |

Whether anything is attached to the A port, and whether it draws current, does
not change the bit. The third row is the controlled one: the operator removed
the Type-A cable, the rail shut down, it came back, and bit 0 was set again with
nothing plugged into the unit at all.

> ~~*Surviving — "bit 0 = Type-A port active":* no counterexample, and it makes
> the observed sequences physically coherent. One session runs `0x05` (A only,
> 16–22 mA idle) → `0x07` (A + C, load ramping 20 → 2100 mA at 5 V) → `0x26`
> (C only, PD negotiated to 12.2 V, bit 0 now clear — consistent with a unit
> that drops the A port when C takes the full power budget). A vendor-app
> screenshot taken during `0x26` shows the Type-A icon dark.~~
>
> **Superseded text, kept deliberately.** The observations in it are still
> correct — it is the *reading* that failed. The `0x05 → 0x07 → 0x26` sequence
> is real; what was wrong was inferring "A, then A and C, then C" from it. The
> vendor-app screenshot showing a dark Type-A icon during `0x26` remains
> unexplained under any current reading and is **not** evidence for the
> refuted one.

> ~~🔲 **Speculative — a work-cycle model.** bit 0 and bit 1 describe the port
> enablement decided when the boost rail starts a work cycle … They are **not
> re-evaluated while the rail stays up**. Supporting evidence: pulling the
> Type-A cable did not change `b7` (2 samples over 9 s); the value only changed
> when the rail cycled 11 s later.~~
>
> 🔴 **Retracted the same day it was written (2026-08-04), by the next capture
> from the same operator.** Kept here struck through, because it was published
> and someone may have read it.
>
> The refutation: across **55 s in which the rail never went down** (87 `0x37`
> samples, 5.12–5.14 V, **none below 4.6 V**), `b7` changed twice —
> `0x05` → `0x07` when a Type-C cable was inserted, then `0x07` → `0x06` about
> 20 s later. "Not re-evaluated while the rail stays up" is simply false.
>
> Why the earlier capture supported it: **it contained no cable insertion while
> the rail was already up** — every plug and unplug in it fell inside a rail-off
> window or a 2 s rail blink. The "pulling the A cable changed nothing"
> observation is *expected* under the replacement reading below, so it was never
> evidence for a latch. A sampling blind spot, not bad data.

🔲 **Speculative — bit 0 as a live "Type-A output path enabled" flag.** One
unit; recorded as a hypothesis, not a decode.

> **bit 1** = a Type-C cable is present (this part is evidenced, see the table).
> **bit 0** = the **Type-A output path is currently enabled** — a live state,
> not a latch. Observed rule: enabled by default when **no Type-C cable is
> present**; dropped roughly **15–20 s** after the Type-C port starts
> delivering; dropped while the unit is **charging**.

Checked against every capture in the corpus:

| Situation | bit 0 predicted | observed |
|---|---|---|
| both ports empty | 1 | **1** (6/6, 7/7, 3/3) |
| Type-A cable only, no load | 1 | **1** |
| Type-A cable + load | 1 | **1** (6/6, 7/7) |
| A cable pulled, still no C cable | 1 | **1** |
| C cable just inserted (< 20 s) | 1 | **1** (4/4) |
| C cable delivering (> 20 s) | 0 | **0** (4/4, 9/9) |
| both cables present, C idle | 1 | **1** (`0x07` held 9 min) |
| charging over Type-C | 0 | **0** (7/7 PD, 6/6 non-PD) |
| rail down | — (`b7` = `0x00`) | **`0x00`** |

The one soft spot is the ~20 s window in which the C port is already delivering
and bit 0 is still set. Reading that as "the A path takes a while to be switched
out" is fitted after the fact, from a single occurrence.

**What does not depend on any of this:** bit 0 is **not** "a Type-A device is
attached" and **not** "the Type-A port is drawing current". That refutation
stands on its own evidence (table above) and is unaffected by which replacement
reading turns out to be right.

**Until then: an implementation must not drive a "Type-A device attached"
indicator from bit 0.** With nothing plugged into either port the bit reads set.
bit 1 may be used, but it means *a Type-C cable is present*, not *the Type-C
port is delivering power*.

### Naming the Type-A path without a Type-A bit ✅

*Added 2026-08-05.* There is no Type-A bit and, after the four refutations
above, no prospect of one. The path can still be named — by **elimination**
rather than by reading a flag:

> **bit 1 clear** (no Type-C cable) **and the unit is discharging**
> ⇒ the energy is leaving through **Type-A**.

Checked against every port-marked power-bank capture in the corpus, pairing each
`0x4B` with the `0x4A` from its own burst, and excluding the `b7 == 0x00` frames
that the standby test decides before any port test ever runs:

| | Samples |
|---|---|
| Derivation agrees with the operator's port label | **29,114** |
| Derivation disagrees | **0** |

Contributed by **three physically distinct units** — so unlike bit 0, this
clears the multi-unit bar. The 46 frames that look like counterexamples are all
one batch marked "Type-A only" in which the operator later confirmed the Type-C
cable had never been unplugged: bit 1 was right and the label was wrong.

Two limits, both load-bearing:

* **Discharge only.** The check paired `0x4A`, and no capture in the corpus
  shows charging with bit 1 clear at all. Charging with no Type-C cable stays
  *undetermined* — if a unit ever produces it, that is new information.
* 🔲 **The Type-C branch is now the weaker one.** bit 1 is *cable present*, so a
  C cable sitting idle while the load is on Type-A reads as Type-C. That is the
  same 46 frames from the other side, and nothing in the register set separates
  the two. An implementation should not present Type-C as more certain than it
  is.

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

| Item | Status | The capture that would settle it |
|---|---|---|
| `0x4B` b7 **bit 0** | 🚫 **Unknown.** Four readings tested, **all four refuted** — including "Type-A active", killed 2026-08-04 by a capture where the bit was set 7/7 with both ports empty | Separate "A cable present" from "A load present" the way bit 1 was: both ports empty → let the rail time out → plug a Type-A cable with **nothing** on the far end → let the rail restart → record 25 s |
| `0x4B` b7 bit 0 = live "Type-A output path enabled" | 🔲 **Speculative**, one unit. Replaces the per-work-cycle model **retracted 2026-08-04** (`b7` changed twice inside 55 s with the rail continuously up). Re-checked 2026-08-05 on a fresh capture from the same unit: **119/119, no counterexample**, and the ~20 s window now has two clean measurements (**10.9 s** and **19.8 s**) rather than one | A second unit run through the same cable-vs-load script. ⚠️ Note this is no longer on the critical path for naming the Type-A output — that is done by elimination from bit 1 + direction, which needs no bit 0 reading at all |
| Which port carries the flow when **bit 1 is SET** | 🔲 bit 1 is *cable present*, so an idle C cable with the load on Type-A reads as Type-C — 46 frames in one batch are exactly that. The elimination rule only settles the bit-1-**clear** half | A capture with a C cable inserted and untouched while the load is moved between A and C, marked at each move |
| Charging with **bit 1 clear** | 🚫 **Never observed.** The elimination rule therefore says nothing about it, and the row keeps its feedback hook there | Any capture that produces it |
| Boost-rail auto-off delay | **32–37 s** after the last load is removed, four measurements, **one unit**. Model behaviour, not protocol | Same measurement on a second unit |
| `0x4B` b7 **bit 4** | **Unknown.** 15 bursts, one physical unit, always as `0x12` | A second unit showing the same bit — or a firmware version readout (`0x29`) from the unit that does |
| `0x4B` **b8** | **Not decoded.** Ruled out as the displayed temperature | A capture with a known second thermal load |
| `0x4C` | **Not decoded.** 691/691 constant | Any capture where it varies |
| `0x21` **b5** on power banks | **Not decoded.** 6,118 frames, constant `0xe2` | Same |
| Where the power-bank current is measured (cell side or port side) | **Unknown** | A capture at a known port load with a simultaneous cell-current reference |
| `0x49` mV field | **Not published.** Tracks PVLT, so decoding it again would just rename an existing number | — |
| bit 3 reverse direction (PD charging ⇒ bit 3) | **Refuted**, 16 counterexamples. Forward direction holds 221/221, and a 2026-08-04 matched-power A/B rules out power and voltage as the driver | 🔲 The 16 may be **non-PD 9 V** chargers. A QuickCharge 9 V charger into the same unit would tell |
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
