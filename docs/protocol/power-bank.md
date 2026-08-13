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
| **bit 5** | **PD output** | 184/184, no counterexample. Set across **two different contract voltages** — ≈9.2 V and ≈12.2 V — ⇒ it tracks the protocol, not one voltage rail; and a **matched-power A/B within a single capture** (2026-08-13) rules out a power threshold. 🔴 **Revised 2026-08-13** — the former wording, ~~"same bit at port voltages from 9.05 V to **13.30 V**"~~, overstated the span at both ends: **13.30 V is a discrete misread, not a contract voltage**. See "On bit 5: the 13.30 V upper bound was a misread" below | — |
| **bit 3** | **PD input** | 221/221, plus a **matched-power A/B on one unit** (2026-08-04): PD in at 9.02–9.08 V / 662–678 mA ⇒ set **7/7**; non-PD in at 4.88–4.90 V / 1,177–1,185 mA ⇒ clear **6/6**. **Input power 6.07 W vs 5.77 W — 5 % apart**, so the bit is not tracking power | ⚠️ **One-way only** still stands. 🔑 **But the counterexamples are now accounted for (2026-08-05): all 62 of them set bit 4 instead.** No ≥8 V charge in the corpus leaves both bits clear (0 of 2,042). See the bit-4 section |
| **bit 2** | **boost rail is outputting** | **Exact equivalence, 52/52** in the controlled capture: set in all 41 samples with the rail up, clear in all 11 with it down. Corpus-wide, ~~every~~ **128 of 133** `b7 = 0x00` frames have the port voltage at cell potential (count and exceptions revised 2026-08-05 — see the `b7 = 0x00` section below) | The two former "689/691" counterexamples (15–31 mA next to a direction change) are **explained**: those are rail transitions, not exceptions |
| **bit 1** | **Type-C cable present (CC detect)** | **Not** "Type-C is delivering". A cable in the C port with **nothing on the far end**, drawing 19 mA, set the bit **9/9**; removing only the load and leaving the cable set it **6/6**. A Type-A-only session is 134/134 clear | The earlier "79/84" caveat: those five frames precede a rail restart, so they are a stale value rather than an error |
| **bit 4** | **unknown**, but **structurally paired with bit 3** | Appears only as `0x12` (bit1+bit4), **62** frames (was "16" — corpus has grown), on **one** unit. ⚠️ **The "firmware variant" reading is dead** — see below | 🚫 Not decoded. But bit 3 and bit 4 are **mutually exclusive** (0 co-occurrences in 42,142 paired bursts), and **every** ≥8 V charge sets exactly one of them |
| **bit 0** | 🚫 **unknown — and specifically NOT "Type-A active"** | Set with **both ports physically empty**, 7/7, 19–22 mA, in a capture where the operator had pulled the Type-A cable 34 s earlier | ⚠️ See the refutation below. Do **not** drive a "Type-A device attached" indicator from it |

**On bit 5: the "13.30 V" upper bound was a misread — the reading survives it**
(2026-08-13).

The row above used to rest on *"the same bit at port voltages from 9.05 V to
13.30 V"*. A corpus-wide rescan of **every burst with bit 5 set**, pairing each
one with its own `0x49` mV field (1 mV/LSB), shows that 13.30 V is not a contract
voltage at all. The 2,845 readings fall into six clusters with **hard gaps
between them — not one sample lands in any gap**:

| cluster | n | empty gap before it |
|---|---|---|
| 8,192 – 8,296 mV | 44 | — |
| **9,108 – 9,408 mV** | **1,101** | 812 mV |
| 10,200 – 10,232 mV | 39 | 792 mV |
| 11,264 – 11,384 mV | 37 | 1,032 mV |
| **12,064 – 12,452 mV** | **1,555** | 680 mV |
| 13,192 – **13,300 mV** | 69 | 740 mV |

