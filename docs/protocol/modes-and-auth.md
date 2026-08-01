# Unlock, cut-off, and anti-theft

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §6 Unlock / cut-off / anti-theft flow

---

## 6. Unlock / cut-off / anti-theft flow

### 6.1 Password encoding

The cut-off password is **never transmitted in plaintext**. Authentication proves
knowledge of it via a **16-bit checksum = sum of the password's character code
units**, split big-endian: `sum_hi = sum>>8`, `sum_lo = sum & 0xFF`.

The auth frame also carries an **echo value** `cb` derived from the dealer-code
label string (§4.4).

**`cb` is the first two payload bytes of `0x27`, big-endian** — equivalently, the
label string's leading **4** characters read as decimal (§4.4 renders those two
bytes as `%04d`):

| `0x27` payload | Label | `cb` |
|---|---|---|
| `00a801020000` | `01680102` | `0x00A8` (168) — ✅ observed on the wire |
| `00a901020000` | `01690102` | `0x00A9` (169) — predicted, **not yet confirmed** |

> 🔴 **This corrects a rule that earlier revisions stated as "the first 8
> characters", and that contradicted the one wire observation printed directly
> beneath it.** Parsing 8 characters of `01680102` gives 1,680,102, whose low 16
> bits are `0xA2E6` — not the `0x00A8` that was actually captured. The "168" in
> the old example came from 4 characters, so the prose and its own evidence
> disagreed. **The evidence wins.**
>
> ⚠️ **This document's own client implemented the 8-character rule**, and a
> 2026-07-30 capture shows it writing `cb = 0xC9F6` (1690102 & 0xFFFF) to a
> `01690102` battery where this table predicts `0x00A9`. The device did not
> change `0x23` in response — see §6.2. That is **consistent with** a rejected
> auth but does not prove it: the same capture's battery was already in normal
> mode, so a correctly-authenticated release would also have been a no-op. **Both
> the 4-character rule and the failure mode need one deliberate capture against a
> unit that is actually in cut-off.**

⚠️ **Both this value and the password checksum
travel in cleartext in the auth write, and the dealer code is broadcast by the
device itself in `0x27` telemetry — so a passive sniffer learns one of the two
for free, and the auth frame is replayable as-is.** This is a property of the
protocol, recorded so owners understand what the "password" does and does not
protect.

### 6.2 `switchMode(mode)` — lock/unlock entry point

Builds and writes (single write):

```
mode frame : [0xB8, 0x23, 0x00, 0x01, mode] + XOR                          (6 bytes)
auth frame : [0xB8, 0x2A, 0x01, 0x04, cb_hi, cb_lo, pwsum_hi, pwsum_lo] + XOR  (9 bytes)
on wire    : mode_frame ++ auth_frame            = 15 bytes, nothing more
```

> **Byte[2] of the bundled auth sub-frame is `0x01`, not `0x00`** (§4.1). A
> standalone auth write uses `0x00`. Live HCI capture confirms the total is
> exactly 15 bytes with no trailing payload.

**Mode argument → action:**

| `mode` | Action |
|---|---|
| `0` | Deactivate / unlock (normal) |
| `1` | Activate anti-theft (防盜) |
| `2` | Activate cut-off (斷電) |
| `6` | **Not a release** — see below. Purpose unknown; the reference client starts a 10 s periodic detect poller after writing it |

> 🔴 **`0x06` does not release a cut-off (measured 2026-07-30).** This row read
> "cut-off release" on the strength of one observation — of a **super-capacitor**,
> whose `0x23` pulsed to `0x06` for about a second and reverted to `0x05`, its
> own status space, and which has no cut-off feature at all.
>
> Against batteries **actually sitting in cut-off**, it does nothing:
>
> | unit | writes of `0x06` | `cb` used | `0x23` |
> |---|---|---|---|
> | 1261 (JIS 40 Ah) | 6 | `a2e6`, plus bare mode frames with no auth | `0x02` throughout |
> | 1441 (EU 50 Ah) | 2 | `00a8` | `0x02` / `0x01` throughout |
>
> Eight writes, two units, both `cb` derivation rules, and auth omitted entirely
> — `0x23` never moved. Every real transition in those captures occurred five to
> fourteen minutes away from any write, i.e. by other means.
>
> ⚠️ 2026-07-31: 1261's presence "in cut-off" is **inferred** from its `0x23` =
> `0x02`, not owner-labelled — batch `010` names no mode (see the withdrawal
> note below). This does not weaken the elimination: the argument is that
> `0x23` **never moved across 20 mode writes**, which holds whatever state the
> pack was in. Across all six exports every single write was `0x06`; mode `0`,
> `1` and `2` were never sent even once.
>
> That eliminates the auth value and the auth requirement, and leaves the mode
> code. **To return a pack to normal, write `0`** — the value the distributor
> gives for 正常模式 and the one the reference UI writes when leaving a mode.
>
> ⚠️ `0` is **not proven** either: no capture holds a successful write. The case
> for it is elimination plus the vendor's numbering, so a client should verify
> against `0x23` afterwards rather than report success.

