# 05 · Security & Privacy

| 項目 | 內容 |
|---|---|
| 產品 | MacPDF |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 範圍 | 資料流、威脅模型、沙盒、塗黑保證、PDF 解析風險、隱私 |
| 狀態 | 設計階段 |

---

## 1. Security objectives

1. **機密性**：文件內容不離開使用者的 Mac；沒有上傳、沒有雲端處理。
2. **完整性**：存檔不損壞原檔；破壞性操作有備份；塗黑後不能還原被移除內容。
3. **可用性**：崩潰/斷電後可恢復；惡意 PDF 不應導致資料遺失。
4. **可驗證性**：塗黑有自動檢查；輸出可在主流閱讀器開啟。
5. **最小權限**：只要求必要的 sandbox entitlements。
6. **可追溯性**：本機日誌可協助除錯，但不記錄文件內容。

---

## 2. Data flow

```
使用者檔案系統
      │
      ▼
┌──────────────────────────────────────────────┐
│ MacPDF                                │
│                                              │
│  Read ──► PDFKit ──► Render / Edit           │
│            │                                 │
│            ├──► OCR (Vision, local)          │
│            ├──► Redaction (local)            │
│            ├──► Compare (local)              │
│            └──► Export (local)               │
│                                              │
│  Write ◄── 原子寫入 / 備份 / 恢復快照         │
└──────────────────────────────────────────────┘
      │
      ▼
使用者選擇的輸出路徑
```

**沒有網路節點。** 第一版不包含更新檢查、字型下載、雲端 API、分析 SDK。

### 2.1 資料分類

| 資料 | 敏感度 | 存放位置 | 保留 |
|---|---|---|---|
| 原始 PDF | 高 | 使用者選擇的位置 | 使用者控制 |
| 編輯中文件 | 高 | 記憶體 | 關閉即釋放 |
| 恢復快照 | 高 | Application Support/Recovery | 恢復或丟棄後刪除 |
| 備份 | 高 | Application Support/Backups | 30 天（可設定） |
| 縮圖快取 | 中 | Application Support/Thumbnails | 可清除 |
| OCR 快取 | 高（含文字） | Application Support/OCRCache | 可清除 |
| 日誌 | 低 | 本機 | 7 天（可設定） |
| 設定 | 低 | UserDefaults | 直到重設 |

---

## 3. Threat model

使用 STRIDE 分類，範圍以「本機 App + 惡意 PDF + 本機檔案」為主。

### 3.1 Assets

- 使用者的 PDF 內容。
- 塗黑前的原始內容。
- OCR 出來的文字。
- 恢復快照/備份。
- 使用者的檔案系統存取權。

### 3.2 Adversaries

- 惡意 PDF 作者（利用 parser 漏洞、JavaScript、附件）。
- 同一台 Mac 上的其他使用者/程式（讀取快取/備份）。
- 遺失/被竊的 Mac（磁碟未加密）。
- 供應鏈攻擊（依賴/更新）。
- 使用者自己誤操作（覆寫、未塗乾淨）。

### 3.3 Threats and mitigations

| Threat | 影響 | 可能性 | 對策 |
|---|---|---|---|
| 惡意 PDF 觸發 PDFKit/CoreGraphics 漏洞 | 當機、任意碼執行 | 中 | 沙盒、最小權限、保持系統更新、隔離解析、資源限制 |
| PDF JavaScript 執行 | 資料外洩、行為異常 | 低（PDFKit 預設不執行） | 不執行 JS；匯入時偵測並提示；清理時移除 |
| 惡意附件/嵌入檔 | 誘導開啟惡意檔 | 中 | 不自動開啟附件；顯示警告；可移除 |
| 塗黑只畫黑框，文字仍可萃取 | 機密外洩 | 高（若實作錯誤） | 真移除或 rasterize；存檔後驗證；測試 |
| 恢復快照/備份被其他程式讀取 | 機密外洩 | 中 | sandbox container、檔案權限 0600、可选加密 |
| OCR 快取含敏感文字 | 機密外洩 | 中 | 快取可清除；預設 7 天過期；可选加密 |
| 日誌記錄檔名/內容 | 機密外洩 | 中 | 只記 ID/錯誤碼；不記內容；可關閉 |
| 剪貼簿/分享外洩 | 機密外洩 | 中 | 明確使用者動作；不自動上傳 |
| 更新通道被替換 | 惡意碼 | 低（第一版無更新） | 若加更新：簽章、HTTPS、公鑰 pinning |
| 第三方依賴漏洞 | 惡意碼/當機 | 低（v1 無依賴） | 依賴審查、SBOM、更新 |
| 磁碟未加密 | 資料外洩 | 中 | 建議使用者開 FileVault；App 不負責磁碟加密 |
| 誤覆寫原檔 | 資料遺失 | 中 | 預設另存；覆寫前備份；確認對話框 |
| 塗黑後仍可從備份還原 | 機密外洩 | 中 | 塗黑輸出另存；備份政策說明；可選「塗黑後刪除舊備份」 |