Two clusters hold **93 %** of the population and are the real contracts (≈9.2 V
and ≈12.2 V). **Each of the other four sits ±1,024 mV (2¹⁰) from one of them** —
8.2 = 9.2 − 1.024, 10.2 = 9.2 + 1.024, 11.3 = 12.3 − 1.024,
13.30 = 12.276 + 1.024. A continuous ripple cannot produce gaps; one flipped bit
in a millivolt register produces exactly this pattern. The same structure appears
independently in `0x37` (10 mV/LSB, 2,630 paired bursts: 8.19–8.41 /
**9.07–9.36** / 10.17–10.23 / 11.26–11.33 / **12.02–12.42** / 13.19–**13.30** V),
so the fault is upstream of both registers rather than in either one's transport.

⇒ 🔲 **13.30 V is the top of a satellite: a ≈12.28 V contract read 1.024 V high.**
The span that survives is **≈9.1 V to ≈12.4 V**. ⚠️ The bottom end has the same
problem in reverse: the lowest bit-5 reading in the corpus, **8,244 mV**, is
9,268 − 1,024 — another satellite, not a contract.

**The conclusion does not change**, for two reasons that do not depend on the
discarded value. First, ≈9.2 V and ≈12.2 V are still two clearly different
contract voltages, so the bit is not naming one rail level. Second, a
**matched-power A/B inside a single capture** (2026-08-13) removes "bit 5 tracks
power" outright: the same unit, same port, same cable and same load, run first on
USB-default 5 V and then on a 12 V PD contract. bit 5 was clear on all **4**
non-PD bursts and set on all **166** PD bursts, while their cell-side power
ranges **overlap completely and share the same maximum** — 2.28 – **6.76 W**
non-PD against 1.47 – **6.76 W** on PD. A burst at the same power with the bit
clear is what kills a power threshold, and there are four of them.

**Practical note for clients.** The misread runs at roughly **6 %** of samples, so
a port voltage rendered straight from `0x37` flickers to ≈11.3 V or ≈13.3 V about
every 14th update during a 12 V PD output. A median or rate limit on that readout
is worth having; the flag byte itself is unaffected.

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

**On bit 4: the "firmware variant" reading is refuted, and bit 3 / bit 4 turn out
to be one field** (2026-08-05).

> 🔴 **Superseded — the 2026-07-31 text below is kept struck through.** Its
> measurements are still correct; its central factual premise is not.

> ~~What the table shows is that **no measured quantity separates the two
> states, while the device does**: every `0x12` frame in the corpus comes from one
> physical power bank, and **that unit has never emitted `0x0a`**. That is what a
> firmware variant would look like.~~
>
> ~~`0x0a` | 247 frames | 8.75 – 9.09 V | 508 – 1,791 mA | two device names,
> **neither** the `0x12` unit~~

**The premise is false, and a whole-corpus re-walk was all it took.** The unit
that produces `0x12` — a single power bank, identified by the MAC it reports in
`0x38` — **also produces `0x0a`**:

| Capture | `0x0a` | `0x12` |
|---|---|---|
| 2026-07-29 | — | 16 |
| 2026-08-01 | — | 46 |
| **2026-08-04** (three separate controlled captures) | **21 + 7 + 7 = 35** | — |

Every one of those captures carries **its own** `0x38` frames reading that same
MAC — the identity is read off the wire in each capture, not inherited from a
nickname (which for power banks is explicitly unreliable: this unit is labelled
under two different names across the two periods, and the vendor app's own device
hash differs between them too).

A firmware variant cannot emit both encodings of the same field, so whatever
separates them is a **state**, not a build.

⚠️ **The claim was true when it was written and went stale.** Through
2026-08-01 the unit really had never emitted `0x0a`; the 2026-08-04 controlled
captures — the same ones this document leans on for bits 1 and 2 — falsified it,
and nobody re-ran the check. That is the failure mode to watch: a "never
observed" claim is a statement about a corpus, and the corpus keeps growing.

**What the re-walk does establish** — pairing every `0x4B` with the `0x49` from
its own burst, 42,142 paired bursts, charge bursts split by port voltage:

| Port voltage while charging | bit 3 set | **bit 4 set** | **neither** | Units |
|---|---|---|---|---|
| **≥ 8 V** | 1,980 | **62** | **0** | 3 |
| 6 – 8 V | 0 | 0 | 1 | 1 |
| < 6 V | 0 | 0 | 9,638 | 6 |

