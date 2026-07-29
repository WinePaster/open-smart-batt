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
also maintains an internal ASCII-hex "current command" string (e.g. `01680104`)
built from received bytes; **these hex strings are never transmitted on the wire**
— they are an in-app dispatch/label key.

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
| Write type | **Write Without Response only** (ATT Write Command). Zero Write-With-Response calls exist (8 distinct write call sites, all without response). |
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
| device-type byte == `D` (0x44) **and** counter % 5 == 0 | `!#` | `21 23` |
| otherwise | `#` | `23` |

*(Note: one verifier flagged that the device-type comparison may read a Smi-tagged
value; the semantic intent — "device type == 'D' / power bank" — is consistent
with the telemetry device-type case, where received `byteList[4]==0x44` is firmly
confirmed. See §9.)*

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
| `f000ffc0-0451-4000-b000-000000000000` | `f000ffc1-…` | Write-Without-Response + Notify |
| `f000ffc0-…` | `f000ffc2-…` | Write-Without-Response + Notify |

Two facts follow directly:

* **`07b9ace3` advertises `W` (write **with** response) and NOT
  Write-Without-Response.** §2's "Write Without Response only" describes the
  reference app's *call sites*; an interop client must honour the characteristic's
  actual property flags or the write is rejected.
* **`f000ffc0`** is a second, non-vendor-base service. The `f000…-0451-4000-b000-…`
  base and the `ffc1`/`ffc2` WwN+Notify pair are the signature of the **TI OAD
  (over-the-air firmware download)** profile. **Not exercised, not decoded, and
  not required for telemetry** — recorded only so an implementer knows it exists
  and does not mistake it for a second telemetry channel.

> The vendor characteristics `ace1`, `ace2`, `bbc1`, `bbc2` are advertised but
> never touched by the reference app. Their contents are unknown.

**`QualifiedCharacteristic` field layout** (struct size 0x14):
`field_7 = characteristicId`, `field_b = serviceId`, `field_f = deviceId`. The
source discovered-characteristic object exposes `characteristicId` at offset 0x7
and `serviceId` at offset 0xf.

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
| `0x00` | Reserved / high byte of length. (Reserved-vs-length semantics inferred.) |
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
2026-07-28): a strict walk of a two-device field capture parsed
**3342 of 3342 frames with a correct XOR and zero leftover bytes**, over two
devices, using exactly the layout above. `byte[2]` was `0x01` on every frame.
Because inbound frames are self-delimiting, a reassembler can and should walk
them by length rather than by scanning for `0xB8` — payload bytes can equal
`0xB8`, so substring/scan-based parsing produces phantom frames (see §10.1).

> One notification packet may carry **several concatenated frames**, and one
> logical packet may arrive **split across multiple ATT notifications** (the
> 42-byte telemetry burst arrives as 20 + 20 + 2). Reassembly must therefore
> buffer across notifications and emit every complete frame found.

