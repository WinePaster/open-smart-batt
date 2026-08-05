# Frame format, command catalog, and checksum

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §4 Packet framing · §5 Command catalog · §7 Checksum

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
| `0x20` | all | TWF warning/status byte | §8.4. **Not a fault flag** — on power banks the **value** `0x20` in this register implies *charging* (one-way: `0x20` ⇒ charging, **not** charging ⇒ `0x20`). Do not confuse the value with this selector, which is also `0x20` |
| `0x21` | all | Temperature | §8. ⚠️ LEN 1 on pack, **LEN 2 on power bank** (§9.1) |
| `0x23` | all | Mode / status register | §8 |
| `0x24` | pack | DVOL per-series cell voltages | §8. **Not gated** — streams unconditionally (9,496 frames observed) |
| `0x25` | all | Manufacture year | §8.2.3. **Not the serial high word** — see §9. ⚠️ **Class corrected to `all` 2026-08-05** — it was listed as `pack`, but a whole-corpus count finds it on every device class, including **36,507 frames on power banks** (constant `07e5` = 2021). Per class: `0x02` battery 217 (`07e4`/`07e9`), `0x17` capacitor 13,900 (`07e4`), `0x18` flagship capacitor 3,483 (`07e8`), `0x22` power bank 36,507 (`07e5`) |
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
| `0x34` | all | **System counters** — standby / connected minutes, sleep / power-on / cut-off counts | see `telemetry-decoding.md` |
| `0x2C` / `0x3A` / `0x3C` / `0x40` / `0x42` / `0x4D` | see §10.1 | Streamed but undecoded | §10.1 |

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

## 7. Checksum

`getCheckSum(list)` = **XOR-fold of all bytes** in the list
(`list.reduce((a,b) => a ^ b)`; closure body is a single `eor`). The single-byte
result is appended as the **final** element of every outbound binary frame before
writing.
