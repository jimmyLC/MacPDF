# 04 · Technical Design

| 項目 | 內容 |
|---|---|
| 產品 | MacPDF |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 目標平台 | macOS 14+，Universal 2（arm64 + x86_64） |
| 語言 | Swift 6 |
| UI | SwiftUI + AppKit bridges |
| PDF | PDFKit + CoreGraphics |
| OCR | Vision |
| 狀態 | 設計階段，尚未實作 |

---

## 1. Goals and constraints

### 1.1 Goals

- 原生 macOS 體驗，不包 web view。
- 100 MB / 500 頁文件可順暢開啟與捲動。
- 所有核心功能離線可用。
- 存檔可靠：原子寫入、備份、當機恢復。
- 塗黑可驗證：存檔後文字萃取不到被塗黑內容。
- 模組化：頁面操作、OCR、塗黑、比對、Flows 各自獨立可測試。

### 1.2 Constraints

- 第一版不引入 PDFium。
- 不執行 PDF JavaScript。
- 第一版不處理 XFA 表單（只支援 AcroForm）。
- 第一版只做繁中＋英文。
- 單人開發，優先減少依賴與建置複雜度。

---

## 2. Stack and rationale

| 層 | 選擇 | 理由 | 替代方案 |
|---|---|---|---|
| UI | SwiftUI + AppKit | 原生、宣告式、易做 inspector/sidebar | AppKit 全手寫（較繁瑣） |
| Document | `NSDocument` | 自動儲存、版本、最近文件、多視窗 | `DocumentGroup`（較新但控制較少） |
| PDF render | PDFKit `PDFView` | 成熟、支援註解/表單/搜尋/列印 | PDFium（需自編） |
| PDF ops | PDFKit + CoreGraphics | 頁面插入/刪除/合併/繪製 | PDFium |
| OCR | Vision | 本地、免費、支援中英文 | Tesseract（需安裝/訓練） |
| Image | CoreImage / ImageIO | 原生、效率好 | libvips |
| Text layer | `CGPDFContext` | 可畫隱形文字 | PDFKit annotation |
| Project | xcodegen | 專案檔可版控、可重現 | 手動 .xcodeproj |
| Tests | XCTest / XCUITest | 原生 | 第三方 |

### 2.1 Why not PDFium in v1

- PDFKit 已涵蓋 80% 功能。
- PDFium 需要自行編譯 XCFramework、處理 C++ 介面、簽章、記憶體。
- 先驗證產品流程，再決定是否為了 content stream 編輯/真塗黑導入。
- 若導入，會放在獨立的 `PDFEngine` module，避免污染 UI。

### 2.2 Why not Flutter

- 只做 macOS，原生 PDFKit 省掉大量工作。
- 較小 App、較好效能、較好沙盒/列印/Quick Actions 整合。
- 若未來要 Windows/iOS，再評估跨平台。

