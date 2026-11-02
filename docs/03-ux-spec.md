# 03 · UX Specification

| 項目 | 內容 |
|---|---|
| 產品 | MacPDF |
| 版本 | 0.2（Planning） |
| 日期 | 2026-11-02 |
| 範圍 | M0–M3 的資訊架構、畫面、互動、狀態與文案 |
| 設計原則 | Native、document-first、keyboard-first、non-destructive |

---

## 1. Design principles

1. **Document first**：打開 App 直接看到文件，不先過首頁廣告或登入。
2. **One window, one job**：主要工作在同一個文件視窗完成，工具用 sidebar / inspector 展開。
3. **Tools are verbs**：工具名稱用動詞（合併、分割、塗黑），不用抽象名詞。
4. **Destructive actions are explicit**：塗黑、覆寫、壓縮前一定要說明後果。
5. **No hidden state**：目前工具、選取頁面、是否已儲存，永遠看得見。
6. **Keyboard is a first-class input**：所有常用動作有快捷鍵；Tab 鍵順序合理。
7. **Native feel**：SF Symbols、toolbar、sidebar、inspector、context menu、drag & drop。
8. **Calm visual design**：中性背景、單一強調色、PDF 內容是主角。

---

## 2. Information architecture

```
App
├── Welcome / Recents
├── Document Window
│   ├── Toolbar
│   ├── Left Sidebar
│   │   ├── Thumbnails
│   │   ├── Outline / Bookmarks
│   │   ├── Search
│   │   └── Comments
│   ├── PDF Canvas
│   └── Right Inspector
│       ├── Selection
│       ├── Page
│       └── Document
├── Tools Hub
│   ├── Edit
│   ├── Organize
│   ├── Convert
│   ├── Protect
│   └── Automate
├── Organize Pages
├── Redaction Setup / Review
├── OCR Progress
├── Compare
├── Flows
│   ├── List
│   ├── Builder
│   └── Run
└── Settings
```

---

## 3. Window layout

### 3.1 Document window

