# Telemetry decoding — constants, formulas, calibration

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §8 · §8.1 Constants · §8.2 Field → selector → formula · §8.2.1 VADJ · §8.2.2 Warning thresholds · §8.3 Write-path inverse · §8.4 `0x34` system counters · §8.5 `0x3A` function flags

> Two sibling subsections of §8 live in their own files because they are
> separate protocol topics: the identity / housekeeping registers and the
> device clock are **§8.2.3** in [`identity-and-rtc.md`](identity-and-rtc.md),
> and the TWF status register is **§8.4** in [`twf-status.md`](twf-status.md).
> The `b[n]` notation used by all three is defined at the head of §8 below.
>
> ⚠️ **`§8.4` is used twice in this document set, and always was** — the TWF
> register in [`twf-status.md`](twf-status.md) and the `0x34` system counters
> below. Cite them by selector, not by number. The new `0x3A` section was
> numbered **§8.5** rather than adding a third `§8.4`; `docs/PROTOCOL.md` (the
> `§` → file index) does not yet carry a row for either `§8.4 0x34` or `§8.5`.

---

## 8. Telemetry parsing

`b[n]` denotes received `byteList[n]`. 16-bit values are big-endian
`(b[i]<<8) + b[i+1]`. Storage fields are controller instance offsets.

### 8.1 Constants

| Constant | Use |
|---|---|
| `1000` | DVOL per-cell divisor |
| `0.025` | OV/UV step (volts per LSB) |
| `14.4` | Over-voltage offset |
| `10.4` | Under-voltage offset |
| `60` | Over-temperature offset (°C) |
| `100` | PVLT/SVLT/VADJ/charge/discharge divisor |
| `256` | Big-endian high-byte multiplier |
| `8.0`, `2/7` (0.2857142857…) | PVLT gauge-index mapping (×3.5) |
| `10` | Second divisor in charge/discharge (/100 then /10 = /1000) |
| `512` | Main-current zero-offset (0x200) |

### 8.2 Field → selector → formula

> 🔴 **This table describes PACKS — device-type `0x02` (battery) and `0x17`
> (super-capacitor) — unless a row says otherwise.** Power banks (`0x22`) reuse
> several of these selectors with **different payload layouts**. Read `0x10`
> before decoding anything here, and see §9.1 for the power-bank map. Applying a
> pack formula to a power bank does not fail loudly; it produces a plausible
> number that is wrong (§9.1 has the worked example).

| Field | Class | Selector | Formula |
|---|---|---|---|
| Main voltage **PVLT** (V) | all | `0x19` | `(b4*256 + b5) / 100.0` |
| PVLT gauge index | pack | `0x19` | `trunc((PVLT − 8.0) * 3.5)`, clamp 0..28 |
| Secondary voltage **SVLT** (V) | all | `0x37` | `(b4*256 + b5) / 100.0` |
| **Temperature** (°C) | all | `0x21` | signed int8 of `b4`; no scaling. ⚠️ LEN differs by class — see §9.1 |
| **DVOL** cell 1..4 (V) | pack | `0x24` | `dvol_i = (b[i] / 1000.0) * VADJ`, i = 4..7. **Ungated** |
| **VADJ** (scale factor) | pack | `0x30` | `(b4*256 + b5) / 100.0` — the DVOL multiplier |
| **Main current** (A) | pack | `0x2E` | `512 − (b4*256 + b5)`. Signed: **negative = discharge, positive = charge**. 🔴 Corrected 2026-08-11 — this row previously said ~~positive = discharge~~. Evidence: five engine-start events on one pack read −211…−446 A while PVLT collapsed 0.90–1.87 V, then current turned positive as PVLT climbed to 14.5 V (the starter motor is the only multi-hundred-amp load, and it can only discharge); an independent second pack shows the same monotonic current↔voltage relation across 139k frames. Earlier captures that were read under the old convention are annotated in place |
| Secondary current (mA) | pack | `0x2F` | parsed/logged only |
| **Warning OV** (V) | pack | `0x2B` | `b4 * 0.025 + 14.4` |
| **Warning UV** (V) | pack | `0x2B` | `b5 * 0.025 + 10.4` |
| **Warning OT** (°C) | pack | `0x2B` | `b6 + 60.0` |
| **Charge** v1 / v2 | ⛔ | `0x41` | `(b4*256+b5)/1000`, `(b6*256+b7)/1000` — **do not apply.** The v2 half is now positively refuted: on device-type `0x17` the last payload byte carries the `0x21` temperature in °C, so `b6..b7` is not a millivolt word. `0x18` uses yet another layout. See §10.1 |
| **Discharge** v1 / v2 | ⚠️ | `0x4A` | `(b4*256+b5)/1000`, `(b6*256+b7)/1000` — **PACK-SIDE ONLY, and never observed on any pack.** On a power bank the same 4 bytes are `[u16 mV][u16 mA]` (§9.1) |
| **Device type** | all | `0x10` | `b4` — `0x02` battery / `0x17` capacitor / `0x22` power bank (§9) |
| **Battery serial** | pack | `0x26` | `b4..b9` packed big-endian into a 48-bit int, `padLeft(6,'0')` |
| **Manufacture year** | all | `0x25` | big-endian u16 (§8.2.3). **Not part of the serial** (§9). ⚠️ **Class corrected from `pack` to `all`, 2026-08-05** — present on every device class, including 36,507 power-bank frames |
| **Dealer code** | all | `0x27` | label string `"%04d%02X%02X"` from `b4..b7` (§4.4) |
| **Mode / status** | all | `0x23` | `b4` — reported-status code space (§6.2) |
| **Capacity / SOH** | ⚠️ | `0x96` | **Never observed.** See §9 before implementing |

### 8.2.1 VADJ is a per-unit calibration constant, not a fixed number

`0x30` is read from the device; **do not hardcode it.** Measured values:

