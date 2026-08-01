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
| **§8.4** TWF status flags | the status register, its observed values, and the charging-direction implication | [`protocol/twf-status.md`](protocol/twf-status.md) |
| **§9.1** Power-bank register map | the power-bank-only selectors, port/protocol flags, pre-scaled per-cell voltages, poll cadence, and this section's pending list | [`protocol/power-bank.md`](protocol/power-bank.md) |
| **§10, §10.1, §10.1.1, §10.2** Open items | unverified items, registers seen on the wire but not decoded, the metadata series, and the capture prerequisite | [`protocol/undecoded-and-metadata.md`](protocol/undecoded-and-metadata.md) |
| **§9** Corrections to earlier revisions | what this document once published and got wrong | [`protocol/corrections-and-glossary.md`](protocol/corrections-and-glossary.md) |
| **§11** Glossary | term definitions | [`protocol/corrections-and-glossary.md`](protocol/corrections-and-glossary.md) |

### Two numbering traps inherited from the original

* **§9.1 is not a subsection of §9.** §9 is the corrections table; §9.1 is the
  power-bank register map. They are unrelated and now live in different files.
  The numbers are kept anyway, because outside references use them.
* **§7 sits between §6 and §8 in the original numbering** but is filed with §4/§5,
  because a checksum is part of the frame format and nothing else refers to it.

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