---

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│ Presentation                                                 │
│  SwiftUI Views · Toolbar · Sidebar · Inspector · Settings    │
├──────────────────────────────────────────────────────────────┤
│ Application                                                  │
│  AppCoordinator · MenuCommands · WindowManager · Onboarding  │
├──────────────────────────────────────────────────────────────┤
│ Document                                                     │
│  PDFDocumentController (NSDocument)                          │
│  DocumentSession · UndoCoordinator · RecoveryStore           │
├──────────────────────────────────────────────────────────────┤
│ PDF                                                          │
│  PDFCanvasView · ThumbnailStore · OutlineController          │
│  SearchController · AnnotationController · FormController    │
├──────────────────────────────────────────────────────────────┤
│ Operations                                                   │
│  PageOperations · MergeSplit · Watermark · OCR · Redaction   │
│  Compression · Compare · FlowExecutor · PDFA                 │
├──────────────────────────────────────────────────────────────┤
│ Platform Services                                            │
│  VisionOCR · ImageIO · SecurityService · FileBookmarks       │
│  PrintService · ShareService                                 │
├──────────────────────────────────────────────────────────────┤
│ Persistence                                                  │
│  Recovery · Backups · ThumbnailCache · OCRCache · FlowStore  │
└──────────────────────────────────────────────────────────────┘
```

**Dependency rule**：上層可依賴下層；下層不可依賴 SwiftUI。Operations 只依賴 PDFKit/CoreGraphics，方便測試與未來替換引擎。

---

## 4. Module breakdown

| Module | Responsibility | Key types |
|---|---|---|
| `App` | App lifecycle, menus, windows, settings | `MacPDFApp`, `AppCoordinator` |
| `Document` | Document state, save, undo, recovery | `PDFDocumentController`, `DocumentSession` |
| `PDFCanvas` | Render, selection, tool interaction | `PDFCanvasView`, `ToolController` |
| `Sidebar` | Thumbnails, outline, search, comments | `ThumbnailStore`, `OutlineController` |
| `Inspector` | Selection properties | `InspectorModel` |
| `PageOps` | Reorder, rotate, delete, insert, extract, merge/split | `PageOperation` |
| `Annotations` | Create/edit/flatten annotations | `AnnotationController` |
| `Forms` | Fill, flatten, build fields | `FormController` |
| `OCR` | Render page, Vision request, embed text | `OCRService` |
| `Redaction` | Marks, review, apply, verify | `RedactionService` |
| `Compare` | Text/visual diff | `CompareService` |
| `Flows` | Batch step execution | `FlowExecutor`, `FlowStore` |
| `Conversion` | Images, text, PDF/A | `ExportService`, `PDFAService` |
| `Security` | Passwords, permissions, sanitize | `SecurityService` |
| `Persistence` | Recovery, caches, backups | `RecoveryStore`, `ThumbnailCache` |
| `Platform` | Bookmarks, print, share, Vision | `FileBookmarks`, `PrintService` |

---

## 5. Document model

### 5.1 NSDocument

Use `NSDocument` rather than `DocumentGroup` for:

- Autosave and versions.
- Recent documents.
- Multiple windows.
- File coordination and locking.
- Mature undo integration.

```swift
final class PDFDocumentController: NSDocument {
    private(set) var session: DocumentSession!

