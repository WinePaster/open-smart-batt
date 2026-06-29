# 版權與法律宣告 / Copyright & Legal Notice

> ⚠️ **本文件不構成法律意見（This document is NOT legal advice）。** 如有疑慮，請諮詢智慧財產權律師。
> ⚠️ **This document is not legal advice. Consult a qualified IP lawyer for your situation.**

---

## 繁體中文

### 1. 淨室開發聲明（Clean-room statement）

本專案的客戶端程式（`app/`）是經由**淨室（clean-room）**流程獨立開發而成：

- **分析角色**：透過合法持有的硬體與其通訊，觀察並記錄通訊協定的**事實**，整理為 `docs/PROTOCOL.md`。
- **實作角色**：**僅**依據 `docs/PROTOCOL.md` 規格撰寫程式，**全程未接觸、未閱讀、未複製**原廠 App 的反編譯碼或原始碼。

兩個角色的分離與紀錄（見 [`CLEANROOM.md`](./CLEANROOM.md)）即為獨立開發的證據。

### 2. 協定事實不受著作權保護

通訊協定、封包欄位、資料格式、數值編碼等屬於**功能性事實（functional facts）與方法**。依一般著作權法理（思想與表達二分原則，idea–expression dichotomy），事實本身與達成互通所必要的功能性元素不受著作權保護。本專案僅使用這些事實，未複製任何具表達性的原創內容。

### 3. 未包含原廠任何原創內容

本專案**不含**下列任何項目：

- 原廠 App 的程式碼或反編譯碼；
- 原廠的美術素材、圖示、字型、音效或介面資源；
- 原廠的逐字字串（verbatim strings）、文案或文件內容。

`app/` 中所有程式碼、文字與資源皆為貢獻者原創。

### 4. 非商業維修權目的

本專案為**非商業性質**，目的是讓**已經購買** RCE 硬體的合法擁有者，在原廠（**RCE 低碳動能開發股份有限公司**，已於[官方 Facebook 宣布停業](https://www.facebook.com/rce168/posts/pfbid08erjAACc445fd3eZargF8EnF84wBeP22cwutPyhwSguDDKPbLsGR6wJzXhVx5LE7l?locale=zh_TW)）停止營運後，能繼續維修、設定與使用自有設備（right-to-repair / 維修權）。本專案不販售、不營利、不提供商業服務。

### 5. 法律理由摘要（台灣法律脈絡，依使用者評估）

以下為本專案採取的法律理由摘要，僅為說明立場，**非法律意見**：

- **EULA（使用者授權合約）**：原廠已停止營運，本專案不使用、不再散布原廠 App，亦不要求使用者接受或違反任何原廠合約；本專案的新客戶端與原廠 EULA 無涉。
- **營業秘密（Trade Secret）**：通訊協定係透過合法持有之硬體於正常使用中可觀察得到的資訊，不具秘密性（已可被一般觀察取得），且本專案未以不正當方法取得或使用任何受保護之營業秘密。
- **著作權合理使用（Fair Use / 合理使用）**：為達成相容互通（interoperability）而進行的還原工程與功能性事實之利用，係屬合理使用範疇；本專案僅利用達成互通所必要之事實，未複製原創表達。

上述理由係基於使用者對台灣法律脈絡的評估，**不保證在任何司法管轄區之結果**。

### 6. 商標聲明（Trademark）

「**RCE**」、「**iBatt**」及相關名稱為其各自所有權人之商標。本專案與該等所有權人**無任何關聯或授權關係**。文中使用該等名稱僅為**指示性合理使用（nominative use）**，用以說明本軟體與哪些硬體相容，並無暗示來源、贊助或背書之意。

---

## English

### 1. Clean-room statement

The client software in `app/` was developed independently via a **clean-room** process:

- **Analysis role**: by communicating with lawfully held hardware, observed and recorded protocol **facts** into `docs/PROTOCOL.md`.
- **Implementation role**: wrote the code **only** from the `docs/PROTOCOL.md` spec, and **never accessed, read, or copied** the original app's decompiled or source code.

The separation of these roles and its record (see [`CLEANROOM.md`](./CLEANROOM.md)) is the evidence of independent development.

### 2. Protocol facts are not copyrightable

Communication protocols, packet fields, data formats, and value encodings are **functional facts and methods**. Under the idea–expression dichotomy, facts themselves and the functional elements necessary for interoperability are not protected by copyright. This project uses only such facts and copies no protectable original expression.

### 3. No original vendor content is included

This project contains **none** of the following:

- the original app's code or decompiled code;
- the vendor's artwork, icons, fonts, audio, or UI resources;
- the vendor's verbatim strings, copy, or document content.

All code, text, and resources in `app/` are original work by contributors.

### 4. Non-commercial right-to-repair purpose

This project is **non-commercial**. Its purpose is to let lawful owners of **already-purchased** RCE hardware continue to repair, configure, and use their own devices after the vendor — **RCE 低碳動能開發股份有限公司** (RCE Low-Carbon Energy Development Co., Ltd.) — [announced its closure on its official Facebook page](https://www.facebook.com/rce168/posts/pfbid08erjAACc445fd3eZargF8EnF84wBeP22cwutPyhwSguDDKPbLsGR6wJzXhVx5LE7l?locale=zh_TW) (right-to-repair). It is not sold, generates no revenue, and offers no commercial service.

### 5. Legal-reasoning summary (Taiwan-law context, per the user's assessment)

The following summarizes the project's reasoning. It explains our position only and is **not legal advice**:

- **EULA**: The vendor has ceased operations. This project does not use or redistribute the original app and does not require users to accept or breach any vendor agreement; the new client is independent of any vendor EULA.
- **Trade secret (營業秘密)**: The protocol is information observable during normal use of lawfully held hardware and therefore lacks secrecy (it is obtainable by ordinary observation); no protected trade secret was acquired or used by improper means.
- **Copyright fair use (著作權合理使用)**: Reverse engineering and use of functional facts to achieve interoperability fall within fair use; the project uses only the facts necessary for interoperability and copies no original expression.

This reasoning is based on the user's assessment of the Taiwan-law context and **guarantees no outcome in any jurisdiction**.

### 6. Trademark note

"**RCE**", "**iBatt**", and related names are trademarks of their respective owners. This project is **not affiliated with or licensed by** those owners. Such names are used only **nominatively** to describe which hardware this software is compatible with, and imply no origin, sponsorship, or endorsement.

---

*See also: [`README.md`](./README.md), [`CLEANROOM.md`](./CLEANROOM.md), [`CONTRIBUTING.md`](./CONTRIBUTING.md), [`LICENSE`](./LICENSE).*
