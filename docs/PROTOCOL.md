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

> ⚠️ **One vendor claim this document does not adopt.** The distributor states
> (2026-07-30) that the third-generation "flagship" super-capacitor is `0x18`,
> with `0x17` reserved for the second generation. Three of the four values given
> match the wire exactly; this one does not, and `0x18` has **never** been
> observed — zero of 13,444 frames.
>
> The conflict is specific rather than vague: the unit whose owner identified it
> as the flagship (serial 7809, dealer `01680217`, fw 1.06, MAC
> `6C:79:B8:33:76:9F`) reports `0x17` across 976 frames, reproduced value-for-
> value on iOS a day later.
>
> Either that unit is a second-generation one its owner labelled wrongly, or
> `0x18` exists on flagship units this corpus has never held, or the claim is a
> planned value rather than a shipped one. **A client should treat an unknown
> device-type byte as unclassified rather than guessing**, which is what leaves
> the failure direction safe here.

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
  gets the extended group *once* — but the 6th session in this capture received no
  `!#` at all (the first one landed 9 minutes later, already inside session 2) and
  therefore streamed **zero** frames from the second row for its entire life.
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

---

## 4. Packet framing

### 4.1 Outbound (app → battery): binary command frame

```
[0xB8, CMD, 0x00, LEN, payload(0..LEN-1)…, XOR]
```

| Field | Meaning |
|---|---|
| `0xB8` (184) | Sync / start byte. The receive path also matches an incoming element == 184. |
| `CMD` | Command code (`0x23`, `0x2A`, `0x2B` observed; matches the read selectors). |
| `0x00` / `0x01` | **Role flag — not reserved, and not a length high byte.** Live HCI capture: `0x00` on a standalone auth frame and on a mode sub-frame; **`0x01` on the auth sub-frame bundled with a mode change** (§6.2). LEN lives in byte[3] alone. |
| `LEN` | Payload length = number of payload bytes (1 or 4 observed). |
| payload | `LEN` bytes. |
| `XOR` | Checksum = XOR-fold of all preceding bytes in the list (`reduce((a,b)=>a^b)`), appended as the final byte. |

Multi-byte payload fields are **big-endian** (hi byte first).

### 4.2 Outbound: ASCII keep-alive tokens

`!#`, `@`, `#` — UTF-8 encoded, distinct from the `0xB8` frames (see §2 poll).

### 4.3 Inbound (battery → app): notification frame

Bytes are accumulated into a buffer, wrapped as a message object
(`len`, `byteList`), passed to the dispatcher, then the buffer is cleared.

```
byte[0]      : start byte (validated == 0xB8 on the receive path)
byte[1]      : command / register SELECTOR  ← main dispatch key
byte[2]      : 0x01 — response marker (constant on every observed inbound frame)
byte[3]      : LEN — payload length in bytes
byte[4..]    : telemetry / payload (LEN bytes)
byte[4+LEN]  : XOR checksum of bytes[0 .. 4+LEN-1]
```

**Inbound framing is fully determined** (upgraded from "not fully decoded",
2026-07-28; corpus re-walked 2026-07-30): a strict walk of the whole field-log
corpus parsed **206,516 of 206,516 frames with a correct XOR and zero leftover
bytes** — 96 sessions, four device classes, using exactly the layout above.
`byte[2]` was `0x01` on **every one** of those frames. (The earlier figure of
3342/3342 was a single two-device capture; the conclusion is unchanged, the
evidence is two orders of magnitude larger.)
Because inbound frames are self-delimiting, a reassembler can and should walk
them by length rather than by scanning for `0xB8` — payload bytes can equal
`0xB8`, so substring/scan-based parsing produces phantom frames (see §10.1).

> One notification packet may carry **several concatenated frames**, and one
> logical packet may arrive **split across multiple ATT notifications** (the
> 42-byte telemetry burst arrives as 20 + 20 + 2). Reassembly must therefore
> buffer across notifications and emit every complete frame found.

