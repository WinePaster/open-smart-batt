# Identity, housekeeping registers, and the device clock

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §8.2.3 Identity / housekeeping registers

> This is a subsection of **§8 Telemetry parsing**; the `b[n]` notation and the
> pack formula table live in [`telemetry-decoding.md`](telemetry-decoding.md).

---

### 8.2.3 Identity / housekeeping registers (decoded 2026-07-28)

> 📌 **Classification note (owner ruling, 2026-07-30).** `0x25`, `0x29`, `0x38`
> and `0x3B` were previously on this project's "engineering-build only" list.
> They are hereby **formally declassified**: the decode below rests entirely on
> this project's own captures (a super-capacitor recorded on Android 2026-07-27
> and iOS 2026-07-28, agreeing byte for byte), not on any vendor tooling. The
> project's internal boundary register has been updated to match.

These arrive in the connect burst, so they only appear once the keep-alive write
path works (§10.2). All values below come from one super-capacitor
(device-type `0x17`, serial 7809) captured on **both** Android (2026-07-27) and
iOS (2026-07-28) — the two captures agree byte for byte, which is what raises
them above single-observation guesses.

| Selector | LEN | Layout | Example | Reading |
|---|---|---|---|---|
| `0x25` | 2 | big-endian u16 | `07e4` | **2020** — manufacture year |
| `0x29` | 2 | `[major, minor]`, **not** a u16 | `0106` | **firmware 1.06** |
| `0x38` | 17 | **ASCII text**, not packed bytes | `41413a…4646` | `"AA:BB:CC:DD:EE:FF"` (illustrative value) — the device MAC |
| `0x3B` | 7 | `[year_hi, year_lo, MM, DD, hh, mm, ss]` — **`MM` and `DD` are 0-based**, `hh`/`mm`/`ss` are not | `07d0 07 10 10 04 35` | 2000-**08-17** 16:04:53 — device RTC |

**`0x29` is a byte pair, not a number.** `0x0106` read as a u16 would be 262;
the unit's firmware is 1.06, independently recorded from the vendor tooling.

**`0x38` is text.** Decoding it as packed bytes yields nonsense; as ASCII it is
the MAC, and it matches the address the Android BLE stack reported for the same
unit. (iOS never exposes a MAC to the app, so on that platform this register is
the *only* way to obtain a stable cross-platform device identity.)

