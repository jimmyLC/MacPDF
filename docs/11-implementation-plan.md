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

## Verification and outstanding work

- Signed, sandbox-enabled Apple Silicon debug build and automated tests pass on the development Mac.
- Manual smoke checks: opening a PDF, searching, rotating, saving a new copy, unsaved close/quit prompts, a second document window, opening the print preview, and restoring an unsaved rotation after force-quitting the isolated sandboxed test app. A Poppler `pdfinfo` check read the saved file and reported the expected page rotation; the source remained unchanged.
- macOS 14 has not been tested. Earlier Finder/Launch Services tests exposed competing SwiftUI/AppDelegate window creation. Document windows are now owned exclusively by PDFWindows; real-window integration tests cover cold batch, duplicate opens, and close-all/reopen. The updated shell visual smoke and drag gesture remain pending because desktop automation failed. See 12-m1-acceptance.md for the fixed gates and evidence. Large-file performance, full accessibility, cross-reader fidelity and all English translations need further validation. Automated tests also cover a synthetic PDF with crop box, annotations, a URL link, and a bookmark before and after reordering, and check local link/bookmark targets during merge and extraction. Links whose targets are outside an extracted range are disabled.
- This is an internal development build, not a public release or a claim that all historical PRD features are implemented. There is no redaction, comparison, batch flow or Office conversion yet; see the M2 section for what exists.

## Build

Requires Xcode and XcodeGen. Run `xcodegen generate`, then open `MacPDF.xcodeproj` or run `xcodebuild -scheme MacPDF build`. Tests: `xcodebuild -scheme MacPDF -destination 'platform=macOS' test`.

## Repeatable acceptance

See [M1 acceptance](12-m1-acceptance.md). Run `python3 scripts/accept-m1.py`; logs and machine-readable results are saved under `build/acceptance`.
