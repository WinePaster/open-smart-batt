# Power-bank port and protocol flags (`0x4B` `b7`)

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`power-bank.md`](power-bank.md) on **2026-09-07** — the text below is
> verbatim. It was given the next free section number, **§9.2**, rather than
> being carried across as an unnumbered subsection of §9.1: one file owns one
> `§` in this document set, and no `§` spans two files. The index in
> [`../PROTOCOL.md`](../PROTOCOL.md) maps `§` to file.
>
> **Covers:** §9.2 Power-bank port and protocol flags (`0x4B` `b7`)

> ⚠️ Despite the numbering, **§9.2 is not a subsection of §9** — and neither is
> §9.1. §9 is the corrections table, in
> [`corrections-and-glossary.md`](corrections-and-glossary.md); §9.1 is the
> power-bank register map, in [`power-bank.md`](power-bank.md); §9.2 is this
> file. §9.1's number is inherited from the original document and is kept so
> existing `§9.1` references (including in the app source) resolve; **§9.2 is
> new on 2026-09-07** and nothing outside this split refers to it yet.

> 📌 **Why this file exists, and what changed in the move.**
> [`power-bank.md`](power-bank.md) had reached **857 lines** against this
> project's 1,000-line ceiling, and this one section was **586** of them (69 %).
> Nothing was rewritten, deleted or renumbered. ~~The only edits are the **two
> cross-references that now cross a file boundary** — "see the pending table"
> and "the Type-A-by-elimination rule below" — each marked in place where it
> occurs.~~ 🔵 **2026-09-07, later the same day: one of those two is gone.**
> *Naming the Type-A path without a Type-A bit* ✅ had been left behind in
> `power-bank.md`, and it has now been moved here as well — verbatim, heading
> unchanged. Its first sentence is *"after the four refutations above"*, and
> those refutations are in this file, so keeping the two apart bought nothing
> and cost **two pointers whose only job was to undo the split**. Both are now
> struck in place. ⇒ **The only surviving cross-file reference is "see the
> pending table"**, which is deliberate: that table stays in §9.1 because
> several of its rows pair a `b7` bit with a `0x49` / `0x4A` / `b8` observation,
> and splitting it would put one open question in two files. Every other
> "above" / "below" in this file points inside it.
>
> 📏 **Size self-report (measured 2026-09-07, after both moves):** see the line
> at the foot of this file. **No size exemption applies to this file** — it is subject to the full
> 1,000-line / 100 KB thresholds from day one.

---

## 9.2 Port and protocol flags (`0x4B` `b7`)

