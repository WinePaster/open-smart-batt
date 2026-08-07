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

### ⚠️ 不要在 CI 加 `--split-per-abi`（會污染版號）

Flutter 在分架構建置時會**自動替各 ABI 加上偏移量**再寫進 `versionCode`
（`armeabi-v7a` +1000、`arm64-v8a` +2000、`x86_64` +4000）。本方案把序號放在
最低兩位，所以偏移量會直接**溢進「日」的欄位**：

```
--build-number=26072842  (2026-07-28，第 42 格)
        ↓ --split-per-abi + arm64
versionCode = 26074842   ← 「日」變成 48，已無意義
```

單看一次建置仍是單調遞增，但**混用就會倒置**：28 號的 split 版
（`26074842`）會大於 29 號的非 split 版（`26072900`），使用者從此裝不回正式版。

實測依據：2026-07-28 為了縮小體積建了一顆 arm64 測試 APK，`aapt2` 讀出的
versionCode 正是 `26074842`。

**現行 CI 建的是單一 fat APK，不受影響。** 若日後真的要分架構發佈，必須先改
版號方案（例如把序號讓出低三位給 ABI 偏移用），不能直接加旗標。

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

## 🔑 Android release 簽章

版號遞增是「能不能更新」的**必要條件，但不是充分條件**：Android 還要求新舊
APK 的簽章憑證一致。

### 曾經的問題（2026-07-28 發現並修正）

`android/app/build.gradle.kts` 的 release buildType 原本指向 **debug** 簽章設定，
而 CI runner 上**沒有**既存的 `~/.android/debug.keystore`，Gradle 會當場產生一把
新的。結果是每一次 CI 執行都用**不同的金鑰**簽章。

實測（2026-07-28，`apksigner verify --print-certs`）：

| APK | 憑證 SHA-256 |
|---|---|
| v0.6.3（CI run 12） | `4d8268c4…802c` |
| v0.6.8（CI，26072812） | `3d39f562…a765` |
| 本機建置 | `a242bb49…62ae` |

**三顆互不相同，包含兩顆都是 CI 產出的。** 造成的後果是：

- 使用者**無法原地更新**，每次都必須先移除舊版；
- 移除會**清空歷史紀錄、已存裝置與設定**；
- 這與版號無關，改版號救不了。

### 修法（已實作）

固定一把 release keystore，以 base64 存進 GitHub Secrets、建置時注入 —— 與 iOS
的 `IOS_P12_BASE64` 同一個模式。

**一、產生 keystore（只做一次，由專案擁有者在本機執行）**

```bash
keytool -genkeypair -v -keystore opensmartbatt-release.jks \
  -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 \
  -alias opensmartbatt \
  -dname "CN=OpenSmartBatt, O=WinePaster, C=TW"
```

> 🚨 **這個檔案與密碼一旦遺失就無法復原。** 遺失等於再也無法對現有安裝發布更新
> ——所有人都得再移除重裝一次。請離線備份（至少兩份，且**不要**放進 repo）。
> `android/.gitignore` 已排除 `key.properties` 與 `**/*.keystore`。

**二、設定四個 GitHub Secrets**

```bash
base64 -i opensmartbatt-release.jks | pbcopy   # 貼進 ANDROID_KEYSTORE_BASE64
```

| Secret | 內容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 檔案的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | `-storepass` |
| `ANDROID_KEY_ALIAS` | `opensmartbatt` |
| `ANDROID_KEY_PASSWORD` | `-keypass`（上面指令未分開設定時同 storepass） |

**三、CI 與 Gradle（已完成，無須手動）**

`release.yml` 會在建置前檢查四個 secret 是否齊全（缺就**直接失敗**，不會默默退回
debug 簽章），解碼 keystore 到 runner 暫存目錄並寫出 `key.properties`；建置後以
`apksigner verify --print-certs` **斷言憑證不是 `CN=Android Debug`**。

