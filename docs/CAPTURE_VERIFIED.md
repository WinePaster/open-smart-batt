# CAPTURE_VERIFIED.md — RCE iBatt live BLE capture (redacted)

Scope: one 89 s BLE session, single connection (conn 0x0002), no reconnect. The
session begins mid-stream (telemetry already flowing at t=0). Facts below are
accepted only where at least one adversarial verifier confirmed them; verifier
corrections are preferred over the raw decode. No device serial/password is
invented — values shown are the redacted ones actually on the wire.

> **隱私註記**：本文中與「特定裝置」相關的認證值（序號、cb=經銷碼、pwsum=密碼字元和、auth 完整位元組）已以 `⟨CB⟩`/`⟨PW⟩`/`00XXXX` 佔位符遮蔽。協定「結構」公開、但個別電池的「值」不公開。

## 1. CONFIRMED by the live capture

### GATT / link (byte-proven, both verifiers)
| Item | Value |
|---|---|
| Vendor service | 07b9fff0-d55f-5e82-ba44-81c0da86c46c, handle range 0x0010–0x0023 |
| Write characteristic | 07b9ace3-…, value handle **0x0018**, props **0x08 = Write-Without-Response only** |
| Notify characteristic | 07b9ace4-…, value handle **0x001b**, props **0x10 = Notify only** |
| CCCD | handle **0x001c**, UUID 2902; enable = write **`0100`** (Notification bit, LE) |
| Second service | f000ffc0-… (TI OAD), handles 0x0024–0xffff — not used |
| ATT MTU | default 23 (20-byte payload); **no Exchange-MTU PDU**. Max PDU on wire = 20 B |
| Value-length histogram (full) | 450×[20], 435×[6], 10×[1], 4×[3], 2×[7], 1× each [9],[2],[19],[15],[13],[12] |
| Outbound writes | **11 total = 10 to 0x0018 + 1 CCCD to 0x001c** (8× keep-alive `23`, 1× auth `value[9]`, 1× mode+auth `value[15]`) |
| Bring-up order | connect → service disc (0.15–0.27 s) → char disc (0.39–0.76 s) → first `#` write (0.859 s) → CCCD `0100` (0.898 s) → more `#` |

### Frame model (both verifiers, 1789/1789 XOR-folds clean)
- **Inbound** sub-frame: `[0xB8, selector, 0x01, LEN, payload(LEN bytes), XOR]`. Payload starts at byte[4]; LEN at byte[3]; 16-bit values big-endian; total = LEN+5. byte[2] is constant **0x01** on every inbound frame.
- Sub-frames **fragment across ATT packets** — receiver MUST reassemble a byte stream and frame by LEN; per-packet `byte[1]=selector` parsing is invalid.
- XOR = fold (`a^b^…`) of all bytes except the trailing one.

### Auth / command frames (byte-exact, both verifiers)
- Standalone verify-auth (L320): `B8 2A 00 04 00 ⟨CB⟩ 00 ⟨PW⟩ ⟨xor⟩` → CMD 0x2A, byte[2]=0x00, LEN 4, payload **00 ⟨CB⟩ 00 ⟨PW⟩**, XOR ⟨xor⟩.
- Mode+auth release (L344, 15 B) = two concatenated sub-frames, **no trailing context payload**:
  - mode: `B8 23 00 01 06 9C` (mode value **0x06**)
  - auth: `B8 2A 01 04 00 ⟨CB⟩ 00 ⟨PW⟩ ⟨xor⟩` (byte[2]=0x01)
