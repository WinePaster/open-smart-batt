# RCE iBatt Community Self-Help Project

> 社群自助 · 維修權 · 獨立淨室重製
> Community self-help · Right-to-repair · Independent clean-room reimplementation

---

## 繁體中文

### 這是什麼

這是一個由電池硬體**車主／持有者**自發組成的社群維修專案。原廠 RCE（iBatt 電池）已停止營運，原有的官方 App 也無人維護，導致大量「已經購買」的硬體無法正常設定、監看或使用。本專案提供一個**全新撰寫**的客戶端，讓這些硬體可以繼續被它們的合法擁有者使用。

### 重要聲明

- 本專案是一個**獨立的淨室（clean-room）重製**成果，僅根據**公開可觀察到的通訊協定事實（protocol facts）**重新撰寫，而非複製原廠程式碼。
- 本專案**與 RCE 公司、其關係企業或繼承者沒有任何關聯、背書或授權關係**。
- 本專案為**非商業性質**，目的純粹是協助**已經購買 RCE 硬體**的擁有者行使其維修權（right-to-repair）。
- 我們**不散布**原廠 App 的任何程式碼、素材、圖示或字串。
- 通訊協定的事實與資料格式屬於功能性事實，依一般理解不受著作權保護；詳見 [`COPYRIGHT.md`](./COPYRIGHT.md)。

### 倉庫結構

```
open-rce-batt/
├── README.md          本檔案
├── LICENSE            MIT 授權條款
├── COPYRIGHT.md       版權與法律宣告
├── CLEANROOM.md       淨室開發流程與獨立性證據
├── CONTRIBUTING.md    貢獻指南
├── docs/
│   └── PROTOCOL.md    由分析角色整理的通訊協定規格（事實）
└── app/
    └── ...            由實作角色依規格全新撰寫的客戶端
```

- `docs/`：協定規格文件，描述觀察到的封包格式、欄位與行為等**事實**。
- `app/`：全新的客戶端程式，**僅**根據 `docs/` 規格撰寫，未接觸原廠 App。

### 安全須知

- **請務必自行從原始碼編譯（compile from source yourself）。** 不要執行來路不明的預編譯二進位檔。
- 本軟體與電池硬體互動，請在了解風險的前提下使用；錯誤的設定可能影響電池行為。
- 本專案不提供任何擔保，請見 [`LICENSE`](./LICENSE)。

### 協定文件

通訊協定的完整規格請見 [`docs/PROTOCOL.md`](./docs/PROTOCOL.md)。

---

## English

### What this is

This is a community **right-to-repair** project run by the **owners/holders** of RCE iBatt battery hardware. The original vendor (RCE) has ceased operations and its official app is no longer maintained, leaving a large number of **already-purchased** devices unable to be configured, monitored, or used. This project provides a **freshly written** client so those devices can keep being used by their lawful owners.

### Important statement

- This is an **independent clean-room reimplementation**, written solely from **publicly observable protocol facts**, not by copying the original vendor's code.
- This project is **not affiliated with, endorsed by, or licensed by** RCE, its affiliates, or any successor.
- This project is **non-commercial**. Its only purpose is to help owners of **already-purchased** RCE hardware exercise their right to repair.
- We **do not distribute** any of the original app's code, assets, icons, or strings.
- Protocol facts and data formats are functional facts that are generally not protected by copyright; see [`COPYRIGHT.md`](./COPYRIGHT.md).

### Repository structure

```
open-rce-batt/
├── README.md          this file
├── LICENSE            MIT license
├── COPYRIGHT.md       copyright & legal notice
├── CLEANROOM.md       clean-room process & evidence of independence
├── CONTRIBUTING.md    contribution guide
├── docs/
│   └── PROTOCOL.md    protocol spec (facts), produced by the analysis role
└── app/
    └── ...            new client, written by the implementation role from the spec
```

- `docs/`: the protocol specification — a description of observed packet formats, fields, and behaviors as **facts**.
- `app/`: a brand-new client written **only** from the `docs/` spec, never touching the original app.

### Safety note

- **Always compile from source yourself.** Do not run unverified pre-built binaries.
- This software interacts with battery hardware; use it understanding the risks. Incorrect configuration may affect battery behavior.
- The software comes with no warranty; see [`LICENSE`](./LICENSE).

### Protocol documentation

The full protocol specification is in [`docs/PROTOCOL.md`](./docs/PROTOCOL.md).

---

*"RCE" and "iBatt" are trademarks of their respective owners and are used here only nominatively, to describe hardware compatibility. See [`COPYRIGHT.md`](./COPYRIGHT.md).*
