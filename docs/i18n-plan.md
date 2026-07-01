# OpenSmartBatt — Internationalization (i18n) Implementation Plan

Status: PLAN (not yet implemented)
Target app: `app_flutter/` (Flutter, Dart SDK `^3.12.2`)
Locales: `en` (English) and `zh` (Traditional Chinese / zh-Hant). Current source UI is hard-coded zh-Hant.

---

## 1. Approach

Use Flutter's first-party **`gen_l10n`** pipeline (no third-party codegen):

- `flutter_localizations` (SDK) + `intl` (already a dependency, `^0.20.0`) + `flutter: generate: true`.
- ARB files live in `app_flutter/lib/l10n/`:
  - `app_en.arb` — **template** (source of truth, English).
  - `app_zh.arb` — Traditional Chinese translations.
- A repo-root (`app_flutter/`) `l10n.yaml` drives generation.
- Build/IDE generates a synthetic `package:flutter_gen` library exposing `AppLocalizations`.
- Widgets read strings via `AppLocalizations.of(context)!` (commonly aliased `final l10n = AppLocalizations.of(context)!;`).

**Why en as template (not zh):** the template defines the canonical key set, placeholder metadata, and plural/select ICU. English is the conventional template for tooling, translation services, and contributor onboarding; zh-Hant becomes a straightforward translation file. (The *current* runtime default stays zh-Hant — see §3 — so end users see no behavioural regression.)

**Why `app_zh.arb` (not `app_zh_Hant.arb`):** per the project's chosen filename. `gen_l10n` maps it to `Locale('zh')`. Since Chinese is the only Chinese variant shipped, `Locale('zh')` resolves correctly. If a Simplified variant is ever added, rename to `app_zh_Hant.arb` (→ `Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')`) and add `app_zh_Hans.arb`. This rename is the only change needed later (see §6).

---

## 2. Dependencies & config to add

### 2.1 `app_flutter/pubspec.yaml`

Add `flutter_localizations` under `dependencies` and `generate: true` under the `flutter:` section. `intl` is already present and compatible.

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:        # ADD
    sdk: flutter                # ADD
  # ... existing deps unchanged (intl: ^0.20.0 already present) ...

flutter:
  uses-material-design: true
  generate: true                # ADD — enables gen_l10n on build / pub get
  # ... existing flutter section unchanged ...
```

### 2.2 `app_flutter/l10n.yaml` (NEW)

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
nullable-getter: false
# Optional: keep generated files in-tree for easier code review / CI without codegen step.
# synthetic-package: false
# output-dir: lib/l10n/generated
```

Notes:
- `nullable-getter: false` makes `AppLocalizations.of(context)` return non-null, so call sites use `AppLocalizations.of(context)` (no `!`). If left default (`true`), use `AppLocalizations.of(context)!`. Pick one and keep it consistent; this plan assumes `false`.
- Run `flutter gen-l10n` (or just `flutter pub get` / a build) to generate after editing ARBs.

### 2.3 Generation / import

```dart
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
```

---

## 3. Locale wiring

### 3.1 Extend the locale preference (`lib/models/app_settings.dart`)

The model already persists language via `enum AppLang { zhHant, en }` (column `lang`, default `zhHant`), with `toMap`/`fromMap` and `copyWith` support, and `SettingsController.setLang(...)` already exists. The only model change is adding a **system** option:

```dart
enum AppLang { system, zhHant, en }
```

- `fromMap` already uses `firstWhere(..., orElse: () => AppLang.zhHant)`, so adding `system` is backward compatible with existing persisted rows.
- **Default stays `zhHant`** (no behavioural change for current users). Consider switching the default to `system` in a later release.

### 3.2 Map `AppLang` → `Locale?`

Add a helper (e.g. in `main.dart` next to `_themeModeOf`, or on `AppLang`):

```dart
static const supportedLocales = <Locale>[
  Locale('en'),
  Locale('zh'), // zh-Hant (see §1)
];

static Locale? _localeOf(AppLang lang) => switch (lang) {
      AppLang.system => null,            // null = follow device locale
      AppLang.zhHant => const Locale('zh'),
      AppLang.en     => const Locale('en'),
    };
