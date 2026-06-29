"""
Async bleak client for the RCE iBatt smart battery.

Implements the session/transport behavior from the protocol spec:

  * Scan filtered by the single 128-bit service UUID (no name filter).
  * Connect (default ATT MTU; all commands fit in 20 bytes).
  * Subscribe to the notify characteristic FIRST, then start the 1 Hz poll.
  * First write after subscribe is the "!#" handshake (start streaming).
  * 1 Hz keep-alive token rotation drives telemetry notifications.
  * switchMode / unlock / cut-off / change-password command flows.

Clean-room implementation from the published spec only.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Callable, Optional

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

from . import protocol as proto
from .protocol import Telemetry

log = logging.getLogger("rce_batt.client")


async def scan(timeout: float = 8.0) -> list[BLEDevice]:
    """
    Scan for iBatt batteries, filtering purely on the vendor service UUID.

    Per spec there is NO device-name filter; results are deduplicated by device
    id. bleak's `service_uuids` filter maps to the platform scan filter where
    supported; we also post-filter on advertised service UUIDs for robustness.
    """
    found: dict[str, BLEDevice] = {}

    def detection(device: BLEDevice, adv) -> None:
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        if proto.SERVICE_UUID.lower() in uuids:
            found[device.address] = device

    scanner = BleakScanner(
        detection_callback=detection,
        service_uuids=[proto.SERVICE_UUID],
    )
    await scanner.start()
    try:
        await asyncio.sleep(timeout)
    finally:
        await scanner.stop()

    # Some backends do not populate adv.service_uuids reliably; if the targeted
    # filter found nothing, fall back to discover() results that advertised it.
    if not found:
        devices = await BleakScanner.discover(
            timeout=timeout, service_uuids=[proto.SERVICE_UUID]
        )
        for d in devices:
            found[d.address] = d

    return list(found.values())


class RceBattClient:
    """
    Connected session to one battery.

    Usage:
        async with RceBattClient(device_or_address) as c:
            await c.start()              # subscribe + 1 Hz poll
            await asyncio.sleep(10)
            print(c.telemetry)
    """

    def __init__(
        self,
        device,
        on_telemetry: Optional[Callable[[Telemetry], None]] = None,
    ) -> None:
        self._device = device
        self._client = BleakClient(device)
        self._notify_char = None  # resolved at connect time
        self._poll_task: Optional[asyncio.Task] = None
        self._tick = 0
        self.telemetry = Telemetry()
        self._on_telemetry = on_telemetry
        # Cut-off password is supplied by the caller for auth-bearing commands.
        self.cutoff_password: str = ""

    # -- connection lifecycle ------------------------------------------------

    async def __aenter__(self) -> "RceBattClient":
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self.disconnect()

    async def connect(self) -> None:
        """Connect and resolve the write/notify characteristics."""
        log.info("connecting to %s", self._device)
        await self._client.connect()
        self._resolve_characteristics()

    async def disconnect(self) -> None:
        """Cancel the poll timer and disconnect."""
        if self._poll_task is not None:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
            self._poll_task = None
        try:
            if self._client.is_connected:
                await self._client.disconnect()
        except Exception as e:  # teardown best-effort
            log.debug("disconnect error: %s", e)

    def _resolve_characteristics(self) -> None:
        """
        Locate the write characteristic by its exact UUID, and the notify
        characteristic by its 'notify' property flag (spec section 3).
        """
        services = self._client.services
        # Write characteristic: exact UUID match.
        wc = services.get_characteristic(proto.WRITE_CHAR_UUID)
        if wc is None:
            raise RuntimeError(
                f"write characteristic {proto.WRITE_CHAR_UUID} not found"
            )
        self._write_char = wc

        # Notify characteristic: selected by property flag, not UUID.
        notify = None
        for service in services:
            for char in service.characteristics:
                props = set(char.properties)
                if "notify" in props or "indicate" in props:
                    notify = char
                    break
            if notify:
                break
        if notify is None and proto.NOTIFY_CHAR_UUID_HINT:
            notify = services.get_characteristic(proto.NOTIFY_CHAR_UUID_HINT)
        if notify is None:
            raise RuntimeError("no notifiable characteristic found")
        self._notify_char = notify
        log.info("notify characteristic: %s", notify.uuid)

    # -- write helpers -------------------------------------------------------

    async def _write(self, data: bytes) -> None:
        """Write Without Response (ATT Write Command) -- the only write type."""
        await self._client.write_gatt_char(self._write_char, data, response=False)
        log.debug("wrote %s", data.hex())

    # -- notifications -------------------------------------------------------

    def _handle_notify(self, _char, data: bytearray) -> None:
        """Notification handler: decode the frame into accumulated telemetry."""
        frame = bytes(data)
        log.debug("notify %s", frame.hex())
        proto.parse_notification(frame, self.telemetry)
        # Mirror the dealer-code field into field_cb used by auth echo.
        if self.telemetry.dealer_code:
            self._field_cb = self.telemetry.dealer_code
        if self._on_telemetry:
            try:
                self._on_telemetry(self.telemetry)
            except Exception as e:
                log.debug("on_telemetry callback error: %s", e)

    _field_cb: str = ""

    # -- start / poll --------------------------------------------------------

    async def start(self) -> None:
        """
        Subscribe to notifications FIRST, then start the 1 Hz keep-alive poll
        (spec sections 2). The poll's tick 1 sends the "!#" handshake.
        """
        await self._client.start_notify(self._notify_char, self._handle_notify)
        self._tick = 0
        self._poll_task = asyncio.create_task(self._poll_loop())

    async def _poll_loop(self) -> None:
        """
        1 Hz keep-alive token rotation (spec section 2):

            tick == 1                        -> "!#"
            counter % 25 == 0                -> "@"
            device_type == 'D' and %5 == 0   -> "!#"
            otherwise                        -> "#"
        """
        try:
            while True:
                self._tick += 1
                tick = self._tick
                if tick == 1:
                    token = proto.TOKEN_HANDSHAKE
                elif tick % 25 == 0:
                    token = proto.TOKEN_AT
                elif self.telemetry.device_type == proto.DEVICE_TYPE_POWERBANK and tick % 5 == 0:
                    # UNVERIFIED - confirm against hardware/HCI snoop: poll-side
                    # device-type comparison may use a Smi-tagged value (spec s10).
                    token = proto.TOKEN_HANDSHAKE
                else:
                    token = proto.TOKEN_HASH
                try:
                    await self._write(token)
                except Exception as e:
                    log.debug("poll write error: %s", e)
                    break
                await asyncio.sleep(1.0)
        except asyncio.CancelledError:
            raise

    # -- command flows -------------------------------------------------------

    async def switch_mode(self, mode: int, password: Optional[str] = None) -> None:
        """
        Send a switchMode command: mode frame (0x23) concatenated with the auth
        frame (0x2A) in a single write (spec section 6.2).
        """
        pw = password if password is not None else self.cutoff_password
        field_cb = self._field_cb or self.telemetry.dealer_code or ""
        frame = proto.build_switch_mode(mode, pw, field_cb)
        await self._write(frame)

    async def unlock(self, password: Optional[str] = None) -> None:
        """Deactivate / unlock (mode 0)."""
        await self.switch_mode(proto.MODE_NORMAL, password)

    async def activate_antitheft(self, password: Optional[str] = None) -> None:
        """Activate anti-theft (mode 1)."""
        await self.switch_mode(proto.MODE_ANTITHEFT, password)

    async def activate_cutoff(self, password: Optional[str] = None) -> None:
        """Activate cut-off (mode 2)."""
        await self.switch_mode(proto.MODE_CUTOFF, password)

    async def change_cutoff_password(
        self, new_password: str, current_password: Optional[str] = None
    ) -> None:
        """
        Change the cut-off password (spec section 6.3). Uses the 0x2A channel;
        checksum is over the NEW password's code units.
        """
        field_cb = self._field_cb or self.telemetry.dealer_code or ""
        frame = proto.build_change_cutoff_password(new_password, field_cb)
        await self._write(frame)

    async def set_warning_params(
        self, ov_volts: float, uv_volts: float, ot_celsius: float
    ) -> None:
        """Write over-voltage / under-voltage / over-temperature thresholds (0x2B)."""
        frame = proto.build_warning_params(ov_volts, uv_volts, ot_celsius)
        await self._write(frame)
