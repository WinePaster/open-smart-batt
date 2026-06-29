# 淨室開發流程與獨立性證據 / Clean-room Development Log

> 本文件記錄本專案的淨室（clean-room）開發流程，作為**獨立開發**的證據。
> This document records the clean-room development process as evidence of **independent development**.

**日期 / Date: 2026-06-29**

---

## 為什麼採用淨室流程 / Why clean-room

為確保 `app/` 的客戶端**不衍生自**原廠 App 的受保護表達，本專案採取**兩個角色分離（two-role separation）**的淨室方法。實作者從未接觸原廠程式碼，只接觸描述「事實」的中介規格文件。

To ensure the `app/` client is **not derived from** the original app's protected expression, this project uses a **two-role separation** clean-room method. The implementer never touches the original code, only an intermediate spec that describes "facts".

---

## 角色與職責 / Roles and responsibilities

### 角色一：分析角色 / Analysis role

- 透過合法持有的 RCE 硬體進行還原工程，觀察通訊行為。
- 將觀察到的**事實**（封包格式、欄位語意、數值編碼、時序等）整理成 `docs/PROTOCOL.md`。
- **輸出僅限事實與功能性描述**，不得搬運原廠的原創表達（程式邏輯結構的逐字複製、註解、字串、素材等）。
- 可接觸反編譯內容；其產出唯一允許進入下游的管道是 `docs/PROTOCOL.md`。

> Reverse-engineers lawfully held hardware, records **facts** into `docs/PROTOCOL.md`, and outputs only facts/functional descriptions — never the vendor's original expression. The only permitted downstream channel is `docs/PROTOCOL.md`.

### 角色二：實作角色 / Implementation role

- **僅**閱讀 `docs/PROTOCOL.md`，據此全新撰寫 `app/` 的客戶端。
- **全程不得接觸、不得閱讀、不得複製**原廠 App 的反編譯碼、原始碼、素材或字串。
- 所有程式碼、命名、結構與資源皆為原創。

> Reads **only** `docs/PROTOCOL.md` and writes `app/` from scratch; never accesses the original app's decompiled/source code, assets, or strings. All code is original.

---

## 資訊流（單向）/ Information flow (one-way)

```
合法硬體 / lawful hardware
        │ 觀察 observe
        ▼
   分析角色 / Analysis role  ──(可接觸反編譯 / may see decompilation)
        │ 僅輸出事實 / facts only
        ▼
   docs/PROTOCOL.md   ◀── 唯一許可的橋樑 / the only permitted bridge
        │ 僅閱讀規格 / spec only
        ▼
   實作角色 / Implementation role  ──(從不接觸原廠碼 / never sees original code)
        │ 全新撰寫 / writes fresh
        ▼
   app/  (原創客戶端 / original client)
```

關鍵：原廠程式碼**從不**直接流向實作角色。中間隔著一份只含事實的規格。

Key: the original code **never** flows directly to the implementation role; a facts-only spec sits in between.

---

## 獨立性檢查清單 / Independence checklist

- [x] 分析角色與實作角色職責明確分離 / Analysis and implementation roles are clearly separated.
- [x] `docs/PROTOCOL.md` 僅含協定事實，不含原廠原創表達 / `docs/PROTOCOL.md` contains only protocol facts, no original vendor expression.
- [x] 實作角色未接觸原廠反編譯碼或原始碼 / Implementation role did not access the original decompiled/source code.
- [x] `app/` 不含原廠程式碼、素材、圖示、字型或逐字字串 / `app/` contains no vendor code, assets, icons, fonts, or verbatim strings.
- [x] 所有 `app/` 內容均為貢獻者原創 / All `app/` content is original to contributors.
- [x] 硬體為合法持有，觀察於正常使用情境 / Hardware is lawfully held; observation under normal use.
- [x] 專案為非商業維修權目的 / Project is non-commercial, right-to-repair purpose.
- [x] 商標僅作指示性使用 / Trademarks used only nominatively.

---

## 紀錄維護 / Record keeping

- 對 `docs/PROTOCOL.md` 與 `app/` 的變更應透過版本控制保存，以維持可稽核的時間線。
- 新貢獻者請先閱讀 [`CONTRIBUTING.md`](./CONTRIBUTING.md) 並遵守角色分離原則。

> Keep changes to `docs/PROTOCOL.md` and `app/` under version control for an auditable timeline. New contributors must read [`CONTRIBUTING.md`](./CONTRIBUTING.md) and honor the role separation.

---

*相關文件 / See also: [`COPYRIGHT.md`](./COPYRIGHT.md), [`README.md`](./README.md).*