> ⚠️ **A mode write is not acknowledged in any observable way.** In a 2026-07-30
> capture a client wrote mode `0x06` five times to a battery (four bundled with
> auth, one mode-only) and `0x23` read `0x00` on **2,131 of 2,131** frames across
> the whole 23-hour session — no pulse, no error frame, no change in the reply
> cadence. The `0x06 → 0x05` pulse quoted in the row above came from a
> **capacitor**, which answers `0x23` in a different code space entirely (§6.2
> reported-status table applies to packs only).
>
> ⇒ **A client cannot tell "accepted" from "rejected" from "not in that state
> anyway" by watching `0x23`.** Do not report success on a write returning
> without error; the only honest UI is "sent", plus whatever `0x23` says
> afterwards.

> 📉 **Negative result — the whole-corpus TX census (2026-07-31).** All **32**
> log files in this project's capture corpus were re-walked on the transmit side: TX lines
> parsed as `b8 SEL ROLE LEN payload XOR`, XOR folded over all preceding bytes,
> with a single TX line allowed to concatenate several frames. ⚠️ De-duplicated
> — exports are cumulative, and a naive union counts **42** `0x23` and **20**
> `0x2A` writes where there are 20 and 10.
>
> | CMD | ROLE | LEN | payload | frames | XOR |
> |---|---|---|---|---|---|
> | `0x23` mode | `0x00` | 1 | `06` — **always** | **20** | 20 / 20 clean |
> | `0x2A` auth | `0x01` | 4 | 6 distinct `cb`/`sum` pairs | **10** | 10 / 10 clean |
>
> **That is the entire set. This app has never written any other binary command
> code, in any session, to any device class.** Specifically:
>
> * 🚫 **No `0x2B` threshold write has ever been captured** — zero frames,
>   corpus-wide. §8.3 documents that write path, but it comes from the reference
>   app's code, **not from the wire.** Nothing here says it is wrong; it says it
>   is **untested**. The same holds for `changeCutOffPassword` (§6.3), which
>   would ride `0x2A`.
> * **All 20 mode writes carried mode `0x06`.** `0`, `1` and `2` have never been
>   sent — which is why the recommendation to write `0` above rests on
>   elimination and the distributor's numbering, not on a capture.
> * **Half the mode writes went out bare:** 10 of 20 `0x23` frames had no `0x2A`
>   bundled behind them.
> * **No write ever moved the readback.** The seven sessions containing a `0x23`
>   write hold **1,730** `0x23` reply frames between them, and in every one of the
>   seven the reply is a **single constant value for the whole session**
>   (`0x00` in two sessions, `0x01` in two, `0x02` in three).
>
> The transmit path itself was alive throughout: the same corpus carries 10,635
> `#`, 423 `@` and 194 `!#` ASCII keep-alive writes (§4.2). This is a statement
> about what was ever *commanded*, not about a dead TX path.
>
> ⇒ Read it as the boundary of the evidence. **Every configuration write in this
> document is decompiled rather than observed.** An implementation may send them,
> but must not present them as verified — and, per the paragraph above, cannot
> verify them by watching `0x23`.

**Reported status** (device → app) uses the **same code space** as the mode
argument:

| reported status | Meaning / UI |
|---|---|
| `0` | Normal (lock icon) |
| `1` | Anti-theft active (防盜模式已啟動) |
| `2` | Cut-off active (斷電模式已啟動) |

