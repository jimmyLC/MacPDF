# 10 · Hard Features — Implementation Research

| 項目 | 內容 |
|---|---|
| 產品 | MacPDF |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 範圍 | RevPDF 的四個旗艦能力：自然文字編輯、版本比對、Flows、進階輸出 |
| 狀態 | 技術方向調查；**尚未做 prototype** |
| 重要 | 下列是工程方案與風險評估，不是已驗證的實作結果 |

---

## 1. Scope and confidence

這份文件回答一個問題：

> 這四個功能「大概怎麼做」、難在哪裡、值不值得自己做？

| 功能 | 核心技術 | 難度 | 我們的信心 | 建議階段 |
|---|---|---|---|---|
| Edit text naturally | content stream + 字型 + CoreText reflow | 極高 | 中（方向明確，品質未驗證） | M4 |
| Compare two PDFs | 文字 diff + 視覺 diff + 頁面配對 | 中 | 高 | M3 |
| Reuse your workflow | JSON 流程 + Swift concurrency pipeline | 中 | 高 | M3 |
| Export to Excel | 表格偵測 + OOXML/XLSX | 高 | 中 | M4 |
| Improved Word files | 版面重建 + OOXML/DOCX | 極高 | 中 | M4 |
| PDF/A-2a | tagged PDF + structure tree + 驗證 | 極高 | 低（2a 可能需要商業 SDK） | M4/SDK |
| Compress more effectively | image XObject 重寫 + 結構最佳化 | 高 | 中 | M2 基本 / M3 進階 |

**結論先講**：

- Compare 與 Flows 值得自己做，投報率高。
- Excel/Word 輸出可以先做「簡單文件」版本，複雜版面不要承諾。
- PDF/A-2a 的「a」（accessible/tagged）是另一個量級的工程；2b 可以做，2a 建議買 SDK 或不做。
- 自然文字編輯是 3–6 個月以上的專案，不建議放進第一版。

---

## 2. Why these are hard

PDF 不是 Word。它是一個**頁面描述格式**：

- 文字是「把某個字形畫在某個座標」的指令，不是段落。
- 沒有「行」、「段落」、「表格」的語意。
- 字型可能是子集（只含用到的字），沒有 Unicode 對應。
- 文字可能被拆在多個 content stream、Form XObject、圖層裡。
- 頁面可以有旋轉、裁切、CTM、clip path、透明度群組。

所以「編輯 PDF」不是改一個字串，而是：

1. 解析繪製指令。
2. 還原字元/字型/位置。
3. 推斷段落/表格/閱讀順序。
4. 重新排版。
5. 產生新的 content stream。
6. 確保其他閱讀器看得懂。

這也是為什麼 RevPDF 的 `librevpdf` 有 122 個 `RevPdf_*` API，其中一大群是 `CoreEdit*`、`TextObj*`、`PageSnapshot*`。

---

## 3. Edit text naturally

### 3.1 RevPDF 的線索

從 `librevpdf` 匯出的 API 可以看到它走的是「content stream + 物件模型」路線：

| API | 意義 |
|---|---|
| `CoreEditOpen/Commit/Apply` | 開啟一個可編輯的文字區塊，commit 後套用 |
| `CoreEditSetFontName/FontSize/Alignment/LineSpacing/CharSpacing` | 字型與段落格式 |
| `CoreEditCaretPos`、`CoreEditHitTestOffset`、`CoreEditSelectionRects` | 游標、hit test、選取 |
| `CoreEditIsCell`、`CoreEditIsMerged`、`CoreEditTryMerge` | 表格 cell 模型 |
| `CoreEditNeedsNextPage`、`CoreEditOverflow` | 文字溢出/跨頁 |
| `CoreEditSetPushDown`、`CoreEditSetBottomClamp` | 重新排版時往下推/底部限制 |
| `TextObjReplaceText`、`TextObjSplitAt` | 文字物件層級操作 |
| `TranslateObjectsByStableIds` | 依穩定 ID 移動物件 |
| `PageSnapshot`、`PageRestoreSnapshot` | 每次編輯的 undo snapshot |

這告訴我們：**不是用 PDFKit 的 annotation 覆蓋，而是自己維護一個頁面物件模型。**

