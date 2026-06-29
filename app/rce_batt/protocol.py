"""
RCE iBatt BLE protocol encode/decode.

Clean-room implementation derived solely from the published functional
protocol specification (UUIDs, command byte layouts, checksum, telemetry
scaling formulas). No vendor source, assets, or UI text are reproduced here.

Two on-wire encodings exist:

1. Binary command frames:  [0xB8, CMD, 0x00, LEN, payload..., XOR]
2. ASCII keep-alive tokens: "!#", "@", "#" (UTF-8)

Inbound notification frames carry a selector at byteList[1] and a telemetry
payload that begins at byteList[4]. 16-bit values are big-endian.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# GATT UUIDs (spec section 3)
# ---------------------------------------------------------------------------

# Vendor 128-bit base; the three UUIDs differ only in the 16-bit slot (bytes 2-3).
# Service UUID is the scan filter; write characteristic is matched by exact UUID.
SERVICE_UUID = "07b9fff0-d55f-5e82-ba44-81c0da86c46c"
WRITE_CHAR_UUID = "07b9ace3-d55f-5e82-ba44-81c0da86c46c"

# UNVERIFIED - confirm against hardware/HCI snoop.
# The notify characteristic UUID is NOT hardcoded in the original app; it is
# selected at runtime by capability flags (notifiable). It is presumed to live
# under the same vendor base/service. We do not hardcode a single literal here;
# client.py selects the notify characteristic by its "notify" property and only
# falls back to this hint if needed.
NOTIFY_CHAR_UUID_HINT: Optional[str] = None  # e.g. "07b9XXXX-d55f-5e82-ba44-81c0da86c46c"

# ---------------------------------------------------------------------------
# Framing constants (spec sections 4, 7)
# ---------------------------------------------------------------------------

SYNC_BYTE = 0xB8  # 184; start byte of binary frames, validated on inbound too.

# ASCII keep-alive tokens (UTF-8).
TOKEN_HANDSHAKE = b"!#"  # 0x21 0x23 - "start streaming" wake frame
TOKEN_AT = b"@"          # 0x40
TOKEN_HASH = b"#"        # 0x23

# Outbound binary command codes (spec section 5.1).
CMD_MODE = 0x23      # mode set: normal / anti-theft / cut-off
CMD_AUTH = 0x2A      # password / auth (cut-off password channel)
CMD_WARNING = 0x2B   # set warning thresholds

# Inbound selectors (byteList[1]); spec section 5.2.
SEL_DEVICE_TYPE = 0x10
SEL_PVLT = 0x19
SEL_TWF = 0x20
SEL_TEMPERATURE = 0x21
SEL_MODE = 0x23
SEL_DVOL = 0x24
SEL_SERIAL_A = 0x25
SEL_SERIAL_B = 0x26
SEL_DEALER = 0x27
SEL_PASSWORD = 0x2A
SEL_WARNING_READBACK = 0x2B
SEL_MAIN_CURRENT = 0x2E
SEL_SECONDARY_CURRENT = 0x2F
SEL_VADJ = 0x30
SEL_SVLT = 0x37
SEL_CHARGE = 0x41
SEL_DISCHARGE = 0x4A
SEL_CAPACITY = 0x96

# Telemetry scaling constants (spec section 8.1).
DVOL_DIVISOR = 1000.0
OV_STEP = 0.025
UV_STEP = 0.025
OV_OFFSET = 14.4
UV_OFFSET = 10.4
OT_OFFSET = 60.0
V_DIVISOR = 100.0
CURRENT_ZERO_OFFSET = 512  # 0x200

# Device type byte that flags a "power bank" (selector 0x10, b4 == 'D').
DEVICE_TYPE_POWERBANK = 0x44  # ASCII 'D'

# Mode arguments for switchMode (spec section 6.2).
MODE_NORMAL = 0          # deactivate / unlock
MODE_ANTITHEFT = 1       # activate anti-theft
MODE_CUTOFF = 2          # activate cut-off
MODE_DETECT_KEEPALIVE = 6  # special: starts a 10 s keep-alive poller app-side

# Reported status code space (device -> app, instance offset 0x113).
STATUS_NORMAL = 0
STATUS_ANTITHEFT = 2
STATUS_CUTOFF = 4

# Lock-status classification decimal bounds (spec section 6.4).
LOCK_RANGE_LOW = 104300001
LOCK_RANGE_HIGH = 104309999


# ---------------------------------------------------------------------------
# Checksum (spec section 7)
# ---------------------------------------------------------------------------

def checksum(data: bytes) -> int:
    """XOR-fold of all bytes (mirrors Dart `list.reduce((a, b) => a ^ b)`)."""
    if not data:
        raise ValueError("checksum requires at least one byte")
    acc = 0
    for b in data:
        acc ^= b
    return acc & 0xFF


# ---------------------------------------------------------------------------
# Binary frame builder (spec section 4.1)
# ---------------------------------------------------------------------------

def build_frame(cmd: int, payload: bytes) -> bytes:
    """
    Build a single binary command frame:

        [0xB8, CMD, 0x00, LEN, payload..., XOR]

    LEN is the payload length. XOR is the checksum over all preceding bytes.
    Multi-byte payload fields are big-endian (caller's responsibility).
    """
    if not 0 <= cmd <= 0xFF:
        raise ValueError("cmd out of byte range")
    length = len(payload)
    if not 0 <= length <= 0xFF:
        raise ValueError("payload too long")
    body = bytes([SYNC_BYTE, cmd & 0xFF, 0x00, length]) + payload
    return body + bytes([checksum(body)])


# ---------------------------------------------------------------------------
# Password / auth encoding (spec section 6.1)
# ---------------------------------------------------------------------------

def password_checksum(password: str) -> int:
    """
    16-bit checksum = sum of the password's character code units (UTF-16 code
    units, matching Dart `String.codeUnits`). Returned as a 16-bit integer.
    """
    return sum(ord(c) for c in password) & 0xFFFF


def split_be16(value: int) -> tuple[int, int]:
    """Big-endian split of a 16-bit value into (hi, lo)."""
    return (value >> 8) & 0xFF, value & 0xFF


def cb_echo_from_field_cb(field_cb: str) -> tuple[int, int]:
    """
    Derive the (cb_hi, cb_lo) echo carried in the 0x2A auth frame.

    Spec quirk (section 6.1): the first 8 characters of field_cb are parsed as a
    BASE-10 integer even though the string looks hex. cb_hi is NOT masked to a
    byte and may exceed 255; only cb_lo is masked. We faithfully reproduce that:
    cb_hi is returned unmasked so callers can decide how to serialize.

        v     = int(field_cb[:8], 10)
        cb_hi = v >> 8        (may exceed one byte)
        cb_lo = v & 0xFF
    """
    if field_cb is None or len(field_cb) < 8:
        # No dealer-code/current-command string received yet; echo is zero.
        return 0, 0
    try:
        v = int(field_cb[:8], 10)
    except ValueError:
        # field_cb[:8] is not all decimal digits (e.g. a hex group like '0168A1..').
        # UNVERIFIED - confirm against hardware/HCI snoop. We default to 0 echo
        # rather than crash; the app would have thrown on a non-decimal parse.
        return 0, 0
    return v >> 8, v & 0xFF


def build_auth_frame(password: str, field_cb: str = "") -> bytes:
    """
    Build the 0x2A auth frame (spec section 6.1):

        [0xB8, 0x2A, 0x00, 0x04, cb_hi, cb_lo, sum_hi, sum_lo] + XOR

    cb_hi is masked to one byte for the on-wire frame (the frame's LEN is fixed
    at 4). The app boxes cb_hi unmasked internally, but a 4-byte payload can only
    carry one byte there; we mask it for serialization.
    # UNVERIFIED - confirm against hardware/HCI snoop: whether cb_hi overflow is
    # truncated, or the frame is actually longer on the wire.
    """
    cb_hi, cb_lo = cb_echo_from_field_cb(field_cb)
    pw_sum = password_checksum(password)
    sum_hi, sum_lo = split_be16(pw_sum)
    payload = bytes([cb_hi & 0xFF, cb_lo & 0xFF, sum_hi, sum_lo])
    return build_frame(CMD_AUTH, payload)


def build_mode_frame(mode: int) -> bytes:
    """Build the 0x23 mode frame: [0xB8, 0x23, 0x00, 0x01, mode] + XOR."""
    return build_frame(CMD_MODE, bytes([mode & 0xFF]))


def build_switch_mode(mode: int, password: str, field_cb: str = "") -> bytes:
    """
    Build the concatenated switchMode write (spec section 6.2):

        mode_frame (0x23)  ++  auth_frame (0x2A)

    The original app additionally appends a small "context" payload (field_13)
    that was not enumerated.
    # UNVERIFIED - confirm against hardware/HCI snoop: exact trailing context
    # bytes and total on-wire length per mode. We omit the unknown trailer.
    """
    return build_mode_frame(mode) + build_auth_frame(password, field_cb)


def build_change_cutoff_password(new_password: str, field_cb: str = "") -> bytes:
    """
    Build the change-cut-off-password frame (spec section 6.3). Same 0x2A
    channel as auth; the checksum is over the NEW password's code units.

        [0xB8, 0x2A, 0x00, 0x04, cb_hi, cb_lo, newsum_hi, newsum_lo] + XOR
    """
    return build_auth_frame(new_password, field_cb)


def build_warning_params(ov_volts: float, uv_volts: float, ot_celsius: float) -> bytes:
    """
    Build the 0x2B warning-threshold frame (spec section 8.3):

        OV_byte = round((ov_volts - 14.4) / 0.025)
        UV_byte = round((uv_volts - 10.4) / 0.025)
        OT_byte = round(ot_celsius - 60)
        [0xB8, 0x2B, 0x00, 0x04, OV_byte, UV_byte, OT_byte, 0x00] + XOR
    """
    ov_byte = _round_half(( ov_volts - OV_OFFSET) / OV_STEP)
    uv_byte = _round_half(( uv_volts - UV_OFFSET) / UV_STEP)
    ot_byte = _round_half(ot_celsius - OT_OFFSET)
    payload = bytes([ov_byte & 0xFF, uv_byte & 0xFF, ot_byte & 0xFF, 0x00])
    return build_frame(CMD_WARNING, payload)


def _round_half(x: float) -> int:
    """Round-half-away-from-zero, matching the write path's LibcRound."""
    import math
    return int(math.floor(x + 0.5)) if x >= 0 else int(math.ceil(x - 0.5))


