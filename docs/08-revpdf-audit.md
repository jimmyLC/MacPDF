# 08 · RevPDF Audit

| 項目 | 內容 |
|---|---|
| 目的 | 記錄對 RevPDF Desktop 的靜態觀察，作為 MacPDF 的功能對照 |
| 對象 | RevPDF Editor 5.0.1（build 89） |
| 分析日期 | 2026-11-02 |
| 方法 | macOS bundle 結構、Mach-O 依賴、Dart AOT 字串/符號、`RevPdf_*` 匯出 API、l10n key、畫面原始檔路徑 |
| 限制 | 靜態分析，未執行 App、未反編譯 Dart 原始碼、未做 runtime 行為驗證 |

> **Clean-room note**：本文件只記錄功能與架構觀察，不包含 RevPDF 的程式碼、資產、圖示、翻譯或專有檔案。MacPDF 是獨立實作，與 RevPDF 無關。

---

## 1. Artifact identity

| 項目 | 觀察 |
|---|---|
| App | `/Applications/RevPDF Editor.app` |
| Bundle ID | `com.revpdf.editor` |
| 版本 | 5.0.1（build 89） |
| 架構 | Universal 2（arm64 + x86_64） |
| 最低 macOS | 11.0 |
| SDK | 26.2 |
| 大小 | 約 100 MB |
| 簽章 | Developer ID Application: Pawandeep Singh（M46PY9758K） |
| 公證 | Gatekeeper accepted；未 stapled |
| Entitlements | App Sandbox、user-selected read-write、security-scoped bookmarks、print、network client、disable-library-validation |
| 引擎 | `librevpdf.dylib`（fat 6.1 MB，arm64 thin 2.97 MB） |
| PDF 渲染 | `libpdfium.dylib`（8.8 MB） |
| native plugin | `revpdf.framework`（Swift，連結 Vision） |
| UI | Flutter / Dart AOT（`App.framework` 約 47 MB） |

### 1.1 觀察到的第三方 framework

`app_links`、`connectivity_plus`、`desktop_drop`、`file_picker`、`file_selector_macos`、`flutter_image_compress_macos`、`gal`、`image_editor_common`、`in_app_purchase_storekit`、`in_app_review`、`macos_secure_bookmarks`、`package_info_plus`、`pasteboard`、`path_provider_foundation`、`printing`、`screen_retriever_macos`、`share_plus`、`shared_preferences_foundation`、`url_launcher_macos`、`webview_flutter_wkwebview`、`window_manager`。

---

## 2. Observed architecture

```
Flutter / Dart AOT (App.framework)
        │
        ├── MethodChannel → revpdf.framework (Swift)
        │                       └── Vision.framework (OCR)
        │
        ├── MethodChannels → Flutter plugins (file, print, share, IAP…)
        │
        └── Dart FFI → librevpdf.dylib
                           ├── libpdfium.dylib
                           ├── C++ (PDF edit, DOCX/XLSX conversion)
                           └── Rust static components
```

### 2.1 Dart side

- 未混淆：保留 `package:revpdf_editor/...` 原始檔路徑、類別名、l10n key。
- 146 個 `package:revpdf_editor/...` 路徑；75 個畫面相關檔案。
- 1,921 個 `get:*` 在地化 getter。
- 16 個語言檔：ar、de、en、es、fr、hi、id、it、ja、ko、nl、pl、pt、ru、tr、zh。
- 繁體中文用詞未出現；`zh` 為簡體用詞（例如「编辑」「页面」「文件」）。

### 2.2 Engine side

- 122 個 `RevPdf_*` 匯出 API。
- 約 4,197 個匯出符號（nm）。
- 依賴：`libpdfium`、`libc++`、`libSystem`。
- `__TEXT` 約 2.0 MB，`__text` 約 1.6 MB（arm64 slice）。
- Rust 痕跡：`rstar`、`unicode-bidi`、`miniz_oxide`、`memchr`、`hashbrown`、`smallvec`、`gimli`、`object`。
- C++ namespace `revpdf::docx`，字串含 OOXML 模板（word/document.xml、xl/workbook.xml）。
- 錯誤字串：`PDF->DOCX conversion error`、`PDF->XLSX conversion error`。

### 2.3 Native plugin

- `RevpdfPlugin`（Swift）。
- 連結 `Vision.framework`。
- 字串：`performOcr: pngBytes is required`、`Vision`、`boundingBox`、`confidence`。
- 推論：OCR 由 Swift 呼叫 Apple Vision，Dart 接收文字與 bounding box 後嵌入 PDF。

---

## 3. Feature inventory

以下依 RevPDF 的畫面、工具列與 l10n key 整理。

### 3.1 Screens

- Home / workspace
- PDF viewer
- PDF editor
- Annotate (annotation bottom bar, comment popup)
- Organize pages / page reorder
- PDF merge
- PDF split / split middle
- PDF compress
- PDF export
- PDF extract images
- PDF header/footer
- PDF make searchable (OCR)
- PDF metadata
- PDF security
- PDF watermark
- PDF/A convert
- PDF creator
- Print
- Compare setup / results
- Redaction setup / review
- Find & replace setup / review
- Flows list / builder / run
- Settings
- Keyboard shortcuts
- Scanner / image editor
- Tabs / outline panel

