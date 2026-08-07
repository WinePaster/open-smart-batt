# Open items — unverified, undecoded, and the capture prerequisite

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §10 Unverified / needs hardware confirmation · §10.1 Observed but not decoded · §10.1.1 `0x40` · §10.2 Capture prerequisite

---

## 10. Unverified / needs hardware confirmation

* ~~**Notify characteristic UUID.**~~ **RESOLVED 2026-07-27** — a live GATT dump
  gives `07b9ace4-d55f-5e82-ba44-81c0da86c46c` (Notify), under service
  `07b9fff0`. See §3.1.
* ~~**Service containing the write/notify characteristics.**~~ **RESOLVED
  2026-07-27** — the same GATT dump places both `07b9ace3` (write) and
  `07b9ace4` (notify) under `07b9fff0`. See §3.1.
* ~~**Received-frame bytes [2]/[3]**~~ **RESOLVED 2026-07-28** — `byte[2]` is a
  constant `0x01` response marker and `byte[3]` is the payload length; 3342/3342
  frames parse with zero leftover bytes. See §4.3.
* **`f000ffc0-0451-4000-b000-000000000000` service.** Present on at least one
  unit with two Write-Without-Response + Notify characteristics (§3.1). Shape
  matches the TI OAD firmware-update profile. Never exercised; contents unknown.
  Irrelevant to telemetry.
* **Vendor characteristics `07b9ace1` / `ace2` / `bbc1` / `bbc2`.** Advertised
  (§3.1) but never read or written by the reference app. Purpose unknown.
* **DiscoveredCharacteristic property-flag semantics.** The five booleans gating
  the notify path (offsets 0x1f/0x23/0x13/0x17/0x1b → presumably
  isReadable/isWritableWithResponse/isWritableWithoutResponse/isNotifiable/
  isIndicatable) were not fully disambiguated from the branch senses
  (medium confidence).
* **TWF bit→meaning mapping (selector 0x20).** The code indexes bit positions
  **[14], [12], [6], [4]** of the binary string, which require a **≥15-char**
  string, yet `b4` is a single byte (`padLeft(8)` would yield only 8 chars,
  indices 0–7). This contradiction means either the TWF status word is **wider
  than one byte** (`padLeft(8)` is only a floor) or the byte source differs. The
  "8-bit binary of byte[4]" framing and the specific protection-flag bit
  assignments are **not reliable**.
  Note the distinction: the **value** `0x20` is now known to accompany charging
  on power banks (§8.4), which says nothing about what bit 5 *means* on the other
  classes — they have never produced it. Resolving a bit still needs a controlled
  experiment.
* **Initial "detect" command bytes.** Never isolated. Not required for telemetry
  (§6.4).
* ~~**Device-type poll comparison tag.**~~ **RESOLVED 2026-07-30** — the wire byte
  is `0x02`/`0x17`/`0x22`; `0x44` occurs in 0 of 3,808 frames and was a Smi-tag
  artefact. See §9.
* ~~**Exact total on-wire length of `switchMode`.**~~ **RESOLVED** — 15 bytes,
  no trailing payload. See §6.2.
* **`0x96` capacity/SOH.** Not merely un-decoded — **never seen**. See §9.
* **`0x4B` `b7` bit 0 and bit 4, and `b8`.** See §9.1; each needs a specific
  capture, named there.
* **Whether the power-bank current is measured cell-side or port-side.** Until
  this is settled, do not multiply it by the port voltage and call the result
  power (§9.1).
* **Full read-selector enumeration.** Further selectors exist in the reference
  app's dispatch table whose wire layouts have not been observed.

### 10.1 Observed on the wire but NOT decoded

Baseline: whole-corpus re-walk **2026-07-30** — 96 sessions, 206,516 XOR-clean
frames. Streamed by real units, with no established meaning. **Do not guess a
layout**; each needs a controlled experiment.

Every row states its **class attribution from the `0x10` byte in the same
session**. Rows that cannot state one say so — that is the point of the column.