    override func makeWindowControllers() {
        let window = DocumentWindowController(session: session)
        addWindowController(window)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentError.unreadable(url)
        }
        session = DocumentSession(url: url, pdf: pdf)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = session.pdf.dataRepresentation() else {
            throw DocumentError.serializationFailed
        }
        return data
    }
}
```

### 5.2 DocumentSession

```swift
@MainActor
final class DocumentSession: ObservableObject {
    let id: UUID
    let originalURL: URL
    var pdf: PDFDocument
    var isDirty: Bool
    var currentPageIndex: Int
    var zoom: CGFloat
    var layout: PageLayout
    let undo: UndoCoordinator
    let recovery: RecoveryStore
    var annotations: AnnotationIndex
    var redactions: [RedactionMark]
}
```

### 5.3 Page references

PDFKit 的 `PDFPage` 沒有穩定 ID。頁面操作時用 index + 內容 hash 追蹤：

```swift
struct PageRef: Hashable {
    let index: Int
    let contentHash: String
}
```

所有 operation 回傳新的 `[PageRef]`，避免 UI 選取錯頁。

---

## 6. PDF rendering

### 6.1 PDFView

- 使用 `PDFView`，設定 `displayMode = .singlePageContinuous`、`displayDirection = .vertical`。
- `autoScales = true`，fit width/page 由 `PDFView` 控制。
- 縮圖用 `PDFPage.thumbnail(of:for:)`，背景產生。
- 大檔用 tiled rendering：只 render 可見頁 + 前後一頁。

### 6.2 Page background

- 預設白色。
- 可選「紙張色」「跟隨系統深色」。
- 深色模式下可反轉頁面（`PDFView.pageShadowsEnabled` 等）。

### 6.3 選取與 hit testing

- 文字：`PDFPage.selection(for:)`、`PDFSelection.bounds(for:)`。
- 註解：`PDFPage.annotation(at:)`。
- 圖片/物件：第一版用 annotation 包裝；進階用 PDFium/CGPDFScanner。

---

## 7. Annotations

### 7.1 Model

以 PDFKit 的 `PDFAnnotation` 為底，外層包一層 `AnnotationRef`：

```swift
struct AnnotationRef: Identifiable {
    let id: UUID
    let pageIndex: Int
    let subtype: PDFAnnotationSubtype
    let annotation: PDFAnnotation
}
```

### 7.2 Creation

| 類型 | 建立方式 |
|---|---|
| Highlight/Underline/Strikeout | `PDFSelection` → bounds → `PDFAnnotation` |
| Sticky note | 點擊位置 → `PDFAnnotation` + contents |
| Text box | `PDFAnnotation` freeText |
| Ink | `PDFAnnotation` ink with paths |
| Shape | `PDFAnnotation` square/circle/line |
| Stamp | `PDFAnnotation` stamp + image |
| Signature | 簽名點陣圖 → stamp annotation |

### 7.3 Flatten

- 逐頁建立新的 `PDFPage`：
  - 先畫原頁內容。
  - 再把 annotation 畫上去。
  - 可選保留文字（vector）或 rasterize。
- 取代原頁，刪除 annotation。
- 這個操作不可 undo（或備份整份文件後可 undo）。

---

## 8. Page operations

### 8.1 Operations

```swift
enum PageOperation {
    case move(from: IndexSet, to: Int)
    case delete(IndexSet)
    case rotate(IndexSet, degrees: Int)
    case insertBlank(at: Int, size: CGSize)
    case insertPDF(URL, pages: IndexSet, at: Int)
    case extract(IndexSet, to: URL)
    case duplicate(IndexSet)
}
```

### 8.2 Merge / split

- Merge：建立新 `PDFDocument`，依序 `insert(page, at:)`。
- Split：依 ranges 建立多個 `PDFDocument`，逐一存檔。
- Split by size：先輸出，若超過大小則降低圖片品質/重新壓縮，迭代到目標。
- Split middle：將 page bounds 切成兩半，建立兩個新頁，畫入對應區域。

### 8.3 Crop / resize

- Crop：調整 `PDFPage.bounds(for: .cropBox)`。
- Resize：建立新頁，將原頁 draw 到新 bounds；可選保持比例。

### 8.4 驗證

- 操作後頁數、頁面尺寸、rotation 必須符合預期。
- 輸出檔用 PDFKit 重新開啟；必要時用 `CGPDFDocument` 驗證。

---

## 9. Undo / redo

### 9.1 Strategy

| 操作 | Undo 方式 |
|---|---|
| 註解新增/修改 | `UndoManager` inverse operation |
| 頁面排序/刪除/插入 | 儲存操作前後的 `[PDFPage]` 參照 |
| 文字編輯 | 每次 commit 建立 snapshot |
| 塗黑 | 不 undo；套用前備份 |
| 壓縮/轉檔 | 不影響原檔；輸出檔可刪除 |

### 9.2 Snapshot

- 小型文件：整份 `PDFDocument` copy。
- 大型文件：只存受影響頁的 `PDFPage` copy + index mapping。
- 上限：50 步或 200 MB，超過就丟最舊的。

### 9.3 Undo groups

- 連續打字合併為一個 group。
- 拖曳移動合併為一個 group。
- 批次操作（例如旋轉 20 頁）為一個 group。

---

## 10. Autosave and recovery

### 10.1 Triggers

- 文件 dirty 後 30 秒。
- 每次重大操作後（page op、annotation commit、OCR apply）。
- App 進入背景/關閉前。

### 10.2 Recovery store

```
Application Support/MacPDF/Recovery/<document-uuid>/
├── manifest.json
├── snapshot.pdf
└── metadata.json
```

`manifest.json`：

```json
{
  "documentID": "UUID",
  "originalPath": "/path/to/file.pdf",
  "displayName": "contract.pdf",
  "savedAt": "2026-11-02T10:00:00Z",
  "pageCount": 24,
  "dirty": true
}
```

### 10.3 Restore flow

1. App 啟動掃描 Recovery 目錄。
2. 若 manifest 的 originalPath 仍存在且 snapshot 較新 → 提示恢復。
3. 使用者選擇「恢復」→ 開 snapshot 為未命名文件，原始檔不變。
4. 選擇「丟棄」→ 刪除 snapshot。

### 10.4 Atomic save

```swift
func atomicWrite(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    try data.write(to: temp, options: .atomic)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
}
```

---

## 11. OCR pipeline

### 11.1 Steps

1. 取得頁面（PDFPage）。
2. Render 成 `CGImage`，300 DPI（可調 200/300/400）。
3. 建立 `VNRecognizeTextRequest`：
   - `recognitionLevel = .accurate`
   - `usesLanguageCorrection = true`
   - `recognitionLanguages = ["zh-Hant", "en-US"]`
4. 取得 `VNRecognizedTextObservation`。
5. 將 normalized bounding box 轉成 PDF 座標。
6. 建立新頁或 overlay：
   - 原頁 draw 到 `CGPDFContext`。
   - 用 `CGContext.setTextDrawingMode(.invisible)` 畫文字。
   - 設定字型大小讓文字覆蓋 bounding box。
7. 儲存新頁，替換原頁。

### 11.2 Text layer

```swift
context.beginPDFPage(nil)
page.draw(with: .mediaBox, to: context)
context.setTextDrawingMode(.invisible)
for line in observations {
    let text = line.topCandidates(1).first?.string ?? ""
    context.setFont(...)
    context.showText(at: point, text: text)
}
context.endPDFPage()
```

**注意**：隱形文字仍可被萃取，這是 OCR 的目的；塗黑時要一併移除。

### 11.3 Cache

- Key：`sha256(page content + language + dpi)`。
- Value：observations JSON。
- 位置：`Application Support/MacPDF/OCRCache/`。
- 失效：頁面內容變更、語言變更。

### 11.4 Failure handling

- 單頁失敗不中斷整份；記錄頁碼與錯誤。
- 低信心頁面標記，讓使用者檢查。
- 取消時刪除未完成的頁面與暫存。

---

## 12. Redaction pipeline

### 12.1 v1 — Rasterize（M3）

**流程**

1. 收集 `RedactionMark`（page, rect, style）。
2. 對每頁：
   - 以 300 DPI render 成 bitmap。
   - 在 mark 位置填黑（或自訂顏色/馬賽克）。
   - 建立新 `PDFPage`，只含 bitmap。
   - 刪除原頁所有 annotation、link、form field。
3. 清理 document metadata、attachments、outline 指向。
4. 另存新檔。
5. 驗證：`PDFPage.string` 在 mark 區域為空。

**優點**：保證看不到、實作簡單。  
**缺點**：失去文字/向量、檔案變大、不能搜尋。

### 12.2 v2 — Content stream（M4）

- 用 `CGPDFScanner` 或自建 parser 掃 content stream。
- 找出與 mark 相交的：
  - `Tj` / `TJ` / `'` / `"` 文字繪製。
  - `Do` 圖片 XObject。
  - 路徑填色/描邊（可選）。