---

## 4. Sandbox and entitlements

### 4.1 建議 entitlements

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
<key>com.apple.security.print</key>
<true/>
```

### 4.2 不需要的權限

- `com.apple.security.network.client`（第一版不聯網）
- `com.apple.security.device.camera`（第一版不做相機掃描；若做 Continuity Camera 再加）
- `com.apple.security.device.microphone`
- `com.apple.security.automation.apple-events`
- `com.apple.security.cs.disable-library-validation`（除非載入 PDFium 等第三方 dylib）

### 4.3 檔案存取

- 使用 `NSOpenPanel` / `NSSavePanel` 取得 security-scoped URL。
- 最近文件儲存 bookmark data，啟動時 `startAccessingSecurityScopedResource()`。
- 不使用 `~/Documents` 的固定路徑（沙盒會失敗）。
- 外部檔案變更 → `NSFilePresenter` / `NSFileCoordinator` 偵測。

---

## 5. Redaction guarantees

### 5.1 定義

「塗黑」在本產品指：**輸出的 PDF 中，被標記區域的文字與圖片無法透過正常工具萃取或還原**。

不是：

- 畫一個黑色矩形覆蓋（底下文字仍在）。
- 把文字顏色改成白色。
- 把頁面截圖後再貼回去但保留原頁（原頁仍可萃取）。

### 5.2 v1 保證（rasterize）

- 受影響頁面完全點陣化。
- 原頁物件、annotation、link、form field 全部移除。
- Metadata/attachments/JS 清理。
- 存檔後 `PDFPage.string` 驗證。
- **保證強度**：視覺與文字萃取層級皆移除；但若使用者保留舊備份，舊檔仍有資料。

### 5.3 v2 保證（content stream）

- 移除與標記相交的文字/圖片繪製指令。
- 保留其他向量內容。
- 需處理：
  - 文字 matrix / CTM。
  - 字型子集與 ToUnicode。
  - 圖片 XObject / inline image。
  - Form XObject 巢狀內容。
  - 圖層/optional content。
- 驗證：文字萃取 + 視覺檢查 + 手動抽查。

### 5.4 驗證流程

1. 套用塗黑 → 輸出到暫存檔。
2. 用 PDFKit 重新開啟。
3. 對每個 mark 區域：
   - 取得該區域文字（`PDFPage.selection(for:)` / `string`）。
   - 若為空 → 通過。
   - 若非空 → 標記失敗頁。
4. 視覺檢查：render 該頁，確認黑框存在。
5. 全部通過才讓使用者儲存最終檔；否則保留暫存檔供檢查。

### 5.5 失敗處理

- 不覆寫原檔。
- 顯示「第 X 頁可能仍有文字」。
- 提供「改用 rasterize 重試」「手動檢查」「取消」。
- 記錄錯誤碼（不記錄內容）。

---

## 6. Malicious PDF handling

### 6.1 不執行

- 不執行 PDF JavaScript。
- 不自動開啟附件/嵌入檔。
- 不自動載入外部 URL。
- 不執行表單 calculation/validation script。

### 6.2 資源限制

- 單檔最大 2 GB（可設定）。
- 單頁 render 最大 10000×10000 px。
- OCR 單頁 timeout 60 秒。
- Flows 單次最多 500 檔。
- 遞迴 XObject 深度限制。
- 啟動時若檔案過大 → 詢問是否以「大檔模式」開啟。

### 6.3 解析隔離

- PDFKit/CoreGraphics 解析在背景執行緒。
- 若可能，將解析放在 XPC service（進階；第一版不做）。
- 崩潰不影響已儲存檔案；恢復快照仍可用。

### 6.4 檔案類型驗證

- 用 UTType / magic bytes 驗證，不只看副檔名。
- 拒絕非 PDF 檔案。
- 巢狀附件需明確使用者操作才能開啟。

---

## 7. Privacy

### 7.1 預設

- 無帳號。
- 無遙測。
- 無分析 SDK。
- 無廣告。
- 無雲端。
- 無自動更新（第一版）。

### 7.2 網路

第一版不應有任何 outbound network request。驗證方式：

- `nettop` / Little Snitch / `lsof -i` 觀察。
- 單元測試檢查沒有 URLSession 使用。
- 程式碼審查：沒有 `URLSession`、`WKWebView`、第三方 SDK。

### 7.3 若未來加功能

| 功能 | 網路 | 控制 |
|---|---|---|
| 更新檢查 | GitHub Releases / 官網 | 可關閉；只傳版本/OS，不傳文件 |
| Google Fonts | fonts.googleapis.com | 可關閉；只傳字型名稱 |
| 崩潰回報 | 第三方 | 預設關閉；需明確同意 |
| 雲端轉檔 | 不做 | — |

### 7.4 日誌

- 使用 `os.Logger`。
- 不記錄：檔名、路徑、PDF 內容、OCR 文字、塗黑文字。
- 可記錄：文件 UUID、頁碼、錯誤碼、耗時。
- 使用者可一鍵清除日誌。

### 7.5 快取

- 縮圖/OCR 快取可能含敏感內容。
- 預設 7 天過期；可在 Settings 清除。
- 可選「離開 App 時清除快取」。
- 未來可選用加密快取（CryptoKit）。

---

## 8. Backup and data retention

| 資料 | 預設保留 | 清除方式 |
|---|---|---|
| 恢復快照 | 直到恢復/丟棄 | 自動 |
| 備份 | 30 天 | Settings → Clear Backups |
| 縮圖快取 | 7 天 | Settings → Clear Cache |
| OCR 快取 | 7 天 | Settings → Clear Cache |
| 日誌 | 7 天 | Settings → Clear Logs |

**塗黑提醒**：備份可能仍含未塗黑內容。套用塗黑後，UI 應提示「舊備份仍可能含原始內容，是否刪除？」（預設不自動刪除，避免誤刪）。

---

## 9. Supply chain

- 第一版零第三方 runtime 依賴。
- 若引入依賴：
  - 固定版本/commit。
  - 記錄授權（SBOM）。
  - 檢查 CVEs。
  - 優先使用 Apple frameworks。
  - 不引入會回傳資料的 SDK。
- 建置可重現：xcodegen + 固定 Xcode 版本。
- Release binary 需簽章/公證（對外時）。

---

## 10. Incident response

### 10.1 塗黑失敗

1. 停止輸出，不覆寫原檔。
2. 保留暫存檔與失敗頁資訊。
3. 通知使用者。
4. 建議改用 rasterize。
5. 記錄 bug，補測試案例。

### 10.2 資料外洩疑似事件

1. 確認是否有網路功能/日誌/快取。
2. 檢查程式碼與網路流量。
3. 若有受影響版本，發佈公告與修正。
4. 提供使用者清除快取/備份的指引。

### 10.3 惡意 PDF 當機

1. 收集 crash log（不含內容）。
2. 重現最小案例。
3. 加入 fixture 與回歸測試。
4. 若為 PDFKit 漏洞，回報 Apple。

---

## 11. Security checklist

### 設計

- [ ] 沒有網路功能（第一版）。
- [ ] 沒有 JavaScript 執行。
- [ ] 沒有自動開啟附件。
- [ ] 沙盒 entitlements 最小化。
- [ ] 檔案權限 0600。
- [ ] 日誌不含敏感內容。
- [ ] 快取可清除、有過期。
- [ ] 塗黑有驗證。
- [ ] 備份有保留期限。

### 實作

- [ ] 使用 security-scoped bookmarks。
- [ ] 原子寫入。
- [ ] 檔案協調（NSFileCoordinator）。
- [ ] 資源限制（大小/頁數/遞迴）。
- [ ] 錯誤處理不吞例外。
- [ ] 沒有 `try!`/`fatalError` 在可恢復路徑。
- [ ] 沒有硬編碼密碼/金鑰。

### 測試

- [ ] 惡意/損壞 PDF fixture。
- [ ] 塗黑驗證測試。
- [ ] 離線測試。
- [ ] 權限測試（唯讀、鎖定、沙盒）。
- [ ] 崩潰恢復測試。
- [ ] 大量檔案測試。

### 發佈

- [ ] 簽章/公證（對外）。
- [ ] Hardened runtime。
- [ ] 版本號/CHANGELOG。
- [ ] 隱私說明。
- [ ] 無 debug 日誌/測試資料。
