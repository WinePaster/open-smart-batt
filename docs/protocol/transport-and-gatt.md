# Transport, session, and GATT

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §1 Overview · §2 Transport & Session · §3 GATT

---

## 1. Overview

The iBatt battery exposes a single proprietary BLE GATT service. A companion
app (here, the reference for this spec) connects, subscribes to one notify
characteristic, and drives the battery by writing short frames to one write
characteristic. Two distinct on-wire encodings exist:

1. **Binary command frames** — `[0xB8, CMD, 0x00, LEN, payload…, XOR]`, used for
   mode switching, password/anti-theft auth, and threshold configuration.
2. **ASCII keep-alive tokens** — `!#`, `@`, `#` (UTF-8), polled ~1 Hz to make the
   battery stream telemetry notifications.

The battery answers with **notification frames** whose **byte[1] is a command/
register selector** and whose telemetry payload begins at **byte[4]**. The app
also maintains an internal ASCII-hex label string (e.g. `01680102`) built from
received bytes; **these strings are never transmitted on the wire** — they are an
in-app dispatch key, and an interop client does not need them (§4.4).

An independent developer can implement a compatible client using only this
document.

---

## 2. Transport & Session

| Aspect | Value |
|---|---|
| Scan filter | Single 128-bit **service UUID** `07b9fff0-d55f-5e82-ba44-81c0da86c46c` (`withServices=[…]`). |
| Device-name filter | **None.** Scanning filters purely on the service UUID; results are deduplicated by device id, no name/prefix/`startsWith` check. |
| Connect | `connectToDevice(deviceId)` only — no `servicesWithCharacteristicsToDiscover`, no explicit connection timeout argument. |
| MTU negotiation | **None.** No `requestMtu`/`negotiateMtu`/`requestConnectionPriority` anywhere. Client must work within the default ATT MTU (23 → 20-byte payload). All commands fit in 20 bytes. |
| GATT cache | A `clearGattCache()` call occurs on the connect/reset path; an interop client may mimic this before (re)connecting. |
| BLE stack note | Connect/subscribe/write use one BLE plugin; disconnect/teardown use a second plugin. Functionally irrelevant to wire protocol. |
| Write type | **Write WITH response (ATT Write Request, opcode `0x12`)** — see §3.1. The write characteristic `07b9ace3` advertises properties `0x08` (Write) and does **not** set `0x04` (Write Without Response). A raw HCI capture confirms it: **50 writes to the value handle across three captures, every one opcode `0x12`, every one answered by `0x13`; opcode `0x52` (Write Command) never occurs.** The reference app's *call sites* pass a without-response flag, but that is an app-side flag — an interop client that forces write-without-response will have the write rejected, and on some stacks (e.g. `flutter_blue_plus`) it throws. **That failure is silent in its consequences: telemetry keeps streaming, the link reports ready, and only the missing connect-burst registers hint at it** (§10.2). |
| Subscribe order | **Subscribe to the notify characteristic FIRST, then start the poll timer.** Notifications are enabled before any periodic write. |
| First write after subscribe | The 2-byte ASCII handshake `!#` (`0x21 0x23`, UTF-8). This is effectively the "start streaming" wake frame; without it no telemetry flows. |

### Connection state machine (observed)

1. Start a **10 ms watchdog** `Timer.periodic` (connection/loading countdown;
   issues **no** characteristic writes) *before* calling `connectToDevice`.
2. `connectToDevice(deviceId)` → listen on the connection-update stream.
3. Stream reports `connecting` / `connected` / `disconnecting`.
4. On **`connected`**: build the notify `QualifiedCharacteristic`, call
   `subscribeToCharacteristic` (the only subscribe site), then cancel any prior
   poll timer and start the **1 Hz telemetry poll** `Timer.periodic`.
5. The 1 Hz poll's tick 1 sends `!#` (handshake), after which the battery streams
   telemetry notifications.

### Telemetry poll (1 Hz keep-alive)

Duration = 1,000,000 µs (1 s). A tick counter drives which token is written
(UTF-8, write-without-response):