**Dispatch is on `byteList[1]`** (the received frame's 2nd byte), bounds-checked
against the frame length.

### 4.4 The `0168xxxx` / `0169xxxx` ASCII-hex IDs

`0168xxxx` / `0169xxxx` are **app-internal label strings, never transmitted on the
wire**. They are formed from the `0x27` dealer-code payload as
`"%04d%02X%02X"` — the first two payload bytes as a 4-digit **decimal** number,
then the next two as 2-digit **hex**. Example: payload `00 A8 01 02` →
`"0168" + "01" + "02"` = `01680102` (the leading `0168` is decimal 168, not hex).

**An interop client does not need these strings and should not reproduce the
reference app's dispatch on them.** They are recorded only because two observed
values identify the device class in field reports: `01680102` on batteries and
`01680217` on capacitors. See §5.3 for the caveat.

---

## 5. Command catalog

### 5.1 Outbound binary commands

| CMD (hex) | LEN | Frame | Meaning | Trigger |
|---|---|---|---|---|
| `0x23` | 1 | `[B8,23,00,01, mode, XOR]` | Mode set (normal / anti-theft / cut-off) | `switchMode(mode)` from function-page buttons |
| `0x2A` | 4 | `[B8,2A,00,04, cb_hi, cb_lo, sum_hi, sum_lo, XOR]` | Password / auth (cut-off password channel) | Rides with every `switchMode`; also `changeCutOffPassword` |
| `0x2B` | 4 | `[B8,2B,00,04, OV, UV, OT, 0x00, XOR]` | Set warning thresholds | `changeWarningParameters` |

> `switchMode` writes **two concatenated sub-frames in one BLE write**: the mode
> frame (`0x23`) followed by the auth frame (`0x2A`). So a mode change always
> carries the password-auth frame. **On the wire this is exactly 6 + 9 = 15 bytes
> with no trailing context payload** (live HCI capture; earlier revisions claimed
> an extra payload — that was wrong). The bundled auth sub-frame carries byte[2]
> = `0x01`, not `0x00` (§4.1).

### 5.2 Inbound selectors (`byteList[1]`) — read / response codes

> 🔴 **Read `0x10` first. Several selectors carry a DIFFERENT payload layout per
> device class** — `0x4A` and `0x21` are both known cases. Applying a pack formula
> to a power bank yields numbers that look perfectly plausible and are wrong by a
> factor of 1000 (§9.1). The "Class" column below is not advisory.

| Selector | Class | Meaning | Notes |
|---|---|---|---|
| `0x10` | all | **Device type** | `byteList[4]`. Observed values: `0x02` car smart battery / `0x17` super-capacitor / `0x22` (34) power bank. **`0x44` is not a wire value** — see §2 and §9 |
| `0x19` | all | Main voltage PVLT | §8 |
| `0x20` | all | TWF warning/status byte | §8.4. **Not a fault flag** — on power banks `0x20` means *charging* |
| `0x21` | all | Temperature | §8. ⚠️ LEN 1 on pack, **LEN 2 on power bank** (§9.1) |
| `0x23` | all | Mode / status register | §8 |
| `0x24` | pack | DVOL per-series cell voltages | §8. **Not gated** — streams unconditionally (9,496 frames observed) |
| `0x25` | pack | Manufacture year | §8.2.3. **Not the serial high word** — see §9 |
| `0x26` | pack | Battery serial number | §8 |
| `0x27` | all | Dealer code (經銷商代號) | §8 |
| `0x29` | all | Firmware version | §8.2.3 |
| `0x2A` | — | Password / auth response | response label |
| `0x2B` | all | Warning parameters readback | §8.2.2 |
| `0x2E` | pack | Main current (A), signed | §8 |
| `0x2F` | pack | Secondary current (mA) | logged only, not stored |
| `0x30` | pack | VADJ voltage-precision adjust | §8; multiplier for DVOL |
| `0x37` | all | Secondary voltage SVLT | §8. On a power bank this is the **port** voltage, not a pack rail (§9.1) |
| `0x38` | all | Device MAC, as an ASCII string | §8.2.3 |
| `0x3B` | all | Device real-time clock | §8.2.3 |
| `0x41` | capacitor | "Charge info" label | §10.1 — **do not decode with the §8.2 formula** |
| `0x47` | battery | Per-cell voltages, **already scaled to mV** | §9.1 |
| `0x49` | power bank | Charge-side (voltage, current) pair | §9.1 |
| `0x4A` | power bank | Discharge-side `[u16 mV][u16 mA]` | §9.1. ⚠️ **A different layout from the pack "discharge info" formula in §8.2** |
| `0x4B` | power bank | `[u16 design mAh][u8 SOC %][u8 port flags][u8 ?]` | §9.1 |
| `0x4C` | power bank | Constant, undecoded | §10.1 |
| `0x96` | — | Capacity / SOH info | ⚠️ **Never observed on the wire** (0 / 206,516 frames) — see §9 |
| `0x2C` / `0x34` / `0x3A` / `0x3C` / `0x40` / `0x42` / `0x4D` | see §10.1 | Streamed but undecoded | §10.1 |

### 5.3 Observed dealer-code label strings

| String | Meaning | Status |
|---|---|---|
| `01680102` | Battery-class dealer code | ✅ observed on the wire (`0x27` payload `00a801020000`) |
| `01680217` | Capacitor-class dealer code | ✅ observed on the wire (`0x27` payload `00a802170001`) |
| `01690102` | Battery-class dealer code, **`0169` prefix** | ✅ observed on the wire (`0x27` payload `00a901020000`, 2,127 frames, 2026-07-30) |

> 📌 **The prefix is not fixed at `0168`.** Every code recorded here before
> 2026-07-30 began `0168`, and §4.4 names the family after it. A motorcycle-class
> battery reports `0169`. A client must therefore parse the code, never match a
> `0168` literal — and `cb` (§6.1) is derived from the whole 8-digit value, so the
> prefix reaches the auth frame: this unit's `cb` is `0xC9F6` (1690102 & 0xFFFF),
> not the `0x00A8` that `01680102` yields.

> ⚠️ Earlier revisions listed further codes (`01680104`, `…0218`, `0211`–`0214`)
> with per-code meanings. **`01680104` has never been observed** in any capture,
> and the `0211`–`0214` meanings were an inference from app-internal behaviour,
> not from the link. They are removed rather than carried as unverified spec text.
>
> In particular, do **not** gate `0x24` (DVOL) on any of these strings — see §5.2.
> A client that does will never display per-cell voltages.

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
> | 19:00 `0x00` | 18:58 `0x02` ← exported as 斷電 |
> | 19:09 `0x02` ← exported as 斷電 | 19:16 `0x01` ← exported as 防盜 |
> | 19:19 `0x01` ← exported as 防盜 | 19:22 `0x00` ← exported as 正常 |
> | 19:24 `0x00` ← exported as 正常 | |
>
> Two independent units, three states each, zero XOR failures, and the
> distributor independently gives the same numbering for the write argument.
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
wire** — no capture in this corpus has a unit in either state. Recorded because
the difference is a safety matter and the register names alone do not convey it.

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

---

## 7. Checksum

`getCheckSum(list)` = **XOR-fold of all bytes** in the list
(`list.reduce((a,b) => a ^ b)`; closure body is a single `eor`). The single-byte
result is appended as the **final** element of every outbound binary frame before
writing.

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
| **Main current** (A) | pack | `0x2E` | `512 − (b4*256 + b5)`. Signed: positive = discharge |
| Secondary current (mA) | pack | `0x2F` | parsed/logged only |
| **Warning OV** (V) | pack | `0x2B` | `b4 * 0.025 + 14.4` |
| **Warning UV** (V) | pack | `0x2B` | `b5 * 0.025 + 10.4` |
| **Warning OT** (°C) | pack | `0x2B` | `b6 + 60.0` |
| **Charge** v1 / v2 | ⚠️ | `0x41` | `(b4*256+b5)/1000`, `(b6*256+b7)/1000` — **see §10.1, do not apply blind** |
| **Discharge** v1 / v2 | ⚠️ | `0x4A` | `(b4*256+b5)/1000`, `(b6*256+b7)/1000` — **PACK-SIDE ONLY, and never observed on any pack.** On a power bank the same 4 bytes are `[u16 mV][u16 mA]` (§9.1) |
| **Device type** | all | `0x10` | `b4` — `0x02` battery / `0x17` capacitor / `0x22` power bank (§9) |
| **Battery serial** | pack | `0x26` | `b4..b9` packed big-endian into a 48-bit int, `padLeft(6,'0')` |
| **Manufacture year** | pack | `0x25` | big-endian u16 (§8.2.3). **Not part of the serial** (§9) |
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

### 8.2.3 Identity / housekeeping registers (decoded 2026-07-28)

> 📌 **Classification note (owner ruling, 2026-07-30).** `0x25`, `0x29`, `0x38`
> and `0x3B` were previously on this project's "engineering-build only" list.
> They are hereby **formally declassified**: the decode below rests entirely on
> this project's own captures (a super-capacitor recorded on Android 2026-07-27
> and iOS 2026-07-28, agreeing byte for byte), not on any vendor tooling. The
> boundary register (`docs/open-pro-boundary.md` §2.2) has been updated to match.

