# MacPDF

> A native, local-first PDF workbench for macOS.  
> Early development — M1 features implemented; validation in progress.

**Repository:** MacPDF  
**Status:** Internal development / M1 validation
**Target:** macOS 14+ · Apple Silicon + Intel · Swift 6 + SwiftUI + PDFKit + Vision  
**Scope:** A RevPDF-class daily PDF workflow, built for personal/internal use first.

---

## What this is

MacPDF is a macOS application under development for editing, organizing, protecting, OCR-ing, comparing, and batch-processing PDF files **without uploading them anywhere**.

The product is intentionally:

- **Native** — SwiftUI + AppKit + PDFKit, not a wrapped web app.
- **Local-first** — no account, no cloud, no telemetry, no subscription.
- **Non-destructive** — originals are never overwritten without explicit confirmation and a backup.
- **Practical** — 80–90% of daily PDF work in one window, not a feature checklist that looks good in screenshots.

---

## What it will do

| Area | Highlights |
|---|---|
| View | Continuous scroll, tabs, thumbnails, outline, search, links, zoom, print |
| Organize | Merge, split, split-middle, reorder, rotate, delete, insert, extract, crop |
| Annotate | Highlight, underline, strikeout, notes, text boxes, ink, shapes, stamps |
| Sign & forms | Draw/import signatures, fill forms, flatten, build forms |
| Edit | Images, text boxes, links, bookmarks; true text editing is a later phase |
| Scan & OCR | Import/scan images, Apple Vision OCR, invisible searchable text layer |
| Convert | PDF → images, images → PDF, text/RTF, PDF/A-1b/2b/3b; PDF/A-2a and Office export are later phases |
| Protect | Passwords, permissions, auto-redaction, PII scanning, metadata cleanup |
| Decorate | Watermarks, headers/footers, page numbers, Bates numbering, stamps |
| Review | Text + visual diff, page matching, change list |
| Automate | Flows: chain compress, OCR, watermark, rotate, split, redact, export |
| Desktop | Quick Actions, default PDF app, Dock menu, keyboard shortcuts, recovery |

The full, itemized scope is in [docs/02-prd.md](docs/02-prd.md) — **271 feature rows** across 17 groups, each with an ID, priority, and difficulty.

---

## Documentation

| Document | What it covers |
|---|---|
| [01 · Product Brief](docs/01-product-brief.md) | Vision, market context, personas, positioning, principles, success metrics |
| [02 · PRD](docs/02-prd.md) | Complete feature list (A–Q), priorities, RevPDF parity, milestones, acceptance criteria |
| [03 · UX Spec](docs/03-ux-spec.md) | Information architecture, screen-by-screen specs, flows, shortcuts, empty/error states |
| [04 · Technical Design](docs/04-technical-design.md) | Architecture, modules, data model, OCR, redaction, compare, Flows, persistence |
| [05 · Security & Privacy](docs/05-security-privacy.md) | Threat model, data flow, sandbox, redaction guarantees, PDF parsing risks |
| [06 · Test Plan](docs/06-test-plan.md) | Test strategy, fixtures, acceptance tests, performance budgets, release checklist |
| [07 · Roadmap](docs/07-roadmap.md) | M0–M4 milestones, estimates, dependencies, risk register, phase gates |
| [08 · RevPDF Audit](docs/08-revpdf-audit.md) | What was observed in RevPDF 5.0.1 and how this plan maps to it |
| [09 · Decisions](docs/09-decisions.md) | Decision log, open questions, ADR-style rationale |
| [10 · Hard Features](docs/10-hard-features.md) | Deep-dive research: natural text editing, compare, Flows, Excel/Word/PDF/A-2a/compression |

---

## Scope at a glance

| Phase | What ships | Status |
|---|---|---|
| **M0** | Open/view, thumbnails, outline, search, multiple windows | Implemented; validation ongoing |
| **M1** | Page operations, merge/extract, basic annotations, export, print, undo/recovery | Implemented; validation ongoing |
| **M2** | OCR, forms fill/flatten, password/permissions, compress, metadata, Quick Actions | Planned |
| **M3** | Form builder, redaction, compare, Flows, PDF/A-1b/2b/3b | Planned |
| **M4** | True text editing, PDF → Word/Excel, digital signatures | Optional / not committed |

M1 is the first internal trial target. M4 is deliberately gated because true text editing and Office conversion are multi-month engineering problems. See [implementation status](docs/11-implementation-plan.md) for exact scope and limitations.

---

## Tech stack

| Layer | Choice |
|---|---|
| UI | SwiftUI + AppKit bridges |
| Document model | In-memory PDFKit model with snapshots |
| PDF rendering | PDFKit `PDFView` |
| PDF operations | PDFKit + CoreGraphics |
| OCR | Vision `VNRecognizeTextRequest` |
| Image processing | CoreImage / ImageIO |
| Text layer | `CGPDFContext` |
| Project generation | xcodegen |
| Tests | XCTest + XCUITest |

No third-party runtime dependencies are planned for v1. PDFium may be evaluated later for content-stream editing and true redaction.

---

## Repository status

This repository contains planning documents and an **early M1 app**:

- Generate the Xcode project with `xcodegen generate`.
- Build and test instructions and current limitations: [Implementation plan](docs/11-implementation-plan.md).
- No public releases; this is an internal development build.

See the implementation plan for current validation, safety behavior and limitations.

---

## License

**No license is granted.**

This repository is public so the plan can be read and reviewed. Without a license, default copyright applies: you may not copy, modify, distribute, sublicense, or use the contents without explicit permission. It is **source-available**, not OSI-approved open source.

If the project later decides to become open source, a license (for example MIT or Apache-2.0) should be added deliberately, with contributor terms.

---

## Non-affiliation

This is an independent clean-room plan. It is **not affiliated with, endorsed by, or derived from RevPDF**. RevPDF is referenced only as a product comparison. No RevPDF code, assets, icons, translations, or proprietary files are included.

Apple, macOS, PDFKit, and Vision are trademarks of Apple Inc.

---

## Reviewing the plan

The most useful review order:

1. Read [01 · Product Brief](docs/01-product-brief.md) for positioning.
2. Skim [02 · PRD](docs/02-prd.md) section 5 and mark features to cut or promote.
3. Check [07 · Roadmap](docs/07-roadmap.md) for scope vs. time.
4. Answer the open questions in [09 · Decisions](docs/09-decisions.md).

Comments belong in GitHub Issues. This is a planning repo, so issues are preferred over pull requests until the M0 skeleton exists.