> 🔴 **Corrected 2026-07-30, from `0 / 2 / 4`.** Earlier revisions carried those
> values *and* the claim that reported status and the mode argument were
> different code spaces that must never be compared. Both came from the
> reference app's decompiled UI logic (`currentMode != 2` / `!= 4`); neither had
> ever been seen on the wire.
>
> An owner then put two batteries through all three states and labelled each
> export with the state it was in. `0x23` tracked the labels exactly:
>
> | unit 1441 (EU 50 Ah) | unit 1261 (JIS 40 Ah) |
> |---|---|
> | 19:00 `0x00` | 18:58 `0x02` ← ⚠️ **unlabelled**, withdrawn |
> | 19:09 `0x02` ← exported as 斷電 | 19:16 `0x01` ← exported as 防盜 |
> | 19:19 `0x01` ← exported as 防盜 | 19:22 `0x00` ← exported as 正常 |
> | 19:24 `0x00` ← exported as 正常 | |
>
> ⚠️ **Narrowed 2026-07-31.** The 1261 `0x02` cell read "exported as 斷電" when
> this table was written. It was not: batch `010`'s readme gives the pack only
> ("日規鋰鐵40AH") and names **no** mode, unlike `011`–`015`, which each name
> one. The owner has ruled that batch's mode unknown and not worth chasing, so
> the row is withdrawn as evidence — the `0x02` **reading** stands, the label
> does not.
>
> State the count honestly: 705 `0x23` frames, zero XOR failures, `0x23`
> constant within every session. `0x02` = cut-off is owner-labelled on **one**
> unit (1441); `0x01` and `0x00` on **two**. The distributor independently gives
> the same numbering for the write argument.
>
> ### ✅ `0x02` = cut-off, confirmed by the vendor's own app (2026-08-01)
>
> The narrowing above left `0x02` resting on a single owner label. It no longer
> does. On 2026-07-31 a reporter photographed unit **1261** in the **original
> iBatt app**, which rendered its own UI string `斷電模式已啟動！`
> ("cut-off mode activated") — and our log of the same unit, from the same
> afternoon, reads `0x23` = `0x02` on **248 of 304** frames spanning both sides
> of that photograph. Every other field on the screen cross-checks against the
> wire in the same window: 9.81 V ↔ `0x19`, 0 A ↔ `0x2E`, 33 °C ↔ `0x21`, and
> per-cell 3.28/5.04/3.26/3.28 V ↔ `0x24`×VADJ **and** `0x47` native mV, all
> three agreeing. ✅ **verified.**
>
> This matters because of *where* it comes from. Every prior data point was an
> owner labelling their own export; this one is the vendor's firmware naming the
> state, which is the escalation path this project's own landing threshold asks
> for. `0x02` = cut-off is now attested on **two** units, and the second
> attestation is semantic rather than circumstantial.
>
> ⚠️ **Two caveats, both real.** The vendor app connected over its own link, and
> there is an **8.5-minute gap** between our last frame before the photo and our
> first after it — the states are contiguous by inference, not by capture. And
> this does **not** restore the withdrawn batch `010` row above: that batch's
> mode remains unknown. This is independent evidence from a different day, not a
> reinstatement.
>
> 🔲 **Still open on this unit:** the screen also said `過電壓保護中`
> ("over-voltage protection engaged") at a pack voltage of 9.81 V, which is not
> self-consistent, and its `SVLT − PVLT` gap of +5.1 V was **already present that
> morning with mode `0x00`** — so the gap is not caused by cut-off. See §8.4.
>
> **`0x04` is not a pack state.** It appears nowhere in this corpus.
>
> What the error cost while it stood: a pack sitting in cut-off reports `0x02`,
> which the old table read as *anti-theft*, so a client following this document
> told an owner their battery was not cut off while it was.
>
> ⚠️ The capacitor exception is unaffected: a super-capacitor answers `0x23` in
> its own space (`0x05` on 2,982 frames) and still must not be read through this
> table. Compare with `==`, never a mask — and the correction sharpens that,
> since `5 & 1 != 0` would now call a healthy capacitor "anti-theft".

**UI button logic** (function page) — ⚠️ **treat as unreliable**:
* Anti-theft: `switchMode(currentMode != 2 ? 1 : 0)`
* Cut-off: `switchMode(currentMode != 4 ? 2 : 0)`

> 🔴 The comparison constants here are `2` and `4` — exactly the reported-status
> values the table above was corrected away from on 2026-07-30. That is unlikely
> to be a coincidence: this decompiled reading is the most probable source of
> those numbers, which means it is quite possibly misread rather than merely
> describing something we misunderstood.
>
> The one part that survives independently is the shape: **leaving a mode writes
> `0`**, which agrees with the distributor's own encoding (`0` normal, `1`
> anti-theft, `2` cut-off) and is what this document now recommends for a
> release. Do not lean on the comparison constants until someone re-derives them.

#### What the two modes physically do

