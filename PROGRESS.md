# MacPDF progress

Updated: 2026-11-02 (Asia/Singapore). M1 is an internal candidate; acceptance is incomplete.

## Implemented

- Native reader with search, outline, thumbnails, multi-window opening and password prompt.
- Page move/rotate/delete, append and range extraction; highlight, notes, text boxes and ink; undo/redo.
- New-file-only export, recovery snapshots, unsaved close/quit prompts and print support. Source files are not overwritten.
- `PDFWindows` is the sole document-window owner, replacing conflicting SwiftUI and AppDelegate routing. Merge/extraction remap local destinations and bookmarks; links to pages outside an extracted range are disabled.
- Cross-volume save uses an item-replacement directory where needed. Sandbox Save-panel export to an isolated APFS volume was manually tested on an earlier build.

- M2 core features (merged to main 2026-11-02): OCR, scan compression, form clear/flatten, document info, images to pages, encrypted/unlocked copies, Document menu, Finder Service. See `docs/11-implementation-plan.md`.
- UI redesign (merged to main): floating Liquid Glass top bar, bottom tool dock and sidebar over an ambient background; new welcome screen and drop overlay. macOS 26+ uses the system glass; macOS 14–25 falls back to materials. Only checked visually on macOS 27 dark mode; light mode and macOS 14–25 fallback are unverified.

- Debug builds honour `MACPDF_APPEARANCE=light|dark` to check both appearances without changing the system setting (`open --env MACPDF_APPEARANCE=light -a MacPDF.app`).

- M3 manual redaction (rasterize, with verification before save) is on branch `m3-redaction`; see `docs/11-implementation-plan.md`.

## Verification

- `python3 scripts/accept-m1.py`: 16 passed, 0 failed, 1 skipped on Apple Silicon/macOS 27; the skipped test requires a mounted isolated external test volume. Full local evidence is in ignored `build/acceptance/`.
- Automated AppKit/PDFKit integration covers cold multi-open, duplicate opens, close-all/reopen, page edits, recovery, no-overwrite and selected PDF fidelity cases.
- Earlier build manually passed sandbox export, unsaved prompts, print preview and force-quit recovery. These do not verify the latest window-owner shell.
- An earlier candidate was built as a universal binary at `build/MacPDF-M1-candidate.app`; this local artifact is not tracked or published. The previous `build/MacPDF.app` remains available locally.

## Next steps

1. Verify the **current candidate** visibly opens, shows controls/menu, handles close/quit with unsaved changes, and opens multiple Finder-selected PDFs without extra blank windows. Desktop automation previously failed even on window listing; avoid repeatedly retesting cases covered by the automated suite.
2. Test Finder drag/drop end to end, then record the result in `docs/12-m1-acceptance.md`.
3. Assess representative real-world PDFs and large-file behavior. macOS 14, non-APFS/network volumes and complete English localization remain unverified.
4. Only mark M1 accepted when its stated gates pass. See `docs/12-m1-acceptance.md` for exact scope and evidence.

## Boundaries

No public release or deployment has been done. Encrypted PDFs and PDFs containing digital signature fields cannot currently be edited or re-exported. PDFKit may not preserve every complex document feature; inspect outputs and retain originals.