```

When `locale: null`, Flutter resolves against `supportedLocales` using the device locale, falling back to the template (`en`) — acceptable, though product may prefer zh-Hant fallback (handled via `localeListResolutionCallback` if desired).

### 3.3 `MaterialApp` (`lib/main.dart`, the `Consumer<SettingsController>` builder)

The `Consumer<SettingsController>` already rebuilds `MaterialApp` on settings changes, so locale changes apply live. Add the delegates, supported locales, and `locale`:

```dart
child: Consumer<SettingsController>(
  builder: (context, settings, _) => MaterialApp(
    title: 'OpenSmartBatt',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: _themeModeOf(settings.themeMode),

    // i18n wiring ---------------------------------------------------------
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales, // or the const above
    locale: _localeOf(settings.lang),                    // null => system
    // ---------------------------------------------------------------------

    home: const RootShell(),
    builder: (context, child) { /* unchanged ×1.15 textScaler wrapper */ },
  ),
),
```

Imports to add in `main.dart`:
```dart
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
```

### 3.4 Re-add the Settings 語言 (Language) toggle

The Settings screen currently has **no** language control (it was removed). Re-add a row in the **Display** section (`lib/ui/settings/settings_screen.dart`, near the Theme segmented control around line 95–113), bound to `SettingsController.setLang`, persisted automatically via `SettingsRepo` (`setLang` → `update` → `saveSettings`). Use a segmented button / dropdown mirroring the Theme control:

```dart
final l10n = AppLocalizations.of(context);
// label: l10n.settingsLanguageLabel, sub: l10n.settingsLanguageSub
// options:
//   AppLang.zhHant -> l10n.settingsLanguageZhHant ("繁體中文")
//   AppLang.en     -> l10n.settingsLanguageEnglish ("English")
//   AppLang.system -> l10n.settingsLanguageSystem  ("跟隨系統" / "System")
// onChanged: (v) => context.read<SettingsController>().setLang(v)
```

New strings for this control: `settingsLanguageLabel`, `settingsLanguageSub`, `settingsLanguageZhHant`, `settingsLanguageEnglish`, `settingsLanguageSystem` (in the key table / ARBs).

---

## 4. Consolidated KEY TABLE

Identical strings are deduped into shared keys (`common*`, `relative*`). The "source area / replaces" column lists the original surveyed keys collapsed into each shared key.

### common (shared)

| key | en | zh | placeholders | source area / replaces |
|---|---|---|---|---|
| commonCancel | Cancel | 取消 | — | dashboard `commonCancel`, devices `devicesCancel`, settings `commonCancel` |
| commonConfirm | OK | 確定 | — | settings `commonConfirm` |
| commonContinue | Continue | 繼續 | — | dashboard `commonContinue` |
| commonClose | Close | 關閉 | — | settings `settingsAboutDialogClose` |
| commonNormal | Normal | 正常 | — | `statusBadgeCapacitorNormal`, `runStatusNormal`, `historyRowNormal`, `historyStatusNormal` |
| commonWarning | Warning | 警告 | — | `statusBadgeCapacitorWarn`, `historyStatusWarning` |
| commonCutOff | Cut-off | 斷電 | — | `statusBadgeCutOffLabel`, `runStatusCutOff` |
| commonAntiTheft | Anti-theft | 防盜 | — | `controlAntiTheft`, `runStatusAntiTheft` |
| commonReleaseCutOff | Release Cut-off | 解除斷電 | — | `controlReleaseCutOff`, `releaseDialogTitle` |
| commonNoRecordsToExport | No records to export | 沒有可匯出的紀錄 | — | `historyExportNothing`, `settingsExportNoRecords` |
| commonExportFailed | Export failed: {error} | 匯出失敗：{error} | error (String) | `historyExportFailed`, `settingsExportFailed` |
| commonOpenBrowserFailed | Could not open browser; link copied: {url} | 無法開啟瀏覽器，已複製連結：{url} | url (String) | `githubOpenFailedCopied`, `settingsOpenBrowserFailed` (en wording normalized) |
| relativeNever | Never connected | 從未連線 | — | `relativeTimeNever` |
| relativeJustNow | Just now | 剛剛 | — | `relativeTimeJustNow`, `devicesTimeJustNow` |
| relativeMinutesAgo | (plural) N minute(s) ago | {count} 分鐘前 | count (int) | `relativeTimeMinutesAgo`, `devicesTimeMinutesAgo` (en normalized to plural) |
| relativeHoursAgo | (plural) N hour(s) ago | {count} 小時前 | count (int) | `relativeTimeHoursAgo`, `devicesTimeHoursAgo` |
| relativeDaysAgo | (plural) N day(s) ago | {count} 天前 | count (int) | `relativeTimeDaysAgo`, `devicesTimeDaysAgo` |

> Normalization note: the dashboard used abbreviated en (`min/h/d ago`) while devices used `min/hr/days ago`. These are merged into one plural form per unit. The call sites pass the raw `int` count; `intl` formats it.

### shell / app (`main.dart`, `ui/util/update_check.dart`)

| key | en | zh | placeholders |
|---|---|---|---|
| navDashboard | Devices | 裝置 | — |
| navHistory | History | 歷史 | — |
| navSettings | Settings | 設定 | — |
| disclaimerCommunityEdition | Community Self-Help Edition · COMMUNITY EDITION | 社群自救版 · COMMUNITY EDITION | — |
| disclaimerBodyPara1 | This app is an open-source tool independently developed by the community, based on public reverse-engineering research, communicating over Bluetooth with the RCE smart capacitor/battery you already own. | 本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。 | — |
| disclaimerBodyPara2 | This project is NOT an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners who have purchased the hardware. | 本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。 | — |
| disclaimerDoNotRelock | After clearing the power cut-off, do not re-lock; the capacitor's own over-voltage / under-voltage / over-temperature protections remain active. | 解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。 | — |
| disclaimerAcknowledgeButton | I understand, get started | 我了解，開始使用 | — |
| disclaimerViewGithub | View GitHub project and docs | 查看 GitHub 專案與文件 | — |
| updateAlreadyLatest | Already up to date (or temporarily offline) | 已是最新版本（或暫時無法連線） | — |
| updateAvailableTitle | New version available {tag} | 有新版本 {tag} | tag (String) |
| updateAvailableBody | Current version v{version}. Go to GitHub to download the latest APK; uninstall the old version first before installing (a different signature prevents overwriting). | 目前版本 v{version}。前往 GitHub 下載最新版 APK，安裝前請先解除安裝舊版（簽章不同無法直接覆蓋）。 | version (String) |
| updateLaterButton | Later | 稍後 | — |
| updateDownloadButton | Download | 前往下載 | — |

> `githubOpenFailedCopied` is replaced by shared `commonOpenBrowserFailed` (placeholder `url`).

### dashboard (`ui/dashboard/*`)

| key | en | zh | placeholders |
|---|---|---|---|
| dashboardDeviceTypeDetected | Detected: {type} | 偵測到：{type} | type (String) |
| dashboardDeviceTypeSupercapacitor | Supercapacitor | 超級電容 | — |
| dashboardDeviceTypeSmartBattery | Smart Battery | 智慧電池 | — |
| dashboardDeviceTypePowerBank | Power Bank | 行動電源 | — |
| dashboardDeviceTypeRceDevice | RCE Device | RCE 裝置 | — |
| dashboardDeviceTypeWithName | {type} ({name}) | {type}（{name}） | type, name (String) |
| dashboardReadoutsHeading | Live Readings | 即時讀數 | — |
| dashboardReadoutTemperatureLabel | Temperature TEMP | 溫度 TEMP | — |
| dashboardReadoutSvltLabel | Secondary Voltage SVLT | 次電壓 SVLT | — |
| dashboardReadoutCurrentLabel | Main Current | 主電流 | — |
| dashboardReadoutSohLabel | Health SOH | 健康 SOH | — |
| dashboardDvolHeading | Per-Cell Voltage DVOL | 分串電壓 DVOL | — |
| dashboardProtectionHeading | Protection Status / Mode | 防護狀態 / 模式 | — |
| gaugePvltLabel | PVLT · Primary Voltage | PVLT · 主電壓 | — |
| gaugeSohUnknown | SOH -- | SOH -- | — |
| gaugeSohValue | SOH {soh}% · Health {label} | SOH {soh}% · 健康{label} | soh (int), label (String) |
| gaugeSohLabelGood | Good | 良好 | — |
| gaugeSohLabelFair | Fair | 普通 | — |
| gaugeSohLabelDegraded | Degraded | 衰退 | — |
| disconnectedTitle | No device connected | 尚未連線裝置 | — |
| disconnectedBody | Pick a saved device to reconnect quickly, or scan for nearby RCE capacitors. | 選擇已儲存的裝置快速重連，或掃描附近的 RCE 電容。 | — |
| disconnectedQuickSelectHeading | Quick Select | 快速選擇 | — |
| disconnectedScanButton | Scan other devices | 掃描其他裝置 | — |
| quickPickLastValue | Last {value} V | 上次 {value} V | value (String) |
| statusBadgeRunModeLabel | Run Mode | 運行模式 | — |
| statusBadgeCapacitorLabel | Capacitor Status | 電容狀態 | — |
| statusBadgeCutOffOn | On | 啟用 | — |
| statusBadgeCutOffOff | Off | 關閉 | — |
| controlDetectCapacitor | Check Capacitor | 檢測電容 | — |
| statusAdvisoryNote | This unit is detected as a Supercapacitor; only supported features are shown (anti-theft appears only on battery models that support it). After releasing the cut-off, avoid re-locking; the capacitor's own over-voltage / under-voltage / over-temperature protection remains active. | 本機已偵測為「超級電容」，僅顯示支援的功能（防盜模式僅在支援的電池型號出現）。解除斷電後建議勿再上鎖；電容本身過壓／低壓／過溫保護仍有效。 | — |
| capacitorCheckNoData | No capacitor readings yet; please wait for live data to update. | 尚未取得電容讀數，請稍候即時資料更新。 | — |
| capacitorCheckReadout | SOH {soh}% · Secondary Voltage {svlt} V · Primary Voltage {pvlt} V | SOH {soh}% · 次電壓 {svlt} V · 主電壓 {pvlt} V | soh, svlt, pvlt (String) |
| capacitorCheckSnack | Capacitor check: {msg} | 電容檢測：{msg} | msg (String) |
| releaseSentNoAuthSnack | Release command sent (experimental: no auth) | 已送出解除指令（實驗：未帶驗證） | — |
| releaseSentSnack | Release cut-off command sent | 已送出解除斷電指令 | — |
| releaseFailedSnack | Release failed: {error} | 解除失敗：{error} | error (String) |
| antiTheftDialogTitle | Enable Anti-theft Mode | 啟用防盜模式 | — |
| antiTheftDialogBody | Anti-theft mode is not fully verified and appears only on supported models. Are you sure you want to send the anti-theft command? | 防盜模式尚未經完整驗證，僅在支援的型號顯示。確定要送出防盜指令嗎？ | — |
| antiTheftSentSnack | Anti-theft command sent | 已送出防盜指令 | — |
| antiTheftFailedSnack | Command failed: {error} | 指令失敗：{error} | error (String) |
| releaseDialogErrorAuthFormat | Invalid auth value format (use decimal or 0x hexadecimal) | 驗證值格式錯誤（用十進位或 0x 十六進位） | — |
| releaseDialogErrorDealerLength | Dealer code must be at least 8 digits | 代理碼需至少 8 碼 | — |
| releaseDialogBody | Sends the known-safe "release" command (mode 0x06). Use the cut-off password, or enter your auth values directly. | 送出已知安全的「解除」指令(mode 0x06)。可用斷電密碼，或直接輸入你的驗證值。 | — |
| releaseDialogAuthModePassword | Password | 密碼 | — |
| releaseDialogAuthModeCode | Advanced: My Code | 進階：我的碼 | — |
| releaseDialogDealerCodeHint | Dealer code (auto-filled when connected) | 代理碼 (Dealer code, 連線時自動帶入) | — |
| releaseDialogPasswordHint | Cut-off password | 斷電密碼 | — |
| releaseDialogCbHint | cb (dealer code value, e.g. 168 or 0xA8) | cb (代理碼數值, 例 168 或 0xA8) | — |
| releaseDialogPwSumHint | pwSum (password checksum, e.g. 204 or 0xCC) | pwSum (密碼校驗值, 例 204 或 0xCC) | — |
| releaseDialogSkipAuthToggle | Experimental: send mode only, skip auth (unproven, fallback) | 實驗：只送 mode、跳過驗證（未證實，備案） | — |
| releaseDialogWarnBox | After releasing, do not re-lock; the capacitor's own over-voltage / under-voltage / over-temperature protection stays active. | 解除後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。 | — |
| releaseDialogConfirm | Confirm Release | 確認解除 | — |

> Replaced by shared keys: `statusBadgeCutOffLabel`→`commonCutOff`, `statusBadgeCapacitorWarn`→`commonWarning`, `statusBadgeCapacitorNormal`→`commonNormal`, `controlReleaseCutOff`/`releaseDialogTitle`→`commonReleaseCutOff`, `controlAntiTheft`/`runStatusAntiTheft`→`commonAntiTheft`, `runStatusCutOff`→`commonCutOff`, `runStatusNormal`→`commonNormal`, `commonCancel`/`commonContinue` shared.

### devices (`ui/devices/*`)

| key | en | zh | placeholders |
|---|---|---|---|
| devicesConnectFailed | Connection failed, please try again | 連線失敗，請再試一次 | — |
| devicesRemoveTitle | Remove device | 移除裝置 | — |
| devicesRemoveBody | Remove "{alias}" from your saved list? (The device itself is unaffected.) | 將「{alias}」從已儲存清單移除？（不影響裝置本身） | alias (String) |
| devicesRemove | Remove | 移除 | — |
| devicesSavedSection | Saved devices | 已儲存裝置 | — |
| devicesNoSaved | No saved devices yet | 尚無已儲存裝置 | — |
| devicesUnnamed | Unnamed device | 未命名裝置 | — |
| devicesScanning | Scanning… | 掃描中… | — |
| devicesNearbyNotFound | No nearby devices found (make sure the capacitor is powered on, Bluetooth is enabled, and you are close by) | 附近找不到裝置（確認電容已上電、藍牙開啟，並靠近一點） | — |
| devicesUnknownName | Unknown | Unknown | — |
| devicesShowRceOnly | Show RCE devices only | 只顯示 RCE 裝置 | — |
| devicesShowAllWithHidden | (plural) Show all BLE devices ({count} non-RCE hidden) | 顯示全部 BLE 裝置（隱藏了 {count} 個非 RCE） | count (int) |
| devicesShowAll | Show all BLE devices | 顯示全部 BLE 裝置 | — |
| devicesMetaLastSeen | Last {time} | 上次 {time} | time (String) |
| devicesSheetTitle | Select device | 選擇裝置 | — |
| devicesRescan | Rescan | 重新掃描 | — |
| devicesNearbyScanning | Scanning nearby… | 附近掃描中… | — |
| devicesNearby | Nearby | 附近裝置 | — |
| devicesDisconnect | Disconnect | 中斷 | — |
| devicesConnect | Connect | 連線 | — |
| devicesAdapterOff | Bluetooth is off. Turn on Bluetooth before scanning. | 藍牙未開啟，請先開啟藍牙再掃描 | — |
| devicesAliasSuggestion1 | Capacitor #1 (front car) | 電容 #1（前車） | — |
| devicesAliasSuggestion2 | Capacitor #2 (backup) | 電容 #2（後備） | — |
| devicesAliasSuggestion3 | Motorcycle capacitor | 機車電容 | — |
| devicesAliasRenameTitle | Rename | 重新命名 | — |
| devicesAliasSaveTitle | Save device | 儲存裝置 | — |
| devicesAliasRenameBody | Set a new alias for this device. | 為這顆裝置設定新的別名。 | — |
| devicesAliasSaveBody | Connected successfully. Give this device a memorable alias so you can quickly reconnect from "Saved devices" next time. | 已連線成功。為這顆裝置取一個好記的別名，下次可在「已儲存裝置」快速重連。 | — |
| devicesAliasSave | Save | 儲存 | — |
| devicesAliasSaveAlias | Save alias | 儲存別名 | — |
| devicesAliasSkip | Skip | 略過 | — |
| devicesAliasHint | e.g. Capacitor #1 (front car) | 例如：電容 #1（前車） | — |

> Replaced by shared keys: `devicesCancel`→`commonCancel`; `devicesTimeJustNow`→`relativeJustNow`; `devicesTimeMinutesAgo`→`relativeMinutesAgo`; `devicesTimeHoursAgo`→`relativeHoursAgo`; `devicesTimeDaysAgo`→`relativeDaysAgo`.

### history (`ui/history/history_screen.dart`)

| key | en | zh | placeholders |
|---|---|---|---|
| historyFilterAll | All | 全部 | — |
| historyFilterToday | Today | 今天 | — |
| historyFilterWarning | Warnings | 警告 | — |
| historyExportCsv | Export CSV | 匯出 CSV | — |
| historyExportSubject | OpenSmartBatt History | OpenSmartBatt 歷史紀錄 | — |
| historyChartTodayTitle | Today's Voltage Trend | 今日電壓趨勢 | — |
| historyChartTitle | Voltage Trend | 電壓趨勢 | — |
| historyLoadFailed | Failed to load history: {error} | 讀取歷史失敗：{error} | error (String) |
| historyEmptyToday | No records today.\nHistory is written automatically once a device is connected. | 今天還沒有紀錄。\n連線裝置後會自動寫入歷史。 | — |
| historyEmptyWarning | No warning or event records. | 沒有警告或事件紀錄。 | — |
| historyEmptyAll | No history yet.\nConnect a device and enable "Auto-logging" to start accumulating. | 尚無歷史紀錄。\n連線裝置並開啟「自動紀錄」即可開始累積。 | — |
| historyFooter | (plural) {count} records · Local SQLite · Export CSV / Share | 共 {count} 筆 · 本機 SQLite · 可匯出 CSV / 分享 | count (int) |
| historyRowEventCutOff | Cut-off mode activated | 斷電模式已啟動 | — |
| historyRowEventAntiTheft | Anti-theft mode activated | 防盜模式已啟動 | — |
| historyRowSoh | SOH {percent}% | SOH {percent}% | percent (int) |
| historyRowCurrent | Current {amps}A | 電流 {amps}A | amps (String) |
| historyRowThresholdWarning | Protection threshold warning | 保護門檻警告 | — |
| historyStatusEvent | Event | 事件 | — |
| historyChartInsufficientData | Not enough data to chart (need at least 2 records) | 資料不足以繪圖（需至少 2 筆） | — |

> Replaced by shared keys: `historyExportNothing`→`commonNoRecordsToExport`; `historyExportFailed`→`commonExportFailed`; `historyRowNormal`/`historyStatusNormal`→`commonNormal`; `historyStatusWarning`→`commonWarning`. (`historyFilterWarning` kept distinct: en "Warnings" plural ≠ "Warning".)

### settings (`ui/settings/settings_screen.dart`)

| key | en | zh | placeholders |
|---|---|---|---|
| settingsConnectionHeading | Connection | 連線 | — |
| settingsAutoReconnectLabel | Auto-reconnect | 自動重連 | — |
| settingsAutoReconnectSub | Automatically attempt to reconnect when the connection drops | 連線中斷時自動嘗試重連 | — |
| settingsKeepAwakeLabel | Keep screen awake while connected | 連線時保持螢幕喚醒 | — |
| settingsKeepAwakeSub | Screen won't turn off automatically, handy for viewing while riding (active when connected) | 螢幕不自動關閉，方便邊騎邊看（連線時生效） | — |
| settingsDisplayHeading | Display | 顯示 | — |
| settingsThemeLabel | Theme | 主題 | — |
| settingsThemeSub | Interface colors (Auto: follow system) | 介面配色（自動：跟隨系統） | — |
| settingsThemeLight | Light | 淺色 | — |
| settingsThemeDark | Dark | 深色 | — |
| settingsThemeAuto | Auto | 自動 | — |
| settingsTempUnitLabel | Temperature unit | 溫度單位 | — |
| settingsLanguageLabel | Language | 語言 | — (NEW, re-added toggle) |
| settingsLanguageSub | Interface language (System: follow device) | 介面語言（系統：跟隨裝置） | — (NEW) |
| settingsLanguageZhHant | 繁體中文 | 繁體中文 | — (NEW) |
| settingsLanguageEnglish | English | English | — (NEW) |
| settingsLanguageSystem | System | 跟隨系統 | — (NEW) |
| settingsDataHeading | Data | 資料 | — |
| settingsAutoLogLabel | Auto-record | 自動紀錄 | — |
| settingsAutoLogSub | Automatically write to history while connected | 連線時自動寫入歷史 | — |
| settingsExportAllLabel | Export all data (CSV) | 匯出全部資料 (CSV) | — |
| settingsClearHistoryLabel | Clear history | 清除歷史紀錄 | — |
| settingsExportSubjectAllData | OpenSmartBatt all data | OpenSmartBatt 全部資料 | — |
| settingsClearHistoryTitle | Clear history | 清除歷史紀錄 | — |
| settingsClearHistoryBody | This will delete all telemetry history on this device. This action cannot be undone. | 將刪除本機所有遙測歷史。此動作無法復原。 | — |
| settingsClearConfirm | Clear | 清除 | — |
| settingsHistoryCleared | History cleared | 已清除歷史紀錄 | — |
| settingsDiagnosticsHeading | Diagnostics / Developer | 診斷 / 開發者 | — |
| settingsRawPacketLogLabel | Log raw Bluetooth packets | 記錄原始藍牙封包 | — |
| settingsRawPacketLogSub | Logs raw TX/RX hex for reporting issues or helping decode unknown commands. Off by default | 記錄 TX/RX 原始 hex，供回報問題或協助破解未知指令。預設關閉 | — |
| settingsLogMaxSizeLabel | Log size limit | 日誌容量上限 | — |
| settingsLogMaxSizeSub | Automatically rotates and overwrites when exceeded | 超過自動輪替覆蓋 | — |
| settingsExportLogLabel | Export diagnostic log (.log) | 匯出診斷日誌 (.log) | — |
| settingsClearLogLabel | Clear diagnostic log | 清除診斷日誌 | — |
| settingsLogEmpty | Diagnostic log is empty | 診斷日誌為空 | — |
| settingsExportSubjectDiagLog | OpenSmartBatt diagnostic log | OpenSmartBatt 診斷日誌 | — |
| settingsClearLogTitle | Clear diagnostic log | 清除診斷日誌 | — |
| settingsClearLogBody | This will delete all raw TX/RX packet records on this device. | 將刪除本機所有原始 TX/RX 封包紀錄。 | — |
| settingsLogCleared | Diagnostic log cleared | 已清除診斷日誌 | — |
| settingsAboutHeading | About | 關於 | — |
| settingsVersionLabel | Version | 版本 | — |
| settingsVersionSub | OpenSmartBatt Community Edition | OpenSmartBatt 社群版 | — |
| settingsCheckUpdateLabel | Check for updates | 檢查更新 | — |
| settingsGithubLabel | GitHub project page | GitHub 專案頁面 | — |
| settingsProtocolDocLabel | Protocol document PROTOCOL.md | 協定文件 PROTOCOL.md | — |
| settingsCopyrightLabel | Copyright & disclaimer | 版權與免責聲明 | — |
| settingsAboutDialogTitle | Copyright & disclaimer | 版權與免責聲明 | — |
| settingsAboutDialogBody | This app is an independent, community-developed open-source tool based on public reverse-engineering research, communicating via Bluetooth with the RCE smart capacitor/battery you have purchased.\n\nThis project is not an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners of the hardware. | 本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。\n\n本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。 | — |
| settingsAboutDialogWarning | Do not re-lock after releasing the power cut-off; the capacitor's own over-voltage / under-voltage / over-temperature protection remains active. | 解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。 | — |

> Replaced by shared keys: `settingsExportNoRecords`→`commonNoRecordsToExport`; `settingsExportFailed`→`commonExportFailed`; `settingsOpenBrowserFailed`→`commonOpenBrowserFailed`; `settingsAboutDialogClose`→`commonClose`; `commonConfirm`/`commonCancel` shared.
> Note: `settingsAboutDialogBody` is kept distinct from `disclaimerBodyPara1/2` because its en wording differs and it joins both paragraphs with literal `\n\n`.

**Total unique keys: 183** (after dedupe: 17 common + 14 shell + 52 dashboard + 32 devices + 19 history + 49 settings).

---

## 5. Placeholder & plural handling (ARB syntax)

### 5.1 Simple placeholders (`{error}`, `{url}`, `{tag}`, etc.)

```json
"commonExportFailed": "Export failed: {error}",
"@commonExportFailed": {
  "placeholders": { "error": { "type": "String" } }
}
```

Generates `String commonExportFailed(String error)` →
`l10n.commonExportFailed(e.toString())`.

Snackbar usage (needs a `BuildContext` / `ScaffoldMessenger`):
```dart
ScaffoldMessenger.of(context)
  .showSnackBar(SnackBar(content: Text(l10n.commonExportFailed('$e'))));
```

### 5.2 Plural (`{count}`)

```json
"relativeMinutesAgo": "{count, plural, =1{1 minute ago} other{{count} minutes ago}}",
"@relativeMinutesAgo": {
  "placeholders": { "count": { "type": "int" } }
}
```
zh (no plural category — single `other`):
```json
"relativeMinutesAgo": "{count, plural, other{{count} 分鐘前}}"
```
Call: `l10n.relativeMinutesAgo(minutes)` (pass the raw `int`).

`historyFooter` mixes plural + an `intl`-formatted count; declare `count` as `int` and let gen_l10n format:
```json
"historyFooter": "{count, plural, =1{1 record · Local SQLite · Export CSV / Share} other{{count} records · Local SQLite · Export CSV / Share}}",
"@historyFooter": {
  "placeholders": { "count": { "type": "int", "format": "decimalPattern" } }
}
```
This replaces the manual `NumberFormat.decimalPattern()` call — `intl` applies locale grouping automatically.

### 5.3 Number/voltage placeholders

Pre-formatted display values (`value`, `svlt`, `pvlt`, `amps`, and `soh` that may be `'--'`) are declared as **String** so the existing `toStringAsFixed(...)` call sites keep formatting:
```json
"capacitorCheckReadout": "SOH {soh}% · Secondary Voltage {svlt} V · Primary Voltage {pvlt} V",
"@capacitorCheckReadout": {
  "placeholders": {
    "soh": { "type": "String" },
    "svlt": { "type": "String" },
    "pvlt": { "type": "String" }
  }
}
```
(Where a value is a clean `int` and locale-aware grouping is wanted, use `{ "type": "int", "format": "decimalPattern" }` instead — e.g. `gaugeSohValue.soh`, `historyRowSoh.percent`.)

### 5.4 Composed strings — split into parts

`capacitorCheckReadout` conditionally appends `svlt`/`pvlt`; `statusAdvisoryNote` was concatenated from two literals. For ARB, prefer one key per *renderable* string. Where segments are conditional (svlt/pvlt may be absent), build the joined string in Dart from smaller keys (e.g. `capacitorCheckSohPart`, `capacitorCheckSvltPart`) joined with `' · '`, OR pass `'--'`/empty and accept the placeholder. This plan keeps `capacitorCheckReadout` as a single key with all three placeholders (simplest); if conditional omission matters, split during implementation.

---

## 6. Migration order & later changes

### 6.1 File-by-file order (smallest blast radius first)

1. **Config**: add deps, `generate: true`, `l10n.yaml`; create `lib/l10n/app_en.arb` + `app_zh.arb` (full content in §7). Run `flutter gen-l10n` and confirm `AppLocalizations` generates.
2. **`lib/models/app_settings.dart`**: add `AppLang.system` (low risk; backward-compatible `fromMap`).
3. **`lib/main.dart`**: add delegates, `supportedLocales`, `locale: _localeOf(settings.lang)`. Migrate `navDashboard/History/Settings` and the disclaimer dialog strings. (The disclaimer `Text.rich` bold spans — see §7 risks.)
4. **`lib/ui/util/update_check.dart`**: 5 update strings (all need `context`).
5. **`lib/ui/settings/settings_screen.dart`**: migrate all `settings*` strings; **re-add the 語言 toggle** bound to `SettingsController.setLang`.
6. **`lib/ui/history/history_screen.dart`**: filters, chart titles, empty states, rows, footer plural.
7. **`lib/ui/devices/device_list_sheet.dart`** + **`alias_dialog.dart`**: device list, relative-time (shared plural keys), alias dialogs.
8. **`lib/ui/dashboard/*`**: `dashboard_page.dart`, `pvlt_gauge.dart` (gauge — see §7), `disconnected_state.dart`, `status_controls.dart`, `release_cutoff_dialog.dart`.
9. **Sweep**: grep for remaining CJK literals to catch stragglers:
   `grep -rnP '[\x{4e00}-\x{9fff}]' app_flutter/lib --include=*.dart` (should only match comments/doc-strings afterwards).
10. **Tests**: any widget test asserting on zh literals must pump with a fixed `locale` and `AppLocalizations.delegate` (wrap in `MaterialApp` with `localizationsDelegates`), or assert via the localized lookup.

### 6.2 Adding a new language later

1. Copy `app_en.arb` → `app_<code>.arb` (e.g. `app_ja.arb`), translate values, set `"@@locale": "<code>"`.
2. Add `Locale('<code>')` to `supportedLocales` (or rely on `AppLocalizations.supportedLocales`).
3. (Optional) add an `AppLang` enum value + a Settings toggle option + `_localeOf` mapping. If you only want device-driven selection, `system` already picks it up with no enum change.
4. For Simplified Chinese: rename `app_zh.arb` → `app_zh_Hant.arb` and add `app_zh_Hans.arb`; update `template-arb-file` only if the template language changes (it won't).

### 6.3 Dates / numbers (intl)

- `intl` is already a dependency and is initialized per-locale by `gen_l10n` / `GlobalMaterialLocalizations`.
- Use `NumberFormat`/`DateFormat` with the active locale: `Localizations.localeName(context)` or `Intl.getCurrentLocale()`, e.g. `DateFormat.Hm(Localizations.localeName(context)).format(dt)`.
- Counts passed to plural ARB keys (`historyFooter`, relative-time) are formatted by `intl` via the `format` placeholder attribute — drop manual `NumberFormat` at those sites.
- Voltage/current values keep `toStringAsFixed(n)` (fixed precision, not locale-formatted) and are passed as String placeholders. If locale-aware decimal separators are desired, switch to `NumberFormat` + numeric placeholders.

---

## 7. Risks & edge cases

- **`const` widgets must drop `const`.** `AppLocalizations.of(context)` is runtime, so any `const Text('…')` / `const`-constructed widget tree containing a localized string must drop `const`. Many nav labels, headings, and dialog buttons in this codebase are `const` today. Removing `const` is required and may surface lints — expect broad but mechanical edits.
- **Gauge / `CustomPaint` text (`pvlt_gauge.dart`).** `gaugePvltLabel`, `gaugeSohUnknown`, `gaugeSohValue`, and the SOH bucket labels are painted inside a `CustomPainter`, which has no `BuildContext`. Resolve the strings in the host widget's `build` (where context exists) and pass them into the painter via constructor fields (e.g. `PvltGaugePainter(pvltLabel: l10n.gaugePvltLabel, sohText: ...)`). Do NOT call `AppLocalizations.of` inside `paint()`. Also: a `CustomPainter`'s `shouldRepaint` must compare these string fields so locale changes trigger a repaint.
- **SnackBars / dialogs need a valid `context`.** All `*Snack`, dialog titles/bodies/buttons require an in-tree `BuildContext`. Capture `final l10n = AppLocalizations.of(context);` and the `ScaffoldMessenger` before any `await` to avoid "use of context across async gaps" lints; do not reuse a context after the widget may be unmounted (`if (!mounted) return;`).
- **Bold inline spans in the disclaimer (`Text.rich`).** `disclaimerBodyPara1/2` are built from 5 `TextSpan`s with inline bold on specific zh phrases. A single ARB string loses the bold. Options: (a) accept plain (no bold) — simplest; (b) split each paragraph into segment keys (`...Para1SegA`, `...Para1Bold`, …) and reassemble `TextSpan`s — preserves bold but multiplies keys and is fragile across languages where the emphasized phrase differs. Recommendation: (a) for v1, revisit if design requires emphasis. Same applies to `settingsAboutDialogBody`.
- **Newlines in ARB.** `historyEmpty*` and `settingsAboutDialogBody` contain `\n` / `\n\n`. JSON requires escaped `\n` (already escaped in §7 ARBs). Verify rendering (no literal backslash-n).
- **Mixed-language strings stay mixed.** `disclaimerCommunityEdition` keeps the English "COMMUNITY EDITION" half in both locales; register mnemonics (`TEMP`, `SVLT`, `SOH`, `DVOL`, `PVLT`), protocol tokens (`mode 0x06`, `cb`, `pwSum`, hex examples), brand/product names, and the literal `'v'` version prefix are intentionally verbatim in both ARBs — do not "translate" them.
- **Full-width vs ASCII punctuation.** zh uses full-width parens `（）` and colon `：`; en uses ASCII `()` `:`. Captured per-locale in the ARBs (e.g. `dashboardDeviceTypeWithName`). Keep them distinct per locale.
- **`devicesUnknownName` ("Unknown").** Currently hard-coded English but user-visible; now a key — zh keeps "Unknown" (matches survey) but it is translatable if product wants 未知.
- **Plural-category mismatch.** zh has only the `other` plural category; en has `one`/`other`. Ensure zh ARB uses `{count, plural, other{…}}` only (extra categories are ignored but noisy). The dashboard↔devices relative-time en wording is normalized to one plural form (behavioural copy change in en only).
- **`historyFilterWarning` vs `commonWarning`.** Same zh ("警告") but en differs ("Warnings" plural vs "Warning"); kept as separate keys — do not merge.
- **Default locale / fallback.** Default remains `zhHant` (no regression). With `AppLang.system`, an unsupported device locale falls back to the template `en`. If product prefers zh-Hant fallback, add a `localeResolutionCallback`.
- **`textScaler` builder unaffected**, but verify English (longer strings) doesn't overflow buttons/badges at the ×1.15 scale — en text is generally longer than zh; check the bottom-nav labels, status badges, and segmented controls.
- **Generated code & CI.** With synthetic package (default), generated sources aren't committed; CI must run `flutter pub get` (or `flutter gen-l10n`) before analyze/build. If committing generated files is preferred, set `synthetic-package: false` + `output-dir` in `l10n.yaml`.

---

## 8. ARB files (copy-paste ready)

### 8.1 `app_flutter/lib/l10n/app_en.arb` (template)

```json
{
  "@@locale": "en",

  "commonCancel": "Cancel",
  "commonConfirm": "OK",
  "commonContinue": "Continue",
  "commonClose": "Close",
  "commonNormal": "Normal",
  "commonWarning": "Warning",
  "commonCutOff": "Cut-off",
  "commonAntiTheft": "Anti-theft",
  "commonReleaseCutOff": "Release Cut-off",
  "commonNoRecordsToExport": "No records to export",
  "commonExportFailed": "Export failed: {error}",
  "@commonExportFailed": {
    "placeholders": { "error": { "type": "String" } }
  },
  "commonOpenBrowserFailed": "Could not open browser; link copied: {url}",
  "@commonOpenBrowserFailed": {
    "placeholders": { "url": { "type": "String" } }
  },
  "relativeNever": "Never connected",
  "relativeJustNow": "Just now",
  "relativeMinutesAgo": "{count, plural, =1{1 minute ago} other{{count} minutes ago}}",
  "@relativeMinutesAgo": {
    "placeholders": { "count": { "type": "int" } }
  },
  "relativeHoursAgo": "{count, plural, =1{1 hour ago} other{{count} hours ago}}",
  "@relativeHoursAgo": {
    "placeholders": { "count": { "type": "int" } }
  },
  "relativeDaysAgo": "{count, plural, =1{1 day ago} other{{count} days ago}}",
  "@relativeDaysAgo": {
    "placeholders": { "count": { "type": "int" } }
  },

  "navDashboard": "Devices",
  "navHistory": "History",
  "navSettings": "Settings",
  "disclaimerCommunityEdition": "Community Self-Help Edition · COMMUNITY EDITION",
  "disclaimerBodyPara1": "This app is an open-source tool independently developed by the community, based on public reverse-engineering research, communicating over Bluetooth with the RCE smart capacitor/battery you already own.",
  "disclaimerBodyPara2": "This project is NOT an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners who have purchased the hardware.",
  "disclaimerDoNotRelock": "After clearing the power cut-off, do not re-lock; the capacitor's own over-voltage / under-voltage / over-temperature protections remain active.",
  "disclaimerAcknowledgeButton": "I understand, get started",
  "disclaimerViewGithub": "View GitHub project and docs",
  "updateAlreadyLatest": "Already up to date (or temporarily offline)",
  "updateAvailableTitle": "New version available {tag}",
  "@updateAvailableTitle": {
    "placeholders": { "tag": { "type": "String" } }
  },
  "updateAvailableBody": "Current version v{version}. Go to GitHub to download the latest APK; uninstall the old version first before installing (a different signature prevents overwriting).",
  "@updateAvailableBody": {
    "placeholders": { "version": { "type": "String" } }
  },
  "updateLaterButton": "Later",
  "updateDownloadButton": "Download",

  "dashboardDeviceTypeDetected": "Detected: {type}",
  "@dashboardDeviceTypeDetected": {
    "placeholders": { "type": { "type": "String" } }
  },
  "dashboardDeviceTypeSupercapacitor": "Supercapacitor",
  "dashboardDeviceTypeSmartBattery": "Smart Battery",
  "dashboardDeviceTypePowerBank": "Power Bank",
  "dashboardDeviceTypeRceDevice": "RCE Device",
  "dashboardDeviceTypeWithName": "{type} ({name})",
  "@dashboardDeviceTypeWithName": {
    "placeholders": {
      "type": { "type": "String" },
      "name": { "type": "String" }
    }
  },
  "dashboardReadoutsHeading": "Live Readings",
  "dashboardReadoutTemperatureLabel": "Temperature TEMP",
  "dashboardReadoutSvltLabel": "Secondary Voltage SVLT",
  "dashboardReadoutCurrentLabel": "Main Current",
  "dashboardReadoutSohLabel": "Health SOH",
  "dashboardDvolHeading": "Per-Cell Voltage DVOL",
  "dashboardProtectionHeading": "Protection Status / Mode",
  "gaugePvltLabel": "PVLT · Primary Voltage",
  "gaugeSohUnknown": "SOH --",
  "gaugeSohValue": "SOH {soh}% · Health {label}",
  "@gaugeSohValue": {
    "placeholders": {
      "soh": { "type": "int" },
      "label": { "type": "String" }
    }
  },
  "gaugeSohLabelGood": "Good",
  "gaugeSohLabelFair": "Fair",
  "gaugeSohLabelDegraded": "Degraded",
  "disconnectedTitle": "No device connected",
  "disconnectedBody": "Pick a saved device to reconnect quickly, or scan for nearby RCE capacitors.",
  "disconnectedQuickSelectHeading": "Quick Select",
  "disconnectedScanButton": "Scan other devices",
  "quickPickLastValue": "Last {value} V",
  "@quickPickLastValue": {
    "placeholders": { "value": { "type": "String" } }
  },
  "statusBadgeRunModeLabel": "Run Mode",
  "statusBadgeCapacitorLabel": "Capacitor Status",
  "statusBadgeCutOffOn": "On",
  "statusBadgeCutOffOff": "Off",
  "controlDetectCapacitor": "Check Capacitor",
  "statusAdvisoryNote": "This unit is detected as a Supercapacitor; only supported features are shown (anti-theft appears only on battery models that support it). After releasing the cut-off, avoid re-locking; the capacitor's own over-voltage / under-voltage / over-temperature protection remains active.",
  "capacitorCheckNoData": "No capacitor readings yet; please wait for live data to update.",
  "capacitorCheckReadout": "SOH {soh}% · Secondary Voltage {svlt} V · Primary Voltage {pvlt} V",
  "@capacitorCheckReadout": {
    "placeholders": {
      "soh": { "type": "String" },
      "svlt": { "type": "String" },
      "pvlt": { "type": "String" }
    }
  },
  "capacitorCheckSnack": "Capacitor check: {msg}",
  "@capacitorCheckSnack": {
    "placeholders": { "msg": { "type": "String" } }
  },
  "releaseSentNoAuthSnack": "Release command sent (experimental: no auth)",
  "releaseSentSnack": "Release cut-off command sent",
  "releaseFailedSnack": "Release failed: {error}",
  "@releaseFailedSnack": {
    "placeholders": { "error": { "type": "String" } }
  },
  "antiTheftDialogTitle": "Enable Anti-theft Mode",
  "antiTheftDialogBody": "Anti-theft mode is not fully verified and appears only on supported models. Are you sure you want to send the anti-theft command?",
  "antiTheftSentSnack": "Anti-theft command sent",
  "antiTheftFailedSnack": "Command failed: {error}",
  "@antiTheftFailedSnack": {
    "placeholders": { "error": { "type": "String" } }
  },
  "releaseDialogErrorAuthFormat": "Invalid auth value format (use decimal or 0x hexadecimal)",
  "releaseDialogErrorDealerLength": "Dealer code must be at least 8 digits",
  "releaseDialogBody": "Sends the known-safe \"release\" command (mode 0x06). Use the cut-off password, or enter your auth values directly.",
  "releaseDialogAuthModePassword": "Password",
  "releaseDialogAuthModeCode": "Advanced: My Code",
  "releaseDialogDealerCodeHint": "Dealer code (auto-filled when connected)",
  "releaseDialogPasswordHint": "Cut-off password",
  "releaseDialogCbHint": "cb (dealer code value, e.g. 168 or 0xA8)",
  "releaseDialogPwSumHint": "pwSum (password checksum, e.g. 204 or 0xCC)",
  "releaseDialogSkipAuthToggle": "Experimental: send mode only, skip auth (unproven, fallback)",
  "releaseDialogWarnBox": "After releasing, do not re-lock; the capacitor's own over-voltage / under-voltage / over-temperature protection stays active.",
  "releaseDialogConfirm": "Confirm Release",

  "devicesConnectFailed": "Connection failed, please try again",
  "devicesRemoveTitle": "Remove device",
  "devicesRemoveBody": "Remove \"{alias}\" from your saved list? (The device itself is unaffected.)",
  "@devicesRemoveBody": {
    "placeholders": { "alias": { "type": "String" } }
  },
  "devicesRemove": "Remove",
  "devicesSavedSection": "Saved devices",
  "devicesNoSaved": "No saved devices yet",
  "devicesUnnamed": "Unnamed device",
  "devicesScanning": "Scanning…",
  "devicesNearbyNotFound": "No nearby devices found (make sure the capacitor is powered on, Bluetooth is enabled, and you are close by)",
  "devicesUnknownName": "Unknown",
  "devicesShowRceOnly": "Show RCE devices only",
  "devicesShowAllWithHidden": "{count, plural, =1{Show all BLE devices (1 non-RCE hidden)} other{Show all BLE devices ({count} non-RCE hidden)}}",
  "@devicesShowAllWithHidden": {
    "placeholders": { "count": { "type": "int" } }
  },
  "devicesShowAll": "Show all BLE devices",
  "devicesMetaLastSeen": "Last {time}",
  "@devicesMetaLastSeen": {
    "placeholders": { "time": { "type": "String" } }
  },
  "devicesSheetTitle": "Select device",
  "devicesRescan": "Rescan",
  "devicesNearbyScanning": "Scanning nearby…",
  "devicesNearby": "Nearby",
  "devicesDisconnect": "Disconnect",
  "devicesConnect": "Connect",
  "devicesAdapterOff": "Bluetooth is off. Turn on Bluetooth before scanning.",
  "devicesAliasSuggestion1": "Capacitor #1 (front car)",
  "devicesAliasSuggestion2": "Capacitor #2 (backup)",
  "devicesAliasSuggestion3": "Motorcycle capacitor",
  "devicesAliasRenameTitle": "Rename",
  "devicesAliasSaveTitle": "Save device",
  "devicesAliasRenameBody": "Set a new alias for this device.",
  "devicesAliasSaveBody": "Connected successfully. Give this device a memorable alias so you can quickly reconnect from \"Saved devices\" next time.",
  "devicesAliasSave": "Save",
  "devicesAliasSaveAlias": "Save alias",
  "devicesAliasSkip": "Skip",
  "devicesAliasHint": "e.g. Capacitor #1 (front car)",

  "historyFilterAll": "All",
  "historyFilterToday": "Today",
  "historyFilterWarning": "Warnings",
  "historyExportCsv": "Export CSV",
  "historyExportSubject": "OpenSmartBatt History",
  "historyChartTodayTitle": "Today's Voltage Trend",
  "historyChartTitle": "Voltage Trend",
  "historyLoadFailed": "Failed to load history: {error}",
  "@historyLoadFailed": {
    "placeholders": { "error": { "type": "String" } }
  },
  "historyEmptyToday": "No records today.\nHistory is written automatically once a device is connected.",
  "historyEmptyWarning": "No warning or event records.",
  "historyEmptyAll": "No history yet.\nConnect a device and enable \"Auto-logging\" to start accumulating.",
  "historyFooter": "{count, plural, =1{1 record · Local SQLite · Export CSV / Share} other{{count} records · Local SQLite · Export CSV / Share}}",
  "@historyFooter": {
    "placeholders": { "count": { "type": "int", "format": "decimalPattern" } }
  },
  "historyRowEventCutOff": "Cut-off mode activated",
  "historyRowEventAntiTheft": "Anti-theft mode activated",
  "historyRowSoh": "SOH {percent}%",
  "@historyRowSoh": {
    "placeholders": { "percent": { "type": "int" } }
  },
  "historyRowCurrent": "Current {amps}A",
  "@historyRowCurrent": {
    "placeholders": { "amps": { "type": "String" } }
  },
  "historyRowThresholdWarning": "Protection threshold warning",
  "historyStatusEvent": "Event",
  "historyChartInsufficientData": "Not enough data to chart (need at least 2 records)",

  "settingsConnectionHeading": "Connection",
  "settingsAutoReconnectLabel": "Auto-reconnect",
  "settingsAutoReconnectSub": "Automatically attempt to reconnect when the connection drops",
  "settingsKeepAwakeLabel": "Keep screen awake while connected",
  "settingsKeepAwakeSub": "Screen won't turn off automatically, handy for viewing while riding (active when connected)",
  "settingsDisplayHeading": "Display",
  "settingsThemeLabel": "Theme",
  "settingsThemeSub": "Interface colors (Auto: follow system)",
  "settingsThemeLight": "Light",
  "settingsThemeDark": "Dark",
  "settingsThemeAuto": "Auto",
  "settingsTempUnitLabel": "Temperature unit",
  "settingsLanguageLabel": "Language",
  "settingsLanguageSub": "Interface language (System: follow device)",
  "settingsLanguageZhHant": "繁體中文",
  "settingsLanguageEnglish": "English",
  "settingsLanguageSystem": "System",
  "settingsDataHeading": "Data",
  "settingsAutoLogLabel": "Auto-record",
  "settingsAutoLogSub": "Automatically write to history while connected",
  "settingsExportAllLabel": "Export all data (CSV)",
  "settingsClearHistoryLabel": "Clear history",
  "settingsExportSubjectAllData": "OpenSmartBatt all data",
  "settingsClearHistoryTitle": "Clear history",
  "settingsClearHistoryBody": "This will delete all telemetry history on this device. This action cannot be undone.",
  "settingsClearConfirm": "Clear",
  "settingsHistoryCleared": "History cleared",
  "settingsDiagnosticsHeading": "Diagnostics / Developer",
  "settingsRawPacketLogLabel": "Log raw Bluetooth packets",
  "settingsRawPacketLogSub": "Logs raw TX/RX hex for reporting issues or helping decode unknown commands. Off by default",
  "settingsLogMaxSizeLabel": "Log size limit",
  "settingsLogMaxSizeSub": "Automatically rotates and overwrites when exceeded",
  "settingsExportLogLabel": "Export diagnostic log (.log)",
  "settingsClearLogLabel": "Clear diagnostic log",
  "settingsLogEmpty": "Diagnostic log is empty",
  "settingsExportSubjectDiagLog": "OpenSmartBatt diagnostic log",
  "settingsClearLogTitle": "Clear diagnostic log",
  "settingsClearLogBody": "This will delete all raw TX/RX packet records on this device.",
  "settingsLogCleared": "Diagnostic log cleared",
  "settingsAboutHeading": "About",
  "settingsVersionLabel": "Version",
  "settingsVersionSub": "OpenSmartBatt Community Edition",
  "settingsCheckUpdateLabel": "Check for updates",
  "settingsGithubLabel": "GitHub project page",
  "settingsProtocolDocLabel": "Protocol document PROTOCOL.md",
  "settingsCopyrightLabel": "Copyright & disclaimer",
  "settingsAboutDialogTitle": "Copyright & disclaimer",
  "settingsAboutDialogBody": "This app is an independent, community-developed open-source tool based on public reverse-engineering research, communicating via Bluetooth with the RCE smart capacitor/battery you have purchased.\n\nThis project is not an official RCE product and has no affiliation with the manufacturer; it is intended solely for personal, non-commercial use by owners of the hardware.",
  "settingsAboutDialogWarning": "Do not re-lock after releasing the power cut-off; the capacitor's own over-voltage / under-voltage / over-temperature protection remains active."
}
```

### 8.2 `app_flutter/lib/l10n/app_zh.arb`

```json
{
  "@@locale": "zh",

  "commonCancel": "取消",
  "commonConfirm": "確定",
  "commonContinue": "繼續",
  "commonClose": "關閉",
  "commonNormal": "正常",
  "commonWarning": "警告",
  "commonCutOff": "斷電",
  "commonAntiTheft": "防盜",
  "commonReleaseCutOff": "解除斷電",
  "commonNoRecordsToExport": "沒有可匯出的紀錄",
  "commonExportFailed": "匯出失敗：{error}",
  "commonOpenBrowserFailed": "無法開啟瀏覽器，已複製連結：{url}",
  "relativeNever": "從未連線",
  "relativeJustNow": "剛剛",
  "relativeMinutesAgo": "{count, plural, other{{count} 分鐘前}}",
  "relativeHoursAgo": "{count, plural, other{{count} 小時前}}",
  "relativeDaysAgo": "{count, plural, other{{count} 天前}}",

  "navDashboard": "裝置",
  "navHistory": "歷史",
  "navSettings": "設定",
  "disclaimerCommunityEdition": "社群自救版 · COMMUNITY EDITION",
  "disclaimerBodyPara1": "本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。",
  "disclaimerBodyPara2": "本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。",
  "disclaimerDoNotRelock": "解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。",
  "disclaimerAcknowledgeButton": "我了解，開始使用",
  "disclaimerViewGithub": "查看 GitHub 專案與文件",
  "updateAlreadyLatest": "已是最新版本（或暫時無法連線）",
  "updateAvailableTitle": "有新版本 {tag}",
  "updateAvailableBody": "目前版本 v{version}。前往 GitHub 下載最新版 APK，安裝前請先解除安裝舊版（簽章不同無法直接覆蓋）。",
  "updateLaterButton": "稍後",
  "updateDownloadButton": "前往下載",

  "dashboardDeviceTypeDetected": "偵測到：{type}",
  "dashboardDeviceTypeSupercapacitor": "超級電容",
  "dashboardDeviceTypeSmartBattery": "智慧電池",
  "dashboardDeviceTypePowerBank": "行動電源",
  "dashboardDeviceTypeRceDevice": "RCE 裝置",
  "dashboardDeviceTypeWithName": "{type}（{name}）",
  "dashboardReadoutsHeading": "即時讀數",
  "dashboardReadoutTemperatureLabel": "溫度 TEMP",
  "dashboardReadoutSvltLabel": "次電壓 SVLT",
  "dashboardReadoutCurrentLabel": "主電流",
  "dashboardReadoutSohLabel": "健康 SOH",
  "dashboardDvolHeading": "分串電壓 DVOL",
  "dashboardProtectionHeading": "防護狀態 / 模式",
  "gaugePvltLabel": "PVLT · 主電壓",
  "gaugeSohUnknown": "SOH --",
  "gaugeSohValue": "SOH {soh}% · 健康{label}",
  "gaugeSohLabelGood": "良好",
  "gaugeSohLabelFair": "普通",
  "gaugeSohLabelDegraded": "衰退",
  "disconnectedTitle": "尚未連線裝置",
  "disconnectedBody": "選擇已儲存的裝置快速重連，或掃描附近的 RCE 電容。",
  "disconnectedQuickSelectHeading": "快速選擇",
  "disconnectedScanButton": "掃描其他裝置",
  "quickPickLastValue": "上次 {value} V",
  "statusBadgeRunModeLabel": "運行模式",
  "statusBadgeCapacitorLabel": "電容狀態",
  "statusBadgeCutOffOn": "啟用",
  "statusBadgeCutOffOff": "關閉",
  "controlDetectCapacitor": "檢測電容",
  "statusAdvisoryNote": "本機已偵測為「超級電容」，僅顯示支援的功能（防盜模式僅在支援的電池型號出現）。解除斷電後建議勿再上鎖；電容本身過壓／低壓／過溫保護仍有效。",
  "capacitorCheckNoData": "尚未取得電容讀數，請稍候即時資料更新。",
  "capacitorCheckReadout": "SOH {soh}% · 次電壓 {svlt} V · 主電壓 {pvlt} V",
  "capacitorCheckSnack": "電容檢測：{msg}",
  "releaseSentNoAuthSnack": "已送出解除指令（實驗：未帶驗證）",
  "releaseSentSnack": "已送出解除斷電指令",
  "releaseFailedSnack": "解除失敗：{error}",
  "antiTheftDialogTitle": "啟用防盜模式",
  "antiTheftDialogBody": "防盜模式尚未經完整驗證，僅在支援的型號顯示。確定要送出防盜指令嗎？",
  "antiTheftSentSnack": "已送出防盜指令",
  "antiTheftFailedSnack": "指令失敗：{error}",
  "releaseDialogErrorAuthFormat": "驗證值格式錯誤（用十進位或 0x 十六進位）",
  "releaseDialogErrorDealerLength": "代理碼需至少 8 碼",
  "releaseDialogBody": "送出已知安全的「解除」指令(mode 0x06)。可用斷電密碼，或直接輸入你的驗證值。",
  "releaseDialogAuthModePassword": "密碼",
  "releaseDialogAuthModeCode": "進階：我的碼",
  "releaseDialogDealerCodeHint": "代理碼 (Dealer code, 連線時自動帶入)",
  "releaseDialogPasswordHint": "斷電密碼",
  "releaseDialogCbHint": "cb (代理碼數值, 例 168 或 0xA8)",
  "releaseDialogPwSumHint": "pwSum (密碼校驗值, 例 204 或 0xCC)",
  "releaseDialogSkipAuthToggle": "實驗：只送 mode、跳過驗證（未證實，備案）",
  "releaseDialogWarnBox": "解除後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。",
  "releaseDialogConfirm": "確認解除",

  "devicesConnectFailed": "連線失敗，請再試一次",
  "devicesRemoveTitle": "移除裝置",
  "devicesRemoveBody": "將「{alias}」從已儲存清單移除？（不影響裝置本身）",
  "devicesRemove": "移除",
  "devicesSavedSection": "已儲存裝置",
  "devicesNoSaved": "尚無已儲存裝置",
  "devicesUnnamed": "未命名裝置",
  "devicesScanning": "掃描中…",
  "devicesNearbyNotFound": "附近找不到裝置（確認電容已上電、藍牙開啟，並靠近一點）",
  "devicesUnknownName": "Unknown",
  "devicesShowRceOnly": "只顯示 RCE 裝置",
  "devicesShowAllWithHidden": "{count, plural, other{顯示全部 BLE 裝置（隱藏了 {count} 個非 RCE）}}",
  "devicesShowAll": "顯示全部 BLE 裝置",
  "devicesMetaLastSeen": "上次 {time}",
  "devicesSheetTitle": "選擇裝置",
  "devicesRescan": "重新掃描",
  "devicesNearbyScanning": "附近掃描中…",
  "devicesNearby": "附近裝置",
  "devicesDisconnect": "中斷",
  "devicesConnect": "連線",
  "devicesAdapterOff": "藍牙未開啟，請先開啟藍牙再掃描",
  "devicesAliasSuggestion1": "電容 #1（前車）",
  "devicesAliasSuggestion2": "電容 #2（後備）",
  "devicesAliasSuggestion3": "機車電容",
  "devicesAliasRenameTitle": "重新命名",
  "devicesAliasSaveTitle": "儲存裝置",
  "devicesAliasRenameBody": "為這顆裝置設定新的別名。",
  "devicesAliasSaveBody": "已連線成功。為這顆裝置取一個好記的別名，下次可在「已儲存裝置」快速重連。",
  "devicesAliasSave": "儲存",
  "devicesAliasSaveAlias": "儲存別名",
  "devicesAliasSkip": "略過",
  "devicesAliasHint": "例如：電容 #1（前車）",

  "historyFilterAll": "全部",
  "historyFilterToday": "今天",
  "historyFilterWarning": "警告",
  "historyExportCsv": "匯出 CSV",
  "historyExportSubject": "OpenSmartBatt 歷史紀錄",
  "historyChartTodayTitle": "今日電壓趨勢",
  "historyChartTitle": "電壓趨勢",
  "historyLoadFailed": "讀取歷史失敗：{error}",
  "historyEmptyToday": "今天還沒有紀錄。\n連線裝置後會自動寫入歷史。",
  "historyEmptyWarning": "沒有警告或事件紀錄。",
  "historyEmptyAll": "尚無歷史紀錄。\n連線裝置並開啟「自動紀錄」即可開始累積。",
  "historyFooter": "{count, plural, other{共 {count} 筆 · 本機 SQLite · 可匯出 CSV / 分享}}",
  "historyRowEventCutOff": "斷電模式已啟動",
  "historyRowEventAntiTheft": "防盜模式已啟動",
  "historyRowSoh": "SOH {percent}%",
  "historyRowCurrent": "電流 {amps}A",
  "historyRowThresholdWarning": "保護門檻警告",
  "historyStatusEvent": "事件",
  "historyChartInsufficientData": "資料不足以繪圖（需至少 2 筆）",

  "settingsConnectionHeading": "連線",
  "settingsAutoReconnectLabel": "自動重連",
  "settingsAutoReconnectSub": "連線中斷時自動嘗試重連",
  "settingsKeepAwakeLabel": "連線時保持螢幕喚醒",
  "settingsKeepAwakeSub": "螢幕不自動關閉，方便邊騎邊看（連線時生效）",
  "settingsDisplayHeading": "顯示",
  "settingsThemeLabel": "主題",
  "settingsThemeSub": "介面配色（自動：跟隨系統）",
  "settingsThemeLight": "淺色",
  "settingsThemeDark": "深色",
  "settingsThemeAuto": "自動",
  "settingsTempUnitLabel": "溫度單位",
  "settingsLanguageLabel": "語言",
  "settingsLanguageSub": "介面語言（系統：跟隨裝置）",
  "settingsLanguageZhHant": "繁體中文",
  "settingsLanguageEnglish": "English",
  "settingsLanguageSystem": "跟隨系統",
  "settingsDataHeading": "資料",
  "settingsAutoLogLabel": "自動紀錄",
  "settingsAutoLogSub": "連線時自動寫入歷史",
  "settingsExportAllLabel": "匯出全部資料 (CSV)",
  "settingsClearHistoryLabel": "清除歷史紀錄",
  "settingsExportSubjectAllData": "OpenSmartBatt 全部資料",
  "settingsClearHistoryTitle": "清除歷史紀錄",
  "settingsClearHistoryBody": "將刪除本機所有遙測歷史。此動作無法復原。",
  "settingsClearConfirm": "清除",
  "settingsHistoryCleared": "已清除歷史紀錄",
  "settingsDiagnosticsHeading": "診斷 / 開發者",
  "settingsRawPacketLogLabel": "記錄原始藍牙封包",
  "settingsRawPacketLogSub": "記錄 TX/RX 原始 hex，供回報問題或協助破解未知指令。預設關閉",
  "settingsLogMaxSizeLabel": "日誌容量上限",
  "settingsLogMaxSizeSub": "超過自動輪替覆蓋",
  "settingsExportLogLabel": "匯出診斷日誌 (.log)",
  "settingsClearLogLabel": "清除診斷日誌",
  "settingsLogEmpty": "診斷日誌為空",
  "settingsExportSubjectDiagLog": "OpenSmartBatt 診斷日誌",
  "settingsClearLogTitle": "清除診斷日誌",
  "settingsClearLogBody": "將刪除本機所有原始 TX/RX 封包紀錄。",
  "settingsLogCleared": "已清除診斷日誌",
  "settingsAboutHeading": "關於",
  "settingsVersionLabel": "版本",
  "settingsVersionSub": "OpenSmartBatt 社群版",
  "settingsCheckUpdateLabel": "檢查更新",
  "settingsGithubLabel": "GitHub 專案頁面",
  "settingsProtocolDocLabel": "協定文件 PROTOCOL.md",
  "settingsCopyrightLabel": "版權與免責聲明",
  "settingsAboutDialogTitle": "版權與免責聲明",
  "settingsAboutDialogBody": "本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。\n\n本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。",
  "settingsAboutDialogWarning": "解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。"
}
```
