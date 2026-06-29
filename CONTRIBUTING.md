# 貢獻指南 / Contributing

感謝你願意協助這個社群維修權專案。為了保護專案的法律乾淨度（淨室原則），請務必遵守以下規則。

Thank you for helping this community right-to-repair project. To protect the project's legal cleanliness (clean-room principle), please follow these rules.

---

## 黃金準則 / Golden rules

1. **絕不**貼上、提交或引用原廠 App 的程式碼、反編譯碼、素材、圖示、字型或逐字字串。
   **Never** paste, commit, or quote the original app's code, decompiled code, assets, icons, fonts, or verbatim strings.

2. **只**貢獻通訊協定的**事實**（封包格式、欄位語意、數值編碼、時序等功能性描述）。
   Contribute **only** protocol **facts** (packet formats, field semantics, value encodings, timing — functional descriptions).

3. **尊重角色分離**：若你曾接觸原廠反編譯碼，請**只**對 `docs/PROTOCOL.md`（分析角色）貢獻，**不要**同時對 `app/` 提交實作。實作 `app/` 的人**不得**接觸原廠程式碼。詳見 [`CLEANROOM.md`](./CLEANROOM.md)。
   **Respect role separation**: if you have seen the original decompilation, contribute **only** to `docs/PROTOCOL.md` (analysis role), and do **not** also implement in `app/`. People implementing `app/` must **not** look at the original code. See [`CLEANROOM.md`](./CLEANROOM.md).

---

## 如何安全貢獻 / How to contribute safely

### 對 `docs/` 的貢獻 / Contributing to `docs/`

- 描述「觀察到什麼」，而非「原廠怎麼寫的」。記錄事實，不搬運表達。
- 不要包含註解、變數名稱或結構的逐字複製。
- 若有可能，附上是如何觀察到的（例如：與硬體互動的封包擷取摘要）。

> Describe *what was observed*, not *how the vendor wrote it*. Record facts, not expression. Do not include verbatim comments, names, or structure. Where possible, note how it was observed.

### 對 `app/` 的貢獻 / Contributing to `app/`

- **只**根據 `docs/PROTOCOL.md` 撰寫；不要參考原廠 App。
- 所有程式碼、命名與資源必須原創。
- 保持非商業、維修權導向的定位。

> Write **only** from `docs/PROTOCOL.md`; never reference the original app. All code, names, and resources must be original. Keep the non-commercial, right-to-repair focus.

---

## 對照真實硬體驗證 / Verify against real hardware

- 提交協定事實或實作前，請在**合法持有**的 RCE 硬體上驗證行為。
- 在 PR 描述中註明你驗證所用的硬體型號／韌體版本與測試情境。
- 未經硬體驗證的推測，請明確標示為「未驗證／推測」。

> Before submitting protocol facts or implementation, verify behavior against **lawfully held** RCE hardware. Note the hardware model/firmware and test scenario in your PR. Mark unverified guesses clearly as "unverified/speculative".

---

## 簽署聲明 / Sign-off

每個 commit 請加上 `Signed-off-by` 行（`git commit -s`），表示你同意以下開發者原創聲明：

Add a `Signed-off-by` line to each commit (`git commit -s`), affirming the following developer statement:

> 我聲明：本貢獻為我的原創作品（或我有權以本專案授權提交）；我未從原廠 App 複製任何程式碼、素材或逐字字串；我已遵守 [`CLEANROOM.md`](./CLEANROOM.md) 的角色分離原則。
>
> I certify that this contribution is my original work (or I have the right to submit it under the project's license); I have not copied any code, assets, or verbatim strings from the original app; and I have honored the role-separation in [`CLEANROOM.md`](./CLEANROOM.md).

格式 / Format:

```
Signed-off-by: Your Name <you@example.com>
```

---

## 行為與授權 / Conduct and license

- 貢獻即表示你同意你的貢獻以本專案的 [`LICENSE`](./LICENSE)（MIT）授權。
- 請閱讀 [`COPYRIGHT.md`](./COPYRIGHT.md) 以了解專案的法律立場。

> By contributing you agree your contribution is licensed under the project's [`LICENSE`](./LICENSE) (MIT). Please read [`COPYRIGHT.md`](./COPYRIGHT.md) for the project's legal position.