```
┌─────────────────────────────────────────────────────────────────────┐
│ ● ● ●   [< >]  contract.pdf   [Saved]        [Share] [Print] [···]  │
├─────────────────────────────────────────────────────────────────────┤
│ [Select] [Highlight] [Text] [Ink] [Shape] [Sign] [Stamp]   [100%]  │
├──────────────┬──────────────────────────────────────┬───────────────┤
│ Thumbnails   │                                      │ Inspector     │
│ ┌──────────┐ │                                      │               │
│ │ 1        │ │              PDF page                │ Annotation    │
│ └──────────┘ │                                      │ Color  █      │
│ ┌──────────┐ │                                      │ Opacity ──●   │
│ │ 2        │ │                                      │ Author  You   │
│ └──────────┘ │                                      │               │
│              │                                      │ [Delete]      │
├──────────────┴──────────────────────────────────────┴───────────────┤
│ Page 3 of 24 · 8.5 × 11 in · 100%                          [Fit]    │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Sidebar tabs

| Tab | Icon | Content |
|---|---|---|
| Thumbnails | `rectangle.grid.1x2` | Page thumbnails, drag to reorder |
| Outline | `list.bullet.indent` | PDF outline + user bookmarks |
| Search | `magnifyingglass` | Query, results, next/prev |
| Comments | `text.bubble` | Annotation list, filter, jump |

### 3.3 Inspector

- **Nothing selected**：document info, page count, file size, PDF version.
- **Page selected**：size, rotation, crop, page label.
- **Annotation selected**：type, color, opacity, line width, author, contents, delete.
- **Image/text box selected**：position, size, rotation, opacity, z-order.
- **Form field selected**：name, type, value, required, font, border.

---

## 4. Screen specifications

### 4.1 Welcome / Recents

**Purpose**：快速回到最近文件，或開始新工作。

**Layout**

- 左側：產品名稱、版本、簡短說明。
- 右側：最近文件清單（縮圖、檔名、路徑、最後開啟時間）。
- 底部：開啟檔案、從圖片建立 PDF、說明文件。

**States**

| 狀態 | 畫面 |
|---|---|
| 首次開啟 | 引導卡片：語言、主題、設為預設 PDF App |
| 沒有最近文件 | 空狀態 + 「開啟 PDF」按鈕 + 拖放提示 |
| 檔案不存在 | 灰色項目 + 「找不到檔案」+ 移除紀錄 |
| 載入中 | 骨架縮圖 |

**Actions**

- 雙擊最近文件 → 開新視窗。
- 右鍵 → 在 Finder 顯示、從最近移除、清除全部。
- 拖放 PDF 到視窗 → 開啟。

---

### 4.2 Document window

**Toolbar**

| 區域 | 控件 |
|---|---|
| 左 | 返回/前進、sidebar toggle |
| 中 | 檔名、儲存狀態、頁碼 |
| 右 | 搜尋、分享、列印、更多 |

**Tool modes**

| 模式 | 行為 |
|---|---|
| Select | 選取文字、圖片、註解、表單 |
| Highlight | 拖曳選取文字 → 建立螢光筆 |
| Text | 點擊頁面 → 插入文字方塊 |
| Ink | 自由繪圖 |
| Shape | 矩形、橢圓、線、箭頭 |
| Sign | 放置簽名 |
| Stamp | 放置印章 |
| Redact | 畫塗黑框 |
| Form | 建立/編輯表單欄位 |

**Status bar**

- 目前頁碼 / 總頁數
- 頁面尺寸
- 縮放百分比
- 目前工具提示
- 背景工作進度（OCR、壓縮）

**Save states**

| 狀態 | 顯示 |
|---|---|
| Clean | `Saved` |
| Dirty | `Edited` + 圓點 |
| Saving | spinner + `Saving…` |
| Error | 紅色 `Save failed` + 詳細資訊 |

---

### 4.3 Tools hub

**Purpose**：把 20+ 個工具分類，避免 toolbar 爆炸。

**Layout**

- 頂部：搜尋框（`toolsSearchHint`）。
- 分類：Edit、Organize、Convert、Protect、Automate。
- 每個工具：圖示、名稱、一句說明、快捷鍵（若有）。

**Tools**

| 分類 | 工具 |
|---|---|
| Edit | 註解、文字方塊、圖片、簽名、表單建立、尋找取代 |
| Organize | 合併、分割、中間分割、頁面整理、裁切、頁碼/Bates |
| Convert | PDF→圖片、PDF→Word、PDF→Excel、PDF/A、OCR、壓縮、擷取圖片 |
| Protect | 密碼、權限、塗黑、中繼資料、Flatten |
| Automate | Flows、批次處理、Quick Action |

**Empty state**：搜尋無結果 → `toolsNoneFound` + 清除搜尋。

---

### 4.4 Organize pages

**Layout**

- 縮圖格（可調大小）。
- 多選：Shift 連選、Command 加選、拖曳框選。
- 工具列：旋轉、刪除、複製、插入、擷取、移動到…、儲存。
- 右側：頁面資訊（尺寸、旋轉、標籤）。

**Interactions**

- 拖曳縮圖 → 排序；拖到文件之間 → 插入。
- 雙擊 → 回到文件視窗該頁。
- Delete → 刪除選取頁（可 undo）。
- 右鍵 → 旋轉、複製、刪除、插入空白頁、插入 PDF。

**Validation**

- 至少保留一頁；刪除最後一頁時顯示 `organizeLastPageGuard`。
- 加密 PDF 需先解鎖：`organizePasswordRequired`。

---

### 4.5 Annotation mode

**Toolbar**

- 螢光筆、底線、刪除線、波浪線、便條、文字、手繪、形狀、印章、簽名。
- 顏色、粗細、透明度。

**Behaviors**

- 選取文字後點螢光筆 → 直接套用。
- 便條紙 → 點頁面放置，彈出輸入框。
- 文字方塊 → 點擊後輸入；雙擊編輯；拖曳移動；角落縮放。
- 手繪 → 放開滑鼠結束一筆；可 undo。
- 註解列表 → 點擊跳轉；右鍵刪除。

**Inspector**

- Type、Color、Opacity、Line width、Author、Contents、Created/Modified。
- `Delete` 按鈕。

---

### 4.6 Form mode

**Fill mode**

- 自動 highlight 可填欄位。
- Tab 到下一個欄位；Shift-Tab 上一個。
- 必填欄位未填 → 儲存時提示。
- 簽名欄位 → 點擊後開簽名對話框。

**Builder mode**

- 工具列：文字欄位、核取方塊、单选钮、下拉、簽名、日期。
- 拖曳建立；Inspector 編輯屬性。
- 對齊、分佈、複製。
- 預覽模式：切換到填寫，檢查 Tab 順序。

**Flatten**

- 顯示警告：`Flatten 後欄位不可編輯`。
- 可選「保留文字」或「rasterize」。

---

### 4.7 Redaction setup / review

**Step 1 — Setup**

- 模式：手動畫框、關鍵字、PII 預設、自訂 regex。
- PII 類別：信用卡、Email、電話、SSN、IBAN、IP、生日、郵遞區號。
- 選項：包含 OCR 文字、只在指定頁、標記樣式（黑框/馬賽克/文字）。

**Step 2 — Scan / Review**

- 左側：頁面縮圖，有標記的頁面顯示紅點。
- 中央：PDF 頁面 + 半透明紅框。
- 右側：標記清單（頁碼、類型、文字、來源）。
- 工具列：上一頁/下一頁、刪除標記、全部接受、取消。

**Step 3 — Apply**

- 確認對話框：
  - 「這會永久移除 N 頁、M 個區域的文字與圖片。」
  - 「原始檔不會被修改；會另存新檔。」
  - 「塗黑後無法復原。」
- 按鈕：`Cancel` / `Apply and Save…`。

**Step 4 — Verify**

- 進度：套用、清理、驗證。
- 結果：
  - 成功：`N 頁、M 個區域已移除；驗證通過。`
  - 警告：`第 X 頁可能還有文字，請手動檢查。`
  - 失敗：保留原始檔，顯示錯誤。

**Empty state**：沒有找到符合項目 → `redactNoMatchesTitle` + 調整關鍵字/類別。

---

### 4.8 OCR progress

**Setup**

- 頁面範圍：全部、目前頁、指定頁碼。
- 語言：繁中、英文、日文、韓文（依 Vision 支援）。
- 選項：嵌入隱形文字、顯示文字層、跳過已有文字頁。

**Progress**

- 總頁數、已完成、目前頁、預估剩餘時間。
- Cancel 按鈕；取消後清掉暫存。

**Result**

- 成功頁數、失敗頁數、低信心頁數。
- 「前往第一頁」/「儲存」。

---

### 4.9 Compare

**Setup**

- 舊檔、新檔（可拖放）。
- 模式：文字、視覺、兩者。
- 選項：忽略空白、忽略格式、頁面配對。

**Results**

- 左：舊版；右：新版；同步捲動。
- 差異 highlight：新增綠色、刪除紅色、修改黃色。
- 右側：變更清單（頁碼、類型、摘要）。
- 工具列：上一筆/下一筆、縮放、匯出報告。

**Empty state**：兩份文件相同 → `沒有差異`。

---

### 4.10 Flows

**List**

- 卡片：名稱、步驟數、最後執行時間、上次結果。
- 按鈕：New Flow、Duplicate、Delete。
- 空狀態：`建立第一個流程`。

**Builder**

- 左：步驟庫（Compress、OCR、Watermark、Stamp、Rotate、Split、Redact、Find & Replace、Export Images、Flatten）。
- 中：步驟序列，可拖曳排序、停用、刪除。
- 右：選中步驟的選項。
- 底部：輸入、輸出、執行。

**Run**

- 檔案清單、每檔進度、成功/失敗/略過。
- Cancel、Retry failed。
- 完成後：開啟輸出資料夾、匯出報告。

---

### 4.11 Settings

| Section | Items |
|---|---|
| General | Language, theme, default zoom, default app |
| Editing | Autosave interval, undo limit, annotation author |
| OCR | Default languages, DPI, skip text pages |
| Redaction | PII presets, custom regex, default style |
| Performance | Large-file mode, cache size, clear cache |
| Shortcuts | Keyboard shortcut editor |
| About | Version, licenses, privacy |

---

### 4.12 Onboarding

**第一啟動**

1. 歡迎 + 一句話說明 local-first。
2. 語言選擇（繁中/英文）。
3. 主題（跟隨系統/淺色/深色）。
4. 設為預設 PDF App（可跳過）。
5. 快速導覽：開啟、註解、整理、塗黑。

**原則**：不超過 4 步；可全部跳過；不要求登入。

---

## 5. Interaction patterns

### 5.1 Selection

- 單擊：選取物件/文字。
- 雙擊：進入文字編輯/註解編輯。
- Shift + 單擊：加選。
- 拖曳空白處：框選。
- Esc：取消選取/退出工具。
- Command+A：全選目前範圍（文字或頁面）。

### 5.2 Drag & drop

- 拖 PDF 到視窗 → 開啟。
- 拖圖片到頁面 → 插入圖片。
- 拖頁面縮圖 → 排序。
- 拖檔案到 Flows → 加入輸入。
- 拖選取文字到另一個 App → 複製。

### 5.3 Context menus

- 頁面：旋轉、刪除、複製、插入、擷取、另存。
- 註解：編輯、刪除、回覆（P3）、複製。
- 文字：複製、尋找、加註解。
- 圖片：複製、另存、取代、刪除。

### 5.4 Undo / redo

- `⌘Z` / `⇧⌘Z`。
- 每個操作是一個 undo group；連續打字合併。
- 塗黑套用後不可 undo（明確警告）。
- 關閉文件前若有未儲存變更 → 提示。

### 5.5 Save

- `⌘S`：儲存；若原檔是別人的/唯讀 → Save As。
- `⇧⌘S`：Save As。
- `⌥⌘S`：Save a Copy。
- 覆寫前 → 備份到 `Backups/`。
- 自動恢復 → 不取代手動儲存。

---

## 6. Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open | `⌘O` |
| Save | `⌘S` |
| Save As | `⇧⌘S` |
| Close | `⌘W` |
| Print | `⌘P` |
| Undo / Redo | `⌘Z` / `⇧⌘Z` |
| Find | `⌘F` |
| Find next / prev | `⌘G` / `⇧⌘G` |
| Zoom in / out | `⌘+` / `⌘-` |
| Actual size | `⌘0` |
| Fit page | `⌘9` |
| Next / prev page | `⌘↓` / `⌘↑` |
| Next / prev tab | `⌃Tab` / `⌃⇧Tab` |
| Toggle sidebar | `⌘⌥1` |
| Toggle inspector | `⌘⌥2` |
| Select tool | `V` |
| Highlight | `H` |
| Text box | `T` |
| Ink | `D` |
| Redact | `R` |
| Form | `F` |
| Escape | `Esc` |

（完整清單見 Settings → Keyboard Shortcuts。）

---

## 7. States & feedback

### 7.1 Empty states

| 畫面 | 文案 |
|---|---|
| 最近文件 | `還沒有最近開啟的文件` + `開啟 PDF` |
| 搜尋 | `找不到「{query}」` + `清除搜尋` |
| 註解 | `這一頁還沒有註解` |
| 書籤 | `還沒有書籤` + `將目前頁加入書籤` |
| 塗黑 | `沒有找到符合的內容` + `調整關鍵字或類別` |
| Flows | `建立第一個流程` |
| Compare | `兩份文件沒有差異` |

### 7.2 Loading states

- 縮圖：灰色骨架 + shimmer（可關閉）。
- OCR：進度條 + 目前頁 + Cancel。
- 壓縮：進度條 + 預估大小。
- 大檔：`正在載入第 X 頁…`，不凍結 UI。

### 7.3 Error states

| 錯誤 | 訊息 | 動作 |
|---|---|---|
| 檔案損壞 | `無法開啟這個 PDF，檔案可能已損壞。` | 顯示詳細資料、回報 |
| 密碼錯誤 | `密碼不正確。` | 重試 |
| 磁碟已滿 | `無法儲存，磁碟空間不足。` | 另存位置 |
| 權限不足 | `沒有權限寫入這個資料夾。` | 選擇其他位置 |
| 塗黑驗證失敗 | `第 X 頁可能還有文字，已保留原始檔。` | 查看、重試 |
| OCR 失敗 | `第 X 頁無法辨識。` | 跳過/重試 |
| 轉檔失敗 | `轉檔失敗，原始檔未變更。` | 查看日誌 |

### 7.4 Confirmation dialogs

- 覆寫原檔：`確定要覆寫 original.pdf？我們會先建立備份。`
- 塗黑：`這會永久移除內容，無法復原。`
- 刪除大量頁面：`確定刪除 N 頁？`
- 關閉未儲存：`要儲存變更嗎？`

---

## 8. Visual design

### 8.1 Style

- 原生 macOS：toolbar、sidebar、inspector、segmented controls、popovers。
- 背景：`NSColor.windowBackgroundColor`；PDF 頁面白色/紙張色。
- 強調色：系統 accent color，預設藍色；可在 Settings 改。
- 圖示：SF Symbols，保持一致粗細。
- 字型：SF Pro；PDF 內容用文件自身字型。
- 圓角：8–12 pt；避免過度圓潤。
- 陰影：只用在浮層/選取，不用在每個卡片。

### 8.2 Dark mode

- PDF 頁面保持白色（可選「反轉頁面」）。
- Sidebar/inspector 跟隨系統。
- 註解顏色在深色背景仍可辨識。

### 8.3 Density

- 預設「舒適」；可切「緊湊」。
- 縮圖大小可調（小/中/大）。
- Inspector 可收合。

### 8.4 Motion

- 尊重「減少動態」。
- 頁面切換、sidebar 展開用短動畫（150–200 ms）。
- 不用彈跳、不用粒子。

---

## 9. Accessibility

- 所有按鈕有 `accessibilityLabel`；圖示按鈕必須有。
- 完整鍵盤導覽；Tab 順序 logical。
- VoiceOver 可讀出頁碼、選取狀態、註解內容。
- 顏色不是唯一資訊：錯誤/差異同時用圖示/文字。
- 支援「增加對比」與「減少透明度」。
- 最小點擊區域 24×24 pt。
- 動態字型：設定/對話框支援文字縮放。

---

## 10. Localization

- 第一版：繁體中文（主）、英文。
- 所有字串用 `String(localized:)` / String Catalog。
- 日期、數字、檔案大小跟隨 Locale。
- 不要用字串拼接重組句子；用格式化參數。
- 專有名詞保留英文：PDF、OCR、PDF/A、Bates。
- 簡體中文、日文、韓文列後續。

---

## 11. Copy guidelines

- 用主動語態：「刪除 3 頁」不是「頁面將被刪除」。
- 錯誤訊息要說「發生什麼 + 下一步」。
- 不要在錯誤訊息責怪使用者。
- 破壞性操作要說結果，不是只問「確定嗎？」。
- 按鈕用動詞：「塗黑並儲存」「保留原檔」。
- 避免「Oops」「Uh oh」這類語氣。

---

## 12. UX acceptance checklist

- [ ] 從開啟到完成一次註解，最多 4 個步驟。
- [ ] 合併 3 份 PDF 不需要開第二個視窗。
- [ ] 塗黑流程有審閱、確認、驗證三個階段。
- [ ] 所有破壞性操作都有 undo 或備份。
- [ ] 沒有滑鼠也能完成開檔、註解、儲存。
- [ ] 關閉未儲存文件一定會提示。
- [ ] 空狀態都有下一步行動。
- [ ] 錯誤訊息都包含解法。
- [ ] 深色模式下 PDF 與註解都可讀。
- [ ] 繁中 UI 沒有英文殘留（專有名詞除外）。
