# OpenSmartBatt

> Community self-help · Right-to-repair · Independent clean-room reimplementation
> An Android / iOS app (Flutter) + protocol documentation to keep monitoring RCE smart
> capacitors/batteries after the vendor's cloud shutdown.

**中文版 → [README.md](./README.md)**

---

## What this is

A community **right-to-repair** project run by the **owners/holders** of RCE iBatt
hardware. The original vendor — **RCE 低碳動能開發股份有限公司** (RCE Low-Carbon Energy
Development Co., Ltd., "iBatt" brand) — [announced its closure on its official
Facebook page](https://www.facebook.com/rce168/posts/pfbid08erjAACc445fd3eZargF8EnF84wBeP22cwutPyhwSguDDKPbLsGR6wJzXhVx5LE7l?locale=zh_TW),
and its official app and cloud service are no longer maintained, leaving many
**already-purchased** devices unable to be configured, monitored, or used. This
project provides a **freshly written** client so those devices can keep being used
by their lawful owners.

## Important statement

- This is an **independent clean-room reimplementation**, written solely from
  **publicly observable protocol facts**, not by copying the vendor's code.
- This project is **not affiliated with, endorsed by, or licensed by** RCE 低碳動能開發股份有限公司
  (RCE Low-Carbon Energy Development Co., Ltd.), its affiliates, or any successor.
- This project is **non-commercial**. Its only purpose is to help owners of
  **already-purchased** RCE hardware exercise their right to repair.
- We **do not distribute** any of the original app's code, assets, icons, or strings.
- Protocol facts and data formats are functional facts generally not protected by
  copyright; see [`COPYRIGHT.md`](./COPYRIGHT.md).

## Naming

The project and the app share one neutral name: **OpenSmartBatt** (repo `open-smart-batt`, bundle id / applicationId `com.winepaster.openSmartBatt`, Dart package `open_smart_batt`). The name is deliberately neutral / non-trademarked to avoid App Store / TestFlight rejection of a non-brand-holder over the vendor's trademarks (Guideline 4.1 / 5.2).

**"RCE" is the hardware, not the app.** OpenSmartBatt is a community client *compatible with* RCE (RCE 低碳動能開發股份有限公司 / "iBatt" brand) low-carbon capacitors/batteries. References to `RCE` in the code and docs (BLE device-name match, the non-affiliation disclaimer, "compatible with RCE devices") are functional / nominative fair use — describing the target hardware, not claiming the vendor's brand. This project is not affiliated with, endorsed by, or licensed by RCE 低碳動能開發股份有限公司, its affiliates, or any successor.

## Repository structure

```
open-smart-batt/
├── README.md / README.en.md      docs (zh / en)
├── LICENSE / COPYRIGHT / CLEANROOM / CONTRIBUTING
├── docs/
│   ├── PROTOCOL.md               protocol INDEX (§ → file; holds no facts itself)
│   ├── protocol/                 the spec, in nine topic files (facts; clean-room analysis role)
│   └── VERSIONING.md             version scheme
├── app_flutter/                  ★ Android / iOS app (Flutter, written from the spec)
├── tools/parse_btsnoop.py        btsnoop → GATT extractor (privacy-safe)
├── mockup/index.html             UI design preview
└── .github/workflows/            CI (Android + iOS compile smoke test) + auto-versioned APK / IPA release
```

`docs/` holds the protocol spec & verification (**facts**). `app_flutter/` and `app/`
are written **only** from `docs/`, never touching the original app.

## Status (2026-08-31)

- ✅ Android / iOS app implemented: BLE connect, live telemetry dashboard, device list +
  aliases, history + CSV export, settings (incl. a default-OFF diagnostic log).
  `flutter analyze` clean, **2,509 unit tests pass**, release APK and iOS archive build.
- ✅ **Monitoring needs no password**: once connected you see voltage / temp / SOH /
  capacitor check (telemetry streams without auth).
- ⚠️ **Super-capacitor**: monitoring + capacitor-check focused. `cut-off / anti-theft`
  are battery-class features; clearing a capacitor "abnormal protection lock" is not
  implemented yet (needs an HCI capture from a faulty unit).
- 🧪 The release command supports three paths — enter the cut-off password, enter the
  validation values directly (cb/pwSum), or an experimental "send mode only, skip
  auth". Whether a release actually takes effect must be verified electrically.

## Install

### Android

- **Build from source (recommended)**: install Flutter, then
  `cd app_flutter && flutter build apk --release`; the APK lands in
  `build/app/outputs/flutter-apk/`.
- Or download the APK straight from
  [GitHub Releases](https://github.com/WinePaster/open-smart-batt/releases) (built by CI,
  published with a SHA256).
- 🔑 **When sideloading, check the signing certificate — not just the file hash.** Since
  `v0.6.10` every release is signed with the **same stable release key**. (Before that
  each build generated a throwaway debug key, so every release carried a different
  certificate, Android refused to update in place, and the only way forward was to
  uninstall — which wipes the history the app exists to collect.)

  ```
  apksigner verify --print-certs open-smart-batt-<version>.apk
  # certificate SHA-256 must be
  # eabe10efb4512cef6debdd171e2bb07ff95e54eccc2702ffaa6d6b94302b8063
  ```

  **The certificate is identical on every release; the file hash is different on every
  release** — so for "did this file come from this project?", the certificate is the
  stronger test. CI also asserts the APK is not debug-signed and fails the build if it is.
- Android can be **sideloaded onto any device with no account**.

### iOS

> **App store name: `OpenSmartBatt`** (bundle id `com.winepaster.openSmartBatt`).
> The iOS build deliberately uses a neutral, non-trademarked app identity to avoid
> App Store rejection of a non-brand-holder over the vendor's marks (RCE/iBatt;
> Guideline 4.1/5.2). The project (repo `open-smart-batt`) is still a community client
> **compatible with RCE 低碳動能 hardware** — stating "compatible with RCE devices" is
> nominative fair use and does not conflict with a neutral app identity.