| Selector | Class | LEN | Payload | Notes |
|---|---|---|---|---|
| `0x40` | **battery `0x02`** (2026-07-30) | 2 | this unit: `20xx`, 15 distinct, `2000` (2134) / `2010` (1582) / `2001` (718) / `200d` (692) … — earlier unattributed capture, de-duplicated: `222b` (708) / `2229` (91) / `022b` (14) | ✅ **Attribution resolved.** The 2026-07-30 capture is a single-device 23-hour log carrying 5,398 `0x40` frames *and* 2,127 `0x10` = `0x02` frames, which is exactly the "capture one *identified* unit" this row used to ask for. Emission is **1:1 with `0x21`/`0x2E`** (5,398 : 5,398 : 5,398) and it sits immediately after `0x20` (TWF) in every telemetry group. Still **not decoded**: byte 1 grouped against current, temperature and PVLT in the same frame shows no separation (all 15 groups' ranges overlap). **Three candidate readings are now positively refuted, and the experiment this row used to propose was the wrong one — see §10.1.1.** |
| `0x3C` | battery `0x02` | 2 | `0000` ×4, `1100` ×1 | Answers `!#` only (§2), so a 23-hour session yielded 5 samples. One of the five differs — enough to prove it is not a constant, far too few to say what changes it. |
| `0x4D` | battery `0x02` (motorcycle so far) | 7 | `320d240d08001c`, `320d1e0cfa0024`, `320d100ce70029`, `320d320d08002a`, `21b8f10000b8f1`, `320d170cfa001d`, `230dea0dcf001b` | Answers `!#` only. ✅ **Field boundaries are established: `[u8][u16 A][u16 B][u16 C]`, with `C == A − B` in 11 of 11 samples across two independent units** (two different reporters, both RCE 9A motorcycle packs, 2026-08-03). That identity is what fixes the layout — it holds arithmetically on every sample, so the split cannot be anywhere else. ⚠️ It also settles the `21b8f1…` sample: with `A` = 47345 and `B` = 0 the identity still holds, so that frame is **the same structure in an unusual state, not a broken one** — the earlier reading of it as "breaks the shape entirely" was wrong. **The meaning remains unknown, and two candidate readings stay positively refuted**: `A`/`B` are **not** the `0x47` cell max/min (re-checked on the second unit — `0x47` reported 3304/3306/3292/3319 mV against `0x4D`'s 3351/3322), and `C` is **not** the `0x21` temperature. `b0` has taken `0x32`, `0x21` and `0x23`. **Do not decode A/B/C.** |
| `0x42` | capacitor | 4 | `07c87805`, constant | Same value on both platforms and every session of the same unit — consistent with a static setting or model code. Unproven. |
| `0x41` | capacitor | **8** | `304d303c0100272d`, `33853375 0100 373d`, `336e33a8 0100 2424` | Labelled "charge info" by the reference app. ✅ **The last payload byte mirrors the `0x21` temperature — but only on device-type `0x17`.** Seven `0x17` units hit 85.9–100% against the nearest-in-time `0x21` (per-unit n from 75 to 3,119); every miss is off by exactly 1 °C, which is what sampling skew between two registers looks like. On all three `0x18` units it is **0%** and the byte is constant for the whole capture (`41` / `36` / `3e`) while `0x21` moves — so `0x18` uses a different layout here, and a decoder must gate on `0x10`. ⚠️ The rest is still **not decoded**: bytes 0–3 are per-unit ~~and constant within a capture~~ — 🔴 corrected 2026-08-07: **stable but not immutable**. Two independent units each changed this word pair exactly once — one mid-rolling-log across a six-day disconnected gap, one between exports four days apart — while every individual connection session stayed constant (tens of thousands of frames each). Read bytes 0–3 as a **device-side stored value that can update between sessions**, not a per-unit constant. Bytes 4–5 are `0100` in every sample, and byte 6 (🔲 hypothesis: a second temperature point — it has stayed ≤ byte 7 on every unit seen) has no external corroboration. The §8.2 2×u16 charge formula stays refused, now for a stronger reason than before: byte 7 carrying °C rules out reading bytes 6–7 as a millivolt word. |
| `0x4C` | power bank | 2 | `3c0a`, **691/691 constant** across 3 units and 2 phones | Nothing varies ⇒ nothing can be inferred about field boundaries. |
| `0x2C` | capacitor | 2 | `3b82` | No hypothesis. |
| ~~`0x34`~~ | — | — | — | ✅ **DECODED 2026-08-05 — moved out of this table**, see [`telemetry-decoding.md`](telemetry-decoding.md) §`0x34`. ⚠️ The note this row used to carry ("earlier revisions printed an 11-byte example and called it 9 bytes; both were wrong") was itself half wrong: **both 10 and 11 are real lengths**, and which one you get identifies the product class. Correcting a length against a single sample is how that happened. |
| `0x3A` | capacitor | 2 | `5100` | No hypothesis. |
| `0x21` `b5` | power bank | (2) | constant `0xe2`, 6,118 frames | The extra byte of the power-bank temperature frame (§9.1). |
| `0x4B` `b8` | power bank | (5) | varies | Ruled **out** as the displayed temperature (§9.1). |

> ⚠️ **"Constant" is a statement about your sample, not about the register.** A
> field held constant through one session only means that session contained no
> state change. This document previously recorded `0x4B` `b7` as "always 38" on
> exactly that basis; a later capture that included a different output mode showed
> it varying across nine distinct values. Any future "constant" claim must state
> which states the sample covered.

Method note: all of the above come from **reassembling the byte stream and walking
frames by LEN**, not from substring-matching hex text. An earlier pass using
`grep` over log text reported `0x1F` and `0x22` as selectors; strict framing shows
**no such frames** — those were payload bytes that happened to follow a `0xB8`.
Any future selector claim should come from the framing walk.

#### 10.1.1 `0x40`: three floated candidates, all refuted (2026-07-31)

`0x40` has been carried as undecoded with three candidate readings in
circulation — **cycle count**, **nameplate capacity (mAh)** and a **cumulative
charge accumulator**. All three are refuted by data already on disk. No new
capture was needed to kill them, and none of them should be re-floated.

Source: a 2026-07-30 capture — one
identified unit (`0x10` = `0x02` on 2,127 of 2,127 frames), six connections,
2026-07-29 18:10 → 2026-07-30 17:06 (≈23 h), **5,398 `0x40` frames**, every one
LEN 2 and XOR-clean. ✅ **verified** — this project's own capture, re-measured
2026-07-31.

| Candidate | Verdict | The measurement that kills it |
|---|---|---|
| **cycle count** | 🔴 refuted | byte 1 **decreases** — 329 times in this one session |
| **cumulative charge** | 🔴 refuted | same measurement; an accumulator does not run backwards |
| **nameplate capacity (mAh)** | 🔴 refuted | byte 1 **changes at all** — 643 times, on one unit, with no hardware change |

Byte 1, walked in timestamp order across all 5,398 frames: **314 increases, 329
decreases, 4,754 unchanged** — it moves on **643 of 5,397** consecutive pairs
(**11.9 %**). First value `0x01`, last `0x0d`, 15 distinct payloads. The
behaviour is present *within* individual connections, so it is not an artefact
of stitching six sessions together (session 4: 124 up / 134 down; session 6:
163 up / 171 down).

Two further measurements from the same re-walk:

* **Byte 0 is not stable within a single session either.** This row previously
  said byte 0 was "per-unit or per-state"; it understated the case. In an older
  unattributed capture (813 `0x40` frames, all inside one continuous 6 min 07 s
  stretch on 2026-07-05) byte 0 is `0x22` on **799** frames and `0x02` on **14**, arriving
  as four short excursions (1, 1, 11 and 1 frames) out of otherwise long `0x22`
  runs. Across the whole corpus byte 0 takes `0x20`, `0x22`, `0x02` and `0x00`, so
  **only bits 1 and 5 are ever used** — but bit 1 flips inside one session on one
  unit, which rules out a fixed per-unit identifier.
  <br>🔴 **Enumeration corrected 2026-08-01.** This said "takes only `0x20`,
  `0x22` and `0x02`". A later capture of the same identified unit — extended to
  47 h and 115,519 frames — carries **4 frames with byte 0 = `0x00`**,
  all landing within 1.6 s of a `link: ready`, byte 1 unchanged across them.
  Note the scope of the correction: only the *list* was wrong. "Only bits 1 and 5
  are ever used" is **not** refuted — `0x00` is the fourth and last combination of
  those two bits, so the corpus now exhibits all four and the bit-mask claim is
  strictly better supported than before. ✅ verified (raw RX lines and per-frame
  XOR checked individually).
* **On the identified unit byte 1 never exceeds `0x18`** — mask `0x1F`, 15 of the
  32 possible low-5-bit patterns, and bit 1 occurs only paired with bit 4. That is
  *consistent with* a bitfield, but a small magnitude occupies the same bits, so
  this is a **reading, not a decode**. It is also not a general property of the
  register: the older unit's byte 1 is `0x29`/`0x2b`, which sets bit 5.

🔴 **Correction to counts previously printed in this row.** The earlier figures
for the unattributed capture — `222b` (8,747) / `2229` (8,745) — do not
reproduce by any method tried, and are far larger than the log can hold. That
session is exported **three times** in the corpus (three separate exports carry
byte-identical copies of it), and de-duplicated it holds `222b` ×708, `2229`
×91, `022b` ×14 = **813 frames total**. ⚠️ Diagnostic exports are
**cumulative** — each contains all earlier sessions for that device — so any
count taken from this corpus must be de-duplicated before it is published.

**The experiment this row used to propose does not exist, and would not have
settled it.** It asked for "the same unit before and after a charge cycle, with
the charge state labelled". Batch `006` *already* carries in-band charge
labelling: `0x2E` (signed main current, §8.2) is present on all 5,398 telemetry
groups, and 339 of them are negative. But those 339 fall into **28 separate
runs, the longest lasting 25.8 s** (2026-07-30 17:05:17.756 → 17:05:43.527),
with current swinging −41 A … +14 A. That is a running vehicle's alternator,
not a charge cycle — labelled, in band, and useless for this purpose.

⇒ **The capture that would actually settle it:** the same `0x10` = `0x02` unit,
on a **sustained** charge — **≥30 min continuous** with `0x2E` negative
throughout — held in **one continuous connection**, with `!#` issued at both ends
so the connect burst brackets the run (§10.2 — without it the metadata
registers never arrive). Anything shorter re-measures the transient that batch
`006` already contains.

> 🚫 **Unconfirmed lead — do NOT implement, and do not read it as a partial
> decode.** Pairing each `0x40` frame with the `0x24` cell voltages from the same
> telemetry group, byte 1 **bit 3** is set almost only when cell 4 (payload index
> 3) is at or above every other cell: **867 of 870** bit-3 frames, 99.7 %.
> **The converse fails badly, and that is the half that matters:** of the 3,437
> frames where cell 4 is the maximum, bit 3 is set in only **867 — 25.2 %**. A
> rule that fires on a quarter of its own condition predicts nothing. It is
> further **confounded with pack voltage**: bit-3 frames average PVLT 13.48 V
> against 13.82 V for the rest, and "cell 4 is highest" is itself a low-voltage
> condition (13.64 V vs 13.99 V), so the association may be entirely mediated by
> voltage. One unit, one session, no controlled variation. Recorded only so the
> next reader does not re-find it and mistake it for a decode.

### 10.2 Capture prerequisite: no keep-alive write ⇒ no metadata

**Which selectors you observe is a property of your client, not of the device.**
A unit that receives no keep-alive write still streams a small telemetry set, so
a broken write path looks like a working connection — and every conclusion drawn
about "what this device supports" from such a capture is wrong.

Evidence, from the whole-corpus re-walk (2026-07-30; 96 sessions, 206,516 frames).
Selectors observed **with a working write path**, grouped by the `0x10` byte:

| Class | Selectors observed |
|---|---|
| Battery `0x02` | `0x10 0x14 0x17 0x19 0x1C 0x1D 0x20 0x21 0x23 0x24 0x25 0x26 0x27 0x29 0x2B 0x2C 0x2E 0x30 0x31 0x34 0x35 0x36 0x37 0x38 0x39 0x3A 0x3B 0x3C 0x3F 0x40 0x47 0x4D` |
| Capacitor `0x17` | `0x10 0x19 0x20 0x21 0x23 0x25 0x26 0x27 0x29 0x2B 0x2C 0x2E 0x34 0x37 0x38 0x3A 0x3B 0x41 0x42` |
| Power bank `0x22` | `0x10 0x19 0x20 0x21 0x25 0x29 0x34 0x37 0x38 0x3A 0x3B 0x49 0x4A 0x4B 0x4C` |
| **Broken write path** (zero TX) | `0x19 0x20 0x21 0x24 0x2E 0x37` — six registers |
| Unattributed sessions | `0x19 0x20 0x21 0x24 0x2E 0x37 0x40` |

> Two things this table says that the previous single-column version could not:
> **`0x96` appears nowhere** (see §9), and the sets differ **by class**, so
> "this device doesn't support X" requires knowing which device you had.
>
> 🔴 **Correction (2026-07-30).** This note previously read "the final row is why:
> `0x40` is only ever seen where no `0x10` arrived", and §10.1 built an
> unattributable-forever caveat on top of it. **A same-day capture falsifies it**:
> one battery, one device, 23 hours, 5,398 `0x40` frames alongside 2,127
> `0x10` = `0x02`. The old statement was true of the corpus at the time and was
> read as though it were true of the register. `0x3C`, `0x40` and `0x4D` are now
> in the battery row above on direct evidence.
>
> Note what changed and what did not: `0x40` remains **undecoded**. Knowing which
> class emits a register is a prerequisite for decoding it, not a substitute.

The six that survive a broken write path are the free-running telemetry stream.
Everything identifying — **device type (`0x10`), serial (`0x26`), manufacture year
(`0x25`), dealer code (`0x27`), VADJ (`0x30`), mode (`0x23`), thresholds
(`0x2B`)**, and on power banks **the entire `0x49`/`0x4A`/`0x4B` group** — rides
the connect burst, which only fires after the device is poked (§2).

Two consequences worth stating plainly:

1. **A capture with no metadata proves nothing about the hardware.** Absence of
   `0x24` means "capacitors don't report cell voltages" only if the burst
   arrived; otherwise it means nothing at all. An earlier claim that
   capacitors stream only voltage and temperature was exactly this mistake.
2. **Log the TX direction, and log write failures.** A silent `catch` around the
   keep-alive write hides the entire failure mode: the link reports ready,
   telemetry flows, and only the missing registers hint at the problem. `TX == 0`
   for a whole session is the diagnostic signature.
