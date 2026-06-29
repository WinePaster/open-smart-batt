"""
rce_batt - community clean-room BLE client for the RCE iBatt smart battery.

This package is an independent, open-source interoperability implementation
built solely from a published functional protocol specification. It is not
affiliated with or endorsed by the original (defunct) vendor.
"""

from .protocol import (
    SERVICE_UUID,
    WRITE_CHAR_UUID,
    Telemetry,
    build_frame,
    build_switch_mode,
    build_warning_params,
    parse_notification,
)
from .client import RceBattClient, scan

__version__ = "0.1.0"

__all__ = [
    "SERVICE_UUID",
    "WRITE_CHAR_UUID",
    "Telemetry",
    "build_frame",
    "build_switch_mode",
    "build_warning_params",
    "parse_notification",
    "RceBattClient",
    "scan",
    "__version__",
]