### 3.2 Toolbar tools

| 工具 | 功能 |
|---|---|
| Merge | 合併多份 PDF |
| Split | 依範圍/每頁/大小分割 |
| Split Middle | 水平/垂直；可選中間或自訂位置 |
| Compress | 影像取樣/品質 |
| Organizer | 頁面排序/旋轉/刪除 |
| Extract Images | 擷取內嵌圖片 |
| PDF to Images | 頁面轉圖片 |
| PDF to Word | PDF → DOCX |
| PDF to Excel | PDF → XLSX（表格/整頁） |
| Convert PDF/A | PDF/A-1b/2b/3b；官網另列 2a |
| Make Searchable | OCR 文字層 |
| Metadata | 文件屬性 |
| Watermark | 文字/圖片浮水印 |
| Header/Footer | 頁首頁尾/頁碼 |
| Security | 密碼/權限 |
| Remove Password | 移除密碼 |
| Flatten | 註解/表單烤進頁面 |
| Compare | 版本比對 |
| Find & Replace | 全文尋找取代 |
| Auto-Redact | PII/關鍵字塗黑 |
| Flows | 批次流程 |
| Scan to PDF | 掃描/圖片轉 PDF |
| Form Builder | 建立表單 |
| Signature | 簽名/縮寫 |
| Stamps | 印章 |
| Page Numbers / Bates | 頁碼/Bates |

### 3.3 Viewer / editor features

- 多分頁、連續捲動、單頁/雙頁、fit width/page、actual size。
- 縮圖、目錄、註解列表、搜尋。
- 文字選取/複製、圖片選取/複製、貼上圖片。
- 內部/外部連結。
- 書籤新增/改名/刪除。
- 註解：highlight、underline、strikeout、squiggly、sticky note、text box、ink、shapes、stamp。
- 簽名：手繪/打字/圖片、去背、儲存常用簽名/縮寫。
- 表單：填寫、重設、flatten、建立、欄位屬性、Tab 順序。
- 文字編輯：`CoreEdit*` API——就地編輯、字型/字級/對齊/行距/字距、表格 cell 合併、undo/redo、push-down reflow。
- 圖片編輯：移動/縮放/旋轉/裁切/取代/透明度。
- 物件：stable ID、transaction、page snapshot、跨頁移動（`SpikeMoveObjectToPage`）。
- 連結：`AddGotoLink`、`AddUriLink`、`RemoveLinkAtRect`。
- 書籤：`Bookmark_Add/Delete/MoveTo/SetTitle`。
- 表單：`CreateFormField`、`DeleteFormField`、`UpdateFormFieldRect`、`AddRadioButtonWidget`、`GetFormField*`。
- 註解：`Annot_*`、`GetAnnot`、`AddStickyNote`。
- 安全：密碼、權限、塗黑、metadata 清理。
- 壓縮：影像/文字、品質預設。
- 比對：文字/視覺、頁面配對、變更清單。
- Flows：compress、OCR、watermark、stamp、rotate、split、split middle、redact、find/replace、PDF→images、flatten。
- 系統：Quick Actions、預設 PDF App、Dock menu、列印、最近文件、恢復、快捷鍵、主題。

### 3.4 Engine APIs（節選）

| API 群 | 代表 |
|---|---|
| Core edit | `CoreEditOpen/Commit/Apply`、`CoreEditSetFontName/FontSize/Alignment/LineSpacing`、`CoreEditTryMerge`、`CoreEditIsCell`、`CoreEditNeedsNextPage` |
| Text | `TextObjReplaceText`、`TextObjSplitAt`、`TranslateObjectsByStableIds`、`SetCharSpacing`、`SetTextColor` |
| Page | `ImportPages`、`PageCloneToDocument`、`PageFlattenAnnotations`、`PageFlattenToSingleStream`、`PageSnapshot`、`PageRestoreSnapshot` |
| Annotation | `AddStickyNote`、`AddGotoLink`、`AddUriLink`、`Annot_*` |
| Forms | `CreateFormField`、`DeleteFormField`、`UpdateFormFieldRect`、`AddRadioButtonWidget` |
| Bookmarks | `Bookmark_Add/Delete/MoveTo/SetTitle` |
| Redaction | `RemoveObjectsByStableIds`、`RemoveObjectsByStableIdsNested` |
| Conversion | `ConvertPdfToDocx`、`ConvertPdfToXlsx` |
| OCR | 不在引擎；Swift/Vision |
| Perf | `PreloadPagesBatch`、`ReleaseCachedResources`、`PageGetComplexityFlags` |

---

## 4. Parity matrix