- 移除或替換這些指令。
- 重建頁面 content stream。
- 保留其他文字與向量。

**難點**：文字位置需要追蹤 text matrix、font size、CTM；圖片需要解析 XObject；表單/註解要另外處理。

### 12.3 v3 — PDFium（M4+）

- 用 PDFium 的 page object API 直接移除物件。
- 需要自編 XCFramework、處理記憶體與執行緒。
- 只在 v2 不足時評估。

### 12.4 Verification

```swift
func verifyRedaction(page: PDFPage, marks: [RedactionMark]) -> Bool {
    guard let text = page.string else { return true }
    for mark in marks {
        if textIntersects(text, rect: mark.rect, page: page) {
            return false
        }
    }
    return true
}
```

若驗證失敗：

- 不覆寫原檔。
- 顯示警告與頁碼。
- 建議改用 rasterize 或手動檢查。

### 12.5 Sanitization

- 移除 metadata：Author、Title、Subject、Keywords、Creator、Producer。
- 移除 XMP。
- 移除 attachments、embedded files。
- 移除 JavaScript actions。
- 移除 hidden layers / optional content。
- 移除註解、表單欄位（可選）。
- 移除書籤/outline 指向被刪頁面。

---

## 13. Conversion

### 13.1 PDF → images

- `PDFPage.thumbnail(of:for:)` 或 `CGPDFPage` draw。
- 格式：PNG、JPEG、TIFF。
- DPI：72/150/300/600。
- 頁面範圍、命名規則。

