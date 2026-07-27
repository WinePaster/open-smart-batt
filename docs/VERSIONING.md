# 版號規則 (Versioning)

採用 **語意化版號 (SemVer)** + **日期推導的 build number**。

## 格式

```
versionName = MAJOR.MINOR.PATCH      （給人看的版本，例如 0.6.8）
versionCode = BUILD = YYMMDDNN       （Android 內部整數，必須單調遞增）
pubspec     = MAJOR.MINOR.PATCH+0    （build number 一律由建置旗標帶入）
```

`--build-name` 對映到 Android `versionName` 與 iOS `CFBundleShortVersionString`；
`--build-number` 對映到 Android `versionCode` 與 iOS `CFBundleVersion`。

**兩個平台、CI 與本機，共用同一個 build number。** 產生器只有一支：
[`tool/build_number.sh`](../tool/build_number.sh)。

---

## build number：`YYMMDDNN`

```
YYMMDD  建置日期（固定以 Asia/Taipei 計算）
NN      當日的 15 分鐘區間序號（00..95）

2026-07-29 14:07（台北）→ 26072956
```

### 為什麼是這個形狀

**無狀態。** 只依賴時鐘，所以 CI 與本機不需要共用計數器就會一致。
舊方案用 `github.run_number`，它綁在**單一 workflow 檔案**上——`release.yml`
一旦改名或重建就從 1 重新數，Android versionCode 會永久倒退且無法挽回。
它也會把失敗的執行與 dry-run 一起計入，跟「第幾次發版」毫無關係。

**只能 8 位數，不要再加精度。** Android 的 `versionCode` 上限是
2,100,000,000。本方案天花板 `99123195`，安全。
但分鐘級的 `YYMMDDHHMM` 會產生像 `2607281530`（26 億）這種**超過上限**的值，
會被直接拒絕。**請不要「改良」這裡的解析度。**
（iOS `CFBundleVersion` 上限是 18 個字元，8 位數綽綽有餘。）

**同一天發兩次也不會撞號。** App Store Connect 會拒絕同一條版本線內重複的
`CFBundleVersion`，所以同日的兩次發版必須是不同數字。15 分鐘一格，
剛好能塞進兩位數，又細到連續發版不會相同。

**時區固定為 `Asia/Taipei`。** CI runner 是 UTC、維護者在 UTC+8。不固定的話，
傍晚的本機建置與幾分鐘後的 CI 建置會算出不同的數字，而且可能**算出更小的**
——Android 會當成降版拒絕安裝。

### 2026-07-28 的一次性跳號（重要）

導入本方案前，同時有三套 build number 在跑：

| 來源 | 值 | 問題 |
|---|---|---|
| `pubspec.yaml` | `+109` | 本機不帶旗標建置時取用 |
| CI (`github.run_number`) | `13`（v0.6.7） | 遠低於 109 → 裝過本機版的人**裝不回** CI 版 |
| TestFlight（本機手動上傳） | `2110` | 遠高於 CI → 0.6.7 這條線上再也傳不上新 build |

切換後兩個平台都跳到 `26072xxx`：Android `13 → 26072xxx`、
iOS `2110 → 26072xxx`。**兩邊都是往上跳**，所以既有安裝與 TestFlight
版本線都不會被破壞。日後看到版號在此處斷層，原因就是這個。

---

## 何時升哪一位

目前處於 **0.x 階段**（協定尚未在硬體完全驗證、API/功能仍會變動），規則：

| 位 | 何時 +1 | 例 |
|----|---------|----|
| **PATCH** | 修 bug、UI 微調、文案、不改行為 | 0.6.7 → 0.6.8 |
| **MINOR** | 新增功能（新頁面、新 BLE 指令支援、相容新型號） | 0.6.8 → 0.7.0 |
| **MAJOR** | 重大不相容變更；**升 1.0.0 = 在實機成功解鎖且穩定** | 0.x → 1.0.0 |

> 0.x 期間 MAJOR 維持 0。實機驗證通過、功能穩定後才發 1.0.0。

---

## 如何發布

### A. 自動推進（推薦，一鍵）

GitHub → Actions → 「Release APK」→ Run workflow → 選 `bump = patch / minor / major`。

CI 會：讀最新 stable tag → 算出下一版號 → **把 `pubspec.yaml` 回寫成新版號並
commit 回分支** → 建立 tag → 編 APK → 發佈 Release。

回寫這一步是刻意加的：舊流程從 git tag 算版號、**從不回寫 pubspec**，
這就是 pubspec 漂到 `0.6.7+109` 而實際發布的是 `13` 的成因。

