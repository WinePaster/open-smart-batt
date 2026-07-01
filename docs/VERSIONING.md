# 版號規則 (Versioning)

採用 **語意化版號 (SemVer)** + **自動遞增 build number**。

## 格式

```
versionName = MAJOR.MINOR.PATCH      （給人看的版本，例如 0.3.1）
versionCode = BUILD                  （Android 內部整數，必須單調遞增）
pubspec     = MAJOR.MINOR.PATCH+BUILD （例如 0.3.1+47）
```

`--build-name` 對映到 Android `versionName` 與 iOS `CFBundleShortVersionString`；
`--build-number` 對映到 Android `versionCode` 與 iOS `CFBundleVersion`（見下方 iOS 區）。

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

## 版本顯示規則（單一真實來源）

- **App 內絕不寫死版本字串。** 「設定 → 關於」用 `package_info_plus` 讀取**安裝 APK 的真實 versionName/versionCode**，永遠與發佈一致。
- 版本的唯一來源：CI 的 `--build-name`（= tag 版號）與 `--build-number`（= `github.run_number`）。本機編譯時自帶 `--build-name/--build-number` 亦同。
- `pubspec.yaml` 的 `version:` 僅作為「未帶 build flag 時」的後備值。

## APK 命名

```
open-smart-batt-v<versionName>-<build>.apk      例：open-smart-batt-v0.4.0-47.apk
```

## iOS 版號（CFBundle 對映、IPA 命名、-rc.N 剝除）

iOS 與 Android 共用同一條版號線，但 Apple 對版本字串格式較嚴格，須注意三點。

### CFBundle 對映

| Flutter 旗標 | Android | iOS（Info.plist） | 規則 |
|---|---|---|---|
| `--build-name` | `versionName` | `CFBundleShortVersionString` | **必須為嚴格數字 `x.y.z`**（不可含 `-rc.N` 等後綴） |
| `--build-number` | `versionCode` | `CFBundleVersion` | 單調遞增整數，沿用 `github.run_number` |

Info.plist 以 `CFBundleShortVersionString = $(FLUTTER_BUILD_NAME)`、
`CFBundleVersion = $(FLUTTER_BUILD_NUMBER)` 接線，CI 的 `--build-name/--build-number`
會自動餵入；兩平台共用同一個 `github.run_number` 作為 build number。

### `-rc.N` 後綴在 iOS 須剝除

Android 的 `versionName` 容忍 `0.7.0-rc.3` 這類預發布後綴，但 Apple 的
`CFBundleShortVersionString` 只接受純數字 `x.y.z`，含後綴的版本字串在上傳
App Store Connect 時會被直接拒絕。

因此 release 流程（見 release.yml，H.2）在傳給 iOS `--build-name` 前，**必須把
`-rc.N` 後綴剝除成純 `x.y.z`**：

```
0.7.0-rc.3  ──(Android)──▶  versionName = 0.7.0-rc.3
            ──(iOS)──────▶  CFBundleShortVersionString = 0.7.0
                            CFBundleVersion            = <github.run_number>
```

rc 建置在 iOS 端應導向 TestFlight 內部測試群組（以遞增的 `CFBundleVersion` 區分），
而非照搬 Android 的 prerelease 版本字串。

### IPA 命名

```
open-smart-batt-v<numericVersion>-<build>.ipa   例：open-smart-batt-v0.4.0-47.ipa
```

`<numericVersion>` 為**已剝除後綴**的純數字版本（= `CFBundleShortVersionString`）。
iOS artifact 命名／上傳與 TestFlight（altool / Transporter）流程，獨立於 Android 的
APK rename + SHA256 步驟。

---
_目前版本：`0.1.0`（UI/協定建置中，尚未硬體驗證）_