| `0x30` payload | VADJ | Frames | Class |
|---|---|---|---|
| `07e1` | **20.17** | 531 | battery (`0x10`=`0x02`) |
| `07f4` | **20.36** | 292 | battery — JIS 40 Ah, 2026-07-30 |
| `07ee` | **20.30** | 112 | battery |
| `07da` | **20.10** | 84 | battery |
| `07d0` | **20.00** | 2,127 | battery — motorcycle class, fw 1.00, 2026-07-30 |

Baseline: whole-corpus re-walk 2026-07-30, plus the 2026-07-30 field capture.
Every observed value came from a battery; no capacitor or power bank has ever
sent `0x30`. Spread is ≈1.3 %, consistent with a factory per-unit calibration.

> 📌 **`20.36` was deleted from this table earlier the same day and then turned up
> on the wire.** It had been listed as "car battery, HCI snoop 2026-07-06" with a
> cross-reference to a section this document does not contain, and it could not be
> reproduced from the public corpus — so it was removed. Hours later a JIS 40 Ah
> battery reported `07f4` across 292 frames.
>
> The removal was defensible on process and wrong on fact. Recording it because
> the distinction matters: **"cannot be reproduced from the material we hold" is
> not "false".** The right treatment for such a row is to move it to the pending
> table with the capture that would settle it, not to delete it.
>
> An earlier fourth value (≈20.06, attributed to a "motorcycle-class unit",
> 2026-07-05) is **still not reproduced, but the reason given for excluding it is
> now void.** That reason was "the logs streaming `0x40` carry no `0x10` at all,
> so they never supported a class attribution" — a 2026-07-30 capture is a
> `0x10`-identified motorcycle-class battery *and* streams `0x40` (§10.1), so the
> class does reach the wire. That unit reports **20.00**, not 20.06, across 2,127
> frames. ⇒ The row stays out on its own merits (this corpus still contains no
> capture reporting 20.06), not because motorcycle-class VADJ was unobservable.

**Consistency check (verified 2026-07-28).** On units that report DVOL, the four
scaled cell voltages sum to the secondary voltage:

```
Σ(dvol_raw[i]) × VADJ / 1000  ≈  SVLT      (selector 0x37)
```

On that car battery, where VADJ is known from the wire: DVOL `a4a4a3a5`
(164+164+163+165 = 656) × 20.17 / 1000 = **13.23 V**, against a measured SVLT of
13.23–13.28 V. This identity is useful two ways — it validates a decoder, and it
lets VADJ be *estimated* for a unit that never sent `0x30` (invert the formula).
**An estimate is not a measurement**: label it as such, and never persist it as if
the device had reported it.

> ⚠️ **The identity holds in steady state only (caveat added 2026-08-09).**
> `0x24` and `0x37` are not sampled at the same instant, so during a fast
> transient — an engine crank collapsing the rail within a second — the two
> sides describe different moments. Across six independently-serialled units
> (car and motorcycle batteries) the corpus shows transient mismatches above
> 1.0 V, worst 2.17 V, while the steady-state median error on the same units is
> 0.020 V; no constant frame-offset realigns them. Two practical consequences:
> **do not treat a transient mismatch as a decoder fault**, and **never invert
> the formula on transient samples to estimate VADJ** — a crank-window sample
> reproduces VADJ ~15 % low. Use samples where PVLT/SVLT is stable for a few
> seconds on either side.

**Until `0x30` arrives, DVOL has no meaningful value.** Scaling raw DVOL by a
default of 1.0 yields plausible-looking but meaningless numbers (a real capture
produced `0.162 V` per cell where the true value was ≈3.28 V). A client must
render/export DVOL as *pending* until VADJ is known.

### 8.2.2 Warning thresholds differ **per unit**, not just per class

Measured `0x2B` readbacks, decoded with the §8.2 formulas (baseline: whole-corpus
re-walk 2026-07-30):

| `0x2B` payload | OV | UV | OT | 4th byte | Class | Frames |
|---|---|---|---|---|---|---|
| `18401414` | 15.0 V | 12.0 V | 80 °C | `0x14` | battery (`0x02`) | 615 |
| `1f3f1414` | 15.175 V | 11.975 V | 80 °C | `0x14` | battery (`0x02`) | 112 |
| `102c2814` | 14.8 V | 11.5 V | 100 °C | `0x14` | capacitor (`0x17`) | 2290 |
| `102c2800` | 14.8 V | 11.5 V | 100 °C | **`0x00`** | capacitor (`0x17`) | 40 |

**Two units of the same class carry different thresholds** (rows 1 and 2 are both
batteries). So thresholds are a per-unit setting; never assume a class default.

**The 4th byte is not a constant.** Both `0x14` and `0x00` are observed on
capacitors. §5.1 sends `0x00` in that position on the write path, which is the
most likely origin of the `0x00` readbacks — i.e. the value may simply be an echo
of what someone last wrote. Its read-path meaning is **unverified** (a UT /
under-temperature threshold is the working hypothesis, scaling unknown).
**Do not decode it** — and note that this is precisely why: a field whose value
your own write path can overwrite is not a measurement.

### 8.3 Write-path inverse (`changeWarningParameters`)

Confirms the read scaling (exact inverse):
```
OV_byte = round( (ov_volts − 14.4) / 0.025 )
UV_byte = round( (uv_volts − 10.4) / 0.025 )
OT_byte = round(  ot_celsius − 60 )
```
Frame: `[0xB8, 0x2B, 0x00, 0x04, OV_byte, UV_byte, OT_byte, 0x00] + XOR`.
*(Write path uses round-half (`LibcRound`); OV/UV additionally pass a precision-
rounding step before rounding; read-path gauge/current use truncation — so a
round-trip may differ by ±1 LSB.)*

---

### 8.4 `0x34` — system counters ✅

