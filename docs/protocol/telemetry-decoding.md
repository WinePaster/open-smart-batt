# Telemetry decoding — constants, formulas, calibration

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §8 · §8.1 Constants · §8.2 Field → selector → formula · §8.2.1 VADJ · §8.2.2 Warning thresholds · §8.3 Write-path inverse

> Two sibling subsections of §8 live in their own files because they are
> separate protocol topics: the identity / housekeeping registers and the
> device clock are **§8.2.3** in [`identity-and-rtc.md`](identity-and-rtc.md),
> and the TWF status register is **§8.4** in [`twf-status.md`](twf-status.md).
> The `b[n]` notation used by all three is defined at the head of §8 below.

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