Two facts fall out, and neither needs a new capture:

* **bit 3 and bit 4 never co-occur** — 0 of 42,142 paired bursts.
* **Every ≥ 8 V charge sets exactly one of them** — 2,042 of 2,042, across three
  physical units, with **zero** leaving both clear. Below 6 V, both are always
  clear (9,638 bursts, six units).

⇒ 🔑 **The "16 counterexamples to the reverse direction of bit 3" and "the 16
unexplained bit-4 frames" were never two open questions. They are the same
frames** — 62 of them now. bit 3's one-way caveat is not an anomaly to be
explained away; it is bit 4 doing the job in those bursts.

⇒ 🔲 **Still not decoded.** This is a structural result, not a semantic one. That
the register always names *some* protocol above 8 V does not tell us *which*
protocol bit 4 is, and bit 4 remains **one unit**. The natural hypothesis is that
bit 3 / bit 4 are a PD / non-PD pair, but that is a hypothesis — see the pending
table.

**The capture that would settle it:** a charger of a known, stated type
(QuickCharge 9 V, non-PD) into a **second** unit, labelled as such.

**`b7 = 0x00` means the boost rail is off** (2026-08-04; counts revised
2026-08-05).

> ~~All 73 `0x00` frames in the corpus have the port voltage (`0x37`) sitting at
> **3.62–4.05 V** — cell potential, i.e. the boost stage has stopped switching —
> with the `0x4A` discharge current at 0.~~
>
> **Superseded 2026-08-05 — arithmetic, not meaning.** That sentence was a
> statement *about the corpus*, and the corpus grew. Kept struck through because
> it was published and because the numbers in it are still correct for the
> frames it was written over.

The corpus now holds **133 `0x00` frames**, and **128 of them** have the port
voltage (`0x37`) at **3.34–4.05 V** — cell potential, i.e. the boost stage has
stopped switching — with the `0x4A` discharge current at 0. That remains the
meaning of the value: **`b7 = 0x00` is the boost rail off.** **The BLE link does
not drop**: `0x37` keeps arriving at 1 Hz throughout. So what a user experiences
as "the power bank turned itself off" is only the 5 V output shutting down; the
radio stays up.

🔲 **The 5 exceptions: a single-poll spurious `0x00`.** One unit, polled at 1 Hz
for 10.5 h — 36,152 complete `0x10`+`0x49`+`0x4A`+`0x4B` bursts, the largest and
cleanest capture in the corpus — produced **5 frames (5 / 36,152 = 0.014 %)**
where `b7` read `0x00` while the unit was demonstrably not idle:

