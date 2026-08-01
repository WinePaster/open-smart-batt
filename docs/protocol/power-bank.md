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

| Bit | Meaning | Evidence | Caveat |
|---|---|---|---|
| **bit 5** | **PD output** | 184/184, no counterexample. Same bit at port voltages from 9.05 V to 13.30 V ⇒ it tracks the protocol, not the voltage rail | — |
| **bit 3** | **PD input ⇒ set** | 221/221 | ⚠️ **One-way only.** PD charging does *not* imply bit 3: a unit charging at 9.05 V / 1.83 A (≈16 W) left it clear |
| **bit 2** | **output active** | 689/691 | Two counterexamples, both at 15–31 mA next to a direction change |
| **bit 1** | **Type-C** | A Type-A-only session was 134/134 clear | ⚠️ A Type-C session was **79/84**, not 84/84 — the first ~11 seconds read as bit-1-clear |
| **bit 4** | **unknown** | Appears only as `0x12` (bit1+bit4), **16** frames, on **one** unit | 🚫 Not decoded. Suspected firmware variant — notably, that is the unit that also failed name-based discovery. See the measurement below |
| **bit 0** | **probably "Type-A active"** | See below | ⚠️ Not settled |

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

**On bit 0: three readings tested, two eliminated, one survives — and it is
still not decoded.**

*Refuted — "bit 0 = 5 V / non-fast-charge":* one capture holds `0x07` and `0x06`
**in the same session, 59 seconds apart, at an identical 5.16 V port voltage**
(15:49:34 → 15:50:33). The two values differ only in bit 0. A 5 V rail cannot
both set and clear the same bit.

*Refuted — "bit 0 = load below some threshold":* the current ranges overlap.
`0x07` bursts reach 268 mA while `0x06` bursts go down to 129 mA.

*Refuted — "bit 0 is a start-of-session settling artefact":* a Type-A-only
session held bit 0 for **136 consecutive bursts over 13 min 10 s, across two
separate connections**.

*Surviving — "bit 0 = Type-A port active":* no counterexample, and it makes the
observed sequences physically coherent. One session runs
`0x05` (A only, 16–22 mA idle) → `0x07` (A + C, load ramping 20 → 2100 mA at
5 V) → `0x26` (C only, PD negotiated to 12.2 V, bit 0 now clear — consistent
with a unit that drops the A port when C takes the full power budget). A
vendor-app screenshot taken during `0x26` shows the Type-A icon dark.

> ⚠️ **PENDING — this is an inference, not a decode.** Every capture to date was
> taken without a record of which ports were physically occupied, so "A + C
> together" is read INTO `0x07`, never confirmed against it. Two further points
> keep it open:
>
> * In both sessions where `0x07` appears it sits at the **start** of a segment
>   and lasts only 5–6 bursts. That is consistent with someone unplugging the A
>   device, and equally consistent with bit 0 meaning something transient that
>   we have not identified.
> * The `0x05` → `0x07` reading of "A, then A and C" is the only interpretation
>   we tried that fits. Fitting is not the same as being tested.
>
> **The experiment that settles it: one capture with both ports deliberately
> loaded at once, labelled as such.** Until then an implementation may show
> "Type-A" from bit 0, but must not present it as more certain than the
> directly-indicated Type-C of bit 1.

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
| `0x4B` b7 **bit 0** = Type-A active | **Inferred.** Three rival readings tested and refuted; this one fits and has no counterexample, but was never tested directly | One session with **both ports deliberately loaded at once**, labelled as such |
| `0x4B` b7 **bit 4** | **Unknown.** 15 bursts, one physical unit, always as `0x12` | A second unit showing the same bit — or a firmware version readout (`0x29`) from the unit that does |
| `0x4B` **b8** | **Not decoded.** Ruled out as the displayed temperature | A capture with a known second thermal load |
| `0x4C` | **Not decoded.** 691/691 constant | Any capture where it varies |
| `0x21` **b5** on power banks | **Not decoded.** 6,118 frames, constant `0xe2` | Same |
| Where the power-bank current is measured (cell side or port side) | **Unknown** | A capture at a known port load with a simultaneous cell-current reference |
| `0x49` mV field | **Not published.** Tracks PVLT, so decoding it again would just rename an existing number | — |
| bit 3 reverse direction (PD charging ⇒ bit 3) | **Refuted**, 16 counterexamples. Forward direction holds 221/221 | Understood; recorded so nobody re-derives the reverse |
| bit 1 = Type-C | **Holds.** An earlier "79/84" figure was a mis-reading — the 5 outliers are a different, correctly-reported port state, not an error | — |

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