### 13.2 Images → PDF

- 建立 `PDFDocument`，每張圖一頁。
- 頁面尺寸：fit image / A4 / Letter / custom。
- 可選 OCR 文字層。

### 13.3 PDF → text / RTF

- `PDFPage.string`，依頁面順序。
- 段落重建：用行距/字型/位置 heuristic。
- RTF：基本段落、粗體/斜體（若可判斷）。

### 13.4 PDF → DOCX / XLSX（M4）

- 不建議自建完整 converter。
- 選項：
  1. 商業 SDK（PDFTron/Apryse、Adobe PDF Services）。
  2. LibreOffice headless（需安裝，非沙盒友善）。
  3. 自建 limited converter（文字 + 簡單表格）。
- 決策點：M3 結束前評估品質/成本。

### 13.5 PDF/A

- 嵌入 sRGB ICC profile。
- 嵌入所有字型（或子集）。
- 移除 JavaScript、attachments、encryption。
- 寫入 XMP metadata。
- 驗證：用 PDF/A validator 或 `CGPDFDocument` 檢查。

### 13.6 Compression

- 影像重新取樣：`CGImageSourceCreateThumbnailAtIndex` + JPEG。
- 品質預設：screen 72 DPI/50%、ebook 150 DPI/65%、print 300 DPI/80%。
- 移除重複資源（M4）。
- 比較前後大小與畫質。

---

## 14. Compare

### 14.1 Text diff

1. 逐頁 `PDFPage.string`。
2. 正規化：空白、換行、連字號。
3. 頁面配對：頁面大小 + 文字相似度（Jaccard / cosine）。
4. 段落 diff：`CollectionDifference` 或 Myers。
5. 將 diff 映射回頁面座標（用 `PDFSelection` 找字）。

### 14.2 Visual diff

1. 兩頁 render 成同尺寸 bitmap（150 DPI）。
2. 像素差異 → threshold → 連通區域。
3. 標框、計算差異百分比。
4. 忽略抗鋸齒/壓縮雜訊（blur + threshold）。

### 14.3 UI

- 左右並排、同步捲動。
- 差異列表：頁碼、類型、摘要。
- 上一筆/下一筆。
- 匯出報告（PDF/HTML）。

---

## 15. Flows

### 15.1 Model

```swift
struct Flow: Codable, Identifiable {
    let id: UUID
    var name: String
    var steps: [FlowStep]
    var input: FlowInput
    var output: FlowOutput
    var createdAt: Date
    var lastRun: FlowRun?
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

### 15.2 Executor

```swift
actor FlowExecutor {
    func run(_ flow: Flow, progress: @Sendable (FlowProgress) -> Void) async throws -> FlowReport
}
```

- 逐檔處理；每個 step 回報進度。
- 錯誤策略：stop / skip / retry。
- 輸出命名：`{name}-{index}-{date}`。
- 不覆寫輸入檔；輸出到指定資料夾。
- 可取消；取消後保留已完成檔案。

### 15.3 Limits

- 單次最多 500 個檔案（可設定）。
- 單檔最大 2 GB（可設定）。
- 並行度：1（預設）或 2（I/O 密集）。
- 進度節流：每 100 ms 更新 UI。

---

## 16. Security and encryption

- 開啟加密 PDF：`PDFDocument` 的 `isLocked` / `unlock(withPassword:)`。
- 加入密碼：PDFKit 不直接支援寫入加密；需用 CoreGraphics 或 PDFium。
  - v1 先支援「移除密碼」（有權限時）。
  - 加入密碼列 M2，必要時用 `CGPDFContext` + PDF encryption dictionary（較複雜）。
- 權限：PDFKit 可讀取 `PDFDocument.accessPermissions`；寫入需自建。
- 不執行 PDF JavaScript。
- 匯入時偵測 JavaScript、附件、XFA，提示使用者。

---

## 17. Sandbox and file access

### 17.1 Entitlements

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.print</key><true/>
```

