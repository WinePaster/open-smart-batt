# 版號規則 (Versioning)

採用 **語意化版號 (SemVer)** + **自動遞增 build number**。

## 格式

```
versionName = MAJOR.MINOR.PATCH      （給人看的版本，例如 0.3.1）
versionCode = BUILD                  （Android 內部整數，必須單調遞增）
pubspec     = MAJOR.MINOR.PATCH+BUILD （例如 0.3.1+47）
```

- **versionCode/BUILD** 由 CI 自動帶入 `github.run_number`（每次 CI 執行 +1，保證遞增，
  滿足 Android「新版必須 > 舊版」的安裝/更新規則）。**開發者永遠不用手動管 build number。**

## 何時升哪一位

目前處於 **0.x 階段**（協定尚未在硬體完全驗證、API/功能仍會變動），規則：

| 位 | 何時 +1 | 例 |
|----|---------|----|
| **PATCH** | 修 bug、UI 微調、文案、不改行為 | 0.3.0 → 0.3.1 |
| **MINOR** | 新增功能（新頁面、新 BLE 指令支援、相容新型號） | 0.3.1 → 0.4.0 |
| **MAJOR** | 重大不相容變更；**升 1.0.0 = 在實機成功解鎖且穩定** | 0.x → 1.0.0 |

> 0.x 期間 MAJOR 維持 0。實機驗證通過、功能穩定後才發 1.0.0。

## 如何發布（兩種，皆自動編 APK 並上傳 GitHub Release）

### A. 自動推進（推薦，一鍵）
到 GitHub → Actions → 「Release APK」→ Run workflow → 選 `bump = patch / minor / major`。
CI 會：讀最新 tag → 自動算出下一版號 → 建立 tag → 編 release APK → 發佈 Release。
**版號全自動推進，你只挑「升哪一位」。**

### B. 明確指定版號
推一個 tag 即可：
```
git tag v0.4.0 && git push origin v0.4.0
```
CI 偵測到 `v*` tag → 用該版號編 APK → 發佈 Release `v0.4.0`。

## 預發布 / 測試版（選用）

`bump` 選 `prerelease` 或 tag 帶後綴（例 `v0.4.0-rc.1`）→ 標記為 GitHub *pre-release*，
不會被當成「最新正式版」，方便先給少數車友試裝。

## APK 命名

```
open-rce-batt-v<versionName>-<build>.apk      例：open-rce-batt-v0.4.0-47.apk
```

---
_目前版本：`0.1.0`（UI/協定建置中，尚未硬體驗證）_
