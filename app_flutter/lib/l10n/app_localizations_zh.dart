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
  String get commonReleaseCutOff => '復電';

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
  String relativeSecondsAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 秒前',
    );
    return '$_temp0';
  }

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
  String get navHome => '主頁';

  @override
  String get navDevices => '裝置';

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
  String get dashboardSerialLabel => '產品序號';

  @override
  String get dashboardDvolHeading => '分串電壓 DVOL';

  @override
  String get dashboardDvolPendingNote =>
      '已收到分串電壓資料，但尚未收到電壓校正係數（VADJ），待其送達後即顯示校正後數值。';

  @override
  String dashboardTelemetryStale(String age) {
    return '資料已暫停更新 · 上次更新$age';
  }

  @override
  String get captureMarkHeading => '標記你正在做的事';

  @override
  String get captureMarkSub => '在診斷日誌寫入一行，讓我們分得出哪一段讀數對應哪個情境。';

  @override
  String captureMarkSaved(String label) {
    return '已標記：$label';
  }

  @override
  String get captureMarkPbOutA => '只插 Type-A 輸出';

  @override
  String get captureMarkPbOutC5v => '只插 Type-C（5V）';

  @override
  String get captureMarkPbOutCPd => '只插 Type-C（PD）';

  @override
  String get captureMarkPbOutBoth => '兩個埠都插';

  @override
  String get captureMarkPbIn => '只接輸入充電';

  @override
  String get captureMarkPbIdle => '全部拔除';

  @override
  String get captureMarkPackIdle => '靜置（未充未放）';

  @override
  String get captureMarkPackCharging => '充電中';

  @override
  String get captureMarkPackLoad => '帶負載放電';

  @override
  String get captureMarkNote => '自訂備註';

  @override
  String get captureWizardTitle => '引導式擷取';

  @override
  String get captureWizardSub => '帶你走完標準劇本，每個狀態停留足夠長的時間才前進。';

  @override
  String captureWizardStep(int n, int total) {
    return '步驟 $n / $total';
  }

  @override
  String captureWizardHold(int seconds) {
    return '請保持此狀態… $seconds 秒';
  }

  @override
  String get captureWizardHoldDone => '時間足夠，可以前進';

  @override
  String get captureWizardNext => '我做好了';

  @override
  String get captureWizardSkip => '略過';

  @override
  String get captureWizardAbort => '中止';

  @override
  String get captureWizardFinished => '擷取完成。請匯出診斷日誌並回傳給我們。';

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
  String get disconnectedBody => '選擇已儲存的裝置快速重連，或掃描附近的 RCE 裝置。';

  @override
  String get disconnectedQuickSelectHeading => '快速選擇';

  @override
  String get disconnectedScanButton => '掃描其他裝置';

  @override
  String get disconnectedConnecting => '連線中…';

  @override
  String disconnectedRetrying(int attempt, int max) {
    return '重新連線中…（第 $attempt 次，共 $max 次）';
  }

  @override
  String get disconnectedRetryingBody => '裝置沒有回應，正在等待下一次嘗試。剛斷線時這是正常的。';

  @override
  String get disconnectedStalledTitle => '已連上，但這台裝置沒有回應';

  @override
  String disconnectedStalledBody(int attempts) {
    return '藍牙確實連上了，但讀不到資料。已經試過 $attempts 次。';
  }

  @override
  String get disconnectedStalledHint =>
      '請把 App 完全關掉再重新打開 —— 目前唯一實測有效的做法就是這個。乾等沒有用：同樣的狀況曾經持續 40 分鐘都沒自己好。';

  @override
  String get disconnectedStalledRetry => '重新連線';

  @override
  String get disconnectedGaveUpTitle => '連不上這台裝置';

  @override
  String get disconnectedGaveUpBody => '試了幾次都沒有連上，已經停止嘗試。';

  @override
  String get disconnectedGaveUpHint =>
      '接下來不會再自動重試。請確認裝置在附近、電源正常，再試一次 —— 或用下面的按鈕重新掃描。';

  @override
  String get disconnectedGaveUpAutoConnect => '已經在等這台裝置自己回來，但它一直沒有再出現，所以停止等待了。';

  @override
  String get disconnectedGaveUpRadioHint =>
      '接下來不會再自動重試。請先把上面說的藍牙問題處理好 —— 在那之前，連線和掃描都一樣不會成功。';

  @override
  String quickPickLastValue(String value) {
    return '上次 $value V';
  }

  @override
  String get statusBadgeRunModeLabel => '運行模式';

  @override
  String get statusBadgeCapacitorLabel => '電容狀態';

  @override
  String get statusBadgeCapacitorUnknown => '無法辨識';

  @override
  String get statusBadgeCutOffOn => '啟用';

  @override
  String get statusBadgeCutOffOff => '關閉';

  @override
  String get controlDetectCapacitor => '檢測電容';

  @override
  String get statusAdvisoryCapacitorUnknown =>
      '本機回報了 App 尚未認得的狀態，未必代表異常。請到「設定」匯出診斷日誌並回報給我們 —— 判斷所需的細節都在日誌裡。';

  @override
  String get statusAdvisoryThresholdBreach =>
      '目前讀數已超出裝置回報的警戒範圍（過壓／低壓／過溫）。此為 App 依裝置回報的門檻自行計算，並非裝置回報的故障。';

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
  String get commonCutOffAction => '斷電';

  @override
  String modeSentSnack(String action, String status) {
    return '已送出$action指令。裝置目前回報：$status。本機型不會回覆確認，請觀察實際狀態。';
  }

  @override
  String modeSentNoAuthSnack(String action, String status) {
    return '已送出$action指令（實驗：未帶驗證）。裝置目前回報：$status。';
  }

  @override
  String modeChangedSnack(String action, String status) {
    return '$action完成 —— 裝置現在回報：$status。';
  }

  @override
  String modeUnchangedSnack(String action, String status) {
    return '已送出$action指令，但裝置狀態沒有變更（仍為：$status）。';
  }

  @override
  String modeUnchangedNoAuthSnack(String action, String status) {
    return '已送出$action（實驗：未帶驗證），裝置狀態沒有變更（仍為：$status）。';
  }

  @override
  String modeUnchangedRetriedSnack(String action, int count, String status) {
    return '已送出$action共 $count 次，裝置仍回報：$status。有時需多試幾次或重新連線後才生效，請稍後再試。';
  }

  @override
  String get cutOffDialogTitle => '送出斷電指令';

  @override
  String get cutOffDialogBody =>
      '斷電會讓電池切斷輸出，車輛將無法啟動。\n\n解除斷電這條路徑目前尚未被證實可用。我們手上沒有任何一次擷取顯示裝置對模式指令有回應，認證值的推導方式也還在查證中。如果解除失敗，本 App 無法讓這顆電池復電。\n\n請確認你有其他復電手段（原廠工具／經銷商）再繼續。風險請自行承擔。';

  @override
  String get cutOffDialogConfirm => '我了解，仍要送出';

  @override
  String cutOffFailedSnack(String error) {
    return '斷電指令失敗：$error';
  }

  @override
  String get cutOffDisabledNote => '只有在裝置回報運行正常時，才能送出斷電指令。';

  @override
  String get releaseDisabledNote => '裝置目前回報運行正常，不在斷電或防盜模式，沒有需要恢復的對象。';

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
  String get releaseConfirmTitle => '恢復正常運作';

  @override
  String get releaseConfirmBody =>
      '此功能用於：如果您的電池處於防盜或斷電模式，可以恢復正常。\\n\\n目前還是實驗功能，請小心使用。';

  @override
  String get releaseConfirmContinue => '復電';

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
  String get devicesConnectFailedBluetoothOff => '藍牙已關閉，請先開啟藍牙';

  @override
  String get devicesConnectFailedBluetoothUnauthorized =>
      '本 App 沒有藍牙權限，請到系統設定開啟';

  @override
  String get devicesConnectFailedPermission => '缺少藍牙權限，請到系統設定授權';

  @override
  String get devicesConnectFailedStale => '找不到這台裝置，請重新掃描後再連一次';

  @override
  String get devicesConnectFailedUnreachable => '找不到這台裝置，請確認它在附近並已開機';

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
  String devicesSavedCount(int count) {
    return '已儲存 · $count 台';
  }

  @override
  String get deviceBadgeConnected => '已連線';

  @override
  String get deviceBadgeConnecting => '連線中';

  @override
  String get deviceBadgeOffline => '未連線';

  @override
  String get deviceBadgeFailed => '連線失敗';

  @override
  String get deviceBadgeNotAnswering => '沒有回應';

  @override
  String get devicesNoSaved => '尚無已儲存裝置';

  @override
  String get devicesUnnamed => '未命名裝置';

  @override
  String get devicesScanning => '掃描中…';

  @override
  String get devicesNearbyNotFound => '附近找不到裝置（確認裝置已上電、藍牙開啟，並靠近一點）';

  @override
  String devicesNearbyNoneVendor(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '附近有 $count 個藍牙裝置，但沒有一個看起來是 RCE 裝置。若你的裝置沒有出現，點上方「顯示全部」。',
    );
    return '$_temp0';
  }

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
  String get historyScopeAllDevices => '全部裝置';

  @override
  String historyScopeHiddenNote(int count) {
    return '另有 $count 筆紀錄未顯示：它們是在 App 尚未辨識出裝置之前存下的。';
  }

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
  String get historyEmptyToday => '今天還沒有紀錄。\n連線裝置後就會開始累積。';

  @override
  String get historyEmptyWarning => '沒有警告或事件紀錄。';

  @override
  String get historyEmptyAll => '尚無歷史紀錄。\n連線裝置後就會開始累積。';

  @override
  String get historyEmptyNoDevices => '尚無裝置紀錄。\n連線並命名裝置後就會開始累積。';

  @override
  String get historyEmptyDeviceRange => '這台裝置在此範圍內沒有紀錄。';

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
  String get settingsBackgroundMonitorLabel => '背景持續監看';

  @override
  String get settingsBackgroundMonitorSubAndroid =>
      '螢幕關閉或切到其他 App 時仍持續記錄，連線期間會顯示一則常駐通知。若開啟後資料仍會停更，請到系統設定把本 App 排除在電池最佳化之外。';

  @override
  String get settingsBackgroundMonitorSubIos =>
      'iOS 目前不支援背景監看：App 切到背景或螢幕關閉時資料會停止更新，時間久了連線也會被系統中斷。請讓 App 保持在前景，並開啟下方的「連線時保持螢幕喚醒」。';

  @override
  String get settingsKeepAwakeLabel => '連線時保持螢幕喚醒';

  @override
  String get settingsKeepAwakeSub => '螢幕不自動關閉，方便邊騎邊看（連線時生效）';

  @override
  String get monitorNotificationTitle => 'OpenSmartBatt · 監看中';

  @override
  String get monitorNotificationTitleConnecting => 'OpenSmartBatt · 連線中…';

  @override
  String get monitorNotificationTitleStalled => 'OpenSmartBatt · 無資料';

  @override
  String get monitorNotificationStop => '停止監看';

  @override
  String get monitorChannelName => '背景監看';

  @override
  String get monitorChannelDescription => '連線期間顯示即時電壓與電量的常駐通知';

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
  String get settingsSpeedDetectionLabel => '速度偵測';

  @override
  String get settingsSpeedDetectionSub => '在儀表板顯示 GPS 速度（新增「騎乘」錶盤）。預設關閉。';

  @override
  String get settingsSpeedUnitLabel => '速度單位';

  @override
  String get speedConsentTitle => '開啟速度偵測？';

  @override
  String get speedConsentIntro => '這個功能會用到手機的定位。開啟前請先確認以下四件事：';

  @override
  String get speedConsentPointForeground => '只在儀表板畫面、App 位於前景時使用 GPS；退到背景就停止。';

  @override
  String get speedConsentPointRecorded => '連線期間的速度會寫入紀錄，並包含在你匯出的診斷檔裡。';

  @override
  String get speedConsentPointNoLocationStored => '位置座標永遠不會被儲存，也不會出現在任何匯出檔中。';

  @override
  String get speedConsentPointBattery => '會增加電池消耗。';

  @override
  String get speedConsentEnable => '啟用';

  @override
  String get speedCardWaitingTitle => '等待定位';

  @override
  String get speedCardWaitingBody => '正在取得第一筆 GPS 讀數。剛開始或在室內可能要等幾秒。';

  @override
  String get speedCardPermissionDeniedTitle => '沒有定位權限';

  @override
  String get speedCardPermissionDeniedBody => '系統尚未允許本 App 取得定位，因此無法顯示速度。';

  @override
  String get speedCardPermissionPermanentBody =>
      '定位權限已被永久拒絕，系統不會再詢問。請到系統設定開啟「使用 App 期間」的定位權限。';

  @override
  String get speedCardOpenSystemSettings => '前往系統設定';

  @override
  String get speedCardHeld => '保持中';

  @override
  String get speedCardNoSignal => '無訊號';

  @override
  String speedCardAccuracy(String value, String unit) {
    return '誤差 ±$value $unit';
  }

  @override
  String speedCardLastMeasured(String value, String unit, int seconds) {
    return '最後量到 $value $unit，$seconds 秒前';
  }

  @override
  String get speedQualityGood => '訊號好';

  @override
  String get speedQualityFair => '訊號普通';

  @override
  String get speedQualityPoor => '訊號差';

  @override
  String get speedQualityNone => '無訊號';

  @override
  String get watchfaceRiding => '騎乘';

  @override
  String get settingsWatchfaceLabel => '錶盤';

  @override
  String get settingsWatchfaceSub => '目前連線裝置的儀表板要放哪些卡片、依什麼順序。';

  @override
  String get settingsWatchfaceSubNoDevice => '此設定綁定裝置。請先連線並儲存裝置，才能在這裡調整。';

  @override
  String get watchfaceStandard => '標準';

  @override
  String get watchfaceCompact => '精簡';

  @override
  String get watchfaceDiagnostic => '診斷';

  @override
  String get settingsRestoreDisplayLabel => '還原預設顯示';

  @override
  String get settingsRestoreDisplayDone => '已還原為標準錶盤。';

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
  String get settingsRetentionLabel => '歷史保留期限';

  @override
  String get settingsRetentionSub =>
      '連線時一律記錄；此設定決定舊資料保留多久。調短會立即刪除超出範圍的紀錄，且無法復原。';

  @override
  String get retention30Days => '30 天';

  @override
  String get retention90Days => '90 天';

  @override
  String get retention365Days => '1 年';

  @override
  String get retentionForever => '永久';

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
  String get rawLogOffDialogTitle => '這份日誌不會包含封包內容';

  @override
  String get rawLogOffDialogBody =>
      '「記錄原始藍牙封包」目前是關閉的，所以這份檔案只會有連線事件，不會有裝置實際傳回的資料。如果你是要回報問題給開發者，這份檔案幫助有限。\n\n開啟後需要重新連線並操作一次，才會錄到內容。';

  @override
  String get rawLogOffExportAnyway => '仍要匯出';

  @override
  String get rawLogOffEnable => '開啟記錄';

  @override
  String get rawLogEnabledSnack => '已開啟原始封包記錄。請重新連線、操作一段時間後再匯出。';

  @override
  String get rawLogContentsDialogTitle => '這份日誌含有裝置的藍牙位址';

  @override
  String get rawLogContentsDialogBody =>
      '原始封包記錄是開啟的，所以這份檔案包含裝置送出的封包內容 —— 其中一筆是裝置回報自己的藍牙硬體位址。\n\n那是你自己的硬體，不是個人資料，而且裝置本來就持續對周圍廣播它。檔案裡保留它是刻意的：移除會破壞幀的校驗碼，那份擷取就失去作為證據的價值。\n\n公開張貼這個檔案前，請留意這一點。';

  @override
  String get rawLogContentsContinue => '我知道了，匯出';

  @override
  String get settingsRawPacketLogLabel => '記錄原始藍牙封包';

  @override
  String get settingsRawPacketLogSub =>
      '記錄 TX/RX 原始 hex，供回報問題或協助破解未知指令。預設關閉。內容含裝置自身的藍牙位址。';

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
  String get startupFailedTitle => '無法啟動';

  @override
  String get startupFailedBody => '資料庫開啟失敗。請先試「重試」；若一直失敗，最後手段是重設資料庫（會刪除所有紀錄）。';

  @override
  String get startupDowngradeTitle => 'App 版本比資料舊';

  @override
  String startupDowngradeBody(int stored, int app) {
    return '你的資料是由較新版本建立的（資料格式 v$stored），這個版本只支援到 v$app，因此不予開啟以免損毀資料。請重新安裝較新版本的 App；你的紀錄完整保留。';
  }

  @override
  String get startupRetry => '重試';

  @override
  String get startupResetDb => '重設資料庫（刪除所有紀錄）';

  @override
  String get startupResetTitle => '確定要重設資料庫？';

  @override
  String get startupResetBody => '這會刪除全部歷史紀錄、已儲存裝置與設定，且無法復原。';

  @override
  String get exportScopeTitle => '匯出範圍';

  @override
  String exportScopeThisDevice(String label) {
    return '只匯出目前裝置（$label）';
  }

  @override
  String get exportScopeThisSession => '只匯出本次連線';

  @override
  String get exportScopeAllDevices => '全部裝置';

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

  @override
  String get dashboardTelemetryStalled =>
      '讀數已經停止更新（連線還在）。系統把 App 凍結時就會這樣；開啟「背景持續監看」可以避免。';

  @override
  String get packLabelUnclassified => '未分類（請指定）';

  @override
  String get classPendingTitle => '正在判定裝置類型';

  @override
  String get classPendingBody =>
      '等待裝置回報自己的類型。在那之前不顯示讀數 —— 同一個數字在電池與行動電源上代表的意義並不相同。';

  @override
  String get classPendingStalledTitle => '連線不穩定';

  @override
  String classPendingStalledBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已有 $count 次輪詢沒有得到回應，裝置尚未回報類型。',
    );
    return '$_temp0';
  }

  @override
  String get classPendingTimeoutTitle => '無法判定裝置類型';

  @override
  String get classPendingTimeoutBody =>
      '裝置有在送讀數，但沒有說自己是什麼。重新連線通常可以解決；你也可以手動指定類型。';

  @override
  String get classPendingRevealButton => '仍要顯示讀數（未分類）';

  @override
  String get classPendingRetryButton => '重新連線';

  @override
  String get packLabelChoose => '設定裝置類型';

  @override
  String get powerBankSocCaption => '電量 · 充電狀態';

  @override
  String get powerBankSocSubUnknown => '尚無讀數';

  @override
  String get powerBankCurrentLabel => '電流';

  @override
  String get powerBankDesignCapacityLabel => '標示容量';

  @override
  String get powerBankSocReadoutLabel => '電量 SOC';

  @override
  String get powerBankOutputVoltageLabel => '輸出電壓';

  @override
  String get powerBankInputVoltageLabel => '輸入電壓';

  @override
  String get powerBankDirectionCharging => '充電中';

  @override
  String get powerBankDirectionDischarging => '放電中';

  @override
  String get powerBankDirectionIdle => '待機';

  @override
  String get usbPortTypeA => 'Type-A';

  @override
  String get usbPortTypeC => 'Type-C';

  @override
  String get powerPathHeading => '能量路徑';

  @override
  String powerPathWaiting(int seconds) {
    return '等待裝置回報 · 已連線 $seconds 秒';
  }

  @override
  String get powerPathPd => 'PD';

  @override
  String get powerPathAskWhichPort => '這是哪個孔?';

  @override
  String get powerPathTagOther => '其他 / 不確定';

  @override
  String powerPathTagSaved(String tag) {
    return '已記錄回報：$tag';
  }

  @override
  String get dashboardChartHeading => '即時曲線';

  @override
  String get dashboardChartWaiting => '等待遙測資料…';

  @override
  String get dashboardTrackCurrent => '主電流';

  @override
  String get dashboardTrackPvlt => 'PVLT · 主電壓';

  @override
  String get dashboardTrackTemperature => '溫度';

  @override
  String get powerBankTrackCurrent => '電流';

  @override
  String get powerBankTrackOutput => '輸出電壓';

  @override
  String get powerBankTrackInput => '輸入電壓';

  @override
  String get powerBankTrackSoc => '電量 SOC';

  @override
  String get capacitorTrackSvlt => '次電壓 SVLT';

  @override
  String get capacitorChartNoCurrentNote => '不顯示電流：本類別回報恆定 0 A，並非真實量測。';
}
