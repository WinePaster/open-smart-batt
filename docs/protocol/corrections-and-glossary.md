# Corrections to earlier revisions, and glossary

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §9 Corrections to earlier revisions · §11 Glossary

> ⚠️ **§9.1 is not part of §9.** The power-bank register map that carries that
> number lives in [`power-bank.md`](power-bank.md); the numbering is inherited
> from the original document and kept so existing references resolve.

---

## 9. Corrections to earlier revisions

Kept because two of these were carried for weeks with a confidence marker on
them, and anyone who implemented against an older copy of this file needs to know.

| Claim in an earlier revision | Status | Evidence |
|---|---|---|
| Device type is `0x44` (`'D'`) for a power bank — *marked "firmly confirmed"* | ❌ **Wrong** | `0x44` never appears: **0 of 3,808** observed `0x10` payloads. It was a Dart Smi-tag artefact, not a wire byte. Power bank is **`0x22`** |
| `0x25`/`0x26` together hold a 6-byte serial | ❌ **Wrong** | `0x25` has **LEN 2 in all 2,403 observed frames** — it cannot hold six bytes. `0x25` is the manufacture year; the serial is `0x26` alone. Decoding `0x25` as a serial high word corrupts the serial |
| `0x24` (DVOL) is gated on the label string `01680104` | ❌ **Wrong** | `01680104` has **never been observed**. `0x24` streams unconditionally (9,496 frames). A client implementing the gate never shows per-cell voltages |
| Write characteristic is Write-Without-Response only | ❌ **Wrong** | props `0x08` = Write **with** response; `0x04` is not set. 50/50 observed writes are opcode `0x12`. See §2, §3.1 |
| Outbound byte[2] is reserved / a length high byte | ❌ **Wrong** | It is a role flag: `0x00` standalone, `0x01` on a mode-bundled auth sub-frame. See §4.1 |
| `switchMode` carries a trailing context payload | ❌ **Wrong** | Exactly 15 bytes on the wire, nothing after the auth sub-frame. See §6.2 |
| `0x41` payload is 9 bytes; `0x34` is 9 bytes | ❌ **Wrong** | LEN is **8** and **10 _or_ 11** respectively. The old figures counted the XOR byte as payload — and the `0x41` "length doesn't match" argument in §10.1 rested on that miscount. ⚠️ **Re-corrected 2026-08-05**: this row previously said `0x34` is "10", full stop. It is 10 on power banks and capacitors and **11 on some batteries** — the correction was made against a sample that happened to contain only one of the two. |
| TWF values are constant for a whole session | ❌ **Wrong** | A power bank moves between ~~`0x00`/`0x01`/`0x20`~~ **`0x00`/`0x01`/`0x20`/`0x21`** inside one connection. 🔴 **`0x21` added 2026-08-13**: the fourth value of the register, one frame, on the `0x20` → `0x01` boundary as a charge terminated at a full pack. This row and §8.4 previously listed three values in two places; both are now updated. It is a correction to the **list of values seen**, not to any bit's meaning — see [`twf-status.md`](twf-status.md) §8.4 |
| `0x2B` 4th byte is `0x14` on every unit | ❌ **Wrong** | `0x00` also observed (§8.2.2) |
| `0x96` carries capacity/SOH | ⚠️ **Never observed** | **0 of 206,516 frames**, across 96 sessions, four device classes and seven months. The formulas came from analysis of the reference app, not from the link. Do not implement against them without a capture |
| Device type `0x18` does not exist — *this document declined the distributor's claim* | ↩️ **Reversed 2026-08-01** | It does exist: **three independent units at once**, serials 145 / 373 / 416, firmware 1.02 and 1.03, three unrelated reporters, identical `0x2B`/`0x42`/`0x27` values sharing none with the four `0x17` units. `0x18` is the super-capacitor's third generation. The original doubt was sound — the corpus held **0 of 13,444** examples on 2026-07-30 — so the entry is kept rather than deleted: *"never observed"* is a statement about the corpus, never about the hardware. See §2 |
| `0x41` carries a charge-voltage pair (`b4..b5`, `b6..b7`), the §8.2 formula | ❌ **Wrong — the v2 half is refuted, not merely unverified** | On device-type `0x17` the **last payload byte mirrors the `0x21` temperature in °C** (seven units, 85.9–~~100~~ **99.4** % against the nearest-in-time `0x21` — 🔴 corrected 2026-08-14: the 100 % upper bound was a single-capture subset of one unit, whose longer capture reads 97.9 %; every miss off by exactly 1 °C, i.e. sampling skew). A byte carrying degrees cannot be half of a millivolt word. On `0x18` units the agreement is 0 % and the byte is constant while `0x21` moves, so that generation uses a different layout again — a decoder must gate on `0x10`. See §10.1 |

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **PVLT** | Primary/main battery voltage |
| **SVLT** | Secondary voltage |
| **DVOL** | Per-series (per-cell) string voltages, 4 cells |
| **VADJ** | Voltage-precision adjustment factor; multiplier applied to DVOL |
| **OV / UV / OT** | Over-voltage / under-voltage / over-temperature warning thresholds |
| **TWF** | Warning/status byte. **Not a fault flag** — see §8.4 |
| **SOH** | State of health. Attributed to selector `0x96`, which this project has never observed (§9) |
| **SOC** | State of charge, %. On a power bank this is `0x4B` `b6` (§9.1) |
| **Anti-theft (防盜)** | Mode `1` / reported status `1` — theft-protection lock (§6.2) |
| **Cut-off (斷電)** | Mode `2` / reported status `2` — power cut-off (§6.2) |
| **Dealer code (經銷商代號)** | Vendor/dealer identifier from selector 0x27 |
| **Label string** | App-internal string (e.g. `01680102`) built from the dealer code; **never transmitted** (§4.4) |
| **Selector** | `byteList[1]` of an inbound notification frame; the dispatch key |
| **Sync byte** | `0xB8` (184), start of outbound binary frames and validated on inbound |
| **XOR checksum** | Final byte of each binary frame = XOR-fold of all preceding bytes |