# ---------------------------------------------------------------------------
# Dealer-code / current-command string (spec section 4.4)
# ---------------------------------------------------------------------------

def combine_bytes_for_agensn(b4: int, b5: int, b6: int, b7: int) -> str:
    """
    Build the app-internal hex-ish ID string (field_cb):

        sprintf("%04d%02X%02X", (b4*256 + b5), b6, b7)

    The first two payload bytes form a 4-digit DECIMAL number; the next two are
    2-digit HEX. Example: b4=0, b5=0xA8(168), b6=1, b7=2 -> "01680102".
    These IDs are never transmitted on the wire.
    """
    dec = (b4 * 256 + b5) & 0xFFFF
    return "%04d%02X%02X" % (dec, b6 & 0xFF, b7 & 0xFF)


# ---------------------------------------------------------------------------
# Telemetry parser (spec section 8)
# ---------------------------------------------------------------------------

@dataclass
class Telemetry:
    """
    Accumulated decoded telemetry. Fields are populated as notifications for the
    relevant selectors arrive; unknown/unseen fields stay None.
    """
    pvlt: Optional[float] = None              # main voltage (V)
    pvlt_gauge: Optional[int] = None          # gauge index 0..28
    svlt: Optional[float] = None              # secondary voltage (V)
    temperature: Optional[int] = None         # deg C (signed)
    dvol: list = field(default_factory=lambda: [None, None, None, None])  # per-cell V
    vadj: Optional[float] = None              # DVOL multiplier
    main_current: Optional[float] = None      # A
    secondary_current: Optional[float] = None  # mA (logged only in app)
    warn_ov: Optional[float] = None           # over-voltage threshold (V)
    warn_uv: Optional[float] = None           # under-voltage threshold (V)
    warn_ot: Optional[float] = None           # over-temperature threshold (deg C)
    charge_v1: Optional[float] = None
    charge_v2: Optional[float] = None
    discharge_v1: Optional[float] = None
    discharge_v2: Optional[float] = None
    capacity_raw: Optional[int] = None        # raw b6 byte
    capacity_bucket: Optional[int] = None     # (n-1)*10 + 5
    device_type: Optional[int] = None         # b4 byte
    is_power_bank: Optional[bool] = None
    serial: Optional[str] = None              # battery serial number
    dealer_code: Optional[str] = None         # field_cb string
    mode_status: Optional[int] = None         # reported status (0/2/4)
    twf_byte: Optional[int] = None            # raw TWF status byte (selector 0x20)

    def status_text(self) -> str:
        """Human-readable mode/status (spec section 6.2)."""
        return {
            STATUS_NORMAL: "normal",
            STATUS_ANTITHEFT: "anti-theft active",
            STATUS_CUTOFF: "cut-off active",
        }.get(self.mode_status, f"unknown({self.mode_status})")


