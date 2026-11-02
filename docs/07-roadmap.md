# 07 · Roadmap

| 項目 | 內容 |
|---|---|
| 產品 | PDF Workbench |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 範圍 | M0–M4 里程碑、估時、依賴、風險、phase gate |
| 前提 | 單人開發 + AI 輔助 + 少量測試人力；先內部使用 |

---

## 1. Milestone overview

| 階段 | 主題 | 產出 | 估時 | 狀態 |
|---|---|---|---|---|
| M0 | 外殼與瀏覽 | 可開檔、看 PDF、縮圖、目錄、搜尋、多視窗 | 2–3 天 | Planned |
| M1 | 日常可用 | 頁面操作、合併/分割、註解、簽名、浮水印、匯出、列印 | 1–2 週 | Planned |
| M2 | 掃描與保護 | OCR、表單填寫/flatten、密碼、壓縮、中繼資料、Quick Action | 2–3 週 | Planned |
| M3 | 進階工作台 | 表單建立、塗黑、比對、Flows、PDF/A-1b/2b/3b | 3–4 週 | Planned |
| M4 | 進階編輯 | 真文字編輯、PDF→Word/Excel、數位簽章 | 3–6 個月 | Optional |

> 估時是「有經驗的開發者 + AI 輔助、沒有重大阻礙」的樂觀值。實際日曆時間要加上需求變更、測試、除錯與使用者回饋。

---

## 2. M0 — Shell & viewing

### 2.1 Scope

- Xcode 專案（xcodegen）。
- App shell：menu、toolbar、window、settings 骨架。
- 開啟 PDF：Open panel、拖放、最近文件、命令列。
- PDFView：連續捲動、單頁/雙頁、fit width/page、actual size。
- 左側欄：縮圖、目錄。
- 搜尋：關鍵字、下一筆/上一筆。
- 多視窗/分頁。
- 深色模式。
- Undo/Redo 骨架。
- 自動恢復骨架。

### 2.2 Exit criteria

- [ ] 100 MB / 500 頁 PDF 5 秒內開啟。
- [ ] 捲動 60 fps。
- [ ] 縮圖/目錄/搜尋可用。
- [ ] 多視窗可獨立操作。
- [ ] 關閉/重開恢復視窗。
- [ ] 沒有 P0 bug。

### 2.3 Dependencies

- macOS 14 SDK。
- PDFKit 可用。
- 無第三方依賴。

---

## 3. M1 — Daily driver

### 3.1 Scope

- 頁面排序、旋轉、刪除、插入空白頁、插入 PDF、擷取。
- 合併、分割、中間分割。
- 註解：螢光筆、底線、刪除線、波浪線、便條、文字方塊、手繪、形狀。
- 簽名、印章。
- 浮水印、頁首頁尾、頁碼、Bates（基本）。
- 匯出圖片、列印、分享。
- Undo/Redo、自動儲存、恢復。
- 鍵盤快捷鍵。
- 連結/書籤編輯（A21/A22）。
- 建立 PDF（G17）。

### 3.2 Exit criteria

- [ ] 合併 10 份 PDF，頁序正確。
- [ ] 分割/中間分割輸出正確。
- [ ] 註解在 Preview/Acrobat 顯示。
- [ ] 簽名可儲存/重複使用。
- [ ] 浮水印/頁碼套用到指定頁。
- [ ] 匯出 PNG/JPEG，DPI 正確。
- [ ] 列印正常。
- [ ] 當機後可恢復。
- [ ] 沒有 P0/P1 bug。

### 3.3 Dependencies

- M0 完成。
- 簽名畫布/圖片處理。
- 列印 plugin（Apple Printing）。

---

## 4. M2 — Scan & protect

### 4.1 Scope

- 匯入圖片、建立 PDF、影像編輯（裁切/旋轉/對比）。
- OCR：單頁/全文件、繁中/英文、隱形文字層、快取、取消。
- 表單填寫、重設、flatten。
- 密碼開啟/移除、權限（讀取）。
- 壓縮：影像取樣、品質預設。
- 擷取內嵌圖片。
- PDF/A-1b／2b／3b（基本）。
- 中繼資料編輯/移除、附件/JS 清理。
- Quick Action、預設 PDF App。
- Dock 選單、多螢幕視窗記憶。