These arrive in the connect burst, so they only appear once the keep-alive write
path works (§10.2). All values below come from one super-capacitor
(device-type `0x17`, serial 7809) captured on **both** Android (2026-07-27) and
iOS (2026-07-28) — the two captures agree byte for byte, which is what raises
them above single-observation guesses.

| Selector | LEN | Layout | Example | Reading |
|---|---|---|---|---|
| `0x25` | 2 | big-endian u16 | `07e4` | **2020** — manufacture year |
| `0x29` | 2 | `[major, minor]`, **not** a u16 | `0106` | **firmware 1.06** |
| `0x38` | 17 | **ASCII text**, not packed bytes | `36433a…3946` | `"6C:79:B8:33:76:9F"` — the device MAC |
| `0x3B` | 7 | `[year_hi, year_lo, MM, DD, hh, mm, ss]` | `07d0 07 10 10 04 35` | 2000-07-16 16:04:53 — device RTC |

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

### 8.4 TWF status flags (selector `0x20`)

The reference app tests individual bit positions of `b4` to set protection
booleans and a status message. **The exact bit→meaning mapping is unverified** —
see §10.

**Values observed on the wire** (baseline: whole-corpus re-walk 2026-07-30):

| `b4` | Seen on | Context |
|---|---|---|
| `0x00` | most units, most sessions | the normal/idle value |
| `0x01` | a unit at PVLT 9.84 V with a 1.75 V cell imbalance; also a unit at a wholly normal PVLT 13.25 V; and ~10 % of power-bank samples while discharging | see below |
| `0x20` | **power banks only** (`0x10 = 0x22`) — 2,769 frames; **0 frames across 14,857 battery/capacitor samples** (13,574 corpus + 1,283 added by a 2026-07-30 two-device capture) | **charging.** PVLT ≈3.8–4.2 V is the SINGLE-CELL voltage, SVLT ≈9.0 V is the PD charging INPUT — not a 12 V pack in trouble |