`build.gradle.kts` 在 `key.properties` 存在時使用它，不存在時退回 debug 簽章 ——
所以本機 `flutter run --release` 與 PR CI（無 secrets）仍然建得起來。**但用 debug
簽章產出的 APK 不可對外發佈**，這正是上面那個 CI 斷言要擋的東西。

實測（2026-07-28，本機）：帶 `key.properties` 建置 →
`Signer #1 certificate DN: CN=OpenSmartBatt Test, …`；移除後重建 →
`CN=Android Debug`。兩條路徑都確認可建置。

### 專案的簽章憑證（可釘住）

首次以固定金鑰簽章的產物（2026-07-28，v0.6.9 建置）：

```
DN:      CN=OpenSmartBatt, O=WinePaster, C=TW
SHA-256: eabe10efb4512cef6debdd171e2bb07ff95e54eccc2702ffaa6d6b94302b8063
```

**之後每一版都應該是這一組。** 對商店之外散佈的 APK，憑證比檔案雜湊是更強的
來源驗證：檔案雜湊每版都變，憑證不變。使用者可以核對：

```bash
apksigner verify --print-certs opensmartbatt-*.apk
```

> 註：`apksigner` 的輸出前綴會隨 build-tools 版本不同（`Signer #1 certificate DN:`
> 或 `V2 Signer: certificate DN:`），比對時看冒號後面的值即可。

### ⚠️ 這個修正救不了既有的安裝

固定金鑰只能讓**從此之後**的更新可以覆蓋安裝。目前手上裝著 debug 簽章版本的
使用者，**第一次**升級到固定金鑰的版本時**仍然必須移除舊版**（歷史會清空）。

因此：**愈早導入，被迫清空的次數愈少。** 若下一版 Android 無論如何都要發，
就應該把本修正一起帶上去 —— 否則就是先清一次、之後再清一次。
發佈說明在那一版仍須明確告知需先移除舊版並先匯出歷史備份。

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

### 完整流程速查（兩平台，實跑過的順序）

一次發版 = **CI 出 Android + 本機出 iOS**，兩者共用同一個 build number。

| # | 步驟 | 做法 |
|---|---|---|
| 1 | 把該進的 PR 都合進 `main` | CI 綠燈後合併 |
| 2 | 本機確認 `main` 沒問題 | `flutter analyze && flutter test`（各 PR 分開過 CI，合起來沒人測過） |
| 3 | **觸發 Android 發版** | Actions →「Release APK」→ Run workflow → `bump=patch` |
| 4 | 等 workflow 綠燈 | 它會回寫 pubspec、打 tag、編 APK、發 Release |
| 5 | **抄下 build number** | 看 Release 的 APK 檔名 `…-v0.6.9-26072881.apk` |
| 6 | **本機出 iOS** | 見「手動上傳 TestFlight」——**務必用同一個 build number** |

> 步驟 3 的 workflow 若在中途失敗（例如簽章斷言），`pubspec.yaml` 可能**已經被
> 回寫成新版號、但沒有 tag 也沒有 Release**。修好之後**直接重跑同一個
> workflow** 即可，不需要手動改 pubspec —— 版號相同時它會識別並跳過回寫。
> 實例：2026-07-28 的 v0.6.9 第一次跑就是這樣（version 成功、build 失敗）。

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

#### 🔴 tag push 不觸發 workflow 時（2026-08-07 記，已三次）

**推了 tag、Actions 什麼都沒發生，而且沒有任何錯誤訊息。** 補救：對著 tag ref
手動 dispatch，出來的結果與 tag 觸發完全相同。

```bash
gh workflow run release.yml --ref v0.7.7
```

之所以等價：`version` job 判斷的是 `GITHUB_REF` 是不是 `refs/tags/v*`。dispatch
到 tag ref 時它就是，所以走的是流程 B（讀 tag 算版號、**不**回寫 pubspec、不重打
tag），`bump` 那個 input 完全不會被用到。

**原因未查明。** 已知的事實只有這些：