*Decoded 2026-08-05.* Previously listed as "streamed but undecoded".

**Two lengths, and the length identifies the class.**

| LEN | Emitted by | Fields |
|---|---|---|
| **11** | battery `0x02` (some units) | all five below |
| **10** | power bank `0x22`, capacitor `0x17`/`0x18`, and other `0x02` units | the first four — **the cut-off counter is absent** |

```
LEN 11:  [u24 standby min][u24 connected min][u16 sleeps][u16 power-ons][u8 cut-offs]
LEN 10:  [u24 standby min][u24 connected min][u16 sleeps][u16 power-ons]
```

All fields big-endian. The three counters — `[6:8]` sleeps, `[8:10]`
power-ons, `[10]` cut-offs — are cumulative over the unit's life; corpus-wide
they only ever step up.

> 🔴 **Corrected 2026-08-07.** This section originally said ~~all cumulative
> over the unit's life~~. The two **u24 minute fields are not lifetime
> counters**: four units across three reporters (batteries and a capacitor)
> have been observed to reset or fall back at a reboot, and on a power bank
> standby + connected × 67 s matched the uptime since wake in 9/9 bursts.
> Treat both minute fields as **since-wake timers**, not lifetime totals.

| Field | Meaning |
|---|---|
| `[0:3]` | minutes spent in **standby** |
| `[3:6]` | minutes spent **connected** |
| `[6:8]` | number of **sleeps** |
| `[8:10]` | number of **power-ons** |
| `[10]` | number of **cut-offs** — LEN 11 only |

**Why the fifth field is battery-only, and why that is a useful cross-check:**
cut-off is a battery feature. Power banks and capacitors have no cut-off mode,
and they are exactly the classes that emit the 10-byte form. So a LEN-11 `0x34`
is a **second, independent signal that the unit is a battery**, alongside the
`0x10` device-type byte.

⚠️ Not every battery sends 11 — 488 battery frames in the corpus are 10 bytes
against 217 that are 11. Treat LEN 11 as sufficient evidence of a battery, never
LEN 10 as evidence against one.

#### Evidence

The **field meanings** were supplied by the hardware distributor and confirmed
against the vendor's own on-screen readout. The **structure** is independently
verified against this project's captures, which is what makes the split
falsifiable rather than taken on trust:

* Two batteries in one capture read `standby 17 / connected 31 / sleeps 0 /
  power-ons 7 / cut-offs 0` and `standby 36192 / connected 142 / sleeps 0 /
  power-ons 17 / cut-offs 0`. Seven and seventeen power-ons are plausible on
  their face; **no other alignment of these 11 bytes produces two plausible
  counters at once.**
* **The connected-minutes field advances once per tick of a fixed interval,
  not once per minute of wall clock — and the tick length is not the same on
  every product family.** ~~Four units measured independently agree: 67.0
  s/tick over a 10.5 h single-connection capture (counter 11 → 573), 67.1
  s/tick median over 109 increments on a capacitor, 67.1 s/tick on a battery
  checked against the unit's own RTC across 5.9 days (which also rules out a
  slow oscillator — the tick unit itself is ~67 s; 2⁲⁶ µs = 67.109 s is a
  candidate, untested), and standby + connected × 67 s ≈ uptime on a power
  bank (9/9 bursts).~~

  > 🔴 **Corrected 2026-08-09 — the corpus is two populations, not one
  > value.** Re-measured over long windows (both minute fields non-decreasing,
  > same power-on count at both ends, wall clock > 60 min per window), the
  > tick falls into two tight groups:
  >
  > | Group | Units | s/tick |
  > |---|---|---|
  > | **61.0 s** | three motorcycle batteries — three independent units, three reporters, three phones (4,268 / 6,284 / 3,961 min of wall clock) | 60.98 / 60.99 / 61.00 — spread **±0.01 s** inside the group |
  > | **67.1 s** | every other unit measured so far: car batteries, capacitors, power banks (five units) | ~~67.13 – 67.27~~ **66.92 – 67.27** (lower edge widened 2026-08-09: two further long windows on one super-capacitor, both passing the same window criteria, read 66.92 / 66.96 s) |
  >
  > The two groups are 6.2 s (10%) apart — 600× the spread inside either
  > group — so this is not measurement noise. It is also not an artefact of
  > summing the two fields: measuring a **single** field directly gives the
  > same answer. On one 61.0 s unit the standby field alone advanced 1,161
  > counts over 1,180.6 min (**61.01 s/tick**, 0.09% quantisation error); on a
  > 67.1 s unit the connected field alone advanced 491 counts over 549.4 min
  > (**67.13 s/tick**). Both minute fields tick at the same rate on any one
  > unit.
  >
  > ⇒ **Establish which group a unit belongs to before converting either
  > minute field into a duration.** `2⁲⁶ µs = 67.109 s` survives as an
  > untested candidate **for the 67 s group only** — it cannot account for the
  > 61 s group.
  >
  > Why this was missed for so long: the earlier samples were small enough
  > (tens of increments) that 61 and 67 read as the same number, and the
  > headline figure was taken from units that happen to all sit in the 67 s
  > group.

  Unaffected by the correction: on any one unit the field advances at the
  *same* rate under near-zero current and under 2 A, so it is time, not
  energy.