**`0x3B` is a clock, and it ticks.** Over a 22-minute capture the field advanced
16:04:53 → 16:27:16 — 22 m 23 s against 22 m 25 s of wall clock — and was
monotonic across **1112 of 1112** consecutive frames, with the seconds field
bounded 0–59. The *rate* is therefore verified; the *absolute value* is not
meaningful here (year 2000, and a time-of-day unrelated to the phone's), because
this unit's RTC was evidently never set. Do not present it to a user as a
timestamp; it is useful for ordering and for detecting a device reset.

**`MM` and `DD` are 0-based** (✅ verified, corrected 2026-08-01). `MM = 0x07` is
**August**, `DD = 0x00` is the **1st**. Evidence, in order of weight:

* Two batteries whose RTCs had been set — their `hh:mm:ss` ran a steady **+4.0 s**
  against wall clock, so the time half was already known-good — emitted
  `MM = 0x07, DD = 0x00` on a day that was in fact **2026-08-01**. Four poll
  bursts across the two units: all four land exactly on the capture date under
  0-based, and all four decode to the impossible "day 0" under 1-based. Two
  further units, captured on two other days, likewise land on their own capture
  date only under 0-based.
* Whole-corpus re-walk: **3,234 frames** decode to an impossible month 0 or day 0
  under 1-based; under 0-based **zero frames** fall outside a legal month/day.
* Power banks with an unset clock emit `MM = DD = 0x00`, which under 0-based is
  the boot origin **2000-01-01** — self-consistent with the same rule.

> 🔴 **Superseded 2026-08-01 (was: 1-based).** The example row above previously
> read `07d0 07 10 10 04 35` as "2000-07-16 16:04:53". Only the month and day
> were wrong; the time fields are plain binary and are unchanged, so the tick-rate
> verification in the paragraph above is unaffected. A client using the old
> reading renders every date one month early and one day short — and on any
> device reporting `DD = 0x00` it produces a date that does not exist.

> 🔴 **SETTLED 2026-08-05 — it IS a calendar clock. The units that look like
> timers were simply never set.** The block below is the superseded hypothesis,
> kept because its measurements are good and because the reasoning failure is
> worth seeing: every observation in it was correct, and the conclusion drawn
> from them was still wrong.
>
> **What settled it:** a capture in which this register was **written and read
> back**. A value written as month 08 / day 05 read back as `MM = 07`, `DD = 04`
> — with hours, minutes and seconds identical to what was written. That is a
> controlled confirmation of the 0-based `MM`/`DD` rule above, which until then
> rested on corpus statistics alone. A second connection in the same capture
> received no write, free-ran **442 s against 441 s of wall clock**, and stayed
> aligned **across a 9-minute disconnect** — a clock, not a session timer.
>
> **And the observation that produced the hypothesis has a better explanation.**
> "Restarts from the same base on every connection" is wrong on the quantifier:
> it restarts on every **device reboot**, not every connection. ~~Three mutually
> independent fingerprints mark a reboot — the register rewinds to a saved
> checkpoint, `0x34`'s last byte increments, and the first telemetry frame after
> reconnecting reads all zeros.~~ Earlier captures could not tell the two apart
> because they held a single connection each.
>
> 🔴 **Quantifier corrected 2026-08-09.** The verdict above stands — `0x3B` is
> a calendar clock, and it does not restart per connection. What is wrong is
> the count: **the three fingerprints are not always synchronous.** On
> motorcycle batteries all three do coincide (three independent units, no
> exception). On power banks the register rewinds to its checkpoint and the
> first frame after reconnect reads all zeros **while the power-on counter
> stays put**: one unit rewound to the same checkpoint at least ten times over
> ten days, across five different calendar dates, with its `0x34` counters
> frozen at 0 sleeps / 3 power-ons in every one of the 126 frames held for it.
> ⇒ Treat the rewind and the all-zero first frame as reliably paired, and the
> power-on counter as **confirming a reboot when it moves, never ruling one
> out when it does not.**
>
> ⚠️ **Field-naming trap in the struck sentence.** "`0x34`'s last byte" is not
> one field: in the LEN-11 layout the last byte is the **cut-off** counter
> `[10]`, and in the LEN-10 layout it is the low half of the **power-on**
> counter `[8:10]`. The fingerprint meant here — and the one measured above —
> is the **power-on counter `[8:10]`**, in both layouts.
>
> ⇒ **A power bank whose `0x3B` shows a fixed base has an unset RTC**, exactly
> like the year-2000 unit described at the top of this section. Rendering it to
> a user is still wrong — but because the value is *unset*, not because the
> register is not a clock.
>
> 🔴 **Counter-example 2026-08-09 — a fixed base does not imply an unset
> clock.** One power bank returns to a fixed checkpoint whose value decodes to
> a date in **2022**, with non-zero `MM` and `DD` — not the year-2000 factory
> value, and not its stated manufacturing year (2021) either. So "fixed base"
> and "never set" are two separate claims: a fixed base only says the unit
> restores a saved checkpoint, it says nothing about what that checkpoint
> holds. **The rendering rule is unchanged** — still do not show `0x3B` to a
> user on a power bank — but the reason has to be the broader one: the value
> is a restored checkpoint of unknown provenance, which covers the unset units
> and this one alike.
>
> ⚠️ Whoever renders this: an unset unit is the common case, not the exception.

<details>
<summary>🔴 Superseded hypothesis (2026-08-04/05), kept for the record</summary>

> 🔲 **Unsettled — power banks may not be running a calendar clock at all.** On
> power-bank units this register has been seen restarting from the same base value
> on three different real-world dates, and half of the units observed emit
> `MM = DD = 0x00` for their whole session (66 observations). That is consistent
> with "elapsed time since power-on" rather than a wall clock, but ~~it rests on
> one- and two-unit observation~~ — see the strengthening below — and is **not**
> a landed conclusion. Until it is settled, treat `0x3B` on power banks as an
> ordering / reset signal only, and do not render it as a date.
>
> **Strengthened 2026-08-05 — a third unit, and the bases disagree.** A 10 h 32 m
> single-connection capture at 1 Hz measured the register end to end. Payload
> shape `07d0 00 00 hh mm ss`: year **`0x07d0` = 2000**, `MM = 0x00`,
> `DD = 0x00` — under the 0-based rule, the boot origin 2000-01-01, i.e. a
> completely unset factory value. It advanced 00:13:19 → 10:41:39, **monotone
> across 36,144 of 36,144 consecutive steps**, and drifted **0.1 s over 10.5 h
> (≈3 ppm)** against wall clock.
>
> Two things follow, and they pull in opposite directions:
>
> * 🔑 **The base is not a protocol constant.** This unit's base is 2000-01-01;
>   another power bank's base decoded to a real date (2026-08-04). Two units, two
>   different origins for the same register ⇒ the absolute value carries no
>   protocol meaning. That is what makes "not a calendar clock" **stronger**, on
>   a third unit.
> * ⚠️ **It is a very good timer.** 3 ppm is crystal-grade; this is not a coarse
>   tick. So "not a calendar clock" is strengthened while "then what *is* it"
>   remains open — elapsed-since-power-on still fits, but this capture holds only
>   **one** connection and therefore cannot test the "restarts from the same
>   origin on every connection" observation that the claim above rests on.
>
> ⇒ Recorded as a strengthening of the 🔲, **not** as a settlement of it.

</details>