⚠️ **A further 84 `0x20` frames sit in sessions with no `0x10` attribution.**
Walked frame by frame, all 84 are power banks (PVLT ≈ 4 V, SVLT ≈ 9 V). They are
listed separately rather than folded in, because "unattributed" is exactly the
condition that produced the misreading described below.

Only **two** of the eight bits have ever been non-zero — bit 0 and bit 5 (the
observed values are `0x00`, `0x01` and `0x20`). Most of the field is untested.

> ⚠️ **A TWF value is not constant for a session.** An earlier revision of this
> section said it was. It is not: a power bank moves between `0x00`, `0x01` and
> `0x20` within a single connection as its charge state changes. A 2026-07-28 capture is the strongest single data point available: two
units on one phone within the same minute — a faulty one (PVLT 9.84 V, far below
its class's 12.0 V UV threshold) reported `0x01` for all 557 frames, while a
healthy reference unit (PVLT 13.28 V) reported `0x00` for all 42. That is
suggestive of **bit 0 = under-voltage**, but it is **not sufficient**: an earlier
capture shows `0x01` on a unit sitting at a perfectly normal 13.25 V. Either the
bit means something else, or its meaning is class-dependent.

### `0x20` means charging, on power banks (2026-07-29)

Direction cross-check over the power-bank corpus. One observation = one complete
poll burst; direction taken from the `0x49`/`0x4A` current fields:

| TWF `b4` | charging | discharging |
|---|---|---|
| `0x20` | **41** | **0** |
| `0x00` | 11 | 404 |
| `0x01` | 0 | 50 |

**The forward direction holds — charging ⇒ `0x20` — but the reverse does not.**
Eleven charging bursts report `0x00`: trickle charge (2–60 mA) and about one
burst of start-up delay after the charger is connected.

> ⚠️ Write this as a one-way implication, not an equivalence. An independent
> second-unit capture reproduced *charging ⇒ `0x20`* 207/207, yet the same
> capture also contains a **discharging** burst whose samples carry `0x20`
> (a transition artefact). `0x20` therefore does not prove charging.

⚠️ **TWF is therefore NOT usable as the direction signal.** Use the `0x49` /
`0x4A` current fields, which are mutually exclusive across the corpus and carry
a magnitude. Deriving direction from this byte would show "discharging" during
trickle charge.

> Naming collision, stated once: the TWF **register** is selector `0x20`; the
> TWF **value** `0x20` is what this section is about. They are unrelated.

**Guidance for implementers.** **Do not present any TWF bit as a fault, not even
a hedged one, until a controlled experiment settles it.**

This advice previously read: label it "suspected", show the raw byte, never
drive a destructive action. An implementation followed that guidance exactly —
and a dealer still concluded from the screen that a healthy power bank was
faulty while it charged normally. The hedge is not protection: a warning banner
on a dashboard is read as a verdict regardless of its wording, and the raw byte
shown beside it means nothing to a vehicle owner.

The failure ran deeper than wording. The rule was derived from a capture that
mixed several units with no per-device attribution, so a power bank's normal
4 V cell reading was taken for a 12 V pack collapsed to 4 V. **Before drawing any
conclusion from a byte, confirm which unit produced it.**

**Known coverage gaps** (both are reasons not to trust any single bit):

* A 2026-07-19 capacitor that the vendor app flagged as faulty reported `0x00`
  for the entire session.
* A 2026-07-28 battery with an unmistakable fault (a 1.75 V cell imbalance and a
  5.07 V terminal-to-string voltage gap) reported `0x01`, **not** `0x20`.

**A research lead, not a signal: `SVLT − PVLT`.** On the two packs whose state was
independently known, the gap between the string voltage (`0x37`) and the terminal
voltage (`0x19`) tracked that state:

| Unit | `SVLT − PVLT` | Independently known state |
|---|---|---|
| capacitor, healthy | −0.04 V | healthy |
| capacitor, 2026-07-19 | 3.11 V | vendor app showed a fault |
| battery, 2026-07-28 | **−0.040 V** | healthy reference (n = 42) |
| battery, 2026-07-28 | **5.07 V** | cell imbalance, deeply discharged (n = 557) |

**This is four units. It is not enough for a classifier, and this document
deliberately does not state a threshold.**

Stating one was tried and it was wrong in both directions. Measured across the
whole corpus (re-walk 2026-07-30), a ">3 V = suspect" rule would have:

* flagged **42.5 % of power-bank discharge bursts** (184/433) — every USB-PD
  output, where the port sits at 9–13 V above a single cell by design;
* flagged **91.9 % of power-bank charge bursts** (237/258) — but *not* the other
  8.1 %, which are 5 V slow charging. So it is not even consistently wrong.

Class medians, for scale:

| class | median `SVLT − PVLT` | n |
|---|---|---|
| capacitor | −0.04 V | 4,473 |
| battery | **−0.06 V** | 6,039 |
| **power bank** | **+1.45 V** (max **+9.49 V**) | 4,489 |

> 📌 The battery median was previously published as −0.09 V. That figure was
> computed over a sample that **included unattributed sessions** — and those
> sessions contain power-bank frames (§10.1). A section whose whole point is
> "confirm which unit produced the byte" had itself not done so. The clean,
> `0x10`-attributed value is −0.06 V.

**Treat this as a direction for a controlled experiment**, not as something to
render: capture a healthy pack parked long enough to rule out self-discharge, and
a faulty one under the same conditions. Until then, an implementation that shows
this to a user is repeating the TWF mistake with different arithmetic.

> Note the corollary for UI work: a device reporting an abnormal condition may do
> so *only* through registers that require the connect burst (`0x10`, `0x23`,
> `0x2B`, `0x96`). If the keep-alive write path is broken, none of them arrive
> and the client cannot tell "healthy" from "faulty" (see §10.2).

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
| `0x41` payload is 9 bytes; `0x34` is 9 bytes | ❌ **Wrong** | LEN is **8** and **10** respectively. The old figures counted the XOR byte as payload — and the `0x41` "length doesn't match" argument in §10.1 rested on that miscount |
| TWF values are constant for a whole session | ❌ **Wrong** | A power bank moves between `0x00`/`0x01`/`0x20` inside one connection |
| `0x2B` 4th byte is `0x14` on every unit | ❌ **Wrong** | `0x00` also observed (§8.2.2) |
| `0x96` carries capacity/SOH | ⚠️ **Never observed** | **0 of 206,516 frames**, across 96 sessions, four device classes and seven months. The formulas came from analysis of the reference app, not from the link. Do not implement against them without a capture |

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
| `0x49` | 4 | `[u16 mV][u16 mA]` — the **charge**-side pair | ✅ direction established; current field decoded |
| `0x4A` | 4 | `[u16 mV][u16 mA]` — the **discharge**-side pair | ✅ |
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

⇒ **Publish a magnitude and a direction; do not publish a signed current.**
Whether the current is measured at the cell or at the port is **not established**,
so the two are not interchangeable with a pack's signed `0x2E`.

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

Observed values: `0x00`, `0x01`, `0x03`, `0x05`, `0x06`, `0x07`, `0x0a`, `0x12`,
`0x26`. (An earlier note listed "38" — that was decimal for `0x26`, listed twice
under two radices. **`0x38` has never occurred.**)

| Bit | Meaning | Evidence | Caveat |
|---|---|---|---|
| **bit 5** | **PD output** | 184/184, no counterexample. Same bit at port voltages from 9.05 V to 13.30 V ⇒ it tracks the protocol, not the voltage rail | — |
| **bit 3** | **PD input ⇒ set** | 221/221 | ⚠️ **One-way only.** PD charging does *not* imply bit 3: a unit charging at 9.05 V / 1.83 A (≈16 W) left it clear |
| **bit 2** | **output active** | 689/691 | Two counterexamples, both at 15–31 mA next to a direction change |
| **bit 1** | **Type-C** | A Type-A-only session was 134/134 clear | ⚠️ A Type-C session was **79/84**, not 84/84 — the first ~11 seconds read as bit-1-clear |
| **bit 4** | **unknown** | Appears only as `0x12` (bit1+bit4), 15 bursts, on **one** unit | 🚫 Not decoded. Suspected firmware variant — notably, that is the unit that also failed name-based discovery |
| **bit 0** | **probably "Type-A active"** | See below | ⚠️ Not settled |

**On bit 0: three readings tested, two eliminated, one survives — and it is
still not decoded.**

*Refuted — "bit 0 = 5 V / non-fast-charge":* one capture holds `0x07` and `0x06`
**in the same session, 59 seconds apart, at an identical 5.16 V port voltage**
(15:49:34 → 15:50:33). The two values differ only in bit 0. A 5 V rail cannot
both set and clear the same bit.

*Refuted — "bit 0 = load below some threshold":* the current ranges overlap.
`0x07` bursts reach 268 mA while `0x06` bursts go down to 129 mA.

*Refuted — "bit 0 is a start-of-session settling artefact":* a Type-A-only
session held bit 0 for **136 consecutive bursts over 13 min 10 s, across two
separate connections**.

*Surviving — "bit 0 = Type-A port active":* no counterexample, and it makes the
observed sequences physically coherent. One session runs
`0x05` (A only, 16–22 mA idle) → `0x07` (A + C, load ramping 20 → 2100 mA at
5 V) → `0x26` (C only, PD negotiated to 12.2 V, bit 0 now clear — consistent
with a unit that drops the A port when C takes the full power budget). A
vendor-app screenshot taken during `0x26` shows the Type-A icon dark.

> ⚠️ **PENDING — this is an inference, not a decode.** Every capture to date was
> taken without a record of which ports were physically occupied, so "A + C
> together" is read INTO `0x07`, never confirmed against it. Two further points
> keep it open:
>
> * In both sessions where `0x07` appears it sits at the **start** of a segment
>   and lasts only 5–6 bursts. That is consistent with someone unplugging the A
>   device, and equally consistent with bit 0 meaning something transient that
>   we have not identified.
> * The `0x05` → `0x07` reading of "A, then A and C" is the only interpretation
>   we tried that fits. Fitting is not the same as being tested.
>
> **The experiment that settles it: one capture with both ports deliberately
> loaded at once, labelled as such.** Until then an implementation may show
> "Type-A" from bit 0, but must not present it as more certain than the
> directly-indicated Type-C of bit 1.

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
| `0x4B` b7 **bit 0** = Type-A active | **Inferred.** Three rival readings tested and refuted; this one fits and has no counterexample, but was never tested directly | One session with **both ports deliberately loaded at once**, labelled as such |
| `0x4B` b7 **bit 4** | **Unknown.** 15 bursts, one physical unit, always as `0x12` | A second unit showing the same bit — or a firmware version readout (`0x29`) from the unit that does |
| `0x4B` **b8** | **Not decoded.** Ruled out as the displayed temperature | A capture with a known second thermal load |
| `0x4C` | **Not decoded.** 691/691 constant | Any capture where it varies |
| `0x21` **b5** on power banks | **Not decoded.** 6,118 frames, constant `0xe2` | Same |
| Where the power-bank current is measured (cell side or port side) | **Unknown** | A capture at a known port load with a simultaneous cell-current reference |
| `0x49` mV field | **Not published.** Tracks PVLT, so decoding it again would just rename an existing number | — |
| bit 3 reverse direction (PD charging ⇒ bit 3) | **Refuted**, 16 counterexamples. Forward direction holds 221/221 | Understood; recorded so nobody re-derives the reverse |
| bit 1 = Type-C | **Holds.** An earlier "79/84" figure was a mis-reading — the 5 outliers are a different, correctly-reported port state, not an error | — |

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
| `0x40` | **battery `0x02`** (2026-07-30) | 2 | this unit: `20xx`, 15 distinct, `2000` (2134) / `2010` (1582) / `2001` (718) / `200d` (692) … — earlier unattributed logs: `222b` (8747) / `2229` (8745) | ✅ **Attribution resolved.** The 2026-07-30 capture is a single-device 23-hour log carrying 5,398 `0x40` frames *and* 2,127 `0x10` = `0x02` frames, which is exactly the "capture one *identified* unit" this row used to ask for. **Byte 0 is `0x20` on all 5,398 frames of that unit but `0x22` in the older logs** ⇒ byte 0 is not a constant, it is per-unit or per-state. Emission is **1:1 with `0x21`/`0x2E`** (5,398 : 5,398 : 5,398) and it sits immediately after `0x20` (TWF) in every telemetry group. Still **not decoded**: byte 1 grouped against current, temperature and PVLT in the same frame shows no separation (all 15 groups' ranges overlap). To decode: the same unit before and after a charge cycle, with the charge state labelled. |
| `0x3C` | battery `0x02` | 2 | `0000` ×4, `1100` ×1 | Answers `!#` only (§2), so a 23-hour session yielded 5 samples. One of the five differs — enough to prove it is not a constant, far too few to say what changes it. |
| `0x4D` | battery `0x02` | 7 | `320d240d08001c`, `320d1e0cfa0024`, `320d100ce70029`, `320d320d08002a`, `21b8f10000b8f1` | Answers `!#` only. Four of five samples share the shape `[0x32][u16][u16][u16]`, the two middle words landing in the same 3.30–3.38 V range as the cells. ⚠️ **They are not the `0x47` max/min** — checked against all five bursts, and one burst puts both words *below* every cell `0x47` reported. The trailing word is likewise **not** the `0x21` temperature (two of four exceed that session's observed maximum). The fifth sample breaks the shape entirely (leading `0x21`, two words repeating `b8f1`) on a frame that is nonetheless XOR-clean. **No hypothesis survives n=5; do not decode.** |
| `0x42` | capacitor | 4 | `07c87805`, constant | Same value on both platforms and every session of the same unit — consistent with a static setting or model code. Unproven. |
| `0x41` | capacitor | **8** | `304d303c0100272d` | Labelled "charge info" by the reference app. ⚠️ The previous reason for refusing the §8.2 formula — "observed length doesn't match" — was **itself a parsing error** (LEN 8 was miscounted as 9 by including the XOR byte), and 8 bytes accommodates the 2×u16 layout. It is still not decoded, but for a better reason: **no capture has ever varied it against a known charge state.** |
| `0x4C` | power bank | 2 | `3c0a`, **691/691 constant** across 3 units and 2 phones | Nothing varies ⇒ nothing can be inferred about field boundaries. |
| `0x2C` | capacitor | 2 | `3b82` | No hypothesis. |
| `0x34` | capacitor | **10** | `000a5d0000810000007d` | No hypothesis. (Earlier revisions printed an 11-byte example and called it 9 bytes; both were wrong.) |
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
| **Anti-theft (防盜)** | Mode 1 / status 2 — theft-protection lock |
| **Cut-off (斷電)** | Mode 2 / status 4 — power cut-off |
| **Dealer code (經銷商代號)** | Vendor/dealer identifier from selector 0x27 |
| **Label string** | App-internal string (e.g. `01680102`) built from the dealer code; **never transmitted** (§4.4) |
| **Selector** | `byteList[1]` of an inbound notification frame; the dispatch key |
| **Sync byte** | `0xB8` (184), start of outbound binary frames and validated on inbound |
| **XOR checksum** | Final byte of each binary frame = XOR-fold of all preceding bytes |

---

*End of specification.*

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
