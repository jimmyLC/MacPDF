# 11 · Implementation plan and status

This plan supersedes milestone scope where the older planning documents differ.

- M0: PDF viewing, navigation, thumbnails, outline, search, password prompt and recent documents.
- M1: page organization, basic annotations, undo/redo, explicit Save a Copy, printing and recovery.
- M2: image import, OCR, AcroForm filling/flattening and basic compression, subject to fixture-based validation.
- M3: manual redaction, review and safe output, gated on independent security tests. Search/OCR only finds candidates and cannot guarantee all sensitive information is found.
- M4: comparison and batch workflows after individual operations are reliable.
- PDF/A, text editing, Office export and certificate signatures require separate feasibility decisions.

## M1 implementation and limitations

The app supports multiple document windows; reading, searching, zooming and navigation; moving, rotating and deleting the current page; appending another PDF; extracting one page range to a separate PDF; highlights, notes, text boxes and freehand ink; undo/redo; printing; recovery snapshots; and saving a new PDF. Note and text placement is by clicking a page. Ink is rendered after the pointer is released.

The app never overwrites an existing destination: it writes and flushes a temporary file, then exclusively links it to the chosen new name. If the destination is on another volume, it attempts to stage in an item-replacement directory on that volume. On a separate APFS test image, an unsandboxed test verified cross-volume export, reopening, and collision protection. A sandboxed build also saved through the system Save panel and the output was read with Poppler. Non-APFS and network volumes are not yet verified; unsupported locations fail without intentionally overwriting an existing file. Abrupt failure before the final link leaves no final file. Changes are snapshotted in the app's Application Support directory after each operation; snapshots can contain confidential PDF content and are removed after a successful save or explicit discard. A recovered snapshot must be saved as a new file.

Editing, extraction and re-export are deliberately disabled for encrypted PDFs and PDFs containing digital signature fields. Decrypting, preserving encryption, and certificate signatures are not implemented. Undo retains up to 20 snapshots and 200 MiB; a document too large for a snapshot cannot be edited. Edits use PDFKit serialization, and fidelity for complex forms, annotations, attachments, signatures and unusual PDFs is not established. Use copies and inspect output before relying on it.

## M2 implementation and limitations

Implemented (all undoable, all produce a new file only when saved):

- **OCR** (Document menu / More > Scanned pages): Apple Vision, Traditional Chinese + English, runs per page with a cancellable progress banner. Each recognised page is redrawn and given an invisible text layer positioned per text line, so it is searchable and selectable. Pages that already have text in the file and rotated pages are skipped. Rebuilt pages use the crop box as their page size; non-link annotations are copied, internal link targets on rebuilt pages are dropped, and bookmarks/links that pointed at replaced pages are re-pointed.
- **Compression**: only full-page scans (a page whose largest image is at least half the page area) are re-encoded as JPEG at 200/150/100 dpi, keeping the existing text layer. If the result is not smaller the change is undone automatically. Vector and born-digital pages are never rasterised.
- **Forms**: PDFKit shows and edits fields in place; edits are tracked so quit/close/recovery know the document changed. "Clear form fields" resets values; "Flatten form" burns fields into the page and leaves other annotations editable. XFA and JavaScript-driven forms are not supported.
- **Document info**: title, author, subject, keywords; "Clear all" removes them. PDFKit still writes its own Producer/Creator, and XMP metadata, attachments and embedded JavaScript are not cleaned.
- **Images to pages**: any image format ImageIO reads, fitted to A4 (portrait or landscape) as JPEG.
- **Protection**: "Save encrypted copy" (open password, optional owner password, print/copy/edit permissions) and, for an encrypted document the user has unlocked, "Save copy without password". Both write a new file; encrypted documents still cannot be edited in place. Encryption strength is whatever PDFKit/CoreGraphics produces and has not been audited.
- **Finder**: an "Open with MacPDF" Service for selected PDFs (declared in `project.yml`, handled in `AppDelegate`). Not yet verified from Finder.