| `0x37` at the frame | `0x49` | `0x4A` |
|---|---|---|
| **5.22 V** | 3 mA | **2,718 mA** (the capture's highest discharge) |
| 5.18 V | 3 mA | 68 mA |
| **4.92 V** | **2,712 mA** | 0 |
| 3.55 V | 667 mA | 0 |
| 4.71 V | 0 | 251 mA |

The hardest of them is the first. `0x37` free-runs at ~0.21 s, and over the
±2 s around that frame its eight samples read 5.23 / 5.23 / 5.23 / 5.23 / 5.23 /
5.24 / 5.24 / 5.22 / 5.18 / 5.17 / 5.18 / 5.22 V — **never below 5.17 V**. The
rail was up. In the same burst the `0x49` mV field also collapsed to 3,436 mV
from a ~5,180 mV baseline, so the corruption is not confined to the flag byte.

⇒ 🔲 **Hypothesis: `0x4B`'s `b7` can misread as `0x00` on a single poll**, taking
the same burst's `0x49` with it. One unit; the reason no earlier capture shows it
is sampling rate — every other power-bank capture polls 5× slower and is orders
of magnitude shorter (the other four units contribute 123 `0x00` frames in
total, none of them exceptional). **The rail-off meaning of `0x00` is not in
question**; what is refuted is treating a lone `0x00` as proof of it.

**Consequence for an implementation.** At 1 Hz this surfaces roughly **once every
two hours** as a one-frame flicker. A client that renders "standby / output off"
from `b7 == 0x00` alone will flicker with it. The fix that does not cost latency
is **same-burst corroboration**: require the burst's own current to be idle as
well.

> 🔴 **Superseded 2026-08-13 — the corroboration holds, the threshold in it does
> not.** Kept struck through: the measurements are still correct for the one unit
> they were taken on, and the sentence was published. What is refuted is treating
> that unit's residual as the class's residual, and a ±0.05 A noise band as
> sufficient on its own. The app's own source has said so since 2026-08-07
> (`app_flutter/lib/ui/dashboard/power_flow.dart`, the `kPowerFlowDeadbandA`
> comment); this paragraph is the doc catching up with the code.
>
> ~~A genuine rail-off always is: with the rail down and both ports empty a unit
> reports `0x49` at **36–39 mA** and `0x4A` at 0, so a signed
> `discharge − charge` lands at **≈ −0.039 A** — inside any sane dead-band. All
> five exceptions above are **68 mA or more**, two orders of magnitude out.~~

A genuine rail-off is idle, but its reported current is **not** reliably inside a
noise dead-band. With the rail down and both ports empty a unit still reports a
charge-side `0x49` residual with `0x4A` at 0, and that residual varies **by unit
and, on the same unit, by session**: **26–69 mA** across the units measured, and
on one unit **42 / 46 / 57 / 60 mA** on four separate days, tracking neither its
state of charge nor its cell voltage. A ±0.05 A band therefore covers *some*
units on *some* days and not others, and it cannot simply be widened to cover
them all — genuine charge and discharge onsets begin not far above it, so a wider
band would trade a per-unit standby bug for misreading real low-rate flow as idle
on every unit.

The corroboration that does hold is **sign-aware and much wider than the noise
band**: a *charging*-signed current below **0.3 A** in a burst whose own `b7`
reads `0x00` is read as idle, and nothing else is vetoed. That line clears both
populations it has to separate — it is above every rail-off residual observed so
far (highest: 69 mA), and well below the two **charge-side** entries in the exception
table above (667 mA and 2,712 mA); the other three exceptions carry the
*discharge* sign, which this rule never touches. The veto is one-way: it can only
downgrade a charging verdict to idle, never invent a direction. In this app the
two constants are `kPowerFlowDeadbandA = 0.05` and `kRailOffChargeVetoA = 0.3`
in `app_flutter/lib/ui/dashboard/power_flow.dart`.

The app applies exactly this rule, and deliberately claims *neither* standby *nor*
a port when the two disagree: at `b7 = 0x00` bit 1 is clear, so the
Type-A-by-elimination rule below would otherwise print a confident "Type-A" for
a frame that was in fact marked Type-C by the operator.

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
> present**; dropped ~~roughly **15–20 s** after~~ **when** the Type-C port
> takes over delivery — the delay between takeover and the drop is **not
> fixed** (withdrawn 2026-08-11, see note below); dropped while the unit is
> **charging**.

Checked against every capture in the corpus:

| Situation | bit 0 predicted | observed |
|---|---|---|
| both ports empty | 1 | **1** (6/6, 7/7, 3/3) |
| Type-A cable only, no load | 1 | **1** |
| Type-A cable + load | 1 | **1** (6/6, 7/7) |
| A cable pulled, still no C cable | 1 | **1** |
| C cable just inserted (C not yet delivering) | 1 | **1** (4/4) |
| C cable delivering (steady state) | 0 | **0** (4/4, 9/9) |
| both cables present, C idle | 1 | **1** (`0x07` held 9 min) |
| charging over Type-C | 0 | **0** (7/7 PD, 6/6 non-PD) |
| rail down | — (`b7` = `0x00`) | **`0x00`** |

~~The one soft spot is the ~20 s window in which the C port is already delivering
and bit 0 is still set. Reading that as "the A path takes a while to be switched
out" is fitted after the fact, from a single occurrence.~~

🔴 **2026-08-11 — the fixed-delay figure is withdrawn.** A corpus-wide rescan of
Type-C handover transitions (eight `07→06` handovers across three units) found
**no fixed delay**: bit 0 has been observed to drop both *before* the C port
starts delivering and *long after* it already has, and two gap-free captures
individually contradict any single window. What remains evidenced is only
**that** bit 0 drops around the C port taking over — not **when**. Do not build
any timing assumption (UI transition delays, "wait N seconds then refresh") on
this flag. The single occurrence the 15–20 s figure was fitted to is one of the
eight; the others do not agree.

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
| `0x4B` b7 bit 0 = live "Type-A output path enabled" | 🔲 **Speculative**, one unit. Replaces the per-work-cycle model **retracted 2026-08-04** (`b7` changed twice inside 55 s with the rail continuously up). Re-checked 2026-08-05 on a fresh capture from the same unit: **119/119, no counterexample**~~, and the ~20 s window now has two clean measurements (**10.9 s** and **19.8 s**) rather than one~~ (🔴 2026-08-11: the fixed-delay window is withdrawn — see the bit 0 note above; the on/off predictions themselves remain unbroken) | A second unit run through the same cable-vs-load script. ⚠️ Note this is no longer on the critical path for naming the Type-A output — that is done by elimination from bit 1 + direction, which needs no bit 0 reading at all |
| Which port carries the flow when **bit 1 is SET** | 🔲 bit 1 is *cable present*, so an idle C cable with the load on Type-A reads as Type-C — 46 frames in one batch are exactly that. The elimination rule only settles the bit-1-**clear** half | A capture with a C cable inserted and untouched while the load is moved between A and C, marked at each move |
| Charging with **bit 1 clear** | 🚫 **Never observed.** The elimination rule therefore says nothing about it, and the row keeps its feedback hook there | Any capture that produces it |
| Boost-rail auto-off delay | **32–37 s** after the last load is removed, four measurements, **one unit**. Model behaviour, not protocol | Same measurement on a second unit |
| `0x4B` b7 **bit 4** | **Unknown semantically**, but no longer unstructured (2026-08-05): **62** bursts, one physical unit, always as `0x12`. bit 3 and bit 4 are **mutually exclusive** (0 of 42,142) and **every ≥8 V charge sets exactly one** (2,042 of 2,042, three units). ⚠️ The **"firmware variant" reading is refuted** — the `0x12` unit emits `0x0a` too (35 vs 62) | A **second** unit emitting `0x12`. 🔲 Working hypothesis, not a finding: bit 3 / bit 4 = PD / non-PD input, which a labelled QuickCharge 9 V charge would test |
| `0x4B` **b8** | **Not decoded.** Ruled out as the displayed temperature | A capture with a known second thermal load |
| `0x4C` | **Not decoded.** 691/691 constant | Any capture where it varies |
| `0x21` **b5** on power banks | **Not decoded.** 6,118 frames, constant `0xe2` | Same |
| Where the power-bank current is measured (cell side or port side) | **Unknown** | A capture at a known port load with a simultaneous cell-current reference |
| `0x49` mV field | ~~**Not published.** Tracks PVLT, so decoding it again would just rename an existing number~~ 🔴 **Corrected 2026-08-05: it tracks the PORT voltage (`0x37`), not PVLT (`0x19`)** — five units, median +4 mV, against a mis-paired control at +1,634 mV (see the mV-fields section above). Still **not decoded by this app** | — (identified). 🔲 What is open is whether to *use* it: it is same-burst with `0x4B` where `0x37` free-runs, so it could close design 0035 §4.5's accepted deviation. Needs a ruling, not a capture |
| bit 3 reverse direction (PD charging ⇒ bit 3) | **Refuted**, 62 counterexamples (was "16"; corpus grew). Forward direction holds 221/221, and a 2026-08-04 matched-power A/B rules out power and voltage as the driver. 🔑 **2026-08-05: the counterexamples are exactly the bit-4 frames** — this row and the bit-4 row are one question, not two | 🔲 A **labelled** non-PD 9 V (QuickCharge) charge. If bit 4 is what a non-PD fast charge looks like, both rows close together |
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
