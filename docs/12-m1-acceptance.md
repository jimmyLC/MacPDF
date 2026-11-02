# M1 acceptance

## Scope and stopping rule

M1 is the agreed internal trial: PDF reading, page organization, merge/range extraction, basic annotations/ink, undo/redo, new-file export, recovery and printing. The older broad PRD is not a release checklist for this milestone.

Run `python3 scripts/accept-m1.py` from the repository. It has a 240-second timeout, writes the complete build/test log and xcresult to `build/acceptance`, and writes `latest.json` on success. A failure or skipped test is not silently counted as passed. Re-run only after a change or a newly diagnosed failure.

## Automated gates

| Gate | Evidence |
|---|---|
| Open invalid/encrypted PDF, retain existing document | ReaderModelTests |
| Rotate/delete/move and undo/redo | PDFEditingTests |
| Never overwrite existing output; preserve source bytes | PDFEditingTests, ReaderModelTests |
| Save/reopen annotations and ink | PDFEditingTests |
| Preserve crop box, annotations, links and bookmarks | PDFFidelityTests, PDFMergeFidelityTests |
| Recovery snapshot and missing-manifest detection | PDFEditingTests |
| Cold batch open, duplicate open, welcome reuse, close-all/reopen | PDFWindowsTests, real NSWindow/PDFDocument objects |

The window tests use an isolated PDFWindows instance and suppress presentation, so they test actual AppKit window ownership without mouse coordinates or system dialog timing. PDFWindows is now the sole document-window owner; SwiftUI supplies the hosted reader UI. The test must assert exactly the requested document windows, with no automatic welcome window after a cold batch.

## Limited manual gates

| Gate | Status |
|---|---|
| Save-panel sandbox grant and local export | Passed on earlier reader build |
| Save-panel export to isolated APFS volume | Passed; output read by Poppler |
| Unsaved close and quit prompts | Passed on earlier reader build |
| Force-quit/relaunch recovery | Passed on earlier reader build |
| Print preview | Passed on earlier reader build |
| Current window-owner build (Liquid Glass UI): launch, welcome screen, open via Finder-style `open -a`, note tool placement, dirty marker + undo enabled, close prompt (Cancel keeps window, Discard closes) | Passed 2026-11-02, macOS 27 / Apple Silicon, dark mode, via desktop driver |
| Liquid Glass UI: light mode (forced via `MACPDF_APPEARANCE=light`, debug builds), highlight across three lines, freehand ink, 300-page generated PDF opens in about a second (serialize 0.03 s, search 0.5 s) | Passed 2026-11-02, macOS 27 / Apple Silicon |
| Liquid Glass UI: macOS 14–25 material fallback, text box tool, page menu actions (rotate/move/delete/merge/extract), Finder drag gesture, real-world PDFs, PDFs of hundreds of MB | Pending |
| Finder-to-reader drag gesture | Pending |

Earlier manual results are not presented as proof of the changed window shell. Current-shell smoke checks must be rerun once, after desktop automation is available. Do not repeatedly retest all PDF operations through Finder.

## M2 gates

Automated (`Tests/M2Tests.swift`, run by the same script): OCR output is searchable and located at the text's position and keeps page labels; Traditional Chinese is recognised; replaced pages keep bookmarks and links; compression shrinks a scan and keeps page size; compression keeps a recognised scan's text; a vector text page is not treated as a scan; flatten keeps values and other annotations and can be undone; form reset can be undone; metadata round trip; image import fits A4; encrypted copy requires the password and honours permissions; unlocked copy is not encrypted.

Manual on 2026-11-02 (macOS 27, Apple Silicon, dark mode, desktop driver): Document-menu OCR on a 3-page generated scan applied a text layer to every page and enabled undo; the Document-info and Compress sheets display; Flatten form on a generated form kept the field values; the sidebar thumbnails keep correct page numbers. The encrypt sheet was clipped at 400 pt wide and was widened to 520; the full flow (sheet → Save panel → file) then produced a PDF that is locked, rejects a wrong password and opens with the right one. The Finder Service "Open with MacPDF" is registered with the system (`pbs -dump_pboard` lists it for com.adobe.pdf); invoking it from Finder was not tried. Not yet checked by hand: images-to-pages through the file picker, OCR on real scans, cancelling a running job.

## Compatibility envelope

Apple Silicon runtime tested on the development Mac. Intel is out of scope (Apple Silicon only). Compilation does not prove macOS 14 compatibility. Network/exFAT volumes, malformed PDFs and a representative large-document corpus have no general compatibility claim. Encrypted/signature-field document editing remains unsupported. These are explicit limitations, not passed acceptance items.