- iOS must be built from source on **macOS + Xcode**: `cd app_flutter && flutter build ios`
  (contributors can verify locally with `--no-codesign`, no Apple account needed).
- **iOS has no account-free install path like Android's.** Apple platforms do not allow
  arbitrary account-free sideloading:
  - **TestFlight**: requires the maintainer's **paid Apple Developer account**, passing
    Beta App Review; each build expires after 90 days; external testing is capped at
    10000 testers.
  - **App Store**: requires full review + the $99/year account.
  - A free Apple ID local sideload lasts only 7 days and requires **the user** to own a
    Mac + Xcode to re-sign.
- In short: **an owner with only an iPhone and no Mac/Apple account has no directly
  installable path on iOS.** Set expectations accordingly — do not assume parity with the
  Android APK flow. See [`docs/VERSIONING.md`](./docs/VERSIONING.md) for the iOS version /
  IPA notes.

## Safety note

- **Always compile from source yourself.** Do not run unverified pre-built binaries.
- This software interacts with battery hardware; use it understanding the risks.
  Incorrect configuration may affect battery behavior.
- After releasing a cut-off / lock, **do not re-lock**; the device's own
  over-/under-voltage and over-temperature protections remain active.
- The software comes with no warranty; see [`LICENSE`](./LICENSE).

## License

The code is licensed under **GNU GPLv3** (see [`LICENSE`](./LICENSE)). Distributing a
derivative or a modified APK requires releasing it under GPLv3 too — keeping this
community self-help tool open for the community and preventing it from being
re-closed or commercialized. The protocol docs (`docs/`) are functional facts, not
subject to copyright.

## Protocol documentation

Full spec: [`docs/PROTOCOL.md`](./docs/PROTOCOL.md) (an index; the spec itself lives in
the nine topic files under [`docs/protocol/`](./docs/protocol/)).

---

*"RCE" and "iBatt" are trademarks of their respective owners and are used here only
nominatively, to describe hardware compatibility. See [`COPYRIGHT.md`](./COPYRIGHT.md).*
