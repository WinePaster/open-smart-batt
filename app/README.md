# open-smart-batt

An independent, open-source (**GPLv3**) BLE client for the **RCE iBatt** smart
battery, written in Python with [`bleak`](https://github.com/hbldh/bleak) so it
runs cross-platform (developed/tested target: **Linux** with a BLE adapter).

This is a **clean-room interoperability** implementation built **solely** from a
published functional protocol specification (UUIDs, command-byte layouts,
checksum, telemetry scaling formulas). It contains no vendor source, assets, or
UI text. It is **not affiliated with or endorsed by** the original (defunct)
vendor. Its purpose is right-to-repair: letting owners keep talking to hardware
they already own.

## Install

Requires Python 3.9+ and a working BlueZ/BLE stack on Linux.

```bash
cd open-smart-batt/app
python3 -m venv .venv
source .venv/bin/activate
pip install -e .          # installs the `rce-batt` console command
# or: pip install -r requirements.txt
```

On Linux, BLE scanning may need permission. Either run with `sudo`, or grant the
Python interpreter the capability once:

```bash
sudo setcap 'cap_net_raw,cap_net_admin+eip' "$(readlink -f "$(which python3)")"
```

## Usage

```bash
# Discover batteries (filters on the vendor service UUID only; no name filter)
rce-batt scan

# One-shot snapshot (streams a few seconds, then prints decoded telemetry)
rce-batt info <ADDRESS>

# Live telemetry until Ctrl-C
rce-batt monitor <ADDRESS>

# Mode changes (require the cut-off password; auth proves knowledge via checksum)
rce-batt unlock    <ADDRESS> --password 1234   # deactivate / normal (mode 0)
rce-batt antitheft <ADDRESS> --password 1234   # activate anti-theft (mode 1)
rce-batt cutoff    <ADDRESS> --password 1234   # activate cut-off    (mode 2)

# Increase log detail with -v / -vv
rce-batt -vv monitor <ADDRESS>
```

`<ADDRESS>` is the BLE device address shown by `scan` (a MAC on Linux).

## How it works

* **Scan** filters purely on the 128-bit service UUID
  `07b9fff0-d55f-5e82-ba44-81c0da86c46c` (no device-name filter).
* **Connect** uses the default ATT MTU (23 -> 20-byte payload); every command
  fits in 20 bytes, so no MTU negotiation is performed.
* **Subscribe first, then poll.** After connecting, the client subscribes to the
  notify characteristic, then starts a 1 Hz keep-alive. Tick 1 sends the `!#`
  handshake ("start streaming"); subsequent ticks rotate `#` / `@` / `!#`.
* **Telemetry** notifications are dispatched on `byteList[1]` (the selector) and
  decoded with the documented scaling formulas (PVLT, SVLT, temperature, DVOL,
  VADJ, currents, charge/discharge, capacity, serial, dealer code, mode/status,
  warning thresholds).
* **Commands** are binary frames `[0xB8, CMD, 0x00, LEN, payload..., XOR]` with an
  XOR-fold checksum, written **Write Without Response**. `switchMode` concatenates
  the mode frame (`0x23`) and the auth frame (`0x2A`) in a single write.
* **Auth** never sends the password in plaintext: the `0x2A` frame carries a
  16-bit checksum (sum of password code units, big-endian) plus an echo value
  derived from the received dealer-code string.

## What works vs. needs hardware confirmation

The spec marks several items as unverified. These are implemented with sensible
defaults and flagged in code with `# UNVERIFIED - confirm against
hardware/HCI snoop`:

| Area | Status |
|---|---|
| Service UUID scan filter, write characteristic UUID | Documented; implemented as-is |
| Binary frame layout + XOR checksum | Documented; implemented as-is |
| 1 Hz keep-alive token rotation | Documented; implemented as-is |
| Telemetry scaling formulas (PVLT/SVLT/temp/DVOL/VADJ/current/charge/discharge/capacity/serial/dealer/mode/warnings) | Documented; implemented as-is |
| **Notify characteristic UUID** | **Not in spec** — selected at runtime by the "notify" property flag. Confirm with an HCI snoop. |
| **Service containing write/notify chars** | Presumed `07b9fff0`; resolved dynamically from discovery. |
| **TWF status bit -> meaning (selector 0x20)** | Raw byte stored only; bit map unverified. |
| **switchMode trailing "context" payload / total length** | Omitted; only the mode+auth frames are sent. Confirm exact trailer on hardware. |
| **Poll-side device-type comparison tag** | Implemented as ASCII `'D'` (0x44); a disputed Smi-tag reading exists. |
| **Capacity/SOH bucket meaning** `(n-1)*10+5` | Computed; whether it is SOH%/SOC%/cycle bucket is unknown. |
| **Initial "detect" command bytes** | Not isolated in the spec; not sent. The `!#` handshake is used to start streaming. |
| **`cb_hi` overflow in auth echo** | App parses an 8-char string as decimal (can exceed one byte); we mask to one byte on the wire. Confirm. |

Until validated against a real device + HCI snoop, treat mode-change/auth
commands as **experimental**. Reading telemetry is the lowest-risk operation.

## Library use

```python
import asyncio
from rce_batt import RceBattClient, scan

async def main():
    devices = await scan()
    async with RceBattClient(devices[0]) as c:
        c.cutoff_password = "1234"
        await c.start()
        await asyncio.sleep(6)
        print(c.telemetry)

asyncio.run(main())
```

## License

GPLv3. See the `license` field in `pyproject.toml`. This software is provided for
interoperability and right-to-repair purposes, without warranty.
