# 06 · Test Plan

| 項目 | 內容 |
|---|---|
| 產品 | PDF Workbench |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 範圍 | M0–M3 的功能、效能、相容性、安全與回歸測試 |
| 狀態 | 規劃中 |

---

## 1. Test strategy

### 1.1 測試層級

| 層級 | 目標 | 工具 | 頻率 |
|---|---|---|---|
| Unit | 純邏輯、operation、parser、diff | XCTest | 每次 commit |
| Integration | PDFKit/CoreGraphics/OCR 整合 | XCTest | 每次 PR |
| UI | 開檔、註解、合併、塗黑流程 | XCUITest | 每日/Release |
| Performance | 開啟、捲動、OCR、壓縮 | XCTest + XCTMetric | Release |
| Fuzz | 損壞/惡意 PDF | 自訂 harness | 每週/Release |
| Manual | 真實文件、相容性、易用性 | 人工 | Release |
| Dogfooding | 內部日常使用 | 人工 | 持續 |

### 1.2 測試原則

- 每個 P0 功能至少一個自動測試；P1 至少一個手動測試案例。
- 塗黑、存檔、OCR 必須有回歸測試。
- 測試資料去識別化；不進版控真實個資。
- 測試輸出固定、可重現；避免依賴時間/網路。
- 效能測試用固定 fixture 與固定機器規格。

---

## 2. Test matrix

### 2.1 文件類型

| 類型 | 變體 | 優先級 |
|---|---|---|
| 純文字 PDF | 1 頁、10 頁、100 頁、500 頁 | P0 |
| 掃描 PDF | 灰階、彩色、300 DPI、歪斜 | P0 |
| 表單 PDF | AcroForm、文字/核取/下拉/簽名 | P0 |
| 加密 PDF | 使用者密碼、擁有者密碼、權限限制 | P1 |
| 註解 PDF | Highlight、note、ink、stamp | P1 |
| 書籤/連結 PDF | 多層 outline、內部/外部連結 | P1 |
| 附件/JS PDF | embedded file、JavaScript action | P1 |
| 多語言 PDF | 繁中、簡中、日文、韓文、阿拉伯文 | P1 |
| 表格 PDF | 合併儲存格、跨頁表格 | P1 |
| 損壞 PDF | 截斷、錯誤 xref、非法物件 | P1 |
| 超大 PDF | 1 GB、1000 頁 | P2 |
| 零頁/怪尺寸 | 0 頁、超寬/超高 | P2 |

### 2.2 功能矩陣

| 功能 | 單元 | 整合 | UI | 手動 |
|---|---|---|---|---|
| 開啟/瀏覽 | — | ✓ | ✓ | ✓ |
| 縮圖/目錄/搜尋 | ✓ | ✓ | ✓ | ✓ |
| 頁面排序/旋轉/刪除 | ✓ | ✓ | ✓ | ✓ |
| 合併/分割 | ✓ | ✓ | ✓ | ✓ |
| 註解 | ✓ | ✓ | ✓ | ✓ |
| 簽名/印章 | ✓ | ✓ | ✓ | ✓ |
| 表單填寫/flatten | ✓ | ✓ | ✓ | ✓ |
| 表單建立 | ✓ | ✓ | — | ✓ |
| OCR | ✓ | ✓ | ✓ | ✓ |
| 塗黑 | ✓ | ✓ | ✓ | ✓ |
| 壓縮 | ✓ | ✓ | — | ✓ |
| 比對 | ✓ | ✓ | ✓ | ✓ |
| Flows | ✓ | ✓ | ✓ | ✓ |
| 密碼/權限 | ✓ | ✓ | ✓ | ✓ |
| 列印 | — | ✓ | — | ✓ |
| 恢復 | ✓ | ✓ | — | ✓ |

---

## 3. Fixtures

### 3.1 目錄結構

```
Fixtures/
├── text/
│   ├── one-page.pdf
│   ├── ten-pages.pdf
│   ├── 100-pages.pdf
│   └── 500-pages.pdf
├── scanned/
│   ├── grayscale-300dpi.pdf
│   ├── color-300dpi.pdf
│   └── skewed.pdf
├── forms/
│   ├── simple-form.pdf
│   ├── all-field-types.pdf
│   └── signed-form.pdf
├── encrypted/
│   ├── user-password.pdf
│   └── owner-password.pdf
├── annotations/
│   ├── highlights.pdf
│   └── ink-and-notes.pdf
├── links/
│   ├── outline.pdf
│   └── external-links.pdf
├── malicious/
│   ├── truncated.pdf
│   ├── bad-xref.pdf
│   ├── javascript.pdf
│   └── embedded-file.pdf
├── languages/
│   ├── zh-Hant.pdf
│   ├── ja.pdf
│   └── ar.pdf
├── tables/
│   ├── simple-table.pdf
│   └── merged-cells.pdf
└── large/
    └── 1gb.pdf
```