### 3.2 實作 pipeline

```
PDF bytes
  │
  ▼
Content stream parser (CGPDFScanner)
  │  產生 display list：
  │  text runs / paths / images / XObjects / graphics state
  ▼
Page model
  │  glyphs + positions + fonts + colors + CTM
  ▼
Layout inference
  │  lines → paragraphs → columns → tables
  ▼
Editing model
  │  caret / selection / replace / reflow
  ▼
Layout engine (CoreText)
  │  attributed string → CTFramesetter → lines
  ▼
PDF writer
  │  新 content stream + 字型嵌入 + resource 更新
  ▼
New PDF
```

### 3.3 關鍵演算法

#### 3.3.1 Content stream 解析

用 `CGPDFScanner` + `CGPDFOperatorTable`：

- `q` / `Q`：圖形狀態堆疊。
- `cm`：CTM。
- `BT` / `ET`：文字物件。
- `Tf`：字型/大小。
- `Td` / `TD` / `Tm` / `T*`：文字位置。
- `Tj` / `TJ` / `'` / `"`：顯示文字。
- `Tc` / `Tw` / `Tz` / `Ts` / `Tr`：字距、詞距、水平縮放、rise、render mode。
- `Do`：XObject（圖片或 Form）。
- `re` / `m` / `l` / `c` / `S` / `f`：路徑（表格線、框線）。

需要遞迴處理 Form XObject，並追蹤 graphics state。

#### 3.3.2 字型與 Unicode

- 解析 `/Resources /Font`。
- Type0/CID：`/Encoding` CMap、`/ToUnicode`、`/W`、`/DW`。
- TrueType/Type1：`/Encoding`、`/Widths`、`/FirstChar`、`/FontDescriptor`。
- 用 ToUnicode 把 glyph code → Unicode。
- 沒有 ToUnicode 時，用 encoding + glyph names 推斷；失敗就用替代字型。
- 取得 advance width，計算每個字元的位置。
- 新字元若不在子集字型 → 需要 fallback 字型並嵌入子集。

#### 3.3.3 行/段落推斷

- 依 baseline y 分群；容差約 0.3 × font size。
- 依 x 間距判斷 word gap；依行距判斷 paragraph gap。
- 依字型大小/粗體判斷 heading。
- 多欄：對 x 座標做 projection，找欄位間空白。
- 表格：找水平/垂直線；沒有線時用欄位對齊與空白推斷。
- 閱讀順序：先欄、再列；RTL/CJK 另外處理。

#### 3.3.4 Reflow

最簡單到最難：

| 等級 | 行為 | 難度 |
|---|---|---|
| L0 | 覆蓋一層文字（不是真編輯） | 低，但不誠實 |
| L1 | 同字型、同大小替換，手動調整字距 | 中 |
| L2 | 行內替換，寬度不變（用字距吸收） | 中 |
| L3 | 段落重新斷行，區塊高度不變（可能溢出） | 高 |
| L4 | 段落重新斷行 + 往下推後續區塊 | 高 |
| L5 | 多欄/表格 + 跨頁 + 頁面重排 | 極高 |

RevPDF 的 `CoreEditSetPushDown`、`CoreEditNeedsNextPage` 顯示它至少做到 L4/L5。

用 CoreText 做 L3/L4：

```swift
let attr = NSAttributedString(string: text, attributes: [
    .font: font,
    .paragraphStyle: style
])
let framesetter = CTFramesetterCreateWithAttributedString(attr)
let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
let lines = CTFrameGetLines(frame) as! [CTLine]
```

- 計算每個 line 的寬高。
- 跟原始 line boxes 比較。
- 若新高度 > 原區塊高度 → 把後續區塊往下移 delta。
- 若超出頁面 → 縮小字級/行距，或提示「需要下一頁」。
- 表格：cell 內 reflow，列高增加，往下推列。

#### 3.3.5 寫回 PDF

- 為每個被修改的文字區塊產生新的 content stream 片段。
- 保留原本的 `q/Q`、CTM、clip；只替換 `BT...ET` 區段。
- 移除舊的文字繪製指令（依 stable ID/位置）。
- 更新 `/Resources`（新字型、圖片）。
- 嵌入字型子集（`FontFile2`/`FontFile3`）。
- 更新 `/Contents`、`/Length`，必要時合併多個 stream。
- 保持其他頁面/物件不變（incremental update 或 full rewrite）。