- 不加 `network.client`（除非未來做更新檢查）。
- 最近文件用 security-scoped bookmarks。
- 拖放檔案用 `NSOpenPanel` / `NSPasteboard`。

### 17.2 File coordination

- 使用 `NSFileCoordinator` 讀寫，避免與其他 App 衝突。
- 檔案被外部修改 → 提示重新載入。
- 檔案鎖定 → 唯讀模式。

### 17.3 Temp files

- 一律放在 `FileManager.default.temporaryDirectory` 的子目錄。
- 離開 App 時清理；崩潰後下次啟動清理超過 24 小時的暫存。

---

## 18. Concurrency

- UI 全部 `@MainActor`。
- PDF 操作在背景 `Task` / `actor`，完成後回主執行緒更新。
- OCR/壓縮/比對用 `TaskGroup` 控制並行度。
- `DocumentSession` 是 `@MainActor`；背景工作只拿 immutable snapshot。
- 取消：`Task.checkCancellation()`；OCR/Flow 需支援。

```swift
@MainActor
func runOCR(pages: [Int]) {
    let snapshot = session.pdf.copy() as! PDFDocument
    Task.detached(priority: .userInitiated) {
        let result = try await OCRService.recognize(snapshot, pages: pages)
        await MainActor.run { self.applyOCR(result) }
    }
}
```

---

## 19. Performance and memory

### 19.1 Budgets

| 項目 | 目標 |
|---|---|
| App 啟動 | < 1 秒 |
| 開 100 MB PDF | < 5 秒 |
| 第一頁可見 | < 1 秒 |
| 縮圖 | < 200 ms/頁 |
| 捲動 | 60 fps |
| OCR | 1–3 秒/頁 |
| 壓縮 100 頁 | < 60 秒 |
| 記憶體 500 頁 | < 1.5 GB |

### 19.2 Techniques

- Tiled rendering：只畫可見區域。
- 頁面快取：NSCache，上限 256 MB。
- 縮圖快取：磁碟 + 記憶體。
- 影像 downsampling：`CGImageSourceCreateThumbnailAtIndex`。
- 自動釋放：記憶體壓力通知時清快取。
- 大檔模式：只載入目前頁 + 前後一頁。

### 19.3 Instruments

- Time Profiler：開啟/捲動/OCR。
- Allocations/Leaks：長時間操作。
- Energy Log：批次處理。

---

## 20. Error handling and logging

### 20.1 Error types

```swift
enum DocumentError: LocalizedError {
    case unreadable(URL)
    case locked
    case wrongPassword
    case serializationFailed
    case saveFailed(underlying: Error)
    case redactionVerificationFailed(pages: [Int])
    case ocrFailed(page: Int, underlying: Error)
}
```

### 20.2 Logging

- 使用 `os.Logger`，subsystem `com.example.macpdf`。
- 分類：document、pdf、ocr、redaction、flows、ui。
- 預設不記錄文件名稱/內容；只記 ID 與錯誤碼。
- 日誌只在本機；不上傳。
- 使用者可在 Settings → About → 匯出診斷（去識別化）。

### 20.3 Crash handling