Not implemented: PDF/A, extracting embedded images, image crop/contrast editing, scanner import, Dock menu, window-position memory. OCR accuracy on real scans (skew, noise, handwriting, mixed languages) is unmeasured; the automated tests use clean generated text.

## M3 implementation and limitations

Manual redaction follows the v1 (rasterize) guarantee in `docs/05-security-privacy.md` section 5.2.

- Candidates come from keywords, a custom regular expression, and PII presets (email, card with Luhn check, phone, SSN, IBAN with mod-97 check, IP, date, Taiwan ID with check digit), plus hand-drawn boxes. Candidates are only suggestions; nothing is removed until the user applies.
- Applying rebuilds every marked page as a flat picture at 200 dpi with the black boxes burned into the pixels before embedding. Annotations, links, form fields and text on those pages are gone. The output has no document info, outline or attachments. Unmarked pages are copied unchanged.
- The output is reopened and checked before the save panel appears: marked pages must have no text and no annotations, and each box centre must render dark. If any check fails nothing is written. The source file is never modified and the new file is created exclusively.
- Not done: postal codes (too many false positives), mosaic/text mark styles, content-stream (v2) redaction, restricting to chosen pages, the independent security test the roadmap gates M3 on. Do not rely on it for truly sensitive documents until that test is done.
- Encrypted PDFs and PDFs with signature fields are refused. Unmarked pages keep their annotations and any actions on them.
- Marked regions are PDF annotations while reviewing. Save, print and undo are disabled during review so they cannot leak into another file.

## M4 compare implementation and limitations

File > Compare two PDFs… opens two files side by side (the earlier-modified one is "old"; a button swaps them).

- Pages are matched first (longest common subsequence over word-set similarity, so inserted, deleted and moved pages are found), then each matched pair is diffed word by word (NaturalLanguage tokenizer, so Chinese is split too).
- Differences are painted on in-memory copies only (red removed, green added, yellow changed) and listed on the right; previous/next steps through them. Source files are never modified.
- Text only: no visual (pixel) diff, no formatting diff, no ignore-header/footer filter, no exported report. A side with almost no stored text (a scan) shows a warning to run OCR first.
- Tested with `Tests/M4Tests.swift` (7 tests) and by hand in a debug build (`MACPDF_COMPARE=old.pdf:new.pdf`, together with both files passed to `open`, because the sandbox only grants those files).

## M4 batch implementation and limitations

File > Batch process… takes many PDFs (picker or drag), a set of steps (OCR, flatten forms, compress scans; run in that order) and an output folder, and writes each result as `name-批次.pdf` (a number is added if that exists; nothing is overwritten). Encrypted and signed files are skipped and reported per file; one failure does not stop the rest; the run can be cancelled.

- Not built: saved reusable flows, step reordering, split/merge/rotate/watermark/redact/find-replace steps, a 500-file limit check, running without the window open.
- Tested by `Tests/BatchTests.swift` (5 tests: OCR, OCR+compress, refusal of encrypted input, non-colliding names, start rules). The window layout was checked by hand; a full run through the file panels was not driven by hand.

## M5 page management, markup and signature

- Pages: insert a blank page before or after the current one (same on-screen size as it); split into one file per page; split by ranges such as `1-3, 5, 8-10` (full-width digits and commas accepted). Splits write new files named `name-001-003.pdf` into a chosen folder; an existing name gets a number instead of being replaced.
- Markup: the highlighter button's menu now offers four highlight colours, underline and strikethrough (real PDF annotations; undoable).
- Signature: draw, type (four script fonts) or import a picture (paper background removed). Saved signatures live in `Application Support/MacPDF/Signatures` on this Mac only. Placing one rebuilds the page with the picture drawn over it while the page's own text stays real text; links that pointed inside the document are dropped from that page, like OCR and compression. Rotated pages are refused.
- Not done: drag-to-reorder and multi-select of thumbnails, sizing a signature after placing it (fixed 160 pt wide; undo and place again), a digital (certificate) signature, a signature field filled by the signature tool.
- Hand-checked: toolbar button and the signature sheet render. Drawing in the sheet and placing it through the desktop driver was not possible (the sheet is a second window the driver could not target), so placement is covered by the unit test that checks the pixels and text.

