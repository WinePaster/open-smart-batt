# RCE iBatt BLE Protocol Specification

> **Right-to-repair research notice.** This document is a clean-room record of
> **functional protocol facts** (UUIDs, command bytes, data formats, state
> machines, scaling formulas) for the RCE iBatt smart battery, whose vendor is
> defunct. It exists solely so that owners can continue to communicate with
> hardware they already own. It contains **no copyrightable expressive material**:
> no verbatim application source, no UI artwork, and no quoted UI text (Chinese
> labels are summarized in English). Facts, protocols, and data formats are not
> copyrightable. This is non-commercial interoperability documentation.

---

## This file is an index

The specification was split by protocol topic on **2026-08-01**, when it reached
1,572 lines / 92 KB. **This file holds no protocol facts** — every fact lives in
one of the files below, moved verbatim. The original `§` numbering is preserved
inside those files, so an existing reference such as "§6.2" or "§9.1" — including
the many in the app source — still names exactly what it always named. Only the
file it lives in has changed.

Nothing was rewritten, deleted, or renumbered in the split.

🔵 **2026-09-07 — a second, smaller split, and this one did allocate a number.**
`protocol/power-bank.md` had reached 857 lines against this project's 1,000-line
ceiling, with 586 of them in a single section. That section — `0x4B` `b7`, the
port and protocol flags — moved verbatim to
[`protocol/power-bank-port-flags.md`](protocol/power-bank-port-flags.md) and was
given **§9.2**, the next free number, rather than being carried across
unnumbered: no `§` in this document set spans two files. ⚠️ ~~Nothing was
rewritten, deleted, or renumbered in the split~~ still holds for the text — not a
word of the moved section changed — but **a number was added**, which the
2026-08-01 sentence above did not have to say.

🔵 **2026-09-07, later the same day — two follow-ups, neither of them a new
split.** ① *Naming the Type-A path without a Type-A bit* had been left behind in
`protocol/power-bank.md`; it moved into **§9.2** as well, verbatim, because its
first sentence is *"after the four refutations above"* and those refutations
were now in the other file. ⚠️ A title-anchored reference to it must now say
[`protocol/power-bank-port-flags.md`](protocol/power-bank-port-flags.md).
② **This index gained two rows it had been missing since before either split** —
`§8.4 0x34` and `§8.5` — so the table below is once again a complete `§` → file
map. That gap is what let the `§8.4` collision go unrecorded here; see the third
numbering trap.

### Section → file

| `§` | Topic | File |
|---|---|---|
| **§1** Overview | what the link looks like from ten thousand feet | [`protocol/transport-and-gatt.md`](protocol/transport-and-gatt.md) |
| **§2** Transport & Session | scan, connect, subscribe order, the keep-alive poll and what each token answers | [`protocol/transport-and-gatt.md`](protocol/transport-and-gatt.md) |
| **§3** GATT | service and characteristic UUIDs, full enumeration, write-type | [`protocol/transport-and-gatt.md`](protocol/transport-and-gatt.md) |
| **§4** Packet framing | outbound binary frame, ASCII tokens, inbound notification frame, the app-internal label strings | [`protocol/framing-and-commands.md`](protocol/framing-and-commands.md) |
| **§5** Command catalog | outbound commands, the **inbound selector master table**, dealer-code strings | [`protocol/framing-and-commands.md`](protocol/framing-and-commands.md) |
| **§7** Checksum | the XOR fold — kept with framing, which is the only thing that uses it | [`protocol/framing-and-commands.md`](protocol/framing-and-commands.md) |
| **§6** Unlock / cut-off / anti-theft | password encoding, `switchMode`, mode and reported-status code spaces, what the modes physically do, password change, detect | [`protocol/modes-and-auth.md`](protocol/modes-and-auth.md) |
| **§8, §8.1, §8.2, §8.2.1, §8.2.2, §8.3** Telemetry decoding | notation, constants, the field → selector → formula table, per-unit VADJ calibration, per-unit warning thresholds, and the write-path inverse | [`protocol/telemetry-decoding.md`](protocol/telemetry-decoding.md) |
| **§8.2.3** Identity, housekeeping, device clock | manufacture year, firmware version, MAC-as-text, and the real-time clock | [`protocol/identity-and-rtc.md`](protocol/identity-and-rtc.md) |
| **§8.4** TWF status flags — ⚠️ **one of two different `§8.4`s** (this one is the **TWF status register**; the `0x34` counters below carry the same number) | the status register, its observed values, and the charging-direction implication | [`protocol/twf-status.md`](protocol/twf-status.md) |
| **§8.4** `0x34` system counters — ⚠️ **the other `§8.4`**, unrelated to the row above and in a different file | the two LEN layouts and why **LEN 11 is a second, independent battery signal**; standby / connected minutes (**since-wake, not lifetime** — corrected 2026-08-07), sleeps, power-ons, cut-offs | [`protocol/telemetry-decoding.md`](protocol/telemetry-decoding.md) |
| **§8.5** `0x3A` function-flag register | 🟡 partially decoded, **super-capacitors only**: what §8.5.1 establishes, and §8.5.2's list of what it does **not** — including which state means what | [`protocol/telemetry-decoding.md`](protocol/telemetry-decoding.md) |
| **§9.1** Power-bank register map | the power-bank-only selectors, ~~port/protocol flags,~~ (🔵 **2026-09-07: the port/protocol flags moved out to §9.2** — see the row below) pre-scaled per-cell voltages, poll cadence, and the pending list for **both** §9.1 and §9.2 | [`protocol/power-bank.md`](protocol/power-bank.md) |
| **§9.2** Power-bank port and protocol flags | `0x4B` `b7`: the bit table (bits 0–5), what each bit is and is not evidenced as, `b7 = 0x00` as the boost rail off, the four refuted readings of bit 0, and 🔵 (since later on 2026-09-07) **〈Naming the Type-A path without a Type-A bit〉** — the bit-1-clear + discharging elimination rule | [`protocol/power-bank-port-flags.md`](protocol/power-bank-port-flags.md) |
| **§10, §10.1, §10.1.1, §10.2** Open items | unverified items, registers seen on the wire but not decoded, the metadata series, and the capture prerequisite | [`protocol/undecoded-and-metadata.md`](protocol/undecoded-and-metadata.md) |
| **§9** Corrections to earlier revisions | what this document once published and got wrong | [`protocol/corrections-and-glossary.md`](protocol/corrections-and-glossary.md) |
| **§11** Glossary | term definitions | [`protocol/corrections-and-glossary.md`](protocol/corrections-and-glossary.md) |