> 🔴 **Anti-theft / cut-off corrected 2026-08-01.** Both rows previously read:
>
> | Term | Meaning |
> |---|---|
> | ~~**Anti-theft (防盜)**~~ | ~~Mode 1 / status 2 — theft-protection lock~~ |
> | ~~**Cut-off (斷電)**~~ | ~~Mode 2 / status 4 — power cut-off~~ |
>
> Those status values contradicted §6.2, which was corrected to `0` / `1` / `2` on
> 2026-07-30. The glossary was simply missed by that correction and kept the
> superseded `0 / 2 / 4` numbering alive in a second place — a client reading only
> §11 would still have decoded a pack sitting in cut-off as *anti-theft*, which is
> exactly the failure §6.2 set out to stop.
>
> **The mode-argument column was always right** (`1` = anti-theft, `2` = cut-off);
> only the reported-status column was wrong. §6.2's finding is that the two share
> one code space, so the corrected rows now read the same number twice.
>
> **Re-verified against the capture corpus before editing.** Across **25,128
> `0x23` frames**, drawn from **24 captures on 32 units**, the byte takes exactly
> four values:
>
> | `0x23` payload | frames | Meaning |
> |---|---|---|
> | `0x00` | 15,843 | Normal (§6.2) |
> | `0x05` | 7,089 | Healthy super-capacitor — a **separate code space**, not a pack state (§6.2) |
> | `0x02` | 1,572 | Cut-off active (§6.2) |
> | `0x01` | 624 | Anti-theft active (§6.2) |
> | **`0x04`** | **0** | **Never observed** |
>
> This confirms §6.2's statement that **`0x04` is not a pack state**. A second,
> independent extraction — the `mode` column of the app's own CSV export, parsed
> separately from the frame stream — gives the same value set (`0`, `1`, `2`, `5`)
> and likewise never yields `4`.
>
> ⚠️ Note `0x05` is **not** a fourth pack state: a super-capacitor has no cut-off
> and no anti-theft and answers `0x23` in its own space. Decode `0x23` only after
> the device class is known, and compare with equality — a bitmask is wrong here,
> since `5 & 1 != 0` would report a healthy capacitor as anti-theft.

---

*End of specification.*