| Condition | Token sent | Bytes |
|---|---|---|
| tick == 1 | `!#` | `21 23` |
| counter % 25 == 0 | `@` | `40` |
| device-type byte == power bank **and** counter % 5 == 0 | `!#` | `21 23` |
| otherwise | `#` | `23` |

> ⚠️ **The value `0x44` ('D') is not a wire byte — do not compare against it.**
> Earlier revisions of this document described the power-bank test as
> `device-type == 0x44`. That value came from a Dart Smi-tagged 34 (`34 << 1 | 1`
> = `0x45`; the tag artefact was read as `0x44`), not from the link. **Across
> 3,808 observed `0x10` frames the payload byte is only ever `0x02`, `0x17` or
> `0x22`; `0x44` occurs zero times.** The power bank is `0x22` (34). See §9.
>
> Re-checked 2026-07-30 over the whole corpus: **13,444 XOR-clean `0x10` frames**,
> still only `0x02` (7,333) / `0x17` (5,272) / `0x22` (839).

> ✅ **`0x18` is real. Confirmed 2026-08-01 — this block previously said the opposite.**
> The distributor stated (2026-07-30) that the third-generation "flagship"
> super-capacitor is `0x18`, with `0x17` reserved for the second generation.
> This document declined to adopt that claim because `0x18` had never been seen:
> zero of 13,444 frames as of 2026-07-30.
>
> It then landed on **three independent units at once**: serials 145 / 373 / 416,
> firmware 1.02 and 1.03, three unrelated reporters. All three answer `0x2B` =
> `402c2814`, `0x42` = `07c8f005` and `0x27` = `00a802180001` byte for byte, and
> share none of those values with the four `0x17` units in the same corpus — so
> the difference tracks the **generation**, not the unit. Two were also caught
> advertising `RCE-SCAP_III`.
>
> The original doubt was reasonable and is kept here on purpose: the corpus
> genuinely held zero examples, and the unit whose owner called it the flagship
> (serial 7809, dealer `01680217`, fw 1.06) really does report `0x17` across 976
> frames. That unit is a second-generation one labelled wrongly; the claim itself
> was a shipped value this corpus simply had not met yet.
>
> **`0x18` and `0x17` are both the super-capacitor class.** They differ in the
> *values* of registers read off the wire, not in which registers exist — with one
> known exception, `0x41`'s last payload byte (see §10.1), where a decoder must
> gate on `0x10`.
>
> **A client should still treat an *unknown* device-type byte as unclassified
> rather than guessing.** That rule is what kept the failure direction safe while
> `0x18` was unmapped, and it is unchanged.

#### The two tokens get **different** answers (measured 2026-07-30)

`#` and `!#` are not interchangeable. A 23-hour single-battery capture
(31,596 lines, 63,375 XOR-clean frames, 5 residual bytes) sent `#` **2,126**
times and `!#` **5** times, and the reply sets separate cleanly:

| Written | Selectors that answer | Frames each |
|---|---|---|
| `#` (and the periodic `@`) | `0x10 0x14 0x19 0x1C 0x1D 0x20 0x21 0x23 0x24 0x26 0x27 0x29 0x2B 0x2E 0x30 0x35 0x37 0x40` | ≈2,127 (identity group) / ≈5,398 (fast telemetry) |
| `!#` **only** | `0x17 0x25 0x31 0x34 0x36 0x38 0x39 0x3A 0x3B 0x3C 0x3F 0x47 0x4D` | **exactly 5** |

2,126 against 5 leaves no ambiguity. Two consequences for anyone writing a client
or reading a capture:

* **`!#` is not just a session opener.** Tick 1 sends it once, so a long session
  gets the extended group *once* — but the **1st** session in this capture received
  no `!#` at all (the first one landed 9 minutes later, already inside session 2)
  and therefore streamed **zero** frames from the second row for its entire life.
  <br>🔴 **Corrected 2026-08-01.** This read "the 6th session", which contradicted
  its own next clause — if the first `!#` lands inside session 2, the session that
  went without it is session 1, not session 6. Re-measured on the same unit's
  longer log (9 sessions, 47 h): session 1 = 0 `!#`, sessions 2–9 = exactly 1
  each; session 6 sent its `!#` 0.06 s after `link: ready`. This project's
  internal device notes had it right all along, so the two documents were in
  open contradiction.