- 不吞例外；`fatalError` 只用在不可能狀態。
- 崩潰後由 RecoveryStore 恢復。
- 可選整合 crash reporter（預設關閉）。

---

## 21. Storage layout

```
~/Library/Application Support/MacPDF/
├── Recovery/<document-uuid>/
│   ├── manifest.json
│   ├── snapshot.pdf
│   └── metadata.json
├── Backups/<timestamp>-<name>.pdf
├── Thumbnails/<content-hash>/
├── OCRCache/<content-hash>.json
├── Flows/<uuid>.json
├── Logs/ (optional)
└── Settings.plist (or UserDefaults)
```

- 所有路徑用 `FileManager.url(for: .applicationSupportDirectory, ...)`。
- 沙盒下會自動導向 Container。
- 快取可清除；Backups 預設保留 30 天。

---

## 22. Internal APIs

### 22.1 PDF operations

```swift
protocol PDFOperation {
    associatedtype Output
    func apply(to document: PDFDocument) throws -> Output
}
```

### 22.2 OCR

```swift
protocol OCRProviding {
    func recognize(page: PDFPage, languages: [String], dpi: CGFloat) async throws -> OCRObservations
}
```

### 22.3 Redaction

```swift
protocol RedactionApplying {
    func apply(marks: [RedactionMark], to document: PDFDocument, mode: RedactionMode) async throws -> RedactionResult
}

struct RedactionResult {
    let output: PDFDocument
    let pagesChanged: [Int]
    let verification: RedactionVerification
}
```

### 22.4 Compare

```swift
protocol CompareProviding {
    func compare(old: PDFDocument, new: PDFDocument, options: CompareOptions) async throws -> CompareResult
}
```

### 22.5 Flows

```swift
protocol FlowStepExecuting {
    var kind: FlowStepKind { get }
    func execute(input: URL, context: FlowContext) async throws -> FlowStepOutput
}
```

---

## 23. Dependency policy

- 第一版：**零第三方 runtime 依賴**。
- 允許：Apple frameworks（PDFKit、Vision、CoreGraphics、ImageIO、UniformTypeIdentifiers）。
- 禁止：會上傳資料的 SDK、廣告 SDK、分析 SDK、JavaScript runtime。
- 未來可評估：
  - PDFium（BSD）— content stream 編輯/真塗黑。
  - Sparkle（MIT）— 官網直裝自動更新。
  - 商業 PDF SDK — Office 轉檔/簽章。
- 每個依賴需記錄：授權、大小、維護狀態、安全紀錄。

---

## 24. Build and release

### 24.1 Project generation

```
project.yml
sources:
  - path: Sources
resources:
  - path: Resources
settings:
  base:
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    PRODUCT_BUNDLE_IDENTIFIER: com.example.macpdf
    SWIFT_VERSION: "6.0"
    CODE_SIGN_STYLE: Automatic
```

- `xcodegen generate` 產生 `.xcodeproj`。
- `.xcodeproj` 不進版控（或進版控但標記 generated）。
- Schemes：`MacPDF`, `MacPDFTests`, `MacPDFUITests`.

### 24.2 Signing

- 內部使用：ad-hoc 或 Development certificate。
- 對外：Developer ID Application + notarization + stapling。
- Hardened runtime 開啟。
- 最小權限 entitlements。

### 24.3 Release checklist

- [ ] 版本號/ build number。
- [ ] 單元/UI/效能測試通過。
- [ ] 塗黑驗證測試通過。
- [ ] 相容性測試（Preview/Acrobat/Chrome）。
- [ ] 離線測試。
- [ ] 隱私檢查（無網路請求）。
- [ ] 簽章/公證（若對外）。
- [ ] Release notes。

---

## 25. Testing hooks

- `MacPDFTests`：operations、redaction、OCR mock、compare。
- `MacPDFUITests`：開檔、註解、合併、塗黑流程。
- `Fixtures/`：見 [06-test-plan.md](06-test-plan.md)。
- 效能測試用 `XCTMetric` + 固定 fixture。
- 若需要，加入 `--ui-testing` 參數停用動畫/對話框。