### 3.4 macOS API 對應

| 工作 | API |
|---|---|
| 解析 content stream | `CGPDFScanner`、`CGPDFOperatorTable` |
| 讀取 PDF 結構 | `CGPDFDocument`、`CGPDFPage`、`CGPDFDictionary` |
| 字型/Unicode | `CGFont`、CoreText `CTFont`、`CTFontGetGlyphsForCharacters` |
| 排版 | `CoreText`（`CTFramesetter`、`CTLine`） |
| 繪製/輸出 | `CGPDFContext` |
| 顯示 | PDFKit `PDFView`（唯讀渲染） |
| OCR 文字層 | `CGPDFContext` + invisible text |

**PDFKit 不提供 content stream 編輯。** 這是為什麼不能只用 PDFKit 做真文字編輯。

### 3.5 難點

1. **Form XObject 巢狀**：文字可能在表單/圖層裡，需遞迴解析與改寫。
2. **Clip path**：文字被裁切時，編輯後可能看不到。
3. **Type3 字型**：字型本身是繪圖指令，沒有標準 Unicode。
4. **子集字型**：新字元不在字型裡，需 fallback + 嵌入。
5. **CJK/RTL**：字距、連字、雙向文字、垂直書寫。
6. **表格**：合併儲存格、欄寬、跨頁。
7. **Z-order**：文字可能被圖片蓋住。
8. **頁面旋轉/裁切**：座標轉換容易錯。
9. **其他閱讀器**：輸出必須在 Preview/Acrobat/Chrome 都正確。
10. **Undo**：每次編輯要有 snapshot/command log。

### 3.6 Build vs buy

| 方案 | 優點 | 缺點 |
|---|---|---|
| 自建 content stream engine | 控制力最高、無授權費 | 3–6 個月以上、品質風險高 |
| PDFium | BSD、渲染成熟 | 編輯 API 有限，不是 full reflow engine |
| MuPDF | 功能強 | AGPL/商業授權；編輯仍有限 |
| PDFTron/Apryse | 成熟 content editing | 授權費高、綁 SDK |
| Adobe PDF Services | 雲端/桌面 API | 上傳/費用/依賴 |

**建議**：若真要做，先做 L1/L2（同字型替換、行內編輯），不要一開始承諾 L5。L3/L4 用 CoreText；L5 只支援簡單表格。

### 3.7 分階段計畫

| 階段 | 交付 | 估時 |
|---|---|---|
| M4.0 | content parser + page model + 文字位置 | 3–4 週 |
| M4.1 | 同字型文字替換、行內編輯 | 4–6 週 |
| M4.2 | 段落 reflow、push down | 6–8 週 |
| M4.3 | 表格/多欄/跨頁 | 8–12 週 |
| M4.4 | 邊界案例、其他閱讀器驗證 | 4–6 週 |

**總計**：6–9 個月（樂觀 4 個月，現實 9–12 個月）。

### 3.8 驗證方式

- 文字萃取：編輯前後，預期字串正確。
- 視覺 diff：編輯區域外無變化；區域內符合預期。
- 字型：所有新字元都有 glyph；輸出嵌入了子集。
- 相容性：Preview/Acrobat/Chrome 開啟正常。
- 回歸：表格、多欄、CJK、RTL、旋轉頁。

### 3.9 信心

- **方向**：高（API 與 PDF 規格明確）。
- **品質/時程**：低到中（dependent on font/layout edge cases）。
- **建議**：不要放進 M0–M3；若沒有明確需求，先做文字方塊/圖片編輯。

---

## 4. Compare two PDFs

### 4.1 RevPDF 的線索

- `CompareSetupScreen`、`CompareResultsScreen`。
- l10n：`compareFilterText`、`compareFilterHideFormatting`、`compareInsertedInNew`、`compareRemovedFromOld`、`compareNounAdded/Deleted/Modified/Moved/Pages/Image`、`compareNextChange/PreviousChange`、`compareUnrelatedWarning`。
- 推論：文字 diff + 視覺 diff + 頁面配對。