**Dispatch is on `byteList[1]`** (the received frame's 2nd byte), bounds-checked
against the frame length. (Earlier recon mislabeled this as a separate message
field `field_13`; it is the array element at index 1.)

### 4.4 The `0168xxxx` / `0169xxxx` ASCII-hex IDs and odd-length literals

* `0168xxxx` / `0169xxxx` are **app-internal** hex IDs, **not wire bytes**. They are
  produced by `combineBytesForAGENSN` from received bytes and stored in
  controller field `field_cb`, then dispatched by string `==` in `setCurrentMode`.
* **Encoding of these IDs:** `combineBytesForAGENSN` builds the string
  `sprintf("%04d%02X%02X", (b4*256+b5), b6, b7)` — i.e. the **first two payload
  bytes as a 4-digit DECIMAL number**, then the next two bytes as **2-digit HEX**.
  Example: `b4=0, b5=0xA8(168), b6=0x01, b7=0x02` → `"0168"+"01"+"02"` =
  `01680102`. (The leading `0168` is decimal 168, not hex.) Bytes `b8/b9` are
  passed but unused.
* `01680104300001` / `01680104309999` — **decimal numeric range bounds**
  (104300001 .. 104309999), `int.parse`d (base 10) and used to range-check a
  received value for lock/anti-theft classification. Not commands.
* `0168014000848` (odd length 13) — a **UI sample/placeholder** for the serial-
  number text field on the device-binding page. Not a command. Its odd length is
  simply a sample serial format.

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
> carries the password-auth frame. The on-wire packet is also concatenated with a
> small additional context payload, making it longer than the bare frames above.

### 5.2 Inbound selectors (`byteList[1]`) — read / response codes

| Selector | Meaning | Notes |
|---|---|---|
| `0x10` | Device type | `byteList[4]`; if `== 'D'` (0x44) → power-bank flag set |
| `0x19` | Main voltage PVLT | §8 |
| `0x20` | TWF warning/status flags | §8 (bit semantics unverified) |
| `0x21` | Temperature | §8 |
| `0x23` | Mode switch | `byteList[4]` → `setCurrentMode` |
| `0x24` | DVOL per-series cell voltages | gated by `field_cb=='01680104'/'01690104'` |
| `0x25` / `0x26` | Battery serial number | §8 |
| `0x27` | Dealer code (經銷商代號) | §8; builds `field_cb` |
| `0x2A` | Password (密碼 PASSWORD) | response label |
| `0x2B` | Warning parameters readback | §8 |
| `0x2E` | Main current (A) | §8 |
| `0x2F` | Secondary current (mA) | logged only, not stored |
| `0x30` | VADJ voltage-precision adjust | §8; multiplier for DVOL |
| `0x37` | Secondary voltage SVLT (also "FW VER" label group) | §8 |
| `0x41` | Charge info | §8 |
| `0x4A` | Discharge info | §8 |
| `0x96` | Capacity / SOH info | §8 |
| `0x25` | Manufacture year | §8.2.3 |
| `0x29` | Firmware version | §8.2.3 |
| `0x38` | Device MAC, as an ASCII string | §8.2.3 |
| `0x3B` | Device real-time clock | §8.2.3 |
| `0x2C` / `0x34` / `0x3A` / `0x42` | Streamed but undecoded | §10.1 |

### 5.3 `field_cb` string-compare codes (used in `setCurrentMode`)

| String | Meaning |
|---|---|
| `01680102` | Dealer-code group |
| `01680104` / `01690104` | DVOL / mode-switch / battery-serial group |
| `01680217` / `01690217` | Capacitor status: normal (green) vs abnormal "locked-protection" (red); status field at instance offset 0x143 |
| `01680218` / `01690218` | Anti-theft / cut-off mode status |
| `01680211`–`01680214` | Parameter-set acknowledgements; each stores `true` at instance offset 0x133 |

> Per-code meaning of `0211`–`0214` (OV/UV/OT/threshold) is an **inference**: all
> four write the **same** flag (offset 0x133); only the string compare and the
> store are proven.

---

## 6. Unlock / cut-off / anti-theft flow

### 6.1 Password encoding

The cut-off password (SQLite `firmware.cutoff_password`) is loaded into controller
`field_e3` and **never transmitted in plaintext**. Authentication proves knowledge
of it via a **16-bit checksum = sum of the password's character code units**, split
big-endian: `sum_hi = sum>>8`, `sum_lo = sum & 0xFF`.

The auth frame also carries an **echo value** `cb` derived from `field_cb`:
```
v      = int.parse( field_cb.substring(0,8) )     // BASE 10 (decimal)
cb_hi  = v >> 8        // NOT masked with 0xFF — may exceed one byte
cb_lo  = v & 0xFF
```
Because the parse is **decimal** on a hex-looking string, `cb_hi` can exceed 255
(e.g. `"01680104"` → 1680104 → `cb_hi` = 6562). This is an app-side quirk faithfully
described here; `cb_hi` is boxed (not byte-constrained) and only `cb_lo` is masked.

### 6.2 `switchMode(mode)` — lock/unlock entry point

Builds and writes (single write):

```
mode frame : [0xB8, 0x23, 0x00, 0x01, mode] + XOR
auth frame : [0xB8, 0x2A, 0x00, 0x04, cb_hi, cb_lo, pwsum_hi, pwsum_lo] + XOR
on wire    : mode_frame ++ auth_frame ++ small_context_payload
```

**Mode argument → action:**

| `mode` | Action |
|---|---|
| `0` | Deactivate / unlock (normal) |
| `1` | Activate anti-theft (防盜) |
| `2` | Activate cut-off (斷電) |
| `6` | Special: after the write, start a **10 s periodic detect/keep-alive poller** (`Timer.periodic`, 10000 ms, stored in `field_b3`) |

After **every** `switchMode` call a boolean at instance offset **0x10f** is set
`true` (mode-command-sent marker), regardless of mode.

**Reported status** (device → app) uses a **different code space**, stored at
instance offset **0x113**:

| status @ 0x113 | Meaning / UI |
|---|---|
| `0` | Normal (lock icon) |
| `2` | Anti-theft active (防盜模式已啟動) |
| `4` | Cut-off active (斷電模式已啟動) |

**UI button logic** (function page):
* Anti-theft: `switchMode(currentMode != 2 ? 1 : 0)`
* Cut-off: `switchMode(currentMode != 4 ? 2 : 0)`

### 6.3 `changeCutOffPassword(newPwBytes)`

```
[0xB8, 0x2A, 0x00, 0x04, cb_hi, cb_lo, newsum_hi, newsum_lo] + XOR
```
where `newsum` = sum of the **new** password bytes; the loop count is the **old**
`field_e3.length` (it iterates the new list using the old length). Same `0x2A`
channel as the auth frame.

### 6.4 Lock-status classification (received `0104` group)

When `field_cb == '01680104'/'01690104'`, a received value (from `field_cf`,
stringified then `int.parse` base 10) is range-checked against the decimal bounds
`104300001 .. 104309999`. If in range, two booleans (offsets 0x123 and 0x127) are
set `true`, and the status at offset 0x113 (`2` → anti-theft, `4` → cut-off) selects
the lock / locked / block-electricity UI.

### 6.5 Detect handshake flags

| Flag | Offset |
|---|---|
| `isSentDetect` | **0x3c** |
| `isReceivedDetect` | **0x40** |
| `isChangedPassword` | **0x10c** |

These gate `sendInitData` / `getFirmwareInfo`. `setCurrentMode` (invoked from the
dispatcher after each mode/status response) manages them. The **exact on-wire bytes
of the initial "detect" send were not isolated** (see §10).

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

| Field | Selector | Formula | Store |
|---|---|---|---|
| Main voltage **PVLT** (V) | `0x19` | `(b4*256 + b5) / 100.0` | `field_73` |
| PVLT gauge index | `0x19` | `trunc((PVLT − 8.0) / (2/7))` = `trunc((PVLT−8)*3.5)`, clamp 0..28 | `field_37` |
| Secondary voltage **SVLT** (V) | `0x37` | `(b4*256 + b5) / 100.0` | `field_77` |
| **Temperature** (°C) | `0x21` | signed int8 of `b4` (if `b4 ≥ 0x80` → `b4 − 0x100`); no scaling | `field_6f` |
| **DVOL** cell 1..4 (V) | `0x24` *(gated `field_cb=='01680104'/'01690104'`)* | `dvol_i = (b[i] / 1000.0) * VADJ`, i = 4..7 | `field_7b/7f/83/87` |
| **VADJ** (scale factor) | `0x30` | `(b4*256 + b5) / 100.0` | `field_8b` (used as DVOL multiplier) |
| **Main current** (A) | `0x2E` | `512 − (b4*256 + b5)` (a `/100`×`100` round-trip nets to identity) | `field_8f` |
| Secondary current (mA) | `0x2F` | parsed/logged only; **not stored** | — |
| **Warning OV** (V) | `0x2B` | `b4 * 0.025 + 14.4` | offset 0x15f (351) |
| **Warning UV** (V) | `0x2B` | `b5 * 0.025 + 10.4` | offset 0x163 (355) |
| **Warning OT** (°C) | `0x2B` | `b6 + 60.0` | offset 0x167 (359) |
| **Charge** v1 / v2 | `0x41` | `(b4*256+b5)/100/10`, `(b6*256+b7)/100/10` (= /1000) | `field_97` / `field_9b` |
| **Discharge** v1 / v2 | `0x4A` | `(b4*256+b5)/100/10`, `(b6*256+b7)/100/10` (= /1000) | `field_9f` / `field_a3` |
| **Capacity raw byte** | `0x96` | `b6` (the `(b4*256+b5)/100` value is computed then discarded) | `field_a7` |
| **Capacity / SOH bucket** | `0x96` | from `b6`: stringify, index chars, `int.tryParse`, then `(n−1)*10 + 5` | `field_ab` |
| **Device type** | `0x10` | `b4`; if `== 0x44 ('D')` → power-bank flag | (HomeController) |
| **Battery serial** | `0x25`/`0x26` | `b4..b9` packed big-endian into 48-bit int (`<<40,<<32,<<24,<<16,<<8,<<0`), stringified, `padLeft(6,'0')` | `field_c7` |
| **Dealer code** | `0x27` | `combineBytesForAGENSN(b4..b7)` → `"%04d%02X%02X"` string (see §4.4) | `field_cb` |
| **Mode** | `0x23` | `b4` → `setCurrentMode` | offset 0x113 (275) |

### 8.2.1 VADJ is a per-unit calibration constant, not a fixed number

`0x30` is read from the device; **do not hardcode it.** Measured values:

| Unit | VADJ | Source |
|---|---|---|
| Car battery, HCI snoop 2026-07-06 | **20.36** | §8.5 connect burst |
| Car battery, device-type `0x02`, 2026-07-06 field capture | **20.17** (`0x30` payload `07e1`, 531 identical frames) | live capture |
| Motorcycle-class unit (streams `0x40`) | **≈20.06** | 2026-07-05 live capture |

Spread across units is ≈1.5 %, consistent with a factory per-unit calibration.

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

### 8.2.2 Warning thresholds differ by product class

Measured `0x2B` readbacks, decoded with the §8.2 formulas:

| Unit | `0x2B` payload | OV | UV | OT | 4th byte |
|---|---|---|---|---|---|
| Car battery (device-type `0x02`) | `18401414` | 15.0 V | 12.0 V | 80 °C | `0x14` |
| Super-capacitor (device-type `0x17`) | `102c2814` | 14.8 V | 11.5 V | 100 °C | `0x14` |

Source: live captures (531 and 445 identical frames respectively). The 4th byte is `0x14` on both; §5.1 sends `0x00` there on the
write path, and its read-path meaning (a UT / under-temperature threshold is the
working hypothesis) is **unverified** — scaling unknown, do not decode it.

### 8.2.3 Identity / housekeeping registers (decoded 2026-07-28)

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

`b4` is converted to a binary string (`toRadixString(2)`, `padLeft(8,'0')`) and
individual bit positions are tested against `'1'` to set protection booleans
(over-voltage protection `field_e7`, under-voltage protection `field_eb`,
high-temp warning `field_ef`/`field_fb`, `field_ff`) and a status message
(`field_11f`). **The exact bit→meaning mapping is unverified** — see §10.

**Values observed on the wire** (every capture to date; each was constant for a
whole session except where noted):

| `b4` | Seen on | Context |
|---|---|---|
| `0x00` | most units, most sessions | the normal/idle value |
| `0x01` | a unit at PVLT 9.84 V with a 1.75 V cell imbalance; also a unit at a wholly normal PVLT 13.25 V | see below |
| `0x20` | **power banks only** (`0x10 = 0x22`) — 447 frames across 4 captures; **0 frames across 13,535 battery/capacitor samples** | **charging.** PVLT ≈3.8–4.2 V is the SINGLE-CELL voltage, SVLT ≈9.0 V is the PD charging INPUT — not a 12 V pack in trouble |

Only three of the eight bits have ever been non-zero, so most of the field is
untested. A 2026-07-28 capture is the strongest single data point available: two
units on one phone within the same minute — a faulty one (PVLT 9.84 V, far below
its class's 12.0 V UV threshold) reported `0x01` for all 557 frames, while a
healthy reference unit (PVLT 13.28 V) reported `0x00` for all 42. That is
suggestive of **bit 0 = under-voltage**, but it is **not sufficient**: an earlier
capture shows `0x01` on a unit sitting at a perfectly normal 13.25 V. Either the
bit means something else, or its meaning is class-dependent.

### `0x20` means charging, on power banks (2026-07-29)

Direction cross-check over the whole power-bank corpus:

| | charging | discharging |
|---|---|---|
| TWF `0x20` | **42** | **0** |
| TWF `0x00` | 10 | 449 |

The forward direction holds without exception; the reverse does not. Ten
charging samples report `0x00` — trickle charge (31–60 mA) and roughly one burst
of start-up delay after the charger is connected.

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

**A stronger candidate signal than any TWF bit: `SVLT − PVLT`.** Where TWF has
disagreed with reality twice, the gap between the string voltage (`0x37`) and the
terminal voltage (`0x19`) has so far tracked it:

| Unit | `SVLT − PVLT` | Independently known state |
|---|---|---|
| capacitor, healthy | 0.04 V | healthy |
| capacitor, 2026-07-19 | 3.11 V | vendor app showed a fault |
| battery, 2026-07-28 | −0.02 V | healthy reference |
| battery, 2026-07-28 | **5.07 V** | cell imbalance, deeply discharged |

Four units, two classes, no overlap between the healthy (<0.1 V) and faulty
(>3 V) groups — and the 2026-07-28 pair removes the earlier confound of comparing
a parked unit against a running one (both were idle, on one phone, in the same
minute). Still **only four units**, and a large gap has an innocent explanation
(a pack under load, or mid-charge). **Unverified** — do not ship it as a decoded
fault without a controlled capture, ideally a healthy unit parked long enough to
rule out self-discharge.

> 🚫 **PACKS ONLY — this signal is meaningless on a power bank, and applying it
> there reproduces the exact failure described above.** On a power bank `PVLT` is
> a single cell and `SVLT` is the USB port, so the two are separated by a boost
> stage by design. Measured over the 2026-07-29 corpus:
>
> | class | median `SVLT − PVLT` |
> |---|---|
> | capacitor | −0.04 V |
> | battery | −0.09 V |
> | **power bank** | **1.41 V (max 9.49 V, n = 4690)** |
>
> The ">3 V = suspect" threshold above would flag **every power bank that is
> charging** — the same false positive as the TWF `0x20` rule, arrived at by a
> different formula. Any use of this signal must be gated on the device-type
> byte first.

> Note the corollary for UI work: a device reporting an abnormal condition may do
> so *only* through registers that require the connect burst (`0x10`, `0x23`,
> `0x2B`, `0x96`). If the keep-alive write path is broken, none of them arrive
> and the client cannot tell "healthy" from "faulty" (see §10.2).

---

## 9. Field offset reference (recovered)

| Datum | Offset/field |
|---|---|
| PVLT | `field_73` |
| PVLT gauge index | `field_37` |
| SVLT | `field_77` |
| Temperature | `field_6f` |
| DVOL 1..4 | `field_7b/7f/83/87` |
| VADJ scale | `field_8b` |
| Main current | `field_8f` |
| Charge v1/v2 | `field_97/9b` |
| Discharge v1/v2 | `field_9f/a3` |
| Capacity raw byte | `field_a7` |
| Capacity / SOH bucket | `field_ab` |
| Battery serial | `field_c7` |
| Dealer code / current-command string | `field_cb` |
| Mode (reported status) | offset 0x113 (275) |
| Mode-command-sent marker | offset 0x10f |
| Lock-range flags | offsets 0x123, 0x127 |
| Param-set ack flag | offset 0x133 |
| Capacitor status field | offset 0x143 |
| Warning OV/UV/OT | offsets 0x15f / 0x163 / 0x167 (351/355/359) |
| Status booleans / message | `field_e7/eb/ef/fb/ff`, `field_11f` |
| Receive buffer (List<int>) | offset 0x34 |
| isSentDetect / isReceivedDetect / isChangedPassword | 0x3c / 0x40 / 0x10c |
| cutoff password | `field_e3` |
| Saved write serviceId / characteristicId / deviceId | `field_5f` / `field_63` / `field_6b` |

> SQLite `deviceData` column correspondence (functional mapping):
> `pvlt, svlt, ampere, temperature, dvol1..4, pattern_flag (mode), status_flag
> (TWF), serialNumber`.

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
* **Per-code meaning of param-set acks `0211`–`0214`.** All four set the same flag
  (offset 0x133); the OV/UV/OT/threshold attribution is inferred, not proven.
* **Initial "detect" command bytes.** Only the gating flags (0x3c/0x40) and that it
  precedes `sendInitData`/`getFirmwareInfo` are confirmed; the exact on-wire bytes
  were not isolated.
* **Device-type poll comparison tag.** One verifier holds that the 1 Hz poll's
  device-type test compares a Smi-tagged value (effective integer 34 / 0x22)
  rather than ASCII `'D'` (0x44); the telemetry device-type case (received
  `byteList[4]==0x44`) is firmly confirmed, but the poll-side tag handling is
  disputed.
* **Exact total on-wire length of `switchMode`.** The mode+auth frames are
  concatenated with an additional context payload (`field_13`) before writing; the
  precise trailing bytes/length per mode were not enumerated.
* **Relationship between the inbound `0xB8` frames and the synthesized `0168xx`
  app IDs** was not fully decoded. (The frame layout itself is now settled — §4.3.)
* **Capacity/SOH bucket semantics.** Whether `(n−1)*10+5` represents SOH%, SOC%, or
  a cycle bucket is unknown (no explicit label found).
* **Full read-selector enumeration.** Additional labels exist in the pool (FW
  version code `0x37` group, rectifier-gear, a "PowerBank Command 7" branch, etc.)
  whose byte offsets were not all mapped.

### 10.1 Observed on the wire but NOT decoded (2026-07-28)

Streamed by real units and reassembled from live captures, but with no
established meaning. They are dropped by the decoder's `default:` branch. **Do
not guess a layout** — each needs a controlled experiment before it is decoded.

| Selector | Seen on | Payload | Notes |
|---|---|---|---|
| `0x40` | smart battery (813 frames in one session; a separate 2026-07-05 capture streamed it 564 times) | 2 bytes, `222b` (8747) / `2229` (8745) | Barely moves. Candidates: cycle count, capacity (mAh), accumulated charge — **none evidenced**. To decode: capture the same unit before and after a charge/discharge cycle and see how it tracks. |
| `0x42` | super-capacitor (488 frames Android; 1113 more on iOS) | 4 bytes, `07c87805`, **constant** | Same value on both platforms and every session of the same unit — consistent with a static setting or model code. Still unproven. |
| `0x2C` | super-capacitor | 2 bytes, `3b82`, constant per session | No hypothesis. |
| `0x34` | super-capacitor | 9 bytes, `000a5d00006b0000007d19`-shaped, constant per session | No hypothesis. |
| `0x3A` | super-capacitor | 2 bytes, `5100`, constant per session | No hypothesis. |
| `0x41` | super-capacitor | 9 bytes, `304d303c0100272d12`-shaped | §5.2 labels this "charge info", but the observed length does not match the 2×u16 layout §8.2 describes. **Do not decode it with that formula** until a capture settles the discrepancy. |

Method note: both were confirmed by **reassembling the byte stream and walking
frames**, not by substring-matching hex text. An earlier pass using `grep` over
the log text also reported `0x1F` and `0x22`; strict framing shows **no such
frames** — those hits were payload bytes that happened to follow a `b8`. Any
future selector claim should come from the framing walk.

### 10.2 Capture prerequisite: no keep-alive write ⇒ no metadata

**Which selectors you observe is a property of your client, not of the device.**
A unit that receives no keep-alive write still streams a small telemetry set, so
a broken write path looks like a working connection — and every conclusion drawn
about "what this device supports" from such a capture is wrong.

Evidence, across every capture collected to date:

| Write path | Selectors observed |
|---|---|
| **Working** (TX present in the log) | `0x10 0x14 0x19 0x1C 0x1D 0x20 0x21 0x23 0x24 0x25 0x26 0x27 0x29 0x2B 0x2C 0x2E 0x30 0x34 0x35 0x37 0x38 0x3A 0x3B 0x41 0x42` |
| **Broken** (zero TX in the log) | `0x19 0x20 0x21 0x24 0x2E 0x37` — six registers, nothing else |

The six that survive are the free-running telemetry stream. Everything
identifying — **device type (`0x10`), serial (`0x25`/`0x26`), dealer code
(`0x27`), VADJ (`0x30`), mode (`0x23`), thresholds (`0x2B`), SOH/SOC (`0x96`)** —
rides the connect burst, which only fires after the device is poked (§2).

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
| **TWF** | Warning/status flag word (bit field of protection states) |
| **SOH** | State of health (capacity/health bucket from selector 0x96) |
| **Anti-theft (防盜)** | Mode 1 / status 2 — theft-protection lock |
| **Cut-off (斷電)** | Mode 2 / status 4 — power cut-off |
| **Dealer code (經銷商代號)** | Vendor/dealer identifier from selector 0x27 |
| **`field_cb`** | App-internal "current command" hex-format string (e.g. `01680104`), built from received bytes; never transmitted |
| **Selector** | `byteList[1]` of an inbound notification frame; the dispatch key |
| **Sync byte** | `0xB8` (184), start of outbound binary frames and validated on inbound |
| **XOR checksum** | Final byte of each binary frame = XOR-fold of all preceding bytes |

---

*End of specification. All values above are functional protocol facts derived from
clean-room analysis; each was confirmed by at least one independent verification
pass except where explicitly marked unverified in §10.*