### 4.2 Exit criteria

- [ ] OCR 10 頁，搜尋得到關鍵字。
- [ ] OCR 文字可選取/複製。
- [ ] 表單填寫/flatten 正確。
- [ ] 加密 PDF 可開/可移除密碼。
- [ ] 壓縮後檔案變小且可開。
- [ ] PDF/A-1b／2b／3b 基本驗證通過。
- [ ] 中繼資料/附件/JS 可清理。
- [ ] 離線測試通過。

### 4.3 Dependencies

- Vision OCR。
- CoreGraphics PDF context。
- 表單欄位 API。
- 密碼/權限 API（PDFKit 限制需驗證）。

---

## 5. M3 — Power tools

### 5.1 Scope

- 表單建立：欄位、屬性、Tab 順序、對齊/分佈。
- 塗黑：手動、關鍵字、PII 預設、OCR、審閱、套用、驗證。
- 版本比對：文字/視覺、頁面配對、變更清單。
- Flows：列表、builder、執行、進度、錯誤報表。
- PDF/A-1b／2b／3b 進階驗證。
- 註解搜尋/篩選。
- 塗黑樣式預設。
- 大檔模式、首次啟動引導。

### 5.2 Exit criteria

- [ ] 建立表單，Tab 順序正確。
- [ ] 塗黑 5 區域，文字萃取為空。
- [ ] 塗黑 PII/OCR，無漏字。
- [ ] 塗黑驗證失敗不覆寫原檔。
- [ ] 比對可列出新增/刪除/修改。
- [ ] Flows 跑 20 檔，報表正確。
- [ ] Flows 可取消。
- [ ] 沒有 P0/P1 bug。

### 5.3 Dependencies

- M2 完成。
- PDF content stream / rasterize 塗黑。
- 文字 diff / 視覺 diff。
- Flow executor。

---

## 6. M4 — Advanced editing（optional）

### 6.1 Scope

- 真文字編輯：段落、字型、字級、對齊、行距、表格。
- PDF → DOCX / XLSX。
- 數位簽章/憑證。
- PDF/X。
- PDF/A-2a（tagged）／PDF/X。

### 6.2 為什麼是 optional

- 真文字編輯需要 content stream、字型、ToUnicode、reflow、表格結構；估 3–6 個月。
- PDF → Office 需要版面重建；高機率「看起來可以、實際排版壞掉」。
- 這兩個功能的成本 > M0–M3 全部加起來。
- 若沒有明確需求，建議不做。

### 6.3 決策點

M3 結束前回答：

1. 真文字編輯是「必要」還是「nice to have」？
2. PDF → Word/Excel 的品質門檻是什麼？
3. 是否願意買商業 SDK？
4. 是否有時間維護？

---

## 7. Critical path

```
M0 shell
  │
  ├──► M1 page ops / annotations / export
  │        │
  │        ├──► M2 OCR / forms / compress
  │        │        │
  │        │        └──► M3 redaction / compare / Flows
  │        │                 │
  │        │                 └──► M4 text editing / Office
  │        │
  │        └──► 使用者 dogfooding（越早越好）
  │
  └──► 測試 fixture / 效能基準（平行）
```

**最長路徑**：M0 → M1 → M2 → M3 → M4。  
**可平行**：fixture 建立、效能測試、UX prototype、文件。

---

## 8. Staffing & effort

### 8.1 假設

- 1 位主要開發者（Swift/macOS）。
- AI 輔助（程式、測試、文件）。
- 0.2–0.5 位測試/使用者回饋。
- 設計：初期用原生控件，不請專職設計。

### 8.2 估時（樂觀/現實）

| 階段 | 樂觀 | 現實 |
|---|---|---|
| M0 | 2–3 天 | 1 週 |
| M1 | 1–2 週 | 3–4 週 |
| M2 | 2–3 週 | 4–6 週 |
| M3 | 3–4 週 | 6–8 週 |
| M4 | 3–6 月 | 6–12 月 |

**M2 可用版本**：現實 6–10 週。  
**M3 完整版本**：現實 12–18 週。  
**M4**：另外 6–12 個月。