---

## 26. Open technical questions

1. PDFKit 能否穩定寫入加密 PDF？若不行，是否導入 PDFium 或 CoreGraphics？
2. `CGPDFScanner` 解析 content stream 的覆蓋率足夠嗎？需要自建 parser 嗎？
3. Vision OCR 對繁中/混合語言的準確度？是否需要 Tesseract fallback？
4. 大型表格 PDF → XLSX 的品質能否接受？要不要買 SDK？
5. 500 頁以上的 tiled rendering 在 PDFKit 的極限？
6. `NSDocument` 與 SwiftUI 的整合細節（toolbar、commands、window restoration）。
7. 塗黑 v1 rasterize 的檔案大小增加幅度？是否需要 JPEG/JPEG2000 壓縮？
8. 是否需要在沙盒外執行（內部工具）以簡化檔案存取？

---

## 27. Proposed repository structure

```
MacPDF/
├── README.md
├── docs/
│   ├── 01-product-brief.md
│   ├── 02-prd.md
│   ├── 03-ux-spec.md
│   ├── 04-technical-design.md
│   ├── 05-security-privacy.md
│   ├── 06-test-plan.md
│   ├── 07-roadmap.md
│   ├── 08-revpdf-audit.md
│   └── 09-decisions.md
├── project.yml                 # xcodegen
├── Sources/
│   ├── App/                    # lifecycle, menus, windows, settings
│   ├── Document/               # NSDocument, session, undo, recovery
│   ├── PDFCanvas/              # PDFView wrapper, tools, selection
│   ├── Sidebar/                # thumbnails, outline, search, comments
│   ├── Inspector/              # selection properties
│   ├── Operations/             # page ops, OCR, redaction, compare, flows
│   ├── Services/               # Vision, printing, sharing, bookmarks
│   ├── Persistence/            # caches, backups, stores
│   └── Shared/                 # types, extensions, design system
├── Resources/
│   ├── Assets.xcassets
│   ├── Localizable.xcstrings
│   └── Info.plist
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── UI/
├── Fixtures/                   # small, de-identified test PDFs
└── Scripts/
    ├── generate.sh             # xcodegen
    ├── test.sh
    └── lint.sh
```

- `Sources` 以 feature 分資料夾，不以技術型別分（避免 `Views/`, `Models/` 大雜燴）。
- `Operations` 不 import SwiftUI；可在測試中單獨執行。
- `Fixtures` 只放小型、去識別化檔案；大檔用下載腳本。

---

## 28. Coding conventions

- **Swift 6 strict concurrency**：UI `@MainActor`；背景工作 `actor`/`Task`。
- **No force unwrap**：除了測試與不可能的初始化；用 `guard`/`throw`。
- **Typed errors**：`LocalizedError`，錯誤訊息含下一步。
- **One type per file**：大型型別可拆 extension。
- **Naming**：程式碼用英文；UI 字串用 String Catalog。
- **No third-party runtime dependency** without a decision record.
- **Tests first for operations**：page ops、redaction、OCR parsing、compare。
- **Docs同步**：架構/範圍變更時更新 `09-decisions.md`。
- **Commit style**：`feat:`, `fix:`, `docs:`, `test:`, `refactor:`。
- **Branching**：trunk-based，短分支；PR 需描述變更與測試。
- **Issue labels**：`feature`, `bug`, `decision`, `ux`, `security`, `performance`.

---

## 29. References

- Apple PDFKit: <https://developer.apple.com/documentation/pdfkit>
- Apple Vision: <https://developer.apple.com/documentation/vision>
- Apple Core Graphics PDF: <https://developer.apple.com/documentation/coregraphics/cgpdfcontext>
- PDF 1.7 spec (ISO 32000-1): <https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf>
- PDF/A: <https://www.pdfa.org/>
- PDFium: <https://pdfium.googlesource.com/pdfium/>
- xcodegen: <https://github.com/yonaskolb/XcodeGen>