### 4.2 Pipeline

```
Old PDF ──► text extraction + page fingerprint ──┐
                                                ├──► page matching ──► text diff ──► change list
New PDF ──► text extraction + page fingerprint ──┘                     │
                                                                       ├──► visual diff
                                                                       └──► report
```

### 4.3 文字抽取

- 第一版：`PDFPage.string`（快，但沒有位置）。
- 進階：content parser 取得每個字元的 bounding box（可重用第 3 節的 parser）。
- 正規化：Unicode NFC/NFKC、空白、換行、連字號、頁首頁尾、頁碼。
- 頁首/頁尾偵測：跨頁重複出現的行 → 忽略。

### 4.4 頁面配對

- 指紋：
  - 文字：word shingles + MinHash/SimHash。
  - 視覺：pHash/dHash 或 Vision `VNGenerateImageFeaturePrintRequest`。
  - 尺寸/頁數。
- 相似度矩陣 → Hungarian assignment。
- 結果：matched / inserted / deleted / moved。
- 移動頁：文字相似度高但 index 不同。

### 4.5 文字 diff

- Word-level diff：`CollectionDifference` 或 Myers/patience。
- 將 diff 映射回 PDF 座標：
  - 用 `PDFSelection` 找字串範圍 → bounds。
  - 或用 content parser 的字元 box。
- 格式 diff：比較字型/大小/顏色/位置（需要 parser）。
- 過濾：只看文字、忽略格式、忽略空白。

### 4.6 視覺 diff

1. 兩頁 render 成相同尺寸（150–200 DPI）。
2. 對齊：phase correlation / translation；必要時特徵匹配。
3. 像素差異：`vImageSubtract` / `CIImage.differenceBlendMode`。
4. 門檻 + 形態學（膨脹/侵蝕）去掉 anti-aliasing 雜訊。
5. 連通區域 → bounding boxes。
6. 忽略小於 N px 的差異。
7. 掃描件先 OCR 或只用視覺 diff。

### 4.7 UI

- 左右並排 PDFView，同步捲動/縮放。
- 變更 overlay：新增綠、刪除紅、修改黃。
- 變更清單：頁碼、類型、摘要、上一筆/下一筆。
- 過濾：文字/格式/圖片。
- 匯出報告（PDF/HTML）。

### 4.8 難點

- 文字抽取順序（多欄/表格）。
- 不同 renderer 造成視覺誤差。
- 掃描件/OCR 錯誤。
- 頁面尺寸/縮放不同。
- 效能：100 頁 × 視覺 diff。
- 移動頁/插入頁的配對。

### 4.9 估時

| 階段 | 交付 | 估時 |
|---|---|---|
| C1 | 文字抽取 + 正規化 + 頁面配對 | 1–2 週 |
| C2 | 文字 diff + UI | 2–3 週 |
| C3 | 視覺 diff + 對齊 | 2–4 週 |
| C4 | 過濾/報告/邊界案例 | 2–3 週 |

**總計**：6–10 週（樂觀 4 週）。

### 4.10 信心

- 方向：高。
- 品質：中高（文字 diff 可靠；視覺 diff 需調參）。
- 建議：M3 做，與塗黑並列為差異化。

---

## 5. Reuse your workflow（Flows）

### 5.1 RevPDF 的線索

- `FlowsListScreen`、`FlowBuilderScreen`、`FlowRunScreen`。
- l10n：`flowAddStep`、`flowInputAllFolder`、`flowOutputAskWhenRun`、`flowOutputOverwrite/Skip/KeepBoth`、`flowSplitBySize`、`flowRedactCat*`、`flowRotateScope*`、`flowReviewOn/Off`、`flowRunFlow`、`flowStepDisable/Enable`。
- 步驟：compress、OCR、watermark、stamp、rotate、split、split middle、redact、find & replace、PDF→images、flatten。

### 5.2 資料模型