* **The power-on counter increments by exactly 1 at a device reboot**, observed
  alongside two other independent reboot fingerprints (`0x3B` rewinding to a
  checkpoint, and the first telemetry frame after reconnect reading all zeros).
  Corpus-wide it steps by 1 and never decreases.

  > 🔴 **Scope narrowed 2026-08-09 — no change of meaning, only of reach.**
  > The counter itself still only steps up; that part is unaffected. What was
  > implicitly protocol-wide is the *co-occurrence* of the three fingerprints,
  > and that has only ever been established on **motorcycle batteries** (three
  > independent units, no exception). Two counter-observations on other
  > product families:
  >
  > * A `0x18` super-capacitor went from 4 to 68 power-ons — **≥64 reboots** —
  >   while its `0x3B` **advanced monotonically and never rewound once**. Its
  >   shortfall against wall clock tracked total *downtime*, not the number of
  >   reboots (one reboot accounted for 532 min of shortfall, sixty-four
  >   reboots for 425 min). ⇒ On the two families the clock reacts to a reboot
  >   in **two different shapes**, so the battery observation and this one are
  >   not the same mechanism sampled twice.
  > * A car battery showed `0x3B` stepping discontinuously — backwards by
  >   ~7 days inside a 16-minute window, and by ~24 h across a 57-minute
  >   window seen from two different phones — with the power-on counter
  >   **frozen** across all six bursts held for it.
  >
  > ⇒ Outside the motorcycle-battery family, **do not read "the power-on
  > counter did not move" as "no reboot happened"**, and do not expect a
  > rewind to accompany one.
* Sleeps and cut-offs are **0 in every frame the corpus holds** (54,139 frames)
  — consistent with counters for states this project's captures never entered.

#### Not settled

* ~~🔲 **The standby-minutes field has partial corroboration but one open
  outlier.** On two units, Δstandby + Δconnected accounts for 97–98% of the
  wall clock between bursts over multi-hour windows, which fits the since-wake
  reading (a third unit reads 89% — unexplained).~~ 🔴 **Settled 2026-08-09 —
  there never was an outlier.** That spread is the two tick groups above, read
  through a single tick constant: 97–98% is exactly what a **61.0 s** unit
  produces (60 / 61.0 = 98.4%) and 89% is exactly what a **67.1 s** unit
  produces (60 / 67.1 = 89.4%). The label was on the wrong unit — the one
  called unexplained was the one agreeing with the 67 s headline figure, and
  the two taken as confirming it were on the other tick.

  **Methodology, and it matters below 89%:** measure coverage against the
  unit's own `0x3B` RTC, **not against the phone's wall clock.** Wall clock
  silently charges any stall or rewind of the device's own time base to the
  standby field. One car battery covers only **84.6%** of a 7-day wall-clock
  window but **100.0%** of the same window measured on its own RTC — the
  93,607 s difference is device downtime, not counter error. Any check of
  either minute field that spans a possible reboot must use the RTC as the
  denominator and record the wall-clock-minus-RTC gap separately.

* 🔲 **The 2,705,779 reading is still an anomaly.** It was originally read as
  ~~about 5.1 years … possible for a cumulative lifetime counter on an old
  pack~~ — 🔴 under the since-wake reading (2026-08-07) that value cannot be a
  duration since last reboot. Do not present either minute field to a user as
  a duration until it is explained.
* 🔲 **Why some batteries send 10 and others 11** is unknown; firmware is the
  obvious guess and is untested.
* 🚫 **Nothing here is decoded by this app.** These are system counters, not
  telemetry; they are documented so the field is not re-opened as "undecoded".

---

### 8.5 `0x3A` — function-flag register 🟡 **partially decoded, super-capacitors only**