| tag | 觸發方式 | `push` 事件 |
|---|---|---|
| `v0.6.15`–`v0.7.2` | 本機 `git push origin <tag>` | ✅ 正常觸發 |
| `v0.7.5` / `v0.7.6` / `v0.7.7` | 同上 | ❌ 靜默 |

三次都確認 tag 已經到 `origin`（`git ls-remote --tags`），workflow 是 `active`，
`on.push.tags` 沒有改過，且 `.github/workflows/release.yml` 在該 tag 的 commit
上存在。

⚠️ **曾經以為原因是 bump commit 帶了 `[skip ci]`。那個診斷是錯的** —— v0.7.7 的
bump commit 刻意不帶，一樣沒觸發。目前寫下來的只有現象與補救，沒有結論；
要下結論得先查 repo 的 Actions 設定與推送用的憑證型別。


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

### 手動上傳 TestFlight（目前的實際做法）

CI 的 iOS job 現況是 skipped（見下一節），所以 TestFlight 一律是**本機用 Xcode
的 Distribute App** 上傳。以下步驟每一條都經實測，照做即可，不必再重新摸索。

#### 1. 先確認 Android 那一版的 build number

兩平台**必須用同一個 build number** —— 這正是本文件開頭那套 `YYMMDDNN` 方案的
目的。到 Release 頁看 APK 檔名即可：

```
open-smart-batt-v0.6.9-26072881.apk
                       ^^^^^^^^ 就是它
```

> ⚠️ **不要重跑 `tool/build_number.sh`。** 它是從時鐘推導的，晚幾分鐘跑就會落在
> 不同的 15 分鐘區間，兩平台版號就對不起來了。

#### 2. 把版號寫進 `Generated.xcconfig`

Xcode archive 時的版號來自 `ios/Flutter/Generated.xcconfig` 的
`FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`（`Info.plist` 裡是
`$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`）。

```bash
cd app_flutter
flutter build ios --release --no-codesign \
  --build-name=0.6.9 --build-number=26072881
```

> 🚨 **一定要帶 `--build-number`。** `pubspec.yaml` 的版號固定寫成 `x.y.z+0`
> （見「為什麼是 +0」），所以**不帶參數**建置會把 `FLUTTER_BUILD_NUMBER` 設成
> **0**，archive 出來的就是 build 0，App Store Connect 會拒收或收到錯的版本。
>
> 實測（2026-07-28）：不帶參數 → `FLUTTER_BUILD_NUMBER=0`；帶參數 →
> `26072881`。另外 `flutter pub get` **不會**動到這個檔案，不必擔心它覆寫。

建完確認一下：

```bash
grep -E 'FLUTTER_BUILD_(NAME|NUMBER)' ios/Flutter/Generated.xcconfig
# FLUTTER_BUILD_NAME=0.6.9
# FLUTTER_BUILD_NUMBER=26072881
```

#### 3. 產生 archive

```bash
cd app_flutter/ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS \
  -archivePath ../build/ios/archive/Runner archive \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=CF3KF2RD3U
```

簽章設定是**命令列覆寫**，`project.pbxproj` 不會被改動（repo 保持乾淨）。
產物固定在 `app_flutter/build/ios/archive/Runner.xcarchive`。

也可以直接在 Xcode 開 `ios/Runner.xcworkspace` → Product → Destination 選
**Any iOS Device (arm64)** → Product → **Archive**；差別是 Xcode 會把 archive
放進 **Organizer**（`~/Library/Developer/Xcode/Archives/`）而不是上面那個路徑。

#### 4. Distribute App

```bash
open app_flutter/build/ios/archive/Runner.xcarchive
```

→ **Distribute App** → App Store Connect → Upload。

archive 本身是用 **Apple Development** 憑證簽的；Distribute 時 Xcode 會**重新以
Distribution 憑證簽章**，所以這是正常的、不必先改成 Distribution。

開啟前先確認版號對：