```swift
struct Flow: Codable, Identifiable {
    let id: UUID
    var schemaVersion: Int
    var name: String
    var steps: [FlowStep]
    var input: FlowInput
    var output: FlowOutput
    var createdAt: Date
    var lastRun: FlowRunSummary?
}

enum FlowStep: Codable {
    case compress(CompressOptions)
    case ocr(OCROptions)
    case watermark(WatermarkConfig)
    case stamp(StampConfig)
    case rotate(RotateOptions)
    case split(SplitOptions)
    case redact(RedactOptions)
    case findReplace(FindReplaceOptions)
    case exportImages(ExportOptions)
    case flatten(FlattenOptions)
}
```

- JSON 存 `Application Support/MacPDF/Flows/<uuid>.json`。
- `schemaVersion` 用於 migration。
- 可匯出/匯入 JSON。

### 5.3 Executor

```swift
actor FlowExecutor {
    func run(_ flow: Flow,
             progress: @Sendable (FlowEvent) -> Void) async throws -> FlowReport
}
```

流程：

1. 解析輸入（檔案/資料夾）。
2. 為每個檔案建立工作項。
3. 逐檔執行 steps：
   - 讀取 → 複製到 temp → step 1 → step 2 → … → 原子寫出。
4. 錯誤策略：stop / skip / retry。
5. 取消：`Task.checkCancellation()`；清 temp。
6. 進度：`AsyncStream<FlowEvent>`。
7. 報表：成功/失敗/略過/耗時。

### 5.4 難點

- 檔案權限/security-scoped bookmarks。
- 輸出命名/碰撞/覆寫。
- 部分失敗的清理。
- 記憶體（同時處理多檔）。
- 塗黑不可逆：Flows 裡的塗黑要 extra confirmation。
- OCR/壓縮耗時：進度/取消。
- 版本遷移：flow schema 改變。

### 5.5 估時

| 階段 | 交付 | 估時 |
|---|---|---|
| F1 | model + store + list/builder UI | 1–2 週 |
| F2 | executor + 3 個 steps | 1–2 週 |
| F3 | 全部 steps + 錯誤/取消/報表 | 2–3 週 |
| F4 | 匯入/匯出、Shortcuts/CLI | 1–2 週 |

**總計**：5–9 週（樂觀 3 週）。

### 5.6 信心

- 高。這是四個功能裡最可控的。
- 建議：M3 做，與 Compare 一起。

---

## 6. Get better output

### 6.1 Export to Excel（PDF → XLSX）

#### 6.1.1 表格偵測

- 文字 runs + bounding boxes。
- 向量線：解析 `re`/`m`/`l`/`S`，找水平/垂直線，聚類成 grid。
- 沒有線：用 x/y 投影 + 空白 gap 推斷欄/列。
- Cell 分配：文字中心點落在哪個 cell。
- 合併儲存格：內部缺少線段 → span。
- 多頁表格：欄位對齊 → 合併到同一 sheet 或分頁。
- Header 偵測：第一列字型/粗體/背景不同。

#### 6.1.2 XLSX 產生

OOXML 最小結構：

```
[Content_Types].xml
_rels/.rels
xl/workbook.xml
xl/_rels/workbook.xml.rels
xl/worksheets/sheet1.xml
xl/styles.xml
xl/sharedStrings.xml (optional)
```

- Cell：`<c r="A1" t="inlineStr"><is><t>...</t></is></c>` 或 sharedStrings。
- 數字/日期：`t="n"` + style。
- 欄寬、換行、框線、合併：`<mergeCells>`。
- ZIP：需要 ZIP writer。選項：
  - `ZIPFoundation`（MIT）— 最省事。
  - 自寫 minimal ZIP（store/deflate + CRC32）— 約 300–500 行。
  - 先輸出 CSV（簡單），但不是 XLSX。

#### 6.1.3 品質

| 情境 | 品質 |
|---|---|
| 簡單表格（有框線、單頁） | 好 |
| 多頁表格 | 中 |
| 合併儲存格 | 中 |
| 旋轉文字/多欄 | 差 |
| 掃描表格 | 需 OCR，差–中 |

#### 6.1.4 估時

- 表格偵測 + XLSX：4–8 週（簡單）。
- 複雜表格/多頁/合併：3–6 個月。
- 信心：中。

### 6.2 Improved Word files（PDF → DOCX）

#### 6.2.1 版面重建