| RevPDF 功能 | MacPDF | 階段 | 備註 |
|---|---|---|---|
| 開檔/瀏覽/縮圖/目錄/搜尋 | 有 | M0 | PDFKit |
| 多分頁 | 有 | M0 | NSDocument |
| 頁面排序/旋轉/刪除 | 有 | M1 | PDFKit |
| 插入/複製/擷取頁 | 有 | M1 | |
| 合併/分割/中間分割 | 有 | M1 | |
| 自訂分割線位置 | 有 | M1 | B12 |
| 依大小分割 | 有 | M1 | |
| 裁切/調整頁面尺寸 | 有 | M1 | |
| 註解（highlight/underline/strike/note/text/ink/shape） | 有 | M1 | PDFKit |
| 簽名/縮寫/去背 | 有 | M1 | |
| 印章 | 有 | M1 | |
| 浮水印/頁首頁尾/頁碼 | 有 | M1 | 含文件名稱/標題/作者/日期 token、Page X of Y |
| Bates | 有 | M1–M2 | |
| 匯出圖片/列印/分享 | 有 | M1 | |
| 連結管理 | 有 | M1 | A21 |
| 書籤編輯 | 有 | M1 | A22 |
| 建立 PDF | 有 | M1 | G17 |
| 表單填寫/flatten | 有 | M2 | |
| OCR/可搜尋 | 有 | M2 | Vision |
| 掃描邊緣偵測/透視校正 | 有 | M2 | F4/F18 |
| 缺字型偵測/下載 | 有 | M2 | O13；預設關閉、需同意 |
| 密碼/權限 | 有 | M2 | 加入密碼可能延後 |
| 壓縮 | 有 | M2 | |
| 擷取內嵌圖片 | 有 | M2 | G16 |
| PDF/A-1b／2b／3b | 有 | M2–M3 | G8 |
| PDF/A-2a（accessible/tagged） | 有（需 tagged PDF） | M4／SDK | G18；難度高 |
| 中繼資料/附件/JS 清理 | 有 | M2 | |
| Quick Action/預設 App | 有 | M2 | |
| 表單建立 | 有 | M3 | |
| 塗黑（手動/關鍵字/PII/OCR） | 有 | M3 | rasterize 先行；含外觀控制 I21 |
| 版本比對 | 有 | M3 | |
| Flows | 有 | M3 | |
| 真文字編輯 | 後期 | M4 | 高風險 |
| PDF→Word/Excel | 後期 | M4 | 高風險 |
| 數位簽章 | 後期 | M4+ | 非核心 |
| Premium/IAP/廣告 | 不做 | — | 內部使用 |
| 手機 App QR | 不做 | — | 非桌面功能 |
| 16 種語言 | 部分 | M1+ | 先繁中/英文 |
| 自動更新 | 不做 | — | 可選 Sparkle |

---

## 5. Deliberate differences

| 項目 | RevPDF | MacPDF | 理由 |
|---|---|---|---|
| UI 技術 | Flutter | SwiftUI/AppKit | 原生整合、較小、較快 |
| PDF 引擎 | 自製 C++ + PDFium | PDFKit 優先 | 降低初期複雜度 |
| 真文字編輯 | 有（CoreEdit*） | M4 optional | 成本極高 |
| PDF→Office | 有 | M4 optional | 成本/品質 |
| OCR | Vision | Vision | 相同路線 |
| 塗黑 | 物件移除 | v1 rasterize；v2 content stream | 先保證安全 |
| 金流 | StoreKit | 無 | 內部使用 |
| 平台 | macOS/iOS/Android | macOS | 專注 |
| 語言 | 16 種 | 繁中/英文 | 先做深 |
| 雲端 | 無 | 無 | local-first |

---

## 6. Unknowns

靜態分析無法確認：

- 真文字編輯在複雜表格/多欄/旋轉頁的實際品質。
- PDF→DOCX/XLSX 的版面還原程度。
- 塗黑是否真的移除 content stream 物件，或只是 rasterize。
- OCR 對繁中/混合語言的準確度。
- 大檔（>500 頁）的實際效能。
- Flows 的錯誤處理/重試/並行度。
- 是否有隱藏的網路請求/遙測（靜態字串未發現）。
- IAP 在 macOS 直裝版是否實際運作（無 MAS receipt）。

---

## 7. Lessons for MacPDF

1. **功能廣度不是問題，深度才是**：RevPDF 的工具清單很完整，但真文字編輯/轉檔仍需大量工程。
2. **PDF 沒有段落模型**：要真編輯，必須自建文字/字型/表格層；這是 M4 的原因。
3. **塗黑要驗證**：畫黑框不等於移除；rasterize 是安全的 v1。
4. **OCR 用 Vision 很合理**：本地、免費、支援中英文。
5. **批次流程是差異化**：Flows 把零散工具變成工作流。
6. **原生 Mac 整合是機會**：Quick Actions、預設 App、列印、沙盒、鍵盤。
7. **不要複製 UI/資產**：功能可以參考，實作要 clean-room。

---

## 8. Legal

- 本文件僅為功能比較與架構觀察。
- 不包含 RevPDF 的原始碼、二進位、資產、翻譯或商標使用。
- MacPDF 是獨立產品，與 RevPDF 無關。
- 若未來需要引用 RevPDF 的介面截圖，需取得授權；目前不使用。
- 「RevPDF」為其所有者商標；本專案不使用該名稱作為產品名。