---

## 9. Phase gates

### Gate 0 → M1

- [ ] M0 exit criteria 全過。
- [ ] 使用者試用一週，確認瀏覽/縮圖/搜尋夠用。
- [ ] 沒有 PDFKit 阻礙。

### Gate 1 → M2

- [ ] M1 exit criteria 全過。
- [ ] 日常註解/頁面整理可取代 Preview。
- [ ] 存檔/恢復可靠。

### Gate 2 → M3

- [ ] M2 exit criteria 全過。
- [ ] OCR/表單/壓縮品質可接受。
- [ ] 離線/隱私測試通過。

### Gate 3 → M4

- [ ] M3 exit criteria 全過。
- [ ] 使用者明確要求真文字編輯/Office 轉檔。
- [ ] 有時間/預算維護。
- [ ] 否則停在 M3。

---

## 10. Risk register

| 風險 | 可能性 | 影響 | 對策 | 觸發點 |
|---|---|---|---|---|
| PDFKit 功能不足（content stream） | 高 | 高 | v1 rasterize；v2 CGPDFScanner；v3 PDFium | M3 塗黑 |
| 真文字編輯難度爆炸 | 高 | 高 | 列 M4；先做文字方塊 | M4 評估 |
| PDF→Office 品質差 | 高 | 中 | 先做文字/RTF；必要時買 SDK | M4 評估 |
| 大檔效能/記憶體 | 中 | 高 | tile render、分頁載入、快取上限 | M0/M1 |
| 塗黑漏字 | 中 | 高 | 審閱 + 驗證 + rasterize 保底 | M3 |
| 表單 flatten 不相容 | 中 | 中 | 多閱讀器測試 | M1/M2 |
| 密碼/權限寫入 API 不足 | 中 | 中 | 先移除密碼；加入密碼延後 | M2 |
| 沙盒檔案存取 | 中 | 中 | security-scoped bookmarks | M0 |
| OCR 準確度不足 | 中 | 中 | 多語言測試；Tesseract fallback | M2 |
| Flows 錯誤處理複雜 | 中 | 中 | 先做 stop/skip；重試延後 | M3 |
| 需求膨脹 | 高 | 高 | phase gate；明確 out of scope | 全程 |
| 單人 burnout | 中 | 高 | 小里程碑、dogfooding、可暫停 | 全程 |

---

## 11. Build vs buy

| 功能 | 自建 | 買/用現成 | 建議 |
|---|---|---|---|
| PDF 渲染 | PDFKit | PDFium | PDFKit |
| OCR | Vision | Tesseract/雲端 | Vision |
| 塗黑 | rasterize/content stream | 商業 SDK | 先自建 |
| PDF→Office | 自建 | PDFTron/Adobe/LibreOffice | 先不做 |
| 壓縮 | CoreGraphics | Ghostscript | 先自建 |
| 數位簽章 | 自建 | 商業 SDK | 先不做 |
| 更新 | Sparkle | — | 需要再做 |

---

## 12. Post-M3 ideas（not commitments）

- 真文字編輯。
- PDF→DOCX/XLSX。
- 憑證簽章。
- OCR 更多語言。
- Shortcuts/AppleScript。
- 選用 Google Fonts。
- 簡中/日文/韓文介面。
- 雲端？不做。
- 協作？不做。
- AI？不做。

---

## 13. Internal rollout plan

1. **Dogfood M0**：自己每天用來開 PDF、找資料。
2. **Dogfood M1**：用它註解/合併/簽名，取代 Preview。
3. **Dogfood M2**：掃描/OCR/表單/壓縮；記錄痛點。
4. **Dogfood M3**：塗黑/比對/Flows；建立真實案例。
5. **內部試用**：2–3 位同事，收集 bug/需求。
6. **穩定版**：M3 + 2 週 bug fix，再考慮對外。

---

## 14. Maintenance

- 每月檢查 macOS 新版相容性。
- 每季檢查 PDFKit/Vision 行為變化。
- 定期更新 fixture。
- 保持零網路/零遙測。
- 若引入依賴，每季檢查 CVE。
- 備份/恢復流程每年演練一次。
