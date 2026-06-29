# Open-RCE-Batt

> 社群自助 · 維修權 · 獨立淨室重製
> Android App（Flutter）+ 通訊協定文件，用於在原廠雲端關閉後繼續監看 RCE 智慧電容／電池。

**English version → [README.en.md](./README.en.md)**

---

## 這是什麼

這是一個由硬體**車主／持有者**自發組成的社群維修專案。原廠 **RCE 低碳動能開發股份有限公司**（iBatt 品牌）已於其[官方 Facebook 宣布停業](https://www.facebook.com/rce168/posts/pfbid08erjAACc445fd3eZargF8EnF84wBeP22cwutPyhwSguDDKPbLsGR6wJzXhVx5LE7l?locale=zh_TW)，官方 App 與雲端服務隨之無人維護，導致大量**已購買**的硬體無法正常設定、監看或使用。本專案提供一個**全新撰寫**的客戶端，讓這些硬體可以繼續被合法擁有者使用。

## 重要聲明

- 本專案是**獨立淨室（clean-room）重製**，僅根據**公開可觀察的通訊協定事實**重新撰寫，並非複製原廠程式碼。
- 本專案**與 RCE 公司、其關係企業或繼承者無任何關聯、背書或授權**。
- 本專案為**非商業性質**，目的純粹是協助**已購買** RCE 硬體的擁有者行使維修權（right-to-repair）。
- 我們**不散布**原廠 App 的任何程式碼、素材、圖示或字串。
- 通訊協定的事實與資料格式屬功能性事實，依一般理解不受著作權保護；詳見 [`COPYRIGHT.md`](./COPYRIGHT.md)。

## 倉庫結構

```
open-rce-batt/
├── README.md / README.en.md      說明（中／英）
├── LICENSE / COPYRIGHT / CLEANROOM / CONTRIBUTING
├── docs/
│   ├── PROTOCOL.md               通訊協定規格（事實，淨室分析角色整理）
│   ├── CAPTURE_VERIFIED.md       以實機 HCI 擷取驗證／修正協定（裝置祕密值已去識別化）
│   ├── HCI_CAPTURE_GUIDE.md      社群擷取解鎖封包指南
│   ├── VERSIONING.md             版號規則
│   └── UNVERIFIED.md             仍需硬體確認的項目
├── app_flutter/                  ★ Android App（Flutter，依規格全新撰寫）
├── app/                          參考用 Python(bleak) CLI 客戶端
├── tools/parse_btsnoop.py        btsnoop → GATT 萃取器（去識別化）
├── mockup/index.html             UI 設計預覽
└── .github/workflows/            CI + 自動版號 APK release
```

`docs/` 為協定規格與驗證文件（**事實**）。`app_flutter/`、`app/` **僅**依 `docs/` 撰寫，未接觸原廠 App。

## 現況（2026-06）

- ✅ Android App 已實作：BLE 連線、即時遙測儀表板、裝置清單＋別名、歷史＋CSV 匯出、設定（含預設關閉的診斷日誌）。`flutter analyze` 乾淨、單元測試 97 項通過、release APK 可編。
- ✅ **監看不需任何密碼**：連線後即可看電壓／溫度／SOH／檢測電容（遙測串流不需認證）。
- ⚠️ **超級電容**：主打監看＋檢測電容。`斷電／防盜`屬電池型功能；電容的「異常鎖定保護」解除尚未實作（需故障單位的 HCI 擷取，見 [`docs/UNVERIFIED.md`](./docs/UNVERIFIED.md)）。
- 🧪 解除指令支援「輸入斷電密碼」「直接輸入驗證值（cb／pwSum）」與實驗性「只送 mode、跳過驗證」三種路徑；實際是否解除請以硬體電氣行為驗證。

## 安裝

- **自行編譯（建議）**：安裝 Flutter，`cd app_flutter && flutter build apk --release`，APK 於 `build/app/outputs/flutter-apk/`。
- 或由 GitHub Actions 的 **Release APK** 工作流程自動產生（附 SHA256；目前為 debug 簽章，請核對雜湊）。

## 安全須知

- **請務必自行從原始碼編譯。** 不要執行來路不明的預編譯二進位檔。
- 本軟體與電池硬體互動，請在了解風險下使用；錯誤設定可能影響電池行為。
- 解除斷電／鎖定後**請勿重新上鎖**；電容本身的過壓／低壓／過溫保護仍持續有效。
- 本軟體不提供任何擔保，詳見 [`LICENSE`](./LICENSE)。

## 協定文件

完整規格見 [`docs/PROTOCOL.md`](./docs/PROTOCOL.md)，實機驗證見 [`docs/CAPTURE_VERIFIED.md`](./docs/CAPTURE_VERIFIED.md)。

---

*「RCE」與「iBatt」為其各自所有者之商標，此處僅作描述硬體相容性之指稱性使用。詳見 [`COPYRIGHT.md`](./COPYRIGHT.md)。*