- Outbound **byte[2] varies**: 0x00 on standalone auth and mode sub-frame, 0x01 on the auth sub-frame bundled with a mode change. (the bundled variant's byte[2]=0x01 flips the XOR by exactly 0x01 vs the standalone — concrete checksum bytes omitted.) It is a role/flag bit, not the fixed "reserved 0x00" the spec implies, and not a length-high byte (LEN lives in byte[3]).
- Keep-alive on the wire is the **single byte 0x23 (`#`)**, never the 2-byte `!#` (0x21 0x23) wake the spec calls mandatory. No `@` (0x40) token anywhere.

## 2. CORRECTED vs PROTOCOL.md
| PROTOCOL.md said | Live capture shows |
|---|---|
| §6.2 switchMode = mode_frame ++ auth_frame ++ "small context payload" | **No trailing payload**; switchMode on-wire = exactly 6+9 = 15 B |
| §4.3 inbound byte[2..3] = "reserved / 16-bit sub-length, not decoded" | byte[2] is a constant **0x01**; byte[3] alone is LEN |
| §2 first post-subscribe write = mandatory `!#` (0x2123) wake | First write is single `#`; `!#` never appears; telemetry streams anyway |
| §2/§8 keep-alive = 1 Hz timer with `@`/`!#` poll counter | Keep-alive is **bursty/page-driven** (writes at 0.86/0.97/1.03/26.67/29.64/40.96/41.02/88.69 s); telemetry streams ~5 Hz unprompted; poll-counter branch never exercised |
| §5.1/§8.3 0x2B threshold = 3 bytes (OV,UV,OT) trailing 0x00 | Readback carries **4 payload bytes**; 4th = 0x14 (=20), not 0x00 |
| §5.2 device-type 0x10 special-cases 0x44('D') | This unit byte[4]=**0x17** (23); power-bank path not taken |
| §6.1 cb_hi can be 6562 (decimal int.parse of `01680104`) | Wire cb = **0x00⟨CB⟩** (⟨CB⟩). This is *consistent* with the spec's `int.parse(field_cb.substring(0,8))` for the short field_cb '0168' (⟨CB⟩>>8=0x00); the 6562 example simply does not arise for a 3-digit field_cb — the spec mechanism is **not** refuted (verifier correction to C5) |

## 3. §10 unverified items now RESOLVED
| §10 item | Resolved value |
|---|---|
| Notify characteristic UUID | **07b9ace4-d55f-5e82-ba44-81c0da86c46c**, handle 0x001b, props 0x10 |
| Service not byte-proven | Service **07b9fff0-…** byte-proven (write 0x0018 & notify 0x001b both in 0x0010–0x0023) |
| MTU negotiation | None — default 23 confirmed |
| Subscribe/write ordering | CCCD `0100`→0x001c enables notify; first command write is single `#` |
| Exact on-wire length of switchMode | **15 bytes**, mode(6)++auth(9), no extra payload |
| Inbound byte[2]/[3] semantics | byte[2]=const 0x01, byte[3]=LEN |

## 4. Telemetry decode (validated against real values)
See telemetryMap. Voltages 0x19/0x37 ≈ 12.2–12.4 V; temp 0x21 = 45–46 °C; current 0x2E = 0 A (no load); TWF 0x20 = 0x00 (no faults); serial 00XXXX; dealer/field_cb '⟨dealer⟩'.

## 5. STILL UNKNOWN (refuted/disputed → not asserted)
- **No durable telemetry signature of the 斷電 release.** Mode register 0x23 reads 0x05 baseline, pulses to **0x06 for only ~2 frames (+28.9–29.8 s) then reverts to 0x05** for the remaining ~55 s. mode=0x06 matches the spec's "detect/keep-alive poller", NOT a latched unlock; physical cut-off release is **inferred from the user's out-of-band report, not observable in the bytes**. (C7/T7 revised by all verifiers — do not claim mode 6 "is the release" or that it supersedes mode 0/2.)
- **Cold-start handshake not captured** — 10 NOTIFYs precede the in-window CCCD write, so the true initial subscribe/wake is outside the redacted window. Whether `!#` is ever required is unproven (it just never appears here).
- **Single-frame sufficiency unproven** — the app always sent a standalone auth ~2 s before the bundled mode+auth; cannot show the lone 15-byte frame alone works.
- **Live-state dependency unproven** — auth is not challenge-bound, but the device streams genuine live telemetry and arms a periodic detect cycle (recurring 0x29 frames); a replay that drops the connection may not complete.
- Undocumented selectors **0x28 (b4=0x00), 0x29 (0x0106=262), 0x2C (0x3B82=15234)** and the 1-byte **0x2A** response — meanings unknown.
- byte[2]=0x01 "bundled-with-mode-change" meaning is an n=1 inference.
- Absent selectors (formulas unconfirmed this session): **0x96 capacity/SOH, 0x24 DVOL, 0x25 alt-serial, 0x2F, 0x30 VADJ, 0x41/0x4A charge/discharge**.
- 0x20 TWF bit-map untestable (always 0x00); 0x2B 4th byte (0x14) and 0x2C value (15234) semantics unknown.
- pwsum=0x00⟨PW⟩=⟨PW⟩ is a non-injective char-code sum — password preimage unknown and unnecessary for replay.
- Post-unlock current not observed (all five 0x2E samples are pre-unlock).

---

## 6. Replay sequence (for the new client)

REPLAY: connect → enable notify → keep-alive → RELEASE CUT-OFF (for THIS battery)

All bytes below are taken verbatim from the live capture. Writes to 0x0018 are
Write-Without-Response; interleave keep-alives freely (no strict timing) but stay
on ONE live connection with notifications enabled the whole time.

UNIVERSAL (same for any device of this model)
  Service UUID : 07b9fff0-d55f-5e82-ba44-81c0da86c46c
  Write char   : 07b9ace3-d55f-5e82-ba44-81c0da86c46c, value handle 0x0018, props 0x08 (WriteWithoutResponse)
  Notify char  : 07b9ace4-d55f-5e82-ba44-81c0da86c46c, value handle 0x001b, props 0x10 (Notify)
  CCCD         : handle 0x001c, UUID 2902
  Keep-alive   : single byte 0x23 ('#') written to 0x0018
  MTU          : leave at default 23 (no Exchange-MTU); reassemble notifications into one byte stream and frame by LEN

BATTERY-SPECIFIC (the auth payload — these two 16-bit values are THIS unit's)
  cb    = 0x00⟨CB⟩ (⟨CB⟩)  -> the device's AGEN/dealer code. It is broadcast in the
                           clear by the device itself in selector-0x27 telemetry
                           ('⟨dealer⟩'), so a passive sniffer learns it for free.
  pwsum = 0x00⟨PW⟩ (⟨PW⟩)  -> checksum (char-code sum) of THIS battery's cut-off
                           password. Travels in cleartext in the auth write.
  => The auth payload 00 ⟨CB⟩ 00 ⟨PW⟩, and therefore the frames
     'b82a0004·00⟨CB⟩00⟨PW⟩·⟨xor⟩' and 'b82a0104·00⟨CB⟩00⟨PW⟩·⟨xor⟩', are REPLAYABLE AS-IS,
     byte-for-byte, against THIS battery while its password is unchanged.
     There is NO nonce/challenge (no READ precedes auth in the whole capture),
     so no anti-replay, no cloud, no password preimage needed.
     They are NOT portable to another battery — another unit needs its own
     cb (its 0x27 dealer code) and its own pwsum.

ORDERED OPERATIONS
  1. Connect (BLE central). Keep a single connection for the whole flow.
  2. Discover services/characteristics; resolve handles 0x0018, 0x001b, 0x001c.
  3. ENABLE NOTIFY: write [01 00] to CCCD handle 0x001c (UUID 2902).
  4. KEEP-ALIVE / wake telemetry: write [23] to 0x0018. Each '#' triggers a full
     register dump ~130-180 ms later; sustain the connection so the device keeps
     streaming (~5 Hz). Repeat '#' as needed (cadence is not protocol-critical).
  5. (faithful replay) VERIFY-AUTH: write the 9-byte frame to 0x0018:
        b8 2a 00 04 00 ⟨CB⟩ 00 ⟨PW⟩ ⟨xor⟩
  6. RELEASE CUT-OFF: write the 15-byte mode+auth frame to 0x0018:
        b8 23 00 01 06 9c b8 2a 01 04 00 ⟨CB⟩ 00 ⟨PW⟩ ⟨xor⟩
     (= mode sub-frame B8 23 00 01 06 9C  ++  auth sub-frame B8 2A 01 04 00 ⟨CB⟩ 00 ⟨PW⟩ ⟨xor⟩)
  7. CONFIRM: watch for selector-0x23 ack frame b8 23 01 01 06 9d (mode echo 0x06).
     NOTE this echo is TRANSIENT — it reverts to 0x05 (b8230101059e) within ~5 s.
     It is a command echo, NOT a persistent "unlocked" latch.

WHAT IS UNIVERSAL vs BATTERY-SPECIFIC
  Universal: every UUID/handle, the CCCD 0100 enable, the keep-alive 0x23, the
             mode byte 0x06, the frame layout/XOR.
  Battery-specific: ONLY the 16-bit cb (00 ⟨CB⟩) and pwsum (00 ⟨PW⟩) inside the auth
             payload. Substitute the target device's own values to retarget.

SAFETY / CAVEATS (read before running)
  - DO NOT RE-LOCK. This recipe only sends the release (mode 0x06 + auth). Do not
    blindly send other mode codes (e.g. 0/2) — their effect on this firmware is
    unverified and could re-engage the cut-off.
  - The physical 斷電 release is NOT observable in the BLE bytes (no cut-off-status
    frame changes; mode 0x23 only pulses 05->06->05). Success was reported
    out-of-band, not proven on the wire — verify electrically, not via telemetry.
  - This capture starts mid-session; the true cold-start subscribe/wake is outside
    the window. If a fresh connection does not stream after step 3-4, the device
    may expect an initial handshake not captured here ('!#'/0x2123 never appears,
    so it is likely unneeded, but this is unproven).
  - "Lone 15-byte frame is enough" is UNPROVEN — the app always pre-sent the
    standalone auth (step 5) ~2 s earlier and kept the keep-alive running. Do
    steps 3-6 within one live connection; do not rely on a single isolated PDU.

---

## 7. Telemetry map (validated)

Inbound frame: [0xB8, selector, 0x01, LEN, payload(LEN), XOR]; payload at byte[4]; 16-bit = big-endian; b4=byte[4], b5=byte[5], ...

selector | LEN | payload offset | formula | real decoded value (this capture)
0x10 device-type    | 1 | b4        | raw; ==0x44('D') => power-bank          | 0x17 (23) -> NOT power-bank
0x19 PVLT main V     | 2 | b4..b5    | (b4*256+b5)/100 V                       | 12.26-12.36 V (e.g. 04d4=12.36)
0x20 TWF flags       | 1 | b4        | bitfield                               | 0x00 all 442 frames (no faults; bit-map untestable)
0x21 temperature     | 1 | b4        | signed int8(b4), no scale              | 45-46 C (2d/2e)
0x23 mode register   | 1 | b4        | mode code                              | 0x05 baseline; transient 0x06 (~2 frames) after mode-write, reverts to 0x05
0x26 serial          | 6 | b4..b9    | 48-bit BE int, padLeft(6,'0')          | 00XXXX (00 00 00 00 XX XX)
0x27 dealer/field_cb | 6 | b4..b7    | '%04d%02X%02X'(b4*256+b5, b6, b7)       | '⟨dealer⟩' (cb=00⟨CB⟩ → first4-digit + b6 + b7); b8,b9 unused. Seeds auth cb.
0x28 [undocumented]  | 1 | b4        | unknown                                | 0x00
0x29 [undocumented]  | 2 | b4..b5    | unknown (post-mode handshake)          | 0x0106 (262)
0x2A auth/pw response| 1 | b4        | unknown (1-byte ack)                   | 0x00
0x2B threshold rdbk  | 4 | b4..b7    | OV=b4*0.025+14.4; UV=b5*0.025+10.4; OT=b6+60; b7=? | OV 14.8 V, UV 11.5 V, OT 100 C, b7=0x14 (20)
0x2C [undocumented]  | 2 | b4..b5    | unknown                                | 0x3b82 (15234)
0x2E main current    | 2 | b4..b5    | 512-(b4*256+b5) A                      | 0 A (0200; only pre-unlock samples observed)
0x37 SVLT secondary V| 2 | b4..b5    | (b4*256+b5)/100 V                       | 12.23-12.33 V (e.g. 04cf=12.31)

Outbound (writes to 0x0018): byte[2] varies (0x00 standalone auth / mode sub-frame, 0x01 bundled auth). XOR same fold rule.
 mode  : B8 23 00 01 06 9C       (mode value 0x06)
 auth  : B8 2A bb 04 00 ⟨CB⟩ 00 ⟨PW⟩ xx  (bb=00 standalone->XOR ⟨xor⟩; bb=01 bundled->XOR ⟨xor⟩)

ABSENT this session (formulas NOT validated): 0x96 capacity/SOH, 0x24 DVOL, 0x25 alt-serial, 0x2F, 0x30 VADJ, 0x41/0x4A charge/discharge.

---

## 8. Remaining unknowns

- Whether the lone 15-byte mode+auth frame suffices without the prior standalone auth (app always pre-sent it ~2s earlier; unproven)
- True cold-start subscribe/wake sequence (capture starts mid-session; 10 NOTIFYs precede the in-window CCCD write); whether the spec '!#' (0x2123) wake is ever required (never appears)
- Physical 斷電 release is NOT observable in BLE bytes; mode 0x23 only pulses 0x05->0x06->0x05; relationship of mode 0x06 to documented modes 0/2/4 unresolved
- Whether the device requires live state / the 10s periodic detect-poller cycle (recurring 0x29 frames) to complete the release
- Meaning of undocumented selectors 0x28 (0x00), 0x29 (262), 0x2C (15234) and the 1-byte 0x2A response
- byte[2]=0x01 'auth bundled with mode-change' semantic is an n=1 inference, not byte-proven
- Formulas for selectors absent this session: 0x96 capacity/SOH, 0x24 DVOL, 0x25 alt-serial, 0x2F, 0x30 VADJ, 0x41/0x4A charge/discharge
- TWF 0x20 warning-bit mapping (untestable: 0x00 in all 442 frames)
- Semantics of 0x2B 4th payload byte (0x14=20) and 0x2C value (15234)
- pwsum=0x00⟨PW⟩ (⟨PW⟩) password preimage — non-injective char-code sum, unknown and not needed for replay
- Portability of auth to other devices requires that device's own cb (its 0x27 dealer code) and pwsum
- Post-unlock current behaviour unknown (all five 0x2E samples are pre-unlock, all 0 A)