### ~~Two~~ **Three** numbering traps inherited from the original

* **§9.1 is not a subsection of §9 — and neither is §9.2.** §9 is the
  corrections table; §9.1 is the power-bank register map; §9.2 is the
  power-bank port-flag byte. All three are unrelated and all three live in
  different files. §9.1's number is kept anyway, because outside references use
  it. 🔵 **§9.2 was allocated on 2026-09-07**, when the port-flag section was
  split out of §9.1 for size: it is a **new** number, so nothing written before
  that date refers to it, and an existing `§9.1` reference still names exactly
  what it always named.
* **§7 sits between §6 and §8 in the original numbering** but is filed with §4/§5,
  because a checksum is part of the frame format and nothing else refers to it.
* 🔵 **`§8.4` is used twice, and always was** (recorded here 2026-09-07; the trap
  itself is not new). One is the **TWF status register**, in
  [`protocol/twf-status.md`](protocol/twf-status.md); the other is the **`0x34`
  system counters**, in
  [`protocol/telemetry-decoding.md`](protocol/telemetry-decoding.md). They are
  unrelated registers in different files and neither number can be changed
  without breaking outside references, so **cite these two by selector, not by
  number** — say "`0x34` system counters", not "§8.4". Both now have their own
  row in the table above; until 2026-09-07 only the TWF one did, which is what
  made the collision invisible to anyone reading the index. ⚠️ For the same
  reason `0x3A` was numbered **§8.5** rather than becoming a third `§8.4`.

### Read this before reading anything else

* **TWF: the register and one of its values share the same code.** The
  disambiguation box is at the top of the TWF subsection in
  [`protocol/twf-status.md`](protocol/twf-status.md), and the selector master
  table in [`protocol/framing-and-commands.md`](protocol/framing-and-commands.md)
  carries the same warning on its row. Conflating the two has already cost this
  project one retracted finding — read the box first.
* **Read the device-type register before decoding anything.** Several selectors
  carry a different payload layout per device class, and applying the wrong one
  does not fail loudly: it produces a plausible number that is wrong. The rule is
  stated in §5.2, in §8.2, and worked through in §9.1.
* **Which selectors you observe is a property of your client, not of the device**
  (§10.2). A capture taken without a working keep-alive write path proves nothing
  about what a unit supports.

---

**How to read the confidence in this document.** Each section states its own
evidence and its own baseline. **Anything without a stated source is unverified**
— treat it that way, and please report it.

There is no blanket assurance here, and there used to be: an earlier revision
closed with "each was confirmed by at least one independent verification pass."
An audit on 2026-07-30 found at least six load-bearing claims that had passed no
such check, two of them carrying confidence markers (§9). A global guarantee is
worse than none, because it makes the un-checked claims indistinguishable from
the checked ones.

Known-open items live in §10; known-wrong items that were once published live in
§9. Corrections to either are welcome — this is a right-to-repair document and it
is only as good as its worst-sourced line.
