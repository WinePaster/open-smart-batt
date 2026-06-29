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
| **Notify characteristic** | *Not hardcoded* — selected by property flags (notifiable). | Chosen by capability flags, not by UUID string. Its UUID is firmware-advertised and **not present in the binary** (see §10). Presumed under the same service/base. |

**Service of the write characteristic:** taken **dynamically** from the discovered
characteristic's serviceId (not embedded as bytes). It is almost certainly
`07b9fff0` (shared base + FFF0 convention), but this linkage is inferred, not
byte-proven.

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
byte[2..3]   : reserved / sub-length (not fully decoded)
byte[4..]    : telemetry / payload
```

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

* **Notify characteristic UUID.** Selected by capability/property flags, not a
  string compare; **absent from the binary**. Likely `07b9XXXX-d55f-5e82-ba44-
  81c0da86c46c` under the same base/service. Capture with a live device or
  platform-channel logs.
* **Service containing the write/notify characteristics.** Read dynamically from
  discovery (`serviceId` is not an embedded literal). Presumed `07b9fff0` from the
  shared base + FFF0 convention; **not byte-proven**.
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
* **Received-frame bytes [2]/[3]** (sub-command vs length) and the relationship
  between the inbound start byte `0xB8` and the synthesized `0168xx` app IDs were
  not fully decoded.
* **Capacity/SOH bucket semantics.** Whether `(n−1)*10+5` represents SOH%, SOC%, or
  a cycle bucket is unknown (no explicit label found).
* **Full read-selector enumeration.** Additional labels exist in the pool (FW
  version code `0x37` group, rectifier-gear, a "PowerBank Command 7" branch, etc.)
  whose byte offsets were not all mapped.

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