## M6 thumbnails and page images

- The Pages tab is now a SwiftUI grid instead of PDFKit's thumbnail strip. Click selects and jumps; Shift-click selects a range; Command-click toggles; drag a thumbnail (or the whole selection) to reorder, with a blue insertion line; dropping in the gap below the last page sends it to the end. Right-click: rotate, delete, extract to a new file, export as images, select all.
- The page commands in the "..." menu (rotate, move earlier/later, delete) act on the selection, or on the page on screen when nothing is selected. Everything goes through the normal undo stack.
- Export as images: all pages, the selection, or a range; PNG or JPEG; 72/150/300 dpi (capped at 10000 px on the long side); one file per page named `name-001.png` in a chosen folder, never replacing an existing file. Runs as a cancellable job.
- Hand-checked on a 300-page file: select, navigate and drag-reorder work (dirty mark, undo enabled, selection follows the moved page). Not hand-checked: Shift/Command-click (the desktop driver cannot send modifier clicks), dragging a multi-page selection, the export sheet and folder panel.
- Not built: the annotation list sidebar (dropped by decision), keyboard shortcuts for the selection (Delete, arrow keys), moving pages between windows.

## M7 PRD P0 completion

Done in this pass (see tests in `Tests/M7Tests.swift`):

- Viewing: single page, continuous, two-up, two-up continuous, fit page, fit width, actual size (View menu, also in the "..." menu); search with match case, whole word, next/previous (Cmd-G, Shift-Cmd-G); File > Open recent and Clear history (also on the welcome screen); optional document tabs (Settings); Settings with appearance (system/light/dark), language (takes effect on next start) and tab preference.
- Share sheet (shares a temporary copy of the document as it is now, removed after ten minutes); copy the page as an image; paste a clipboard image as a new page.
- Pages: Insert blank pages (count, position, size A4/A5/Letter/custom/same as page, landscape); rotate 90/180/270 and all pages; create or combine PDFs from images, PDFs (with page ranges), blank pages and the clipboard, in a chosen order, as a new unsaved document or into the current one at a position; TIFF export.
- Decorations: text or image watermark (font size, colour, opacity, rotation, position, tiled, behind content), headers and footers with six slots, tokens {page} {pages} {title} {author} {filename} {date}, start number, skip first page, mirrored even pages, page range. Pages are rebuilt (text stays real text; links are restored; a rotated page is rebuilt in the orientation it is seen in).
- Annotations: styles for new highlights (opacity), underline/strikethrough colour, ink colour and width, text box font/size/colour/alignment, author; "Select and edit annotations" inspector to change colour, opacity, line width, text, font size, author or delete (undoable). Text-box font, size, colour and alignment now survive saving (PDFKit's own font setter wrote an entry it could not read back).
- OCR: choose languages (Traditional/Simplified Chinese, English, Japanese, Korean), all pages / this page / a range, and the result names pages where nothing was found or that were skipped.
- Document info: creator and producer fields; creation and modification dates shown.
- Save over the original: File > Save over original (with backup) copies the file to MacPDF's Backups folder first, verifies the copy, then replaces the file in one step; nothing is replaced if the backup fails. Save a Copy remains the default.
- Documents with signature fields can be edited after an explicit confirmation that existing signatures become invalid.

Known limits:

- PDFKit stores a highlight's colour but not its translucency, so highlight opacity applies while editing and in this app's view but is not written to the file.
- Thumbnails are generated on demand in memory; there is no disk cache.
- The annotation list sidebar and note reply threads were not built (decided out of scope); signature fields are not filled as form values (the signature is placed over the field).
- Hand-checked: the watermark/header sheet, the create/combine sheet and the new dock buttons render. Not hand-checked: tabs, the Settings window, share sheet, the inspector and style popover, overwrite-with-backup through a real file panel, and the other new sheets.

## M8 keep it simple (Jimmy's direction, 2026-11-03)

Direction: MacPDF stays small, good-looking and easy. The key jobs are merge/split, OCR, editing recognised text, rotating pages, adding a password, converting to Markdown, and compression; everything runs on this Mac. Not wanted: file info/cleanup, page numbers/stamps, annotation extras, reading extras, other conversions (Word/Excel/RTF), accessibility extras, hard features (form building, find-and-replace in PDF text, PDF/A, large-file paging).

- Common tools: the grid button in the top bar opens eight big buttons: Merge, Split, Rotate, Text, Convert to Markdown, Add password, Compress, Make scans searchable. The "..." menu keeps the rest.
- Compression: four levels (smallest ~100 dpi, balanced ~150, print ~200, best ~300). It never renders at more detail than a scan really has, counts how many pages a level will touch, reduces scans and pages with large pictures, keeps text searchable, and undoes itself if the file does not get smaller.
- Text panel (top bar: tools > Text, or Document > Extract and edit text, Option-Command-T): reads the page or all pages. Pages with text in the PDF are read directly (with headings found from font size); pages that are pictures are recognised with the languages chosen in Settings. The text is editable. Scanned pages can write corrections back so search and copy use them (the picture stays, up to 300 dpi); pages that already have text are not changed, edits there only affect Copy and Export. Export: Markdown (.md) or plain text.
- Markdown: headings from relative text size, bullet and numbered lists, paragraphs from line spacing, CJK lines joined without spaces, `---` between pages. Tables and images are not converted.
- Convert to Markdown reads every page, then goes straight to the save panel.
- Pages: Duplicate pages; Split sheet (one file per page, by ranges, or just the selection).
- Settings: default layout, recent documents kept, OCR languages, reset, About (states that nothing leaves the Mac and Apple Intelligence is not needed).
- Window size and place are remembered (a frame that is too small or off-screen is ignored); Dock right-click menu (open, create, recent documents).
- No Apple Foundation Models (AFM) are used. Vision does the recognition, rules do the Markdown. AFM would need macOS 26 and Apple Intelligence; it could improve Markdown structure later as an optional step.
- Not built: scanning with an iPhone camera (Continuity Camera), which would be a small addition if wanted.

## Verification and outstanding work

- Signed, sandbox-enabled Apple Silicon debug build and automated tests pass on the development Mac.
- Manual smoke checks: opening a PDF, searching, rotating, saving a new copy, unsaved close/quit prompts, a second document window, opening the print preview, and restoring an unsaved rotation after force-quitting the isolated sandboxed test app. A Poppler `pdfinfo` check read the saved file and reported the expected page rotation; the source remained unchanged.
- macOS 14 has not been tested. Earlier Finder/Launch Services tests exposed competing SwiftUI/AppDelegate window creation. Document windows are now owned exclusively by PDFWindows; real-window integration tests cover cold batch, duplicate opens, and close-all/reopen. The updated shell visual smoke and drag gesture remain pending because desktop automation failed. See 12-m1-acceptance.md for the fixed gates and evidence. Large-file performance, full accessibility, cross-reader fidelity and all English translations need further validation. Automated tests also cover a synthetic PDF with crop box, annotations, a URL link, and a bookmark before and after reordering, and check local link/bookmark targets during merge and extraction. Links whose targets are outside an extracted range are disabled.
- This is an internal development build, not a public release or a claim that all historical PRD features are implemented. There is no redaction, comparison, batch flow or Office conversion yet; see the M2 section for what exists.

## Build

Requires Xcode and XcodeGen. Run `xcodegen generate`, then open `MacPDF.xcodeproj` or run `xcodebuild -scheme MacPDF build`. Tests: `xcodebuild -scheme MacPDF -destination 'platform=macOS' test`.

## Repeatable acceptance

See [M1 acceptance](12-m1-acceptance.md). Run `python3 scripts/accept-m1.py`; logs and machine-readable results are saved under `build/acceptance`.