- 文字 runs → lines → blocks → paragraphs。
- Heading：字型大小/粗體/編號。
- List：bullet/numbering 偵測。
- 多欄：x-projection。
- 表格：同 6.1。
- 圖片：抽取 image XObject，依位置插入。
- 頁首/頁尾/頁碼：可選。
- 閱讀順序：欄/列。

#### 6.2.2 DOCX 產生

OOXML 最小結構：

```
[Content_Types].xml
_rels/.rels
word/document.xml
word/styles.xml
word/numbering.xml
word/settings.xml
word/_rels/document.xml.rels
word/media/image1.png
```

- Paragraph：`<w:p>` + `<w:pPr>` + `<w:r>`。
- Run：字型、大小、粗體、斜體、底線、顏色。
- 表格：`<w:tbl>`、`<w:tr>`、`<w:tc>`、`<w:gridSpan>`、`<w:vMerge>`。
- 圖片：`<w:drawing>` + relationship。
- 頁面尺寸/邊界：`<w:sectPr>`。

#### 6.2.3 品質

| 情境 | 品質 |
|---|---|
| 純文字/簡單段落 | 好 |
| 標題/清單 | 中高 |
| 簡單表格 | 中 |
| 多欄/雜誌版面 | 差 |
| 掃描件 | 需 OCR，差 |

#### 6.2.4 Build vs buy

- 自建：6–12 週（簡單），3–6 個月（完整）。
- LibreOffice headless：品質較好，但需安裝、啟動慢、沙盒不友好、授權/大小。
- 商業 SDK：PDFTron/Apryse、Adobe PDF Services；費用高但品質穩。
- **建議**：先做 PDF→RTF/DOCX 的「文字 + 基本段落」，不要承諾完整版面。

### 6.3 PDF/A-2a

#### 6.3.1 規格要求

PDF/A-2（ISO 19005-2）基於 PDF 1.7。Level A（accessible）要求：

- Tagged PDF：`/MarkInfo << /Marked true >>`、`/StructTreeRoot`、結構元素、`/RoleMap`、`/ParentTree`、MCID。
- 邏輯結構/閱讀順序/標題/清單/表格/圖片。
- 圖片 `/Alt`、連字 `/ActualText`、語言 `/Lang`。
- 所有字型嵌入 + ToUnicode。
- 無加密、無 JavaScript、無 audio/video、無外部內容。
- Output intent（ICC）。
- XMP：`pdfaid:part=2`、`pdfaid:conformance=A`。
- PDF/A-2 允許透明度（A-1 不允許）。

#### 6.3.2 難點

- PDFKit/CoreGraphics **不提供**建立 structure tree/tagged PDF 的高階 API。
- 既有 PDF 通常沒有 tag；要「推斷」標題/段落/表格/閱讀順序，等於做一次版面分析。
- 需要低階 PDF writer 或商業 SDK。
- 驗證工具：veraPDF（Java）、Adobe Preflight；整合到 CI 需要 Java。

#### 6.3.3 選項

| 方案 | 2b | 2a | 備註 |
|---|---|---|---|
| 自建 CoreGraphics + XMP | 可能 | 很難 | 2b 需字型嵌入/ICC/清理 |
| Ghostscript | 可 | 不確定/通常不 | 2b 常見；2a tagging 不完整 |
| LibreOffice | 2b | 不確定 | 需外部 App |
| PDFTron/Apryse | 可 | 可 | 商業授權 |
| Adobe PDF Services | 可 | 可 | 雲端/費用 |

#### 6.3.4 建議

- M2/M3 先做 **PDF/A-2b**（basic）：嵌入字型、ICC、移除加密/JS/附件、XMP。
- **PDF/A-2a** 只有在明確需求（法規/客戶）時才做；優先評估商業 SDK。
- 不要在新聞稿/UI 寫「支援 PDF/A-2a」直到 veraPDF 驗證通過。

#### 6.3.5 估時

- 2b：4–8 週。
- 2a：6–12 個月（自建）或 SDK 整合 2–4 週。

### 6.4 Compress more effectively

#### 6.4.1 等級