> The rest of the register — `0x4B`'s design-capacity and SOC fields, the
> `0x49` / `0x4A` pair and which voltage each of their mV fields copies, the
> class-dependent layouts, `0x47`, the poll cadence, **and the pending-items
> table that also collects this section's open questions** — is **§9.1**, in
> [`power-bank.md`](power-bank.md).

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
| **bit 5** | ~~**PD output**~~ 🔵 **narrowed 2026-09-04 to "non-5 V output contract"** (the output contract is above the USB-default 5 V) | **2,872/2,872, no counterexample** (was ~~184/184~~ — the corpus grew ×15.6). Two kinds of evidence now. **(a) Separation:** across **8,429** complete `0x49`+`0x4B` bursts on one unit, every burst with bit 5 set reads **8,192 – 10,232 mV** and every burst with it clear reads **3,144 – 5,348 mV** — **not one sample lands between them**. **(b) 🆕 A new evidence type — switching inside one connection** (2026-09-02 batch): **10 transitions across 8 separate connections with no disconnect in between** (⚠️ **that is the batch's *increment* segment, from 2026-08-13 14:35 — the same log counted end-to-end holds 15 transitions across 11 connections; see "What the '8 connections' are counted over" below**), bit 5 changing together with the port voltage moving between the 9 V and 5 V families, within **≤17.9 s and mostly ≈5 s**. Set across **two different contract voltages** — ≈9.2 V and ≈12.2 V — ⇒ it tracks the contract, not one voltage rail; and a **matched-power A/B within a single capture** (2026-08-13) rules out a power threshold. 🔴 **Revised 2026-08-13** — the former wording, ~~"same bit at port voltages from 9.05 V to **13.30 V**"~~, overstated the span at both ends: **13.30 V is a discrete misread, not a contract voltage**. See "On bit 5: the 13.30 V upper bound was a misread" below | ⚠️ **"PD" was never observed — only voltage was.** No capture in this corpus records which protocol the far end negotiated, so the evidenced claim is *"the contract is above 5 V"*, not *"the contract is PD"*. See "On bit 5: why the label is no longer 'PD'" below |
| **bit 3** | **PD input** | 221/221, plus a **matched-power A/B on one unit** (2026-08-04): PD in at 9.02–9.08 V / 662–678 mA ⇒ set **7/7**; non-PD in at 4.88–4.90 V / 1,177–1,185 mA ⇒ clear **6/6**. ~~**Input power 6.07 W vs 5.77 W — 5 % apart**, so the bit is not tracking power~~ 🔺 **Strengthened 2026-09-04 — same conclusion, a second unit, and roughly ten times the margin.** The A/B's 6.07 W vs 5.77 W (and the **6.14 W** high-water mark for a non-PD input anywhere in that capture) was the whole of the "not a power threshold" case, and it rested on **one unit at a 5 % margin**. A 2026-09-03 capture of a **different** unit caught the **14 s before PD negotiation**: the port sat in the USB-default 5 V family at **4.880 V × 2.117 A = 10.33 W** with **bit 3 clear**, and bit 3 then set as the port stepped to 9.05 V **in the same poll**. The same capture's PD section runs down to **9.32 V × 0.114 A = 1.06 W** with bit 3 **set**. ⇒ the non-PD ceiling moves **6.14 W ⇒ 10.33 W**, and the refutation is now **two units at ≈10×**, not one unit at 5 %. See "On bit 3: the 2026-09-03 pre-negotiation window" below | ⚠️ **One-way only** still stands. 🔑 **But the counterexamples are now accounted for (2026-08-05): all 62 of them set bit 4 instead.** No ≥8 V charge in the corpus leaves both bits clear (0 of 2,042). See the bit-4 section |
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
every 14th update during a 12 V ~~PD~~ **non-5 V** output contract. A median or
rate limit on that readout is worth having; the flag byte itself is unaffected.

**On bit 5: why the label is no longer "PD" — and what the 2026-09-02 batch
actually added** (2026-09-04).

🔵 **Narrowed: ~~"PD output"~~ ⇒ "non-5 V output contract".** The narrowing of the
wording and the upgrade of the sample are **one change, not two** — the evidence
got *stronger* at the same moment the claim got *weaker*. Read either half alone
and you will draw the wrong conclusion about which way this row moved.

**What got stronger.** One power bank, 8,429 complete
`0x49`+`0x4B` bursts:

| | before (through 2026-08-13) | 🆕 2026-09-02 batch |
|---|---|---|
| bursts with bit 5 set | 184 | **2,872** |
| separation | — | set: **8,192 – 10,232 mV**; clear (5,557 bursts): **3,144 – 5,348 mV**; **no sample in between** |
| kind of evidence | comparison **between** captures | 🆕 **10 switches inside 8 single connections, no disconnect** (increment segment; **15 / 11** over the whole log) — 9 V ⇄ 5 V, bit 5 following within **≤17.9 s**, mostly **≈5 s** |

The in-connection switches are the part that is new in kind, not just in size.
They hold everything else fixed — same unit, same cable, same port, same session,
same firmware — so only the contract moves. Nothing before this ruled out "bit 5
is a property of how the session started".

📏 **What the "8 connections" are counted over** (added 2026-09-05 — the figure
was right, the sentence did not say what it was a figure *of*). The batch it
comes from is a **rolling** log: it carries three weeks of history, of which only
the part after **2026-08-13 14:35** was new relative to the previously ingested
capture. The batch analysis counted the switches **on that increment**, because
the increment was what it was reporting. **10 / 8 is therefore a subset, not the
total.**

Counted end-to-end over the same log — 8,429 bursts, cut into connections at any
gap over 120 s, exactly the rule the batch used — the figure is **15 transitions
across 11 connections** (26 connections in total, so 11 of 26 contain at least
one switch). The three connections the increment cut off (2026-08-11 13:58,
2026-08-12 14:10, 2026-08-12 15:40) contribute the other **5**.

⚖️ **Every one of the 15 behaves the same way**, so the larger figure only
strengthens the row: bit 5 changes together with the port voltage crossing
between the 9 V and 5 V families — at these 15 instants, 9,148 – 10,212 mV on one
side and 5,184 – 5,348 mV on the other, **never within a family** — in
**≤17.9 s and mostly ≈5 s**. The 17.9 s worst case is still the one already
quoted, so **no bound in this document moves**. **Zero counterexamples,
15 of 15.**

**Why "PD" is nevertheless the wrong word.** Not because of a counterexample —
there is none — but because **no capture in this corpus has ever recorded which
protocol the far end negotiated.** Every bit-5 observation is a *voltage*
observation; "PD" was inferred from that voltage being ≈9 V or ≈12 V. The
2026-09-02 batch is no exception: it carries no port labels and no capture marks,
so nobody can say what was plugged in. ⇒ what the corpus evidences is **"the
output contract is above USB-default 5 V"**, and that is now what the row claims.

🔲 **PPS remains open — as a possibility, not as the explanation.** USB-PD's
programmable-supply mode is continuously adjustable rather than stepped, so a
contract that does not land on 5/9/12/15/20 V is still compatible with PD. ⚠️ It
is **untested**, and the paragraph below removes the observation that made it look
necessary. Do not write PPS down as a finding.

🔴 **In-place correction to the argument that prompted this narrowing.** The batch
analysis argued from **143 bit-5 bursts reading 10.0 – 10.4 V**, on the grounds
that 10.2 V is not a PD fixed voltage. **Re-measured against the same log
(2026-09-04), that argument does not survive** — and what kills it is already in
this document, in the 13.30 V section above:

* **140 of the 143** sit at exactly **(a value observed in the same unit's 9 V cluster) + 1,024 mV** — 2¹⁰, the same flipped bit.
* They are **isolated samples, not a contract**: the 143 fall into **135 runs, of which 128 are a single burst** with 9 V bursts on both sides. A negotiated 10.2 V contract would hold for a run of bursts; 128 one-burst "contracts" is a misread.
* The **131** bit-5 bursts *below* 8.8 V mirror this exactly: **130 of 131** are **(a 9 V cluster value) − 1,024 mV**, in **121 runs of which 112 are one burst long**.
* Combined satellite rate **274 / 2,872 = 9.5 %**, against the **≈6 %** this document already records for the same defect.

⇒ **The 10.0 – 10.4 V group is the same ±1,024 mV discrete misread as 13.30 V, not
a third contract voltage.** The narrowing therefore rests entirely on the *other*
reason — that the protocol itself was never observed — which is independent of the
10.2 V group and is unaffected by this correction. 🔲 **Recorded rather than
silently rewritten**: the ruling stands on that second reason, and whether it
should stand on it alone is a question for the owner, not for this file.

**The capture that would settle it:** a **QC-only (non-PD) load** — a QuickCharge
handset, or a QC trigger board — on this unit's output port for **90 s**, with the
port and the load written down.

* bit 5 **set** ⇒ it tracks *"output above 5 V"*, independent of protocol, and the wording above is right.
* bit 5 **clear**, with `0x49` confirming the port genuinely rose to ≈9 V ⇒ "PD" was correct all along, and the label can go back.

📌 This is the same shape as the open question on **bit 3** (a non-PD 9 V charge
would look like a PD one), one port over — input side there, output side here.
⛔ They are **two captures and two rows**; do not try to close both with one run,
and do not carry a finding from one to the other.

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

**On bit 3: the 2026-09-03 pre-negotiation window — a second unit, and a 10×
margin** (added 2026-09-04).

🔺 **This strengthens the row above; it does not revise it.** The label stays
**PD input** and the "one-way only" caveat stays exactly as written. What changed
is the strength of the evidence against reading bit 3 as *power*.

The 2026-08-04 A/B could only put **6.07 W vs 5.77 W** — a 5 % gap on **one
unit** — between "PD" and "power", with **6.14 W** the highest non-PD input
anywhere in that capture. A 2026-09-03 capture of a **different** power bank
recorded the 14 s **between the cable going in and the PD contract landing**:

| segment | `b7` | bits | `0x49` port mV | `0x49` charge mA | input power |
|---|---|---|---|---|---|
| pre-negotiation, ~14 s | `0x03` | 0 + 1 | **4,880** | **2,117** | **10.33 W**, bit 3 **clear** |
| after negotiation | `0x0a` | 1 + 3 | 9,050 | 1,441 | 13.04 W, bit 3 **set** |
| same capture, CV tail | `0x0a` | 1 + 3 | 9,320 | 114 | **1.06 W**, bit 3 **set** |

* The pre-negotiation segment is a **non-PD input at 10.33 W with bit 3 clear**;
  the tail is a **PD input at 1.06 W with bit 3 set**. Any power threshold would
  have to sit above 10.33 W and below 1.06 W at once.
* ⇒ the non-PD ceiling for this refutation moves **6.14 W ⇒ 10.33 W**, and the
  result now rests on **two independent units** rather than one.
* 4.880 V is the USB-default 5 V rail after cable drop, so this is the ordinary
  5 V charge case — not an exotic one constructed to break the reading.

🔑 **Why this is worth its own paragraph:** the 2026-08-04 A/B was a *matched*
comparison, which is the strongest shape available on one unit but leaves a 5 %
gap that a sloppy threshold could still live in. This is the opposite shape — an
*unmatched* comparison with the sign deliberately wrong-way-round — and 10× is
outside anything a threshold could absorb. **Two different failure modes, both
now closed.**

⛔ **Do not merge this with the 2026-09-04 narrowing of bit 5.** They landed on
the same day and both touch "PD", and they are unrelated:

* **bit 5** was narrowed because **the protocol was never observed** — every
  bit-5 observation is a *voltage* observation, so the corpus could not say
  whether the contract was PD.
* **That reason does not apply to bit 3.** Bit 3 has a **ground-truth-labelled
  instance**: the 2026-08-04 charge segment above, whose port and protocol come
  from the **owner's own statement of what was plugged in** (21/21 frames, see
  the ground-truth block earlier in this section). It is the only place in this
  file where the protocol itself was recorded rather than inferred.
* ⇒ bit 5 got **weaker wording with stronger numbers**; bit 3 got **stronger
  numbers with unchanged wording**. Carrying either conclusion across is wrong.

📌 Source: `feedback-analysis/2026.09.03-007.md` §1.1 (capture 2026-09-03,
Android `0.7.41`). ⚠️ **Single capture, single unit for the new half** — it is a
second unit relative to the 2026-08-04 A/B, which is the point, but it is not a
population.

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
table (📌 that table stayed with **§9.1**, in
[`power-bank.md`](power-bank.md) — it collects the pending items of this
section too).

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
Type-A-by-elimination rule ~~below~~ (📌 **2026-09-07, later the same day: the
two sections were reunited in this file, so this is a same-file reference again**
— *Naming the Type-A path without a Type-A bit*, below. The word is left struck
through rather than restored: superseded wording is kept visible in this document
set, never silently reinstated) would otherwise print a confident "Type-A" for
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

*Second instance, on a different unit — added 2026-09-07.* A controlled
2026-08-04 capture on this corpus's long-serving power bank holds `0x06` at
21:21:58.788 and `0x07` at 21:22:53.241 — **one connection, 54 s apart, port
voltage 5.13 V both times**, discharge 22 mA vs 25 mA, **and the same capture
mark on both**. The instance above is a different unit, so the same-session flip
is now recorded on **two units**. ⛔ Nothing else moves: it is one more instance
of an already-refuted reading, and every entry in the bit table stays as it is.

> ⚠️ **That capture mark does not mean "both ports are empty".** Its label reads
> *"everything unplugged"*, but the operator — who was also the reporter —
> stated afterwards that **only the loads were pulled; the cables stayed in
> both ports** for the whole session. A bit reading inferred from the *wording*
> of such a mark therefore rests on something that was never observed. The
> refutation table below does not depend on this: its "empty" rows come from
> the operator's own account of the actions performed, not from a mark label.

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
~~above~~ (📌 **2026-09-07, later the same day: the two sections were reunited
in this file, so "above" is accurate again** — those four refutations of bit 0
are in this same `§9.2`, a few screens up. The word is left struck through
rather than restored: in this document set superseded wording is kept visible,
never silently reinstated), no
prospect of one. The path can still be named — by **elimination**
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

---

> 📏 **Size self-report.** This file is **~~639 lines / 41,330 B~~ 693 lines /
> 44,383 B** (`wc -l -c`, 2026-09-07 — the day it was split out of
> [`power-bank.md`](power-bank.md)). The struck figure was correct for the few
> hours between the two moves; the current one includes *Naming the Type-A path
> without a Type-A bit*.
> Thresholds are **1,000 lines / 100,000 B**, and **no exemption covers this
> file**. Re-measure rather than quoting this line: it is a snapshot, not a
> current value.