### 3.2 Fixture 規則

- 全部去識別化；不得含真實個資。
- 每個 fixture 記錄：來源、頁數、大小、預期行為。
- 損壞/惡意 fixture 不進一般使用者路徑；只在測試 target。
- 大型 fixture 用 Git LFS 或下載腳本，不直接進 repo。

---

## 4. Acceptance tests

### 4.1 M0 — 外殼與瀏覽

- [ ] 開啟 10 頁 PDF，第一頁 1 秒內可見。
- [ ] 開啟 100 MB PDF，5 秒內可見。
- [ ] 連續捲動 60 fps（Instruments 無掉幀）。
- [ ] 縮圖側欄顯示所有頁；點擊跳轉正確。
- [ ] 目錄樹展開/收合/跳轉正確。
- [ ] 搜尋關鍵字，結果數量與頁碼正確。
- [ ] 多視窗/分頁可獨立操作。
- [ ] 最近文件可重開；檔案搬移後顯示找不到。
- [ ] 深色模式切換正常。

### 4.2 M1 — 日常可用

- [ ] 合併 3 份 PDF，頁序正確。
- [ ] 分割成指定 ranges，檔名/頁數正確。
- [ ] 中間分割水平/垂直，輸出尺寸正確。
- [ ] 旋轉 20 頁，儲存後重新開啟仍正確。
- [ ] 刪除 5 頁，undo 可恢復。
- [ ] 插入空白頁/其他 PDF，位置正確。
- [ ] 螢光筆/底線/刪除線在 Preview 顯示。
- [ ] 便條紙內容可讀、可刪。
- [ ] 手繪/形狀可 undo。
- [ ] 簽名可儲存/重複使用。
- [ ] 浮水印/頁首頁尾/頁碼套用到指定頁。
- [ ] 匯出 PNG/JPEG，DPI/頁碼正確。
- [ ] 列印預覽正常。
- [ ] 關閉未儲存文件會提示。
- [ ] 強制關閉後可恢復。

### 4.3 M2 — 掃描與保護

- [ ] 匯入 10 張圖片，排序/頁面尺寸正確。
- [ ] OCR 10 頁，搜尋得到關鍵字。
- [ ] OCR 文字可選取/複製。
- [ ] OCR 取消後不留下暫存頁。
- [ ] 填寫表單，Tab 順序正確。
- [ ] Flatten 表單，值保留、欄位不可改。
- [ ] 開啟加密 PDF，正確密碼可開。
- [ ] 移除密碼後可儲存。
- [ ] 壓縮 100 頁，檔案變小、可開啟。
- [ ] PDF/A 輸出可通過基本檢查。
- [ ] 中繼資料編輯/移除正確。
- [ ] Quick Action 可從 Finder 觸發。

### 4.4 M3 — 進階工作台

- [ ] 建立表單欄位（文字/核取/下拉/簽名），Tab 順序正確。
- [ ] 手動塗黑 5 個區域，存檔後文字萃取為空。
- [ ] 關鍵字塗黑 Email/電話，無漏字。
- [ ] OCR 掃描件塗黑，無漏字。
- [ ] 塗黑審閱可逐頁檢查/刪除標記。
- [ ] 塗黑驗證失敗時不覆寫原檔。
- [ ] 版本比對可列出新增/刪除/修改。
- [ ] 視覺比對可標出圖片差異。
- [ ] Flows 跑 20 個檔案，成功/失敗報表正確。
- [ ] Flows 可取消，已完成檔案保留。
- [ ] PDF/A 轉換後 JavaScript/附件被移除。

---

## 5. Performance tests

### 5.1 基準環境

- MacBook Pro / Mac mini，Apple Silicon（M1 以上），16 GB RAM。
- macOS 14+。
- 關閉其他大型 App。
- 固定 fixture：100 MB / 500 頁、10 MB / 20 頁、掃描 300 DPI。

### 5.2 指標

