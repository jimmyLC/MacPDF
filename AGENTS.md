# MacPDF agent guide

- Read `PROGRESS.md` for the current handoff and `docs/12-m1-acceptance.md` before changing M1 or claiming acceptance.
- Generate the Xcode project with `xcodegen generate`. Run `python3 scripts/accept-m1.py` for bounded M1 regression evidence; inspect skipped tests and `build/acceptance/latest.json`.
- `PDFWindows` owns document windows; `ReaderModel` coordinates the UI, `PDFEditing` handles in-memory edits and new-file export, and `RecoveryStore` manages snapshots. Keep file ownership and lifecycle in one place.
- Preserve input files, reject overwriting existing output, and retain recovery data until save or explicit discard. Validate document fidelity and failure paths when changing PDF operations or saving.
- M1 is an internal candidate. Encrypted PDFs and documents with signature fields are not editable/exportable; see `docs/11-implementation-plan.md` for restrictions and unverified compatibility.
- Use generated, non-sensitive PDF fixtures. Do not treat compilation or unit tests as proof of GUI, Finder drag/drop, cross-reader, Intel, or macOS 14 behavior.
- Keep `PROGRESS.md` current when milestones or validation change. The `build/` output and generated Xcode project are local artifacts; reproduce from `project.yml`.