> 🔵 **Ruling, 2026-09-04 (owner).** Publishing the `0x3A` decoding in this
> **public** repository was ruled in on that date. It was prompted by FB-111: the
> capacitor self-check gate now requires **both** `0x23` and `0x3A` to read
> normal, and `app_flutter` decodes `0x3A` accordingly — so leaving this document
> saying *"no hypothesis"* would put the repository in the mirror image of the
> failure it recorded on 2026-07-30, when the protocol document published a
> meaning that the shipped `selectors.dart` did not carry. **Code decoding a
> register that the document calls unknown is the same inconsistency, pointed the
> other way.**
>
> ⚠️ **Relationship to the ruling of 2026-08-23** ("declassified, but this round
> the public repo adds no words"): this is a **per-selector exception for `0x3A`
> alone**. ⛔ It does **not** lift that ruling wholesale and is **not** a
> precedent for any other selector — each still needs its own ruling.
>
> ⛔ **Scope of what is published here.** Only what this project's **own captures**
> support: the wire shape, the per-class value sets counted from this project's
> own corpus, and the one relation those values establish. **Every other bit of
> this register is left unresolved**, and no bit labels from any other source
> appear below or may be added to this section.

**Wire shape** (✅ verified). LEN is **2 in ~~511,431 of 511,431~~ 🔵 512,123 of
512,123 frames** (re-run 2026-09-07; the 692 new frames are the two batches named
below, and LEN stayed 2 in every one of them), so the payload is a single
**big-endian u16**, `b4..b5`. `b4` is called **byte 0** below.

⚠️ **How often it answers differs by class**, which is why the frame counts below
are so lopsided: on a super-capacitor `0x3A` answers **every `#`**, while the
2026-07-30 battery measurement puts it in the **`!#`-only** set — see
[`transport-and-gatt.md`](transport-and-gatt.md) §2. A small battery count here
is a polling artefact, not a quiet register.

**What each class sends** (✅ verified — whole-corpus count, ~~run 2026-09-04~~
🔵 **re-run in full 2026-09-07**;
🔵 **the Machines column was recounted on 2026-09-05 and again on 2026-09-07 —
see the caliber notes under the table**). Class is the `0x10` byte read **in the same device section**;
~~"machines" is `fb.py machines` under the inline-verified gate, whose known
over- and under-count risks the tool prints with every run~~ ⇒ 🔑 **"Machines"
here is `COUNT(DISTINCT MAC)`, where the MAC is the one that device row decodes
out of its own `0x38` frames.** It is **not** `wire_id`, and **not**
`fb.py machines`:

| `0x10` | Payloads observed (frames) | Frames | Machines | Log files |
|---|---|---|---|---|
| `0x02` battery | `0300` (2,186) · `0700` (884) · `0500` (~~136~~ **138**) · 🆕 `0101` (3) · `4500` (2) · `4700` (1) · `0701` (1) | ~~3,210~~ **3,215** | 6 · ~~30~~ **24** · ~~3~~ **4** · **1** · 1 · 1 · 1 | ~~157~~ **158** |
| `0x17` capacitor, 2nd gen | `5100` (176,768) · `5800` (1,453) · `7801` (98) · `7101` (69) | 178,388 | ~~21~~ **19** · 5 · 1 · 1 | 56 |
| `0x18` capacitor, 3rd gen | `4100` (~~217,817~~ **218,488**) · 🆕 `4800` (16) | ~~217,817~~ **218,504** | ~~7~~ ~~5~~ **6** · **1** | ~~19~~ **20** |
| `0x22` power bank | `0000` (111,528) | 111,528 | 6 | 59 |

🔵 **2026-09-07 re-count (superseded figures struck through, never deleted).**
Two separate things moved, and they must not be confused with each other:

* **Corpus growth.** Batches `2026.09.04/002` and `/003` were sealed on
  2026-09-05, i.e. **after** the 2026-09-04/05 run above. They add one 3rd-gen
  capacitor (one unit, 671 `4100` frames **+ 16 of a byte-0 value
  this table had never held**) and one motorcycle battery (MAC
  one battery, 2 `0500` frames + 3 of another new value, `0101`). Those
  account for **every** change in the table. ⇒ `0x18` `4100` 5 → **6** and
  battery `0500` 3 → **4** are **new hardware, not a re-count of old hardware**.
* **The caliber gap closed.** See the two notes below: `fb.py machines` now
  answers `COUNT(DISTINCT MAC)` on its own, so the two calibers agree and the
  Machines column is no longer hand-computed.

⚠️ 🆕 **`4800` and `0101` are values, not decodings.** Each was seen on **one**
machine in **one** capture, so under the landing threshold nothing may be
concluded from either beyond "this value exists". ⛔ Neither may be presented to
a user as a state, and neither is decoded anywhere in this document.

📋 **Reproducing the Machines column** (over `tools/fb.db`; `56` = `0x38`,
`58` = `0x3A`, `16` = `0x10`). Every column of the table above comes out of this
one query, so the caliber cannot drift between columns:

```sql
WITH devmac AS (SELECT f.device_id did, p.hex machex FROM frame f
                JOIN payload p ON p.id = f.payload_id
                WHERE f.selector = 56 GROUP BY f.device_id, p.hex),
     cls    AS (SELECT f.device_id did, p.hex cl FROM frame f
                JOIN payload p ON p.id = f.payload_id
                WHERE f.selector = 16 GROUP BY f.device_id, p.hex),
     -- The merged header-less row reports TWO classes in one section; the
     -- sentence above excludes it, so the query must too. Without this CTE its
     -- 488 frames are counted once under `02` and again under `17`.
     one    AS (SELECT did FROM cls GROUP BY did HAVING COUNT(*) = 1)
SELECT cls.cl                              AS class,
       p.hex                               AS payload,
       COUNT(*)                            AS frames,
       COUNT(DISTINCT dm.machex)           AS machines,   -- the caliber
       COUNT(DISTINCT d.wire_id)           AS wire_ids,   -- NOT the caliber
       COUNT(DISTINCT f.device_id)         AS device_rows,
       COUNT(DISTINCT l.file_id)           AS log_files
FROM frame f
JOIN payload p ON p.id = f.payload_id
JOIN device  d ON d.id = f.device_id
JOIN logfile l ON l.id = d.logfile_id
JOIN cls ON cls.did = f.device_id
JOIN one ON one.did = f.device_id
LEFT JOIN devmac dm ON dm.did = f.device_id
WHERE f.selector = 58
GROUP BY cls.cl, p.hex ORDER BY cls.cl, frames DESC;
```

📏 **Which column of the table this produces.** The **Payloads observed** and
**Machines** columns are read straight off these rows. The **Frames** and **Log
files** columns are the **per-class** totals — drop `p.hex` from the `SELECT` and
the `GROUP BY` to get them (`02` 3,215 / 158 · `17` 178,388 / 56 · `18`
218,504 / 20 · `22` 111,528 / 59). ⚠️ They are **not** the row-wise sums: a log
file holding two payloads of the same class is one file, not two.

🔑 **`machines` and `wire_ids` are deliberately side by side.** Where they differ,
the difference *is* the rename/collision error this section keeps warning about —
e.g. battery `0700` reads **24** machines against **38** `wire_id`s, and `0x17`
`5100` reads **19** against **23**. ⚠️ Where they are equal it is a fact about
those particular rows, not a guarantee: `0300`, `0500`, `5800` and every
single-machine payload happen to have never been renamed.

⚠️ One device row merges a capacitor and a battery section (the header-less
capture that §10.1 elsewhere marks as **not to be counted**); its 488 `5100`
frames are excluded from every figure in this section.

📏 **Caliber of the Machines column, and why the struck-through figures were too
high** (2026-09-05). Every device row counted in this section decodes a MAC out
of its **own** `0x38` frames — **0 rows without one** — so each row resolves to
exactly one BLE address and the count is simply `COUNT(DISTINCT MAC)` over the
rows that sent that payload. 🔴 **The struck-through figures came from
`fb.py machines`, which answers a different question**: that command resolves a
device row to a machine only when the MAC is already registered in the corpus
index's `hardware` table, and **falls back to the raw `wire_id` when it is not**.
~~That table currently holds **19** rows against **63** distinct self-reported MACs
in the corpus ⇒ **44 unregistered**, and **179 device rows that do send `0x38`
are counted by their `wire_id` anyway** — so one physical unit renamed between
captures is counted twice.~~ 🔑 **The worst case is `0x18` `4100`, and it carried
both error directions at once**: a single unit (**213,191 of the
217,817 frames**) was spread over **three** `wire_id`s, while a fourth `wire_id`
was shared by **two** different MACs ⇒ 7 labels, ~~7~~ **5** units.

✅ **2026-09-07 — that gap is closed, and the two calibers now agree by
construction.** The `hardware` table was populated from the wire evidence on
2026-09-07 (**19 → 65** rows, **25 → 129** aliases; every one of the **65**
distinct self-reported MACs in the corpus is now registered, so **0 unregistered**).
`fb.py machines` consequently resolves **351 of the 367** non-synthetic device
rows by MAC, and on **all 14** `0x3A` payloads it now returns exactly the
`COUNT(DISTINCT MAC)` figure this table quotes — checked payload by payload, with
the `wire_id` fallback reported as **0 rows** in every one of them. ⇒ 🔑 **The
Machines column and `fb.py machines` are no longer two different questions for
`0x3A`.** Worked example: `0x18` `4100` went **8 → 6** (the three labels of
three labels collapsed into one unit) at the same moment the corpus grew
by a genuinely new 6th unit.

⚠️ **No conclusion in this section moves.** The exclusivity, the state relation
and the `0x23` pairing are frame counts, and the machine counts they do quote
(~~**6**~~ **7** machines seen in both states — 🔵 **the 7th is the new 3rd-gen
unit added on 2026-09-07, see §8.5.1**; **5** / **1** / **1** in the `0x23`
split) were re-checked under the MAC caliber and are otherwise **unchanged**.
What was overstated is only **how many independent units** stand behind the
numbers — by **40 %** on `0x18`, and by **6 units** on battery `0700`.

📌 **General note, beyond this section: ~~`fb.py machines` currently over-counts~~
`fb.py machines` over-counted for the reason above, and did so for as long as
`hardware` lagged the corpus. 🔵 2026-09-07: `hardware` no longer lags** — see
the ✅ note above. ⛔ **The instruction does not lapse: do not quote its output
without first establishing the caliber**, because the agreement is a *property of
the current table*, not of the command. It reverts to `wire_id` the moment a
capture introduces a MAC nobody has registered yet, and it says so in its own
output (`未收斂的 wire_id N 列`). 🔑 **Read that line before quoting the number:
`N = 0` means MAC caliber, `N > 0` means the figure is a mixture of two calibers
and is an upper bound.**

⚠️ **Three residual blind spots survive the 2026-09-07 registration** and are not
fixable by registering more MACs:

* **16 non-synthetic device rows resolve to no machine at all.** Every one of
  them sends **zero** `0x38` frames (15 hold no frames whatsoever — a capture
  taken with the raw packet log off; the 16th holds 2,556 frames and never a
  `0x38`). They are excluded here by the inline-verified gate anyway, but any
  *other* count that includes header-attributed rows inherits them.
* **26 synthetic device rows (145,206 frames) are never credited to a machine**,
  by design — `unattributed` / `(pre-section)` mean the exporter itself could not
  attribute them, and one such bucket demonstrably holds two devices.
* **Four labels still name two units each** (`旗艦電容`, `機車電池`, `行動電源`,
  `電容`). A row carrying only such a label cannot be resolved even in principle,
  and the tool refuses to guess rather than merging two units.

🔑 **No payload is shared between two classes.** A decoder must therefore gate on
`0x10` before reading any bit of this register, and **the capacitor reading below
must not be carried to a battery or a power bank.**

#### 8.5.1 What is established on super-capacitors

Restricted to `0x10` = `0x17` or `0x18` — 🔵 **2026-09-07 re-count: 396,892
frames · 91 device rows · 31 wire ids · 26 machines · 73 log files ·
2026-07-28 → 2026-09-04.**

🔴 **Superseded 2026-09-05 line, kept verbatim, do not quote:**
~~396,205 frames · 90 device rows ·~~ ~~31~~ ~~30 wire ids ·~~ ~~29~~
~~25 machines · 72 log files · 2026-07-28 → 2026-09-03~~
(🔵 both recounted 2026-09-05; re-run in full 2026-09-07):

> 🔵 **2026-09-07 — why every figure moved by exactly one unit's worth.** The
> whole delta is the single device row `RCE-SCAP_III · 93f150f3` (MAC
> a single third-generation unit) in batch `2026.09.04/003`, sealed **after** the 2026-09-05
> run: **+687 frames · +1 device row · +1 wire id · +1 machine · +1 log file**,
> and 396,205 + 687 = **396,892** exactly. ⇒ **Nothing was recounted differently;
> the corpus grew.** The **machines** figure is the one place where two effects
> could have cancelled — the `hardware` table was also populated on 2026-09-07
> (§8.5 caliber note) — so it was verified separately: `COUNT(DISTINCT MAC)`
> under this gate is **26** and `fb.py machines` now returns the same MAC caliber
> with a `wire_id` fallback of **0 rows**. The 2026-09-05 value of **25** was
> already the MAC caliber and was already correct for the corpus of that day.

> 📏 **Both corrected figures are measured under this section's own gate** — the
> one stated just above, i.e. every capacitor `0x3A` frame in the corpus **except**
> the 488 belonging to the merged header-less device row. Under that gate the
> frames (396,205), device rows (90) and log files (72) reproduce exactly, and the
> distinct `wire_id`s come to **30**, not 31. ⛔ **31 is only reachable by counting
> the merged row's own label as a 31st**, which contradicts the sentence excluding
> it. **29 machines** was `fb.py machines`; the MAC caliber defined above gives
> **25**, and 25 is also what the stricter `fb.py` frame gate gives (which drops a
> further 5 frames on 5 `unattributed` rows, all of them a MAC already counted)
> ⇒ **the machine figure does not depend on which of the two gates is used.**

* ✅ **Byte 0 bit 0 and byte 0 bit 3 are mutually exclusive, ~~396,205 /
  396,205~~ 🔵 396,892 / 396,892 (re-run 2026-09-07).** Exactly one of the two is
  set in every capacitor frame — never both, never neither. Byte 0 takes ~~five~~
  **six** values: `0x51`, `0x41`, `0x71` carry **bit 0**; `0x58`, `0x78`, 🆕
  **`0x48`** carry **bit 3**. (In big-endian-u16 terms those are bits **8**
  and **11** of `b4..b5`.) ⇒ the pair reads as **one two-valued state**, not as
  two independent flags. 🔑 **The sixth value strengthens this bullet rather than
  weakening it** — it arrived from a generation that had never shown bit 3 at
  all, and it still lands on exactly one side of the pair.
* 🔴 **2026-09-07 — the sentence below is FALSIFIED. Original kept verbatim,
  do not quote it.**
  ~~⚠️ **The bit-3 state has only ever been seen on 2nd-generation (`0x17`)
  units.** All **217,817** frames from the~~ ~~seven~~ ~~**five** `0x18` machines
  are `4100`, i.e. the bit-0 state, and that register never moved. So the
  exclusivity above is arithmetically true across both generations but **only
  carries information on `0x17`** — on `0x18` it is satisfied vacuously. Do not
  quote it as a cross-generation result.~~
  ✅ **What replaces it:** batch `2026.09.04/003` (sealed 2026-09-05) holds
  **16 `4800` frames** from a 3rd-generation unit (`0x10` = `0x18`, MAC
  one third-generation unit) ⇒ **the bit-3 state has now been observed on `0x18`**, and
  the exclusivity is no longer vacuous on that generation. ⚠️ **But it is one
  machine, one capture, 16 frames** — under the landing threshold that is enough
  to **retract** a "never observed" claim and **not** enough to establish
  anything about 3rd-generation behaviour. ⛔ Do not read `4800` as a 3rd-gen
  equivalent of `5800` in this document; no such equivalence is measured here.
  📌 **Why the miss is worth recording:** the counter-example was already in the
  corpus and already written up when this section was last revised on 2026-09-05
  — it was the *per-payload* figures that were refreshed, while the *prose*
  bullet that quoted the same numbers was not re-read.
* ✅ **It is a state, not a per-unit constant.** ~~Six~~ **Seven** machines have
  been observed in both states (🔵 re-run 2026-09-07; the 7th is the `0x18` unit
  above), and in **10 (device row, log file) pairs** both states occur **inside a
  single capture**.
* ✅ **`0x3A` carries a state that `0x23` does not report.** Pairing every
  capacitor `0x3A` frame with the nearest `0x23` within 1 s (**396,193 of
  396,205** frames pair): the bit-0 state is accompanied by `0x23` = `05` in
  **394,642 / 394,642** frames — and so is the bit-3 state, in **1,447 of 1,551**
  frames on **5 machines**. The remaining 104 read `07` (98 frames, one machine)
  and `06` (6 frames, one machine).
  ⚠️ 🔵 **2026-09-07 caliber note — this bullet's pairing was NOT re-run.** Its
  denominators are the 2026-09-05 corpus (396,205 frames; bit-3 = 1,551). The
  corpus is now 396,892 frames and bit-3 is **1,567** — the 16 `4800` frames of
  the new 3rd-gen unit are **not** in the 1,551 and therefore not in the 1,447
  either. ⇒ **The 93 % conclusion is unaffected in direction** (it can only move
  by ≤ 16 frames of a 1,567-frame denominator), but ⛔ **do not quote
  "1,447 / 1,551 on 5 machines" as a current figure** — re-run the pairing before
  using it as anything but the 2026-09-05 measurement it is.
  🔑 **`0x23` = `05` is the resting code
  [`modes-and-auth.md`](modes-and-auth.md) §6.2 records for a super-capacitor**
  (that section records `0x06` there only as a ~1 s pulse following a mode
  write, and records no `0x07` at all),
  so a client watching `0x23` alone cannot see this state change at all. **That
  is the whole reason FB-111 needs both registers**, and it is measured here, not
  assumed.
* ✅ **Byte 1 is `0x00` on every machine but one.** One 2nd-gen unit sends `0x01`
  there, in **both** states (`7101` / `7801`). One machine ⇒ nothing is inferred
  from it.

#### 8.5.2 What is NOT established — read this before using the register

* 🔲 **Which state means what.** ⛔ **This corpus does not say what the two states
  are.** ~~Three~~ **Four** quantities could have separated them; none does:
  * **`0x2E` main current is `0` in every capacitor frame** the corpus holds
    (4,275 nearest-in-time pairs on the machines that show both states, every one
    of them `512 − 512 = 0 A`). It separates nothing.
  * **`0x19` PVLT does not separate them on 5 of the 6 machines.** Per-machine
    medians, bit-0 state → bit-3 state: 13.21 → 13.31 V, 12.37 → 12.30 V,
    12.50 → 12.30 V, 13.61 → 13.48 V, 12.95 → 13.09 V — **two go up, three go
    down, all by less than the within-state spread.** Only the sixth collapses
    (13.25 → 5.84 V), and that is the same machine whose `0x23` reads `07`,
    i.e. a condition `0x23` already reports on its own.
    ⚠️ 🔵 **2026-09-07: there are now seven machines seen in both states, and
    the seventh was not measured here.** The five medians above are unchanged and
    still say what they said; **the seventh unit is simply absent from this
    bullet.** ⇒ The claim survives as *"does not separate them on 5 of the 6
    machines measured"* — ⛔ it must **not** be restated as "5 of 7", which would
    assert a measurement nobody has made.
  * **`0x23` reads the healthy `05` in 93 % of the bit-3 frames** (above).
  * 🔵 **2026-09-05 — a fourth quantity was tried and is now RULED OUT: the
    separation between the two voltage rails, `|0x37 SVLT − 0x19 PVLT|`.** The
    idea was that a large separation could only occur while the two rails were
    NOT tied together, so the state carrying it would be identifiable. **The
    corpus disproves it: a separation ≥ 1.8 V occurs in BOTH states.** Pairing
    every capacitor `0x3A` frame with the nearest `0x19` **and** the nearest
    `0x37` within 1 s (the same pairing this section already uses for `0x23`),
    over the §8.5.1 gate:

    | state | frames paired | of those, separation ≥ 1.8 V | device rows | machines (MAC) |
    |---|---|---|---|---|
    | bit-0 | 394,631 | **666** | 2 | **1** |
    | bit-3 | 1,551 | 1,486 | 9 | 5 |

    ⚠️ 🔵 **2026-09-07: measured on the 2026-09-05 corpus and NOT re-run.** The
    §8.5.1 gate has since grown to 396,892 frames (bit-3 to **1,567**), so the
    two denominators above are stale by the 687 frames of one new 3rd-gen unit.
    **The conclusion is unaffected** — it is a *counter-example* claim ("a
    separation ≥ 1.8 V occurs in BOTH states"), and a counter-example cannot be
    undone by adding frames. ⛔ But the four counts themselves are the
    2026-09-05 measurement; re-run before quoting them as current.
    📏 **Caliber, stated explicitly**: "machines (MAC)" here is
    `COUNT(DISTINCT MAC)` over the device rows in that group, MAC decoded from
    each row's own `0x38` — the same caliber as §8.5's Machines column, **not**
    `wire_id` and **not** `fb.py machines`.

    The bit-0 counter-examples are not scattered noise. All **666** carry byte 0
    = `0x51`, they belong to **one** physical machine (two device rows, one
    self-reported MAC), their separation is **mean 5.87 V, min 5.73, max 5.98**,
    and they run **2026-08-15T15:42:41 → 15:49:40** — i.e. the condition is held
    for **seven minutes**, not a transient. Through that window `0x23` reads the
    resting `05` in **407 / 407** frames and `0x2E` reads `0200` = **0 A** in
    **407 / 407**, and the same unit's `0x3A` visits **both** groups (368 frames
    `5100`, 39 frames `5800`) while the separation stays ~5.9 V. Median PVLT
    12.50 V against median SVLT 6.61 V.

    🔑 **Why this is recorded rather than dropped:** the inference is a natural
    one and was reached independently once already. Without this note the next
    reader spends the same effort to arrive at the same dead end.

    <details><summary>How to reproduce</summary>

    Over `tools/fb.db`: take the device rows that report `0x10` ∈ {`0x17`,
    `0x18`} (super-capacitors), drop the merged header-less row §8.5.1 excludes,
    and for every `0x3A` frame on them classify byte 0 into the bit-0 / bit-3
    group and attach the nearest `0x19` and `0x37` frame on the same device row
    within ±1 s; count the frames whose `|SVLT − PVLT|` is ≥ 1.8 V per group.
    Frame counts reproduce §8.5.1's 396,205 exactly.

    </details>
* ✅ **2026-09-05 — this app no longer claims a polarity.** ~~`CapacitorMos` in
  `app_flutter/lib/protocol/selectors.dart` treats the bit-0 state as *output
  engaged* and the bit-3 state as *output cut*~~ — those labels were not
  supported by our own captures and have been removed. ~~`CapacitorMos.group()`
  now answers `CapacitorMosGroup.bit0` / `.bit3` / `null`~~ 🔵 **the type names
  were renamed on 2026-09-07 — see the next bullet**;
  `CapacitorFunctionFlags.group()` answers `CapacitorFlagGroup.bit0` / `.bit3` /
  `null`, named after the
  distinguishing bit and nothing else, and the one feature that consumes it (the
  capacitor self-check unlock, FB-111) compares against **the group the register
  was in before the check started** — which needs no polarity at all. ⛔ A client
  must not present either state to a user as a physical fact, and this document
  does not corroborate any such label.
* ✅ **2026-09-07 — the type names went the same way, and for the same reason.**
  ~~`CapacitorMos`~~ / ~~`CapacitorMosGroup`~~ in
  `app_flutter/lib/protocol/selectors.dart` are now **`CapacitorFunctionFlags`**
  / **`CapacitorFlagGroup`**, after this register's own name in §8.5 rather than
  after a component (`.group()`, `bitGroup0` and `bitGroup3` are unchanged).
  🔑 **The 2026-09-05 pass took the polarity out of the constants but left the
  class name still asserting a hardware reading** — that these two bits switch an
  output MOSFET. That reading has no more support in our own captures than the
  polarity did: "MOS" was a word borrowed from the vendor engineering build's
  screen, never something observed on the wire here. ⛔ Neither the class name,
  the enum, nor the constants may name a component or a state — say which group
  `0x3A` is in.
* 🔲 **The other six bits of byte 0 are unresolved.** Across the five observed
  values, bit 6 is set in all five, bit 4 in four (not in `0x41`, the 3rd-gen
  value), bit 5 in two, bit 7 in none. Nothing in the corpus separates them, so
  nothing is claimed about them. ⛔ Do not fill them in from any other source.
* 🔲 **Battery and power-bank halves stay undecoded**, and stay in
  [`undecoded-and-metadata.md`](undecoded-and-metadata.md) §10.1. The battery
  value set moves per unit; the power bank has sent `0000` and nothing else in
  111,528 frames, which is the "constant" warning at the foot of §10.1, not a
  decoding.

**The capture that would settle the polarity:** one super-capacitor on a bench
with a **measurable load on its output**, driven through whatever action moves
byte 0 from `0x51` to `0x58`, with the load current recorded on both sides of the
transition. Everything above is passive-observation evidence — **nothing in this
corpus was captured with the capacitor's output instrumented**, which is exactly
why the polarity is still open.
