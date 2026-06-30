// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get commonCancel => '取消';

  @override
  String get commonConfirm => '確定';

  @override
  String get commonContinue => '繼續';

  @override
  String get commonClose => '關閉';

  @override
  String get commonNormal => '正常';

  @override
  String get commonWarning => '警告';

  @override
  String get commonCutOff => '斷電';

  @override
  String get commonAntiTheft => '防盜';

  @override
  String get commonReleaseCutOff => '解除斷電';

  @override
  String get commonNoRecordsToExport => '沒有可匯出的紀錄';

  @override
  String commonExportFailed(String error) {
    return '匯出失敗：$error';
  }

  @override
  String commonOpenBrowserFailed(String url) {
    return '無法開啟瀏覽器，已複製連結：$url';
  }

  @override
  String get relativeNever => '從未連線';

  @override
  String get relativeJustNow => '剛剛';

  @override
  String relativeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 分鐘前',
    );
    return '$_temp0';
  }

  @override
  String relativeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 小時前',
    );
    return '$_temp0';
  }

  @override
  String relativeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 天前',
    );
    return '$_temp0';
  }

  @override
  String get navDashboard => '裝置';

  @override
  String get navHistory => '歷史';

  @override
  String get navSettings => '設定';

  @override
  String get disclaimerCommunityEdition => '社群自救版 · COMMUNITY EDITION';

  @override
  String get disclaimerBodyPara1 =>
      '本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。';

  @override
  String get disclaimerBodyPara2 =>
      '本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。';

  @override
  String get disclaimerDoNotRelock => '解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。';

  @override
  String get disclaimerAcknowledgeButton => '我了解，開始使用';

  @override
  String get disclaimerViewGithub => '查看 GitHub 專案與文件';

  @override
  String get updateAlreadyLatest => '已是最新版本（或暫時無法連線）';

  @override
  String updateAvailableTitle(String tag) {
    return '有新版本 $tag';
  }

  @override
  String updateAvailableBody(String version) {
    return '目前版本 v$version。前往 GitHub 下載最新版 APK，安裝前請先解除安裝舊版（簽章不同無法直接覆蓋）。';
  }

  @override
  String updateAvailableBodyIos(String version) {
    return '目前版本 v$version。前往 GitHub release 頁面查看最新版本與安裝說明。';
  }

  @override
  String get updateLaterButton => '稍後';

  @override
  String get updateDownloadButton => '前往下載';

  @override
  String dashboardDeviceTypeDetected(String type) {
    return '偵測到：$type';
  }

  @override
  String get dashboardDeviceTypeSupercapacitor => '超級電容';

  @override
  String get dashboardDeviceTypeSmartBattery => '智慧電池';

  @override
  String get dashboardDeviceTypePowerBank => '行動電源';

  @override
  String get dashboardDeviceTypeRceDevice => 'RCE 裝置';

  @override
  String dashboardDeviceTypeWithName(String type, String name) {
    return '$type（$name）';
  }

  @override
  String get dashboardReadoutsHeading => '即時讀數';

  @override
  String get dashboardReadoutTemperatureLabel => '溫度 TEMP';

  @override
  String get dashboardReadoutSvltLabel => '次電壓 SVLT';

  @override
  String get dashboardReadoutCurrentLabel => '主電流';

  @override
  String get dashboardReadoutSohLabel => '健康 SOH';

  @override
  String get dashboardDvolHeading => '分串電壓 DVOL';

  @override
  String get dashboardProtectionHeading => '防護狀態 / 模式';

  @override
  String get gaugePvltLabel => 'PVLT · 主電壓';

  @override
  String get gaugeSohUnknown => 'SOH --';

  @override
  String gaugeSohValue(int soh, String label) {
    return 'SOH $soh% · 健康$label';
  }

  @override
  String get gaugeSohLabelGood => '良好';

  @override
  String get gaugeSohLabelFair => '普通';

  @override
  String get gaugeSohLabelDegraded => '衰退';

  @override
  String get disconnectedTitle => '尚未連線裝置';

  @override
  String get disconnectedBody => '選擇已儲存的裝置快速重連，或掃描附近的 RCE 電容。';

  @override
  String get disconnectedQuickSelectHeading => '快速選擇';

  @override
  String get disconnectedScanButton => '掃描其他裝置';

  @override
  String quickPickLastValue(String value) {
    return '上次 $value V';
  }

  @override
  String get statusBadgeRunModeLabel => '運行模式';

  @override
  String get statusBadgeCapacitorLabel => '電容狀態';

  @override
  String get statusBadgeCutOffOn => '啟用';

  @override
  String get statusBadgeCutOffOff => '關閉';

  @override
  String get controlDetectCapacitor => '檢測電容';

  @override
  String get statusAdvisoryNote =>
      '本機已偵測為「超級電容」，僅顯示支援的功能（防盜模式僅在支援的電池型號出現）。解除斷電後建議勿再上鎖；電容本身過壓／低壓／過溫保護仍有效。';

  @override
  String get capacitorCheckNoData => '尚未取得電容讀數，請稍候即時資料更新。';

  @override
  String capacitorCheckReadout(String soh, String svlt, String pvlt) {
    return 'SOH $soh% · 次電壓 $svlt V · 主電壓 $pvlt V';
  }

  @override
  String capacitorCheckSnack(String msg) {
    return '電容檢測：$msg';
  }

  @override
  String get releaseSentNoAuthSnack => '已送出解除指令（實驗：未帶驗證）';

  @override
  String get releaseSentSnack => '已送出解除斷電指令';

  @override
  String releaseFailedSnack(String error) {
    return '解除失敗：$error';
  }

  @override
  String get antiTheftDialogTitle => '啟用防盜模式';

  @override
  String get antiTheftDialogBody => '防盜模式尚未經完整驗證，僅在支援的型號顯示。確定要送出防盜指令嗎？';

  @override
  String get antiTheftSentSnack => '已送出防盜指令';

  @override
  String antiTheftFailedSnack(String error) {
    return '指令失敗：$error';
  }

  @override
  String get releaseDialogErrorAuthFormat => '驗證值格式錯誤（用十進位或 0x 十六進位）';

  @override
  String get releaseDialogErrorDealerLength => '代理碼需至少 8 碼';

  @override
  String get releaseDialogBody => '送出已知安全的「解除」指令(mode 0x06)。可用斷電密碼，或直接輸入你的驗證值。';

  @override
  String get releaseDialogAuthModePassword => '密碼';

  @override
  String get releaseDialogAuthModeCode => '進階：我的碼';

  @override
  String get releaseDialogDealerCodeHint => '代理碼 (Dealer code, 連線時自動帶入)';

  @override
  String get releaseDialogPasswordHint => '斷電密碼';

  @override
  String get releaseDialogCbHint => 'cb (代理碼數值, 例 168 或 0xA8)';

  @override
  String get releaseDialogPwSumHint => 'pwSum (密碼校驗值, 例 204 或 0xCC)';

  @override
  String get releaseDialogSkipAuthToggle => '實驗：只送 mode、跳過驗證（未證實，備案）';

  @override
  String get releaseDialogWarnBox => '解除後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。';

  @override
  String get releaseDialogConfirm => '確認解除';

  @override
  String get devicesConnectFailed => '連線失敗，請再試一次';

  @override
  String get devicesRemoveTitle => '移除裝置';

  @override
  String devicesRemoveBody(String alias) {
    return '將「$alias」從已儲存清單移除？（不影響裝置本身）';
  }

  @override
  String get devicesRemove => '移除';

  @override
  String get devicesSavedSection => '已儲存裝置';

  @override
  String get devicesNoSaved => '尚無已儲存裝置';

  @override
  String get devicesUnnamed => '未命名裝置';

  @override
  String get devicesScanning => '掃描中…';

  @override
  String get devicesNearbyNotFound => '附近找不到裝置（確認電容已上電、藍牙開啟，並靠近一點）';

  @override
  String get devicesUnknownName => 'Unknown';

  @override
  String get devicesShowRceOnly => '只顯示 RCE 裝置';

  @override
  String devicesShowAllWithHidden(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '顯示全部 BLE 裝置（隱藏了 $count 個非 RCE）',
    );
    return '$_temp0';
  }

  @override
  String get devicesShowAll => '顯示全部 BLE 裝置';

  @override
  String devicesMetaLastSeen(String time) {
    return '上次 $time';
  }

  @override
  String get devicesSheetTitle => '選擇裝置';

  @override
  String get devicesRescan => '重新掃描';

  @override
  String get devicesNearbyScanning => '附近掃描中…';

  @override
  String get devicesNearby => '附近裝置';

  @override
  String get devicesDisconnect => '中斷';

  @override
  String get devicesConnect => '連線';

  @override
  String get devicesAdapterOff => '藍牙未開啟，請先開啟藍牙再掃描';

  @override
  String get devicesAliasSuggestion1 => '電容 #1（前車）';

  @override
  String get devicesAliasSuggestion2 => '電容 #2（後備）';

  @override
  String get devicesAliasSuggestion3 => '機車電容';

  @override
  String get devicesAliasRenameTitle => '重新命名';

  @override
  String get devicesAliasSaveTitle => '儲存裝置';

  @override
  String get devicesAliasRenameBody => '為這顆裝置設定新的別名。';

  @override
  String get devicesAliasSaveBody => '已連線成功。為這顆裝置取一個好記的別名，下次可在「已儲存裝置」快速重連。';

  @override
  String get devicesAliasSave => '儲存';

  @override
  String get devicesAliasSaveAlias => '儲存別名';

  @override
  String get devicesAliasSkip => '略過';

  @override
  String get devicesAliasHint => '例如：電容 #1（前車）';

  @override
  String get historyFilterAll => '全部';

  @override
  String get historyFilterToday => '今天';

  @override
  String get historyFilterWarning => '警告';

  @override
  String get historyExportCsv => '匯出 CSV';

  @override
  String get historyExportSubject => 'OpenSmartBatt 歷史紀錄';

  @override
  String get historyChartTodayTitle => '今日電壓趨勢';

  @override
  String get historyChartTitle => '電壓趨勢';

  @override
  String get historyRangeToday => '今天';

  @override
  String get historyRangeWeek => '近 7 天';

  @override
  String get historyRangeAll => '全部';

  @override
  String get historyLegendVoltage => '電壓';

  @override
  String get historyLegendTemperature => '溫度';

  @override
  String get historyStatMin => '最小';

  @override
  String get historyStatAvg => '平均';

  @override
  String get historyStatMax => '最大';

  @override
  String historyDetailSamples(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 筆',
    );
    return '$_temp0';
  }

  @override
  String historyLoadFailed(String error) {
    return '讀取歷史失敗：$error';
  }

  @override
  String get historyEmptyToday => '今天還沒有紀錄。\n連線裝置後會自動寫入歷史。';

  @override
  String get historyEmptyWarning => '沒有警告或事件紀錄。';

  @override
  String get historyEmptyAll => '尚無歷史紀錄。\n連線裝置並開啟「自動紀錄」即可開始累積。';

  @override
  String historyFooter(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '共 $countString 筆 · 本機 SQLite · 可匯出 CSV / 分享',
    );
    return '$_temp0';
  }

  @override
  String get historyRowEventCutOff => '斷電模式已啟動';

  @override
  String get historyRowEventAntiTheft => '防盜模式已啟動';

  @override
  String historyRowSoh(int percent) {
    return 'SOH $percent%';
  }

  @override
  String historyRowCurrent(String amps) {
    return '電流 ${amps}A';
  }

  @override
  String get historyRowThresholdWarning => '保護門檻警告';

  @override
  String get historyStatusEvent => '事件';

  @override
  String get historyChartInsufficientData => '資料不足以繪圖（需至少 2 筆）';

  @override
  String get settingsConnectionHeading => '連線';

  @override
  String get settingsAutoReconnectLabel => '自動重連';

  @override
  String get settingsAutoReconnectSub => '連線中斷時自動嘗試重連';

  @override
  String get settingsKeepAwakeLabel => '連線時保持螢幕喚醒';

  @override
  String get settingsKeepAwakeSub => '螢幕不自動關閉，方便邊騎邊看（連線時生效）';

  @override
  String get settingsDisplayHeading => '顯示';

  @override
  String get settingsThemeLabel => '主題';

  @override
  String get settingsThemeSub => '介面配色（自動：跟隨系統）';

  @override
  String get settingsThemeLight => '淺色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeAuto => '自動';

  @override
  String get settingsTempUnitLabel => '溫度單位';

  @override
  String get settingsLanguageLabel => '語言';

  @override
  String get settingsLanguageSub => '介面語言（系統：跟隨裝置）';

  @override
  String get settingsLanguageZhHant => '繁體中文';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageSystem => '跟隨系統';

  @override
  String get settingsDataHeading => '資料';

  @override
  String get settingsAutoLogLabel => '自動紀錄';

  @override
  String get settingsAutoLogSub => '連線時自動寫入歷史';

  @override
  String get settingsExportAllLabel => '匯出全部資料 (CSV)';

  @override
  String get settingsClearHistoryLabel => '清除歷史紀錄';

  @override
  String get settingsExportSubjectAllData => 'OpenSmartBatt 全部資料';

  @override
  String get settingsClearHistoryTitle => '清除歷史紀錄';

  @override
  String get settingsClearHistoryBody => '將刪除本機所有遙測歷史。此動作無法復原。';

  @override
  String get settingsClearConfirm => '清除';

  @override
  String get settingsHistoryCleared => '已清除歷史紀錄';

  @override
  String get settingsDiagnosticsHeading => '診斷 / 開發者';

  @override
  String get settingsRawPacketLogLabel => '記錄原始藍牙封包';

  @override
  String get settingsRawPacketLogSub => '記錄 TX/RX 原始 hex，供回報問題或協助破解未知指令。預設關閉';

  @override
  String get settingsLogMaxSizeLabel => '日誌容量上限';

  @override
  String get settingsLogMaxSizeSub => '超過自動輪替覆蓋';

  @override
  String get settingsExportLogLabel => '匯出診斷日誌 (.log)';

  @override
  String get settingsClearLogLabel => '清除診斷日誌';

  @override
  String get settingsLogEmpty => '診斷日誌為空';

  @override
  String get settingsExportSubjectDiagLog => 'OpenSmartBatt 診斷日誌';

  @override
  String get settingsClearLogTitle => '清除診斷日誌';

  @override
  String get settingsClearLogBody => '將刪除本機所有原始 TX/RX 封包紀錄。';

  @override
  String get settingsLogCleared => '已清除診斷日誌';

  @override
  String get settingsAboutHeading => '關於';

  @override
  String get settingsVersionLabel => '版本';

  @override
  String get settingsVersionSub => 'OpenSmartBatt 社群版';

  @override
  String get settingsCheckUpdateLabel => '檢查更新';

  @override
  String get settingsGithubLabel => 'GitHub 專案頁面';

  @override
  String get settingsProtocolDocLabel => '協定文件 PROTOCOL.md';

  @override
  String get settingsCopyrightLabel => '版權與免責聲明';

  @override
  String get settingsAboutDialogTitle => '版權與免責聲明';

  @override
  String get settingsAboutDialogBody =>
      '本 App 為社群獨立開發的開源工具，基於公開逆向研究，透過藍牙與您已購買的 RCE 智慧電容／電池通訊。\n\n本專案非 RCE 官方產品、與原廠無任何關係，僅供已購買硬體之車主個人、非商業用途。';

  @override
  String get settingsAboutDialogWarning => '解除斷電後請勿重新上鎖；電容本身過壓／低壓／過溫保護仍持續有效。';
}
