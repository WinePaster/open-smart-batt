# OpenSmartBatt — iOS 實機 QA 驗收清單

> 來源：`docs/ios-port-plan.md` 第 5 節。**模擬器無藍牙、雲端裝置農場連不到實體電池**——以下每一項都須在**真 iPhone（有瀏海機型）+ 鄰近一顆實體 RCE 電池**上實測；UI/版面項另在 **iPad** 各跑一遍（Impeller 渲染）。
>
> 安裝方式：TestFlight → 安裝 OpenSmartBatt（build 0.6.0 (101)）。
> 標 ⭐ 者為本次移植新修、最該優先確認的項目。

記號：`[ ]` 未測 · `[x]` 通過 · `[!]` 失敗（請在「備註」記下畫面訊息）

## A. BLE 核心路徑（iPhone）
- [ ] 1. 首次啟動跳出藍牙權限 prompt 且**不當機**（驗 B.1）　備註：
- [ ] 2. ⭐ 點「不允許」或事後撤銷後，顯示**「至設定開啟藍牙權限」**（與「藍牙關閉」區分）且能 deep-link 設定；回答授權後掃描**自動重跑**（驗 D.2）　備註：
- [ ] 3. 冷啟動開啟裝置清單**不丟未捕捉例外**（adapterState 競爭已處理，驗 D.1）　備註：
- [ ] 4. 掃描能發現 RCE / `07b9fff0` 裝置（留意 iOS peripheral name 較不可靠，name-prefix 'RCE' fallback 可能漏掉不廣播 service UUID 的裝置）　備註：
- [ ] 5. ⭐ 連線成功；對 stale/未知 UUID 須在**數秒內**浮出錯誤，**非 60s 凍結 spinner**；無 spurious 狀態抖動（驗 D.4）　備註：
- [ ] 6. ⭐ saved device：**reinstall app 後**仍能由次要訊號（local name）重新綁定並連線；舊 NSUUID 失效時標記 stale 而非無限重連（驗 D.3，本次已補完持久化）　備註：
- [ ] 7. 1Hz keep-alive（0x23）維持連線；連線中按**電源鍵鎖屏**，確認預期行為（背景掛起導致斷線，回前景能重連，驗 D.5）　備註：
- [ ] 8. 連線時螢幕保持喚醒（wakelock）　備註：

## B. 資料持久化（iOS 路徑未驗過）
- [ ] 9. 儲存一個裝置 + 寫入一筆 history，重啟 app 後仍存在（sqflite `getDatabasesPath` round-trip）　備註：
- [ ] 10. disclaimer marker 寫入 Application Support，跨啟動仍在（`getApplicationSupportDirectory`）　備註：

## C. UI / 匯出 / 更新（iPhone + iPad）
- [ ] 11. ⭐ CSV/log 匯出在 iPhone **與 iPad**（popover anchor）都能開啟 share sheet（驗 D.7，本次已接線 3 個呼叫點）　備註：
- [ ] 12. ⭐ 更新對話框顯示 iOS 適配文案，開啟 release 頁而**非 `.apk`**（驗 D.6）　備註：
- [ ] 13. 直向鎖定維持，啟動/splash 無旋轉（iPad 即使系統允許四向，runtime 仍鎖直向）　備註：
- [ ] 14. 完整 button/trigger 接線稽核：無 dead button（placeholder History/Settings、未呼叫的 showDeviceListSheet 等）　備註：
- [ ] 15. 逐頁視覺驗證（dashboard gauge、device list sheet、history chart CustomPaint、settings、明/暗/auto 主題切換）；重點檢查 analyze 看不出的版面 bug（IndexedStack 置中、IntrinsicHeight readout grid、ListView 下 Row stretch、gauge FittedBox 尺寸）　備註：
- [ ] 16. SafeArea/inset 稽核：底部 nav 與頂部 app bar 在瀏海機型與 iPad 上無被 home-indicator/狀態列裁切或重疊（驗 E.3）　備註：
- [ ] 17. 主畫面圖示下方顯示**「OpenSmartBatt」**可讀名稱（驗 E.1）　備註：

## D. 發行前合規（TestFlight 處理後）
- [x] 18. `PrivacyInfo.xcprivacy` 與各 pod manifest 完備（已於建置含入；TestFlight 處理通過即佐證）
- [x] 19. 上傳無出口合規卡關（`ITSAppUsesNonExemptEncryption=false`）；版本字串純數字 `0.6.0`（驗 H.2）
- [x] 20. committed pbxproj 不含 `DEVELOPMENT_TEAM`（驗 G.1；已確認提交版本 0 次）

---

### 失敗項回報格式（貼給維護者/Claude）
```
項次：
裝置 / iOS 版本：
重現步驟：
預期 / 實際：
畫面訊息或截圖：
```