### B. 明確指定版號

因為 pubspec 是版號的真實來源，順序是**先改 pubspec、再推 tag**：

```bash
# 1. 把 app_flutter/pubspec.yaml 的 version 改成 0.6.8+0
git commit -am "chore(release): bump pubspec to 0.6.8+0"
git push

# 2. 對著這個 commit 打 tag
git tag v0.6.8 && git push origin v0.6.8
```

若 tag 與 pubspec 版號不符，release workflow 會**直接失敗**並告訴你要改哪裡。

### 本機建置（不經 CI）

**永遠要帶 `--build-number`**，否則會取 pubspec 的 `+0`：

```bash
flutter build apk --release \
  --build-name="$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//;s/+.*//')" \
  --build-number="$(../tool/build_number.sh)"
```

沒帶旗標時產生的是 versionCode `0` 的 APK。這是**刻意設計**：它裝不到任何
已發布版本之上，所以絕不可能像過去的 `109` 那樣悄悄卡住使用者的更新路徑。

---

## 預發布 / 測試版（選用）

`bump` 選 `prerelease` 或 tag 帶後綴（例 `v0.7.0-rc.1`）→ 標記為 GitHub
*pre-release*，不會被當成「最新正式版」，方便先給少數車友試裝。

---

## 版本顯示規則（單一真實來源）

- **App 內絕不寫死版本字串。** 「設定 → 關於」用 `package_info_plus` 讀取
  **安裝 APK 的真實 versionName/versionCode**，永遠與發佈一致。
- 版號的唯一來源鏈：`pubspec.yaml`（versionName）+ `tool/build_number.sh`（build）
  → release workflow 的 `version` job → Android 與 iOS **共用同一組 output**。
  兩個平台在結構上不可能算出不同的 build number。

## APK 命名

```
open-smart-batt-v<versionName>-<build>.apk    例：open-smart-batt-v0.6.8-26072956.apk
```

---

## iOS 版號

### CFBundle 對映

| Flutter 旗標 | Android | iOS（Info.plist） | 規則 |
|---|---|---|---|
| `--build-name` | `versionName` | `CFBundleShortVersionString` | **必須為嚴格數字 `x.y.z`**（不可含 `-rc.N` 等後綴） |
| `--build-number` | `versionCode` | `CFBundleVersion` | `YYMMDDNN`，與 Android 同值 |

Info.plist 以 `CFBundleShortVersionString = $(FLUTTER_BUILD_NAME)`、
`CFBundleVersion = $(FLUTTER_BUILD_NUMBER)` 接線，CI 的
`--build-name/--build-number` 會自動餵入。

### `-rc.N` 後綴在 iOS 須剝除

Android 的 `versionName` 容忍 `0.7.0-rc.3` 這類預發布後綴，但 Apple 的
`CFBundleShortVersionString` 只接受純數字 `x.y.z`，含後綴的版本字串在上傳
App Store Connect 時會被直接拒絕。

release workflow 的 `version` job 會輸出剝除後的 `numeric`，iOS job 用它：

```
0.7.0-rc.3  ──(Android)──▶  versionName = 0.7.0-rc.3
            ──(iOS)──────▶  CFBundleShortVersionString = 0.7.0
                            CFBundleVersion            = YYMMDDNN
```

rc 建置在 iOS 端應導向 TestFlight 內部測試群組（以遞增的 `CFBundleVersion`
區分），而非照搬 Android 的 prerelease 版本字串。

### TestFlight 上傳的開關

iOS job 由 repo variable **`IOS_RELEASE_ENABLED`** 控制
（Settings → Secrets and variables → Actions → Variables）：

| 值 | 行為 |
|---|---|
| 未設定 / `false` | job 顯示為 **skipped（灰色）** |
| `true` 但 secret 不齊 | job **失敗**，並列出缺哪幾個 |
| `true` 且 secret 齊全 | 編 IPA 並上傳 TestFlight |

舊版在缺 secret 時是**綠色 no-op**，這正是 2026-07-28「以為 CI 推了
TestFlight、實際是本機手動上傳 build 2110」的直接成因。灰色的 skipped
與綠色的 success 在 UI 上分得開，綠燈不會再說謊。

開啟前需備齊的 secrets：
`APPLE_TEAM_ID`、`IOS_P12_BASE64`、`IOS_P12_PASSWORD`、
`IOS_MOBILEPROVISION_BASE64`、`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_API_KEY_BASE64`。
這些一律只存在於 GitHub Actions secrets，**絕不進 repo**。
