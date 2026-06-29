# RCE iBatt 解鎖封包擷取指南 (HCI Snoop Capture Guide)

> 社群自救研究文件 · 非商業 · 供已購買 RCE 硬體的車友參考
> 目的：在「解除斷電」成功的當下，側錄藍牙封包，把社群的經驗性方法變成可重現的協定事實。
> 本文只記錄**操作流程與通訊事實**，不含任何原 App 的程式碼或資源。

---

## 0. 背景（為什麼要做這個）

RCE 公司結束營業、雲端 `api.rceibatt.com` 關閉後，iBatt pro App 因無法登入導致部分功能失效。
社群實測發現：**用 iBatt pro 版本，在解除斷電時反覆重試，可以跳過登入/連線 server 的錯誤，仍有機會成功解除斷電。**

從 App 反編譯分析可知，這個現象是有程式根據的：
- 送 BLE 指令的程式在「server 回傳失敗(null)」時，會以分支跳過錯誤、**繼續送出 BLE 指令**。
- 解除斷電所需的指令是由**序號 / 本機快取資料 + XOR 校驗**組成，並不依賴即時連上 server。
- 「重試有效」推測是 async 競態：讓「本機資料 → BLE 寫入」這條路徑先於「登入失敗提示」完成。

但這仍是**經驗性**結論。只要在成功的當下側錄到藍牙封包，我們就能：
1. 取得這顆電池**真正成功解鎖的指令位元組**（實證，而非推測）。
2. 讓社群開發的**新 App 直接重播**這串指令 → 以後不需要原 App、也不需要 server。
3. 順便擷取電池回傳的遙測封包，校正電壓/溫度/電流的解析公式。

---

## 1. 你需要準備的東西

- 一支 Android 手機（裝有 **iBatt pro** 版本 APK）。
- 你的 RCE 智慧電池/電容（已配對過、原本可用的那顆最好）。
- 一條 USB 線 + 一台電腦（用來取出 log）。免 root 即可（多數機型）。

---

## 2. 開啟藍牙 HCI 監聽記錄

1. **設定 → 關於手機 → 連點「版本號」7 下** → 出現「您已成為開發人員」。
2. **設定 → 系統 → 開發者選項**，找到並開啟：
   **「啟用藍牙 HCI 監聽記錄」(Enable Bluetooth HCI snoop log)**。
3. **把藍牙關掉再打開一次**（讓記錄設定生效，這步很重要）。

> 小提醒：有些機型（三星/小米/OPPO）名稱略不同，搜尋「HCI」或「藍牙監聽」即可。
> 部分機型開啟後需要重開機才會開始寫 log。

---

## 3. 執行社群解鎖流程（同時 log 正在背景記錄）

> ⚠️ 成功解除後**就停手，不要再上鎖**。理由：上鎖→再解鎖的循環若有任一步真的需要當年的 server/密碼，
> 雲端已關，可能會卡在鎖定狀態解不開。電池本身的過壓/低壓/過溫(OV/UV/OT)保護是獨立的，不上鎖也仍有保護。

1. 打開 **iBatt pro**，**連結裝置**。
2. 進入功能頁，點 **斷電（關閉）** —— 此時應會跳出**登入畫面或失敗訊息**。
3. **重複幾次**「再試著解開」的動作。
4. 直到**手動斷電成功解除**。
5. **成功後立即停止操作**（不要再上鎖）。

請記下：你大約在第幾次重試成功、操作的時間點（方便之後在 log 裡定位那一段）。

---

## 4. 取出 log 檔

### 方法 A：產生錯誤報告（免 root，最通用）
1. 開發者選項 → **「產生錯誤報告 / Bug report」** → 選「完整(Full)」。
2. 產生後透過通知分享，存成一個 `.zip`。
3. log 會在 zip 內的 `FS/data/misc/bluetooth/logs/` 或 `btsnoop_hci.log`。

