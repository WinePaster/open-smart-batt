"""
Command-line interface for the RCE iBatt community client.

Subcommands:
    scan                 list nearby iBatt batteries (filtered by service UUID)
    info     <addr>      connect, stream briefly, print a one-shot snapshot
    monitor  <addr>      connect and print live telemetry until Ctrl-C
    unlock   <addr> --password PW   deactivate anti-theft / cut-off (mode 0)
    antitheft<addr> --password PW   activate anti-theft (mode 1)
    cutoff   <addr> --password PW   activate cut-off (mode 2)

Run with --help on any subcommand for details.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from . import protocol as proto
from .client import RceBattClient, scan


def _fmt(v, unit="", nd=2):
    """Format an optional numeric telemetry value, marking unseen ones."""
    if v is None:
        return "--"
    if isinstance(v, float):
        return f"{v:.{nd}f}{unit}"
    return f"{v}{unit}"


def _render(tel) -> str:
    """Render an accumulated Telemetry snapshot as a multi-line block."""
    dvol = " ".join(_fmt(x, "V", 3) for x in tel.dvol)
    lines = [
        f"  device type   : {_fmt(tel.device_type)}"
        + ("  (power bank)" if tel.is_power_bank else ""),
        f"  serial        : {tel.serial or '--'}",
        f"  dealer code   : {tel.dealer_code or '--'}",
        f"  mode/status   : {tel.status_text()}",
        f"  PVLT (main V) : {_fmt(tel.pvlt, 'V')}   gauge {_fmt(tel.pvlt_gauge)}",
        f"  SVLT (sec V)  : {_fmt(tel.svlt, 'V')}",
        f"  temperature   : {_fmt(tel.temperature, 'C')}",
        f"  main current  : {_fmt(tel.main_current, 'A')}",
        f"  sec current   : {_fmt(tel.secondary_current, 'mA')}",
        f"  DVOL cells    : {dvol}",
        f"  VADJ          : {_fmt(tel.vadj)}",
        f"  charge v1/v2  : {_fmt(tel.charge_v1,'',3)} / {_fmt(tel.charge_v2,'',3)}",
        f"  dischg v1/v2  : {_fmt(tel.discharge_v1,'',3)} / {_fmt(tel.discharge_v2,'',3)}",
        f"  capacity raw  : {_fmt(tel.capacity_raw)}   bucket {_fmt(tel.capacity_bucket)}"
        " (SOH/SOC? UNVERIFIED)",
        f"  warn OV/UV/OT : {_fmt(tel.warn_ov,'V')} / {_fmt(tel.warn_uv,'V')}"
        f" / {_fmt(tel.warn_ot,'C')}",
    ]
    twf = "--" if tel.twf_byte is None else f"0x{tel.twf_byte:02X} (bit map UNVERIFIED)"
    lines.append(f"  TWF flags     : {twf}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Subcommand implementations
# ---------------------------------------------------------------------------

async def cmd_scan(args) -> int:
    print(f"scanning {args.timeout:.0f}s for service {proto.SERVICE_UUID} ...")
    devices = await scan(timeout=args.timeout)
    if not devices:
        print("no iBatt batteries found (need a BLE adapter + battery in range)")
        return 1
    for d in devices:
        name = d.name or "(no name)"
        print(f"  {d.address}   {name}")
    return 0


async def _connected_session(args):
    """Connect, start streaming, and yield the running client."""
    client = RceBattClient(args.address)
    if getattr(args, "password", None):
        client.cutoff_password = args.password
    await client.connect()
    await client.start()
    return client


async def cmd_info(args) -> int:
    client = await _connected_session(args)
    try:
        # Stream a few seconds so several selectors arrive before snapshotting.
        await asyncio.sleep(args.duration)
        print("snapshot:")
        print(_render(client.telemetry))
    finally:
        await client.disconnect()
    return 0


async def cmd_monitor(args) -> int:
    client = await _connected_session(args)
    print("live telemetry (Ctrl-C to stop)\n")
    try:
        while True:
            await asyncio.sleep(1.0)
            # Repaint: clear screen then render the accumulated snapshot.
            sys.stdout.write("\033[2J\033[H")
            sys.stdout.write(_render(client.telemetry) + "\n")
            sys.stdout.flush()
    except (KeyboardInterrupt, asyncio.CancelledError):
        print("\nstopping.")
    finally:
        await client.disconnect()
    return 0


async def cmd_mode(args, mode: int, label: str) -> int:
    """Shared handler for unlock / antitheft / cutoff."""
    client = await _connected_session(args)
    try:
        # Let a few notifications arrive so field_cb (dealer code echo) is known
        # before we send the auth-bearing mode command.
        await asyncio.sleep(args.settle)
        print(f"sending {label} (mode {mode}) ...")
        await client.switch_mode(mode, args.password)
        # Give the battery time to report new status back.
        await asyncio.sleep(args.settle)
        print(f"reported status: {client.telemetry.status_text()}")
        print(
            "note: exact switchMode on-wire context trailer is UNVERIFIED - "
            "confirm against hardware/HCI snoop."
        )
    finally:
        await client.disconnect()
    return 0


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rce-batt",
        description="Community BLE client for the RCE iBatt smart battery "
        "(clean-room, unofficial).",
    )
    p.add_argument("-v", "--verbose", action="count", default=0,
                   help="increase log verbosity (-v, -vv)")
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("scan", help="list nearby iBatt batteries")
    sp.add_argument("--timeout", type=float, default=8.0, help="scan seconds")
    sp.set_defaults(func=cmd_scan)

    sp = sub.add_parser("info", help="one-shot telemetry snapshot")
    sp.add_argument("address", help="BLE device address/id")
    sp.add_argument("--duration", type=float, default=6.0,
                    help="seconds to stream before snapshot")
    sp.set_defaults(func=cmd_info)

    sp = sub.add_parser("monitor", help="live telemetry until Ctrl-C")
    sp.add_argument("address", help="BLE device address/id")
    sp.set_defaults(func=cmd_monitor)

    # Mode-change subcommands share a password and settle time.
    for name, mode, label, helptext in (
        ("unlock", proto.MODE_NORMAL, "unlock/normal", "deactivate anti-theft/cut-off"),
        ("antitheft", proto.MODE_ANTITHEFT, "anti-theft", "activate anti-theft"),
        ("cutoff", proto.MODE_CUTOFF, "cut-off", "activate power cut-off"),
    ):
        sp = sub.add_parser(name, help=helptext)
        sp.add_argument("address", help="BLE device address/id")
        sp.add_argument("--password", required=True,
                        help="cut-off password (proves auth via checksum)")
        sp.add_argument("--settle", type=float, default=4.0,
                        help="seconds to wait before/after the command")
        sp.set_defaults(func=lambda a, m=mode, l=label: cmd_mode(a, m, l))

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    level = logging.WARNING - min(args.verbose, 2) * 10
    logging.basicConfig(level=level, format="%(levelname)s %(name)s: %(message)s")
    try:
        return asyncio.run(args.func(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