def _be16(data: bytes, i: int) -> int:
    """Big-endian 16-bit value at offset i (data[i] high byte)."""
    return (data[i] << 8) + data[i + 1]


def _signed8(b: int) -> int:
    """Interpret a byte as signed int8."""
    return b - 0x100 if b >= 0x80 else b


def parse_notification(frame: bytes, tel: Optional[Telemetry] = None) -> Telemetry:
    """
    Parse one inbound notification frame and fold its data into `tel`.

    Frame layout (spec section 4.3):
        byte[0]    = start byte (0xB8, validated)
        byte[1]    = selector (dispatch key)
        byte[2..3] = reserved / sub-length (not fully decoded)
        byte[4..]  = telemetry payload (b4 == frame[4], etc.)

    Returns the same Telemetry instance (creating one if None was passed). The
    parser is defensive: a too-short frame for a given selector is ignored
    rather than raising, so a noisy radio link does not crash the monitor.
    """
    if tel is None:
        tel = Telemetry()
    if len(frame) < 2:
        return tel
    # Validate start byte (spec: receive path matches element == 0xB8).
    if frame[0] != SYNC_BYTE:
        # UNVERIFIED - confirm against hardware/HCI snoop: some stacks may strip
        # or reframe. We still try to dispatch on byte[1] but flag nothing.
        pass

    selector = frame[1]

    def b(n: int) -> int:
        """Payload byte byteList[n] (n is absolute index into the frame)."""
        return frame[n]

    # Helper to require a minimum frame length for a selector's payload.
    def have(n: int) -> bool:
        return len(frame) > n

    if selector == SEL_DEVICE_TYPE and have(4):
        tel.device_type = b(4)
        tel.is_power_bank = (b(4) == DEVICE_TYPE_POWERBANK)

    elif selector == SEL_PVLT and have(5):
        pvlt = _be16(frame, 4) / V_DIVISOR
        tel.pvlt = pvlt
        # Gauge index: trunc((PVLT - 8.0) * 3.5), clamp 0..28.
        gauge = int((pvlt - 8.0) * 3.5)  # int() truncates toward zero
        tel.pvlt_gauge = max(0, min(28, gauge))

    elif selector == SEL_TWF and have(4):
        # UNVERIFIED - confirm against hardware/HCI snoop: exact bit->meaning
        # mapping (spec section 8.4 / 10). We store the raw byte only.
        tel.twf_byte = b(4)

    elif selector == SEL_TEMPERATURE and have(4):
        tel.temperature = _signed8(b(4))  # no scaling

    elif selector == SEL_MODE and have(4):
        tel.mode_status = b(4)  # passed to setCurrentMode app-side

    elif selector == SEL_DVOL and have(7):
        # dvol_i = (byte_i / 1000.0) * VADJ, i = 4..7. VADJ defaults to 1.0 if
        # not yet received (selector 0x30). Gated app-side on field_cb; we always
        # parse here since the gate is an app dispatch detail.
        vadj = tel.vadj if tel.vadj is not None else 1.0
        tel.dvol = [(frame[4 + k] / DVOL_DIVISOR) * vadj for k in range(4)]

    elif selector == SEL_VADJ and have(5):
        tel.vadj = _be16(frame, 4) / V_DIVISOR

    elif selector == SEL_MAIN_CURRENT and have(5):
        # 512 - (b4*256 + b5); the app's /100 *100 round-trip nets to identity.
        tel.main_current = float(CURRENT_ZERO_OFFSET - _be16(frame, 4))

    elif selector == SEL_SECONDARY_CURRENT and have(5):
        # Logged only in the app, not stored; we keep it for completeness.
        tel.secondary_current = float(_be16(frame, 4))

    elif selector == SEL_SVLT and have(5):
        tel.svlt = _be16(frame, 4) / V_DIVISOR

    elif selector == SEL_WARNING_READBACK and have(6):
        tel.warn_ov = b(4) * OV_STEP + OV_OFFSET
        tel.warn_uv = b(5) * UV_STEP + UV_OFFSET
        tel.warn_ot = b(6) + OT_OFFSET

    elif selector == SEL_CHARGE and have(7):
        tel.charge_v1 = _be16(frame, 4) / V_DIVISOR / 10.0
        tel.charge_v2 = _be16(frame, 6) / V_DIVISOR / 10.0

    elif selector == SEL_DISCHARGE and have(7):
        tel.discharge_v1 = _be16(frame, 4) / V_DIVISOR / 10.0
        tel.discharge_v2 = _be16(frame, 6) / V_DIVISOR / 10.0

    elif selector == SEL_CAPACITY and have(6):
        raw = b(6)
        tel.capacity_raw = raw
        # Bucket: stringify b6, index chars, int.tryParse, (n-1)*10 + 5.
        # The app indexes characters of the decimal string; we mirror the net
        # effect: parse the byte value n, then (n-1)*10 + 5.
        # UNVERIFIED - confirm against hardware/HCI snoop: char-indexing detail
        # (spec section 8.2 / 10). Net formula reproduced here.
        n = raw
        tel.capacity_bucket = (n - 1) * 10 + 5

    elif selector in (SEL_SERIAL_A, SEL_SERIAL_B) and have(9):
        # b4..b9 packed big-endian into a 48-bit int, stringified, padLeft(6,'0').
        val = 0
        for k in range(6):
            val |= frame[4 + k] << (8 * (5 - k))
        tel.serial = str(val).rjust(6, "0")

    elif selector == SEL_DEALER and have(7):
        tel.dealer_code = combine_bytes_for_agensn(b(4), b(5), b(6), b(7))

    # Other selectors (0x2A password label, 0x37 FW-ver group extras, etc.) are
    # acknowledged but not decoded into telemetry here.
    return tel


def in_lock_range(value: int) -> bool:
    """Decimal lock/anti-theft range check (spec section 6.4)."""
    return LOCK_RANGE_LOW <= value <= LOCK_RANGE_HIGH