### 方法 B：直接抓檔（部分機型可讀）
常見路徑（依機型擇一存在）：
```
/sdcard/btsnoop_hci.log
/sdcard/Android/data/btsnoop_hci.log
/data/misc/bluetooth/logs/btsnoop_hci.log        (需 root 或經 bug report)
```
用電腦 adb 取出：
```
adb pull /sdcard/btsnoop_hci.log
# 或從 bug report zip 解出 btsnoop_hci.log
```

### 方法 C：有 root 最簡單
```
adb shell su -c "cp /data/misc/bluetooth/logs/btsnoop_hci.log /sdcard/"
adb pull /sdcard/btsnoop_hci.log
```

---

## 5. 把 log 交出來 / 自己分析

- 把 `btsnoop_hci.log`（或 bug report `.zip`）放進專案資料夾即可分析。
- 我們會用 **Wireshark** 或解析器，從 log 中萃取：
  - GATT **service / characteristic UUID**（電池實際用的讀寫特徵）
  - 寫入(ATT Write) 的**實際 unlock 位元組**，比對反編譯出的 `0168xxxx` 指令表
  - 通知(Notify) 回傳的遙測位元組，校正解析公式

> 用 Wireshark 自己看：直接開啟 `btsnoop_hci.log`，
> 過濾列輸入 `btatt` 只看 GATT，找 `Sent Write Request` / `Handle Value Notification`，
> 對照解除斷電的時間點那幾筆即可。

---

## 6. 我們已知 vs 還需要確認（給社群提問用）

**已從反編譯確認（高信心）：**
- App 為 Flutter，套件 `com.rcepower.ibattpro`，本機資料庫 `ibattDB37.db`。
- BLE 指令是 ASCII-hex 字串協定：`0168xxxx`=送出/請求、`0169xxxx`=回應。
- 封包尾端為 **XOR 校驗**（所有位元組 XOR）。
- 指令用到 `substring` / `int.parse` 組裝，**App 端無任何加密/雜湊**（無 md5/sha/aes）。
- `cutoff_password` 是**伺服器指派、存在本機 firmware 表**的值，App 端不從序號推算。

**還需要社群/硬體確認（請幫忙回報）：**
- 解除斷電當下實際送出的**完整位元組**（這份指南就是要抓這個）。
- 電池的 **service / characteristic UUID** 實際值。
- 不同電池的 `(serial_number, cutoff_password)` 配對 → 用來測試「密碼是否能由序號推導」。
- 你的機型 + Android 版本 + 是否成功（建立社群相容性清單）。

---

## 7. 社群提問範本（可直接複製貼出）

```
【RCE iBatt 自救 — 徵求解鎖封包側錄】
雲端關閉後，我用 iBatt pro 版照社群方法（連線→斷電關→重試→解除）成功解鎖。
為了做出不需 server 的開源 App，我們需要側錄成功當下的藍牙封包：
1. 開發者選項開「藍牙 HCI 監聽記錄」→ 關開藍牙
2. 跑一次解鎖流程
3. 產生 bug report，取出 btsnoop_hci.log

徵求：
- 你成功解鎖的 btsnoop_hci.log（會去識別化，只取 GATT 指令位元組）
- 你的電池序號 + 對應 cutoff password（如已知）
- 機型 / Android 版本 / 第幾次重試成功
目的：非商業、純自救，做開源相容 App 給大家用。
```

---

## 8. 隱私與法律

- log 內可能含手機藍牙位址等資訊；分享前可去識別化（只保留 GATT 指令段）。
- 本研究為**非商業、互通性(right-to-repair)自救**目的，記錄的是**通訊協定事實**（不受著作權保護），
  不散布原 App 的程式碼、資源或改裝 APK。
- 本文非法律意見；如要大規模公開，建議先諮詢智慧財產律師。

---

_文件版本：2026-06-29 · RCE iBatt 社群自救研究_
