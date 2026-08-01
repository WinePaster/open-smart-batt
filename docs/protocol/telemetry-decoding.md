# Telemetry decoding — constants, formulas, calibration

> Part of the **RCE iBatt BLE protocol specification**. Split out of
> [`../PROTOCOL.md`](../PROTOCOL.md) on 2026-08-01 — text is verbatim, and the
> original `§` numbering is preserved so every cross-reference in this document
> set (and in the app source) still resolves. The index maps `§` to file.
>
> **Covers:** §8 · §8.1 Constants · §8.2 Field → selector → formula · §8.2.1 VADJ · §8.2.2 Warning thresholds · §8.3 Write-path inverse

> Two sibling subsections of §8 live in their own files because they are
> separate protocol topics: the identity / housekeeping registers and the
> device clock are **§8.2.3** in [`identity-and-rtc.md`](identity-and-rtc.md),
> and the TWF status register is **§8.4** in [`twf-status.md`](twf-status.md).
> The `b[n]` notation used by all three is defined at the head of §8 below.

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