```bash
plutil -extract ApplicationProperties.CFBundleShortVersionString raw \
  app_flutter/build/ios/archive/Runner.xcarchive/Info.plist   # 0.6.9
plutil -extract ApplicationProperties.CFBundleVersion raw \
  app_flutter/build/ios/archive/Runner.xcarchive/Info.plist   # 26072881
```

> 🚨 **這個路徑只有在 archive 成功時才會被覆蓋。** 若 archive 失敗，舊的
> `Runner.xcarchive` 會原封不動留在那裡 —— 開起來就是**上一版**。2026-07-28 就
>發生過：archive 失敗但沒注意，打開看到的是前一天的 0.6.7 / 2110。
> **先用上面的 `plutil` 確認版號再 Distribute。**

#### ⚠️ 為什麼 `flutter build ipa` 會失敗

公開 repo 的 `Runner` target 是 `CODE_SIGN_STYLE = Manual`（保留給 CI 注入用）。
Flutter 其實有傳 `DEVELOPMENT_TEAM=CF3KF2RD3U -allowProvisioningUpdates`，但
**Manual 模式會忽略它**，必須明確指定 profile，於是：

```
error: "Runner" requires a provisioning profile.
       Select a provisioning profile in the Signing & Capabilities editor.
```

畫面上 Flutter 印的那段「請到 Xcode 選 Development Team」是**誤導**——團隊本來
就傳了。真正的原因要加 `-v` 才看得到上面那行。

**不要試著用 `PROVISIONING_PROFILE_SPECIFIER=…` 補救**，會踩到兩件事：

1. 命令列的 build setting 會套用到**所有 target**，而 Pods 的各套件不支援
   profile → `permission_handler_apple does not support provisioning profiles`
   之類的錯誤一串；
2. `iOS Team Store Provisioning Profile: com.winepaster.openSmartBatt` 是
   **Xcode managed** 的，manual 模式會直接拒絕：
   `is Xcode managed, but signing settings require a manually managed profile`。

所以正解就是上面那條 `CODE_SIGN_STYLE=Automatic` + `-allowProvisioningUpdates`。

#### 需要的本機條件

- 憑證：`Apple Distribution: MOOOORE CO., LTD. (CF3KF2RD3U)`（Distribute 時用）
- Team：`CF3KF2RD3U`

檢查：

```bash
security find-identity -v -p codesigning | grep Distribution
```

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

### 發版前先查現況（不要憑印象）

本文件寫的是**做法**，不是**現況**。哪些 secret 已經設好會變，所以這裡**刻意不放
快照** —— 快照只會換個地方腐爛。要知道現況就跑：

```bash
gh secret list      # 只列名稱與設定時間，不會顯示值
gh variable list    # IOS_RELEASE_ENABLED 在這裡，不在 secret 裡
```

判讀：

| 看到什麼 | 意義 |
|---|---|
| 四個 `ANDROID_*` 都在 | Android release 會用固定 keystore 簽 → **可原地更新** |
| 少任一個 `ANDROID_*` | workflow 會**大聲失敗**（不是靜默退回 debug），先補齊再發 |
| `gh variable list` 是空的 | iOS job 一律 skipped，**不論 secret 補得多齊** |
| 六個 iOS secret 不齊而 variable 為 `true` | job 失敗並列出缺哪幾個 |

> 📌 **這一節是 2026-07-30 補的，起因是一次真實的誤判。** 當時 `todo.md` 把 F1
> 簽章列為「待擁有者設 secret」，實際上四個 Android secret 早在 **2026-07-28 12:00**
> 就設好了，v0.6.9 / 0.6.10 / 0.6.11 全部是用它簽的 —— 待辦上多躺了一週。
>
> 成因不是誰偷懶：稽核時誠實標注了「外部動作，無法從 repo 判定」，而**「無法判定」
> 在轉述時變成了「尚未完成」**。兩者差很多。一行 `gh secret list` 就能分開。
>
> ⇒ **凡是 repo 裡看不到的狀態（secrets、TestFlight 上架、實機驗證），文件只能寫
> 「怎麼查」，不能寫「現在是什麼」。**