⚠️ **Source: the vendor's distributor, verbally, 2026-07-30. NOT verified on the
wire.** Recorded because the difference is a safety matter and the register
names alone do not convey it.

> 🔴 **Corrected 2026-07-31 — the reason it is unverified has changed.** This
> paragraph used to say "no capture in this corpus has a unit in either state".
> That is no longer true: `010`–`015` hold two packs sitting in cut-off and
> anti-theft for minutes at a time. The claim is still unverified, but now for a
> different and more fixable reason — **no load and no output-side
> measurement**:
>
> `0x2E` current by mode, per-minute buckets from the `014` / `015` exports
> (min–max, mean, buckets/samples):
>
> | unit | 斷電 (`0x02`) | 防盜 (`0x01`) | 正常 (`0x00`) |
> |---|---|---|---|
> | 1441 (EU 50 Ah) | `0.00` flat (10 / 1321) | `0.00` flat (9 / 1278) | `0.00` flat (9 / 931) |
> | 1261 (JIS 40 Ah) | 0.00–0.46, x̄ 0.13 (8 / 2118) | 0.00–0.73, x̄ 0.37 (7 / 1617) | 0.51–1.00, x̄ 0.75 (2 / 311) |
>
> 1441 reads `0.00 A` in **every** mode, so nothing about it distinguishes
> cut-off from normal — it had no load attached. 1261's mean rises monotonically
> 0.13 → 0.37 → 0.75 across 斷電 → 防盜 → 正常. Per the owner (2026-07-31) the
> residual draw is the **BLE module and BMS supplying themselves**, which is
> consistent with cut-off disconnecting the *output* while the electronics stay
> powered — the pack must keep its radio up to be released again.
>
> ⚠️ Three caveats. (1) 1261's cut-off column comes from the sessions whose mode
> label was **withdrawn** above, so "this is what cut-off looks like" is not
> established for that unit. (2) It cannot be cross-checked against 1441, which
> reads `0.00 A` regardless. (3) **The draw is not a floor**: cut-off and
> anti-theft each contain minute-buckets averaging exactly `0.00 A`, so the
> current does not sit at a steady housekeeping level — and 460 mA is high for a
> BLE module alone. The 正常 column is 2 buckets / 311 samples, far too thin to
> lean on.
>
> **To actually verify:** put a known load on a pack in cut-off and record
> whether the load current is zero while `0x2E` still shows the housekeeping
> draw. One capture settles it.

| Mode | Behaviour |
|---|---|
| **Cut-off** (`2`) | Output is disconnected outright. Nothing is supplied; the vehicle will not start. |
| **Anti-theft** (`1`) | Output stays live. The pack watches the current draw and disconnects **when it exceeds a configured amperage**, after which it supplies nothing. |

Two consequences worth stating plainly:

* **Anti-theft is a current trip, not a passive flag.** It works by letting a
  thief connect and then cutting power the moment they draw enough to crank the
  engine. That is also why it is model-gated: a pack without the current sense
  cannot implement it.
* 🔴 **Anti-theft is arguably the more hazardous of the two while a vehicle is
  in use.** Cut-off fails immediately and obviously — the vehicle will not
  start. Anti-theft fails *later*, on a current spike, which on a moving vehicle
  means power is lost while it is being driven. A client offering this control
  should say so, not merely warn that the mode is "unverified".

**The trip current is configurable**, per the same source — but **no write path
for it is identified in this document**. `0x2B` (§8.2.2) carries OV / UV / OT and
a trailing byte, with no current field, so the threshold is set somewhere this
corpus has not captured. Anyone reverse-engineering the anti-theft path should
start there rather than assume `0x2B` covers it.

### 6.3 `changeCutOffPassword(newPwBytes)`

```
[0xB8, 0x2A, 0x00, 0x04, cb_hi, cb_lo, newsum_hi, newsum_lo] + XOR
```
where `newsum` = sum of the **new** password bytes. Same `0x2A` channel as the
auth frame.

> ⚠️ Note a quirk in the reference app: the byte loop is bounded by the **old**
> password's length, so changing to a longer password silently truncates the
> checksum input. An interop client should sum the full new password.

### 6.4 Detect handshake

The reference app maintains internal "detect sent" / "detect received" flags that
gate its init and firmware-info requests. **The exact on-wire bytes of the initial
detect send have not been isolated** (see §10) — but they are not required:
telemetry streams from the keep-alive `#` alone (§2), and every capture to date
shows telemetry flowing well before any auth.