| 測試 | 目標 | 測量 |
|---|---|---|
| App 啟動 | < 1 s | `XCTApplicationLaunchMetric` |
| 開啟 100 MB | < 5 s | 自訂 timer |
| 第一頁 render | < 1 s | Instruments |
| 縮圖 100 頁 | < 20 s | 背景完成時間 |
| 捲動 | 60 fps | Core Animation |
| 搜尋 500 頁 | < 2 s | timer |
| OCR 1 頁 | 1–3 s | timer |
| OCR 100 頁 | < 5 min | timer |
| 壓縮 100 頁 | < 60 s | timer |
| 合併 10 檔 | < 10 s | timer |
| 記憶體 500 頁 | < 1.5 GB | Allocations |
| 塗黑 10 頁 | < 30 s | timer |

### 5.3 記憶體/洩漏

- 開 10 份文件、關閉，記憶體回到基準 ±10%。
- 連續註解 100 次，無 leak。
- OCR 100 頁後 cache 不超過上限。
- Instruments Leaks 無持續成長。

---

## 6. Compatibility tests

### 6.1 閱讀器

| 閱讀器 | 測試 |
|---|---|
| Apple Preview | 開檔、註解、表單、書籤、列印 |
| Adobe Acrobat Reader | 開檔、註解、表單、簽名 |
| Google Chrome | 開檔、文字選取、連結 |
| Firefox | 開檔、基本渲染 |

### 6.2 輸出格式

- PDF 1.4 / 1.7 / 2.0。
- PDF/A-1b / 2b / 3。
- 圖片 PNG / JPEG / TIFF。
- 文字 TXT / RTF。

### 6.3 OS/硬體

- macOS 14 / 15 / 26（若支援）。
- Apple Silicon / Intel。
- 外接螢幕 / 多螢幕。
- 網路磁碟 / iCloud Drive（若使用者選擇）。

---

## 7. Security tests

- 損壞 PDF：不崩潰、不覆寫原檔、顯示錯誤。
- JavaScript PDF：不執行、提示、可清理。
- 附件 PDF：不自動開啟、可移除。
- 超大 PDF：資源限制、可取消。
- 加密 PDF：錯誤密碼不洩漏資訊。
- 唯讀檔：不嘗試覆寫、提示另存。
- 沙盒：只能存取使用者選取的檔案。
- 日誌：不含檔名/內容。
- 快取：可清除、過期。
- 塗黑：文字萃取驗證、視覺驗證。
- 網路：`nettop`/`lsof` 無 outbound。

---

## 8. Regression checklist

每次 release 前：

### 文件

- [ ] 開 10/100/500 頁。
- [ ] 開掃描/表單/加密/損壞 PDF。
- [ ] 開多語言 PDF。

### 操作

- [ ] 合併/分割/排序/旋轉/刪除。
- [ ] 註解/簽名/印章。
- [ ] OCR/塗黑/壓縮。
- [ ] 表單填寫/flatten。
- [ ] 比對/Flows。

### 資料

- [ ] 存檔/另存/覆寫備份。
- [ ] 當機恢復。
- [ ] 快取清除。
- [ ] 最近文件。

### 系統

- [ ] 列印。
- [ ] Quick Action。
- [ ] 預設 PDF App。
- [ ] 深色模式。
- [ ] 鍵盤快捷鍵。

---

## 9. Bug severity

| 級別 | 定義 | 範例 | 處理 |
|---|---|---|---|
| P0 | 資料遺失/安全漏洞/無法啟動 | 存檔損壞、塗黑失效 | 立即修，阻擋 release |
| P1 | 核心功能失效 | 無法合併、OCR 全錯 | release 前修 |
| P2 | 功能異常但有 workaround | 縮圖錯位、匯出檔名錯 | 排程修 |
| P3 | 外觀/文案/低頻 | 對齊、翻譯 | 有空修 |

---

## 10. Release checklist

### 功能

- [ ] M 階段功能全部通過 acceptance tests。
- [ ] 沒有 P0/P1 未修 bug。
- [ ] 回歸清單全過。

### 效能

- [ ] 效能指標達標。
- [ ] 無記憶體洩漏。
- [ ] 大檔可開啟。

### 安全/隱私

- [ ] 離線測試通過。
- [ ] 塗黑驗證通過。
- [ ] 日誌不含敏感內容。
- [ ] entitlements 最小化。

### 相容

- [ ] Preview/Acrobat/Chrome 可開。
- [ ] macOS 14+ 測試。
- [ ] Intel/Apple Silicon 測試。

### 發佈

- [ ] 版本號/CHANGELOG。
- [ ] 簽章/公證（對外）。
- [ ] Release notes。
- [ ] 備份/回復方案。

---

## 11. Test data privacy

- 不使用真實個資；必要時用合成資料。
- 測試截圖去識別化。
- 測試 log 不上傳。
- 大型 fixture 用下載腳本，不進 repo。
- 測試完成後清除暫存/快取。