| 等級 | 做法 | 品質 | 難度 |
|---|---|---|---|
| C1 | 整頁 rasterize + JPEG | 失去文字/向量 | 低 |
| C2 | 影像 XObject 重新取樣/重編碼 | 保留文字/向量 | 中高 |
| C3 | 移除重複資源/未使用物件/字型子集 | 保留品質 | 高 |
| C4 | Linearize/object streams/xref streams | 結構最佳化 | 中 |
| C5 | JBIG2/JPEG2000/CCITT | 掃描件最佳 | 高（專利/編碼器） |

#### 6.4.2 C2 實作

1. 解析 content stream，找 `/XObject` image。
2. 解碼（DCTDecode/JPX/Flate）。
3. 重新取樣（ImageIO/CoreImage）。
4. 重編碼 JPEG（品質/DPI）。
5. 替換 image stream，更新 `/Width`/`/Height`/`/Filter`/`/Length`。
6. 保留文字/向量。
7. 可選：移除重複 image。

#### 6.4.3 工具

- `qpdf`（Apache-2.0）：結構最佳化、linearize、object streams。可作為 CLI helper 或參考實作。
- Ghostscript（AGPL）：壓縮效果好，但授權/沙盒/大小需評估。
- PDFium：渲染/物件，不直接壓縮。
- 自建：控制力高，但工作量大。

#### 6.4.4 估時

- C1：1–2 週。
- C2：6–10 週。
- C3/C4：2–4 個月。
- 信心：中。

---

## 7. Recommended sequencing

| 階段 | 功能 | 理由 |
|---|---|---|
| M2 | 基本壓縮（C1）、PDF/A-2b 評估 | 先解決常見需求 |
| M3 | Compare、Flows | 投報率高、可控 |
| M3 | 塗黑（rasterize） | 差異化、安全 |
| M4 | Excel/Word（簡單文件） | 先驗證品質 |
| M4 | 自然文字編輯（L1/L2） | 先做最小可用 |
| M4+ | PDF/A-2a、C2/C3 壓縮、完整 Word | 需求/預算明確再做 |

### 7.1 先做 spike（技術驗證）

在寫正式程式前，先做 5 個小 spike：

1. **Content parser**：解析一頁文字，取出字元/字型/位置，畫回原位。
2. **Line edit**：替換一行同字型文字，輸出後在 Preview 看起來一樣。
3. **Visual diff**：兩頁 render + diff + bounding boxes。
4. **XLSX writer**：產生一個 3×3 表格，Excel 可開。
5. **PDF/A-2b**：一份簡單 PDF 轉 2b，veraPDF 通過。

每個 spike 1–3 天；通過再排 M4。

---

## 8. What we know vs. what we don't

### 8.1 已知

- RevPDF 的 API 顯示它自建 content stream/物件模型（`CoreEdit*`）。
- PDFKit 不支援 content stream 編輯。
- Compare/Flows 用 PDFKit + Swift concurrency 可做。
- XLSX/DOCX 是 OOXML + ZIP，格式明確。
- PDF/A-2a 需要 tagged PDF，CoreGraphics/PDFKit 不直接支援。

### 8.2 未知（需 spike）

- 我們的 content parser 能否正確處理 90% 常見 PDF？
- CoreText reflow 在真實文件中夠不夠好？
- Vision OCR 對繁中/表格的準確度？
- PDF/A-2b 在 veraPDF 的通過率？
- 視覺 diff 的誤報率？
- 大型表格轉 Excel 的可用性？
- 壓縮 C2 的畫質/大小平衡？

### 8.3 不要把「有調查」當成「已驗證」

這份文件是 **desk research + API 觀察**，不是實作結果。任何估時都應該在 spike 後修正。

---

## 9. References

- PDF 1.7 / ISO 32000-1: <https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf>
- PDF/A: <https://www.pdfa.org/>
- veraPDF: <https://verapdf.org/>
- CGPDFScanner: <https://developer.apple.com/documentation/coregraphics/cgpdfscanner>
- CoreText: <https://developer.apple.com/documentation/coretext>
- Vision: <https://developer.apple.com/documentation/vision>
- qpdf: <https://qpdf.sourceforge.io/>
- Ghostscript: <https://www.ghostscript.com/>
- ZIPFoundation: <https://github.com/weichsel/ZIPFoundation>
- OOXML (ECMA-376): <https://www.ecma-international.org/publications-and-standards/standards/ecma-376/>
