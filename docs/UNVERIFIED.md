# 待硬體確認清單 (Unverified — needs live-device / HCI capture)

> 這些項目靜態分析無法 100% 確定，需用 HCI snoop log 或 nRF Connect 對實機驗證。

- Notify characteristic UUID is not in the binary (capability-flag selected); needs live-device capture.
- Whether write/notify characteristics reside under service 07b9fff0 is inferred from shared base, not byte-proven (serviceId read dynamically from discovery).
- TWF status-flag bit mapping (selector 0x20): code indexes bits [14],[12],[6],[4] which require a >=15-char string, contradicting the single-byte/8-bit source — bit-to-meaning unreliable.
- Exact on-wire bytes of the initial connect-time 'detect' command (sets isSentDetect 0x3c) not isolated.
- Per-code meaning of param-set acks 0211-0214 (OV/UV/OT/threshold) inferred; all four set the same flag at offset 0x133.
- 1Hz poll device-type comparison: disputed whether it tests ASCII 'D' (0x44) or a Smi-tagged value (effective 34/0x22).
- switchMode concatenates mode+auth frames with an extra context payload; exact total on-wire length/trailing bytes per mode not enumerated.
- Inbound frame bytes[2]/[3] (sub-command vs length) and the link between the 0xB8 sync byte and synthesized 0168xx app IDs not fully decoded.
- Capacity/SOH bucket (n-1)*10+5 semantics (SOH%/SOC%/cycle) unknown.
- Full inbound read-selector enumeration incomplete (FW version, rectifier-gear, PowerBank Command 7, etc.).
