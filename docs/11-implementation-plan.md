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

## Verification and outstanding work

- Signed, sandbox-enabled Apple Silicon debug build and automated tests pass on the development Mac.
- Manual smoke checks: opening a PDF, searching, rotating, saving a new copy, unsaved close/quit prompts, a second document window, opening the print preview, and restoring an unsaved rotation after force-quitting the isolated sandboxed test app. A Poppler `pdfinfo` check read the saved file and reported the expected page rotation; the source remained unchanged.
- Intel compilation succeeded; Intel runtime and macOS 14 have not been tested. Earlier Finder/Launch Services tests exposed competing SwiftUI/AppDelegate window creation. Document windows are now owned exclusively by PDFWindows; real-window integration tests cover cold batch, duplicate opens, and close-all/reopen. The updated shell visual smoke and drag gesture remain pending because desktop automation failed. See 12-m1-acceptance.md for the fixed gates and evidence. Large-file performance, full accessibility, cross-reader fidelity and all English translations need further validation. Automated tests also cover a synthetic PDF with crop box, annotations, a URL link, and a bookmark before and after reordering, and check local link/bookmark targets during merge and extraction. Links whose targets are outside an extracted range are disabled.
- This is an internal development build, not a public release or a claim that all historical PRD features are implemented. There are no OCR, forms, redaction or Office conversion features yet.

## Build

Requires Xcode and XcodeGen. Run `xcodegen generate`, then open `MacPDF.xcodeproj` or run `xcodebuild -scheme MacPDF build`. Tests: `xcodebuild -scheme MacPDF -destination 'platform=macOS' test`.

## Repeatable acceptance

See [M1 acceptance](12-m1-acceptance.md). Run `python3 scripts/accept-m1.py`; logs and machine-readable results are saved under `build/acceptance`.