* **"This device does not support X" is unprovable from a capture that wrote only
  `#`.** That is the same failure mode as §10.2, one level finer: there, a broken
  write path hid 20-odd registers; here, a *working* write path that never
  re-sends `!#` still hides 13 of them.

---

## 3. GATT (service + characteristic UUIDs)

All three UUIDs share the vendor 128-bit base `…-d55f-5e82-ba44-81c0da86c46c`,
differing only in the 16-bit slot (bytes 2–3) — a textbook BLE base+slot layout.

| Role | UUID | How resolved |
|---|---|---|
| **Service (scan filter)** | `07b9fff0-d55f-5e82-ba44-81c0da86c46c` | Hardcoded as 16 literal bytes built at runtime (`Uint8List.fromList` → `Uuid`), passed to `scanForDevices`. Slot `FFF0` = classic proprietary-service region. |
| **Write characteristic** | `07b9ace3-d55f-5e82-ba44-81c0da86c46c` | During discovery, each characteristic's `Uuid.toString()` is compared to this literal; on match its serviceId/characteristicId are saved for all command writes. Slot `ACE3`. |
| **Notify characteristic** | `07b9ace4-d55f-5e82-ba44-81c0da86c46c` | *Not hardcoded* — the client selects it by property flags (notifiable), so the UUID is absent from the binary. **Confirmed on the wire** by a live GATT dump (see below). Slot `ACE4`. |

**Service of the write characteristic:** taken **dynamically** from the discovered
characteristic's serviceId (not embedded as bytes). A live GATT enumeration
confirms it is `07b9fff0` — the same service that carries the notify
characteristic.

### 3.1 Full GATT enumeration (observed 2026-07-27)

A device-side dump of every service/characteristic with its property flags,
taken from a super-capacitor unit (device-type `0x17`):

| Service | Characteristic | Properties |
|---|---|---|
| `1800` (Generic Access) | `2a00` / `2a01` / `2a02` / `2a03` / `2a04` | R / R / RW / W / R |
| `1801` (Generic Attribute) | `2a05` | Indicate |
| **`07b9fff0-…`** (vendor) | `07b9ace1-…` | RW |
| **`07b9fff0-…`** | `07b9ace2-…` | R |
| **`07b9fff0-…`** | **`07b9ace3-…`** | **W (with response) — the write characteristic** |
| **`07b9fff0-…`** | **`07b9ace4-…`** | **Notify — the telemetry channel** |
| **`07b9fff0-…`** | `07b9bbc1-…` | R |
| **`07b9fff0-…`** | `07b9bbc2-…` | RW |
| `f000ffc0-0451-4000-b000-000000000000` | `f000ffc1-…` | props `0x1c` = Write-Without-Response + Write + Notify |
| `f000ffc0-…` | `f000ffc2-…` | props `0x1c` = Write-Without-Response + Write + Notify |

Two facts follow directly:

* **`07b9ace3` advertises `W` (write **with** response) and NOT
  Write-Without-Response.** An interop client must honour the characteristic's
  actual property flags or the write is rejected — §2 has the byte-level evidence.
  Note that the same device *does* set the `0x04` bit on other characteristics
  (the TI OAD pair above is `0x1c`), so `0x08` on `ace3` is deliberate, not a
  stack quirk.
* **`f000ffc0`** is a second, non-vendor-base service. The `f000…-0451-4000-b000-…`
  base and the `ffc1`/`ffc2` WwN+Notify pair are the signature of the **TI OAD
  (over-the-air firmware download)** profile. **Not exercised, not decoded, and
  not required for telemetry** — recorded only so an implementer knows it exists
  and does not mistake it for a second telemetry channel.

> The vendor characteristics `ace1`, `ace2`, `bbc1`, `bbc2` are advertised but
> never touched by the reference app. Their contents are unknown.

> Clarification: the strings `07b9ace3-…` (BLE characteristic UUID, no leading
> slash) and `/9f580fc5-c252-45d0-af25-9429992db112` (a Dart deferred-load /
> navigation-route hash, leading slash, unrelated base) are distinct. Only the
> latter is a non-BLE string.
