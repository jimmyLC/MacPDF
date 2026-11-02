import AppKit
import PDFKit
import NaturalLanguage

/// Text comparison of two PDFs: pages are matched first, then each matched pair is diffed word by word.
enum PDFCompare {
    enum Kind { case added, removed, modified }

    struct Change: Identifiable {
        let id = UUID()
        let kind: Kind
        let oldPage: Int?
        let newPage: Int?
        let oldText: String
        let newText: String
        let oldRects: [CGRect]
        let newRects: [CGRect]
        /// True for a page that exists on one side only.
        var wholePage = false
    }

    struct Result {
        var changes: [Change] = []
        var matchedPages = 0
        /// A side with almost no extractable text cannot be compared word by word.
        var oldHasText = true
        var newHasText = true
        var isIdentical: Bool { changes.isEmpty }
    }

    struct Token { let text: String; let range: NSRange }

    static func tokens(of text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range])
            result.append(Token(text: piece.precomposedStringWithCompatibilityMapping, range: NSRange(range, in: text)))
            return true
        }
        return result
    }

    static func similarity(_ a: [Token], _ b: [Token]) -> Double {
        if a.isEmpty && b.isEmpty { return 0.5 }
        let first = Set(a.map(\.text)), second = Set(b.map(\.text))
        let union = first.union(second).count
        return union == 0 ? 0 : Double(first.intersection(second).count) / Double(union)
    }

    /// Longest common subsequence over pages, counting only pairs that look like the same page.
    static func matchPages(_ old: [[Token]], _ new: [[Token]], threshold: Double = 0.4) -> [(Int, Int)] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return [] }
        var sim = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n { for j in 0..<m {
            // Two picture-only pages are paired only when they sit at the same place.
            sim[i][j] = (old[i].isEmpty && new[j].isEmpty) ? (i == j ? 0.5 : 0) : similarity(old[i], new[j])
        } }
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { for j in 1...m {
            var best = max(dp[i - 1][j], dp[i][j - 1])
            if sim[i - 1][j - 1] >= threshold { best = max(best, dp[i - 1][j - 1] + sim[i - 1][j - 1]) }
            dp[i][j] = best
        } }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if sim[i - 1][j - 1] >= threshold, abs(dp[i][j] - (dp[i - 1][j - 1] + sim[i - 1][j - 1])) < 1e-9 { pairs.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return pairs.reversed()
    }

    @MainActor static func rects(for tokens: ArraySlice<Token>, on page: PDFPage, text: String) -> (String, [CGRect]) {
        guard let first = tokens.first, let last = tokens.last else { return ("", []) }
        let range = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
        let snippet = (text as NSString).substring(with: range)
        guard let selection = page.selection(for: range) else { return (snippet, []) }
        let boxes = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        return (snippet, boxes)
    }

    @MainActor static func compare(old: PDFDocument, new: PDFDocument) -> Result {
        func texts(_ doc: PDFDocument) -> [String] { (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" } }
        let oldTexts = texts(old), newTexts = texts(new)
        let oldTokens = oldTexts.map(tokens(of:)), newTokens = newTexts.map(tokens(of:))
        var result = Result()
        result.oldHasText = oldTokens.reduce(0) { $0 + $1.count } >= 5
        result.newHasText = newTokens.reduce(0) { $0 + $1.count } >= 5
        let pairs = matchPages(oldTokens, newTokens)
        result.matchedPages = pairs.count
        let matchedOld = Set(pairs.map(\.0)), matchedNew = Set(pairs.map(\.1))

        var changes: [Change] = []
        for (oi, ni) in pairs {
            guard let oldPage = old.page(at: oi), let newPage = new.page(at: ni) else { continue }
            let a = oldTokens[oi], b = newTokens[ni]
            let diff = b.map(\.text).difference(from: a.map(\.text))
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in diff {
                switch change { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if (i < a.count && removed.contains(i)) || (j < b.count && inserted.contains(j)) {
                    let startI = i, startJ = j
                    while i < a.count && removed.contains(i) { i += 1 }
                    while j < b.count && inserted.contains(j) { j += 1 }
                    let (oldText, oldRects) = rects(for: a[startI..<i], on: oldPage, text: oldTexts[oi])
                    let (newText, newRects) = rects(for: b[startJ..<j], on: newPage, text: newTexts[ni])
                    let kind: Kind = i > startI && j > startJ ? .modified : (i > startI ? .removed : .added)
                    changes.append(Change(kind: kind, oldPage: oi, newPage: ni, oldText: oldText, newText: newText, oldRects: oldRects, newRects: newRects))
                } else { i += 1; j += 1 }
            }
        }
        for index in 0..<old.pageCount where !matchedOld.contains(index) {
            let box = old.page(at: index)?.bounds(for: .cropBox) ?? .zero
            changes.append(Change(kind: .removed, oldPage: index, newPage: nil, oldText: String(oldTexts[index].prefix(80)), newText: "", oldRects: [box], newRects: [], wholePage: true))
        }
        for index in 0..<new.pageCount where !matchedNew.contains(index) {
            let box = new.page(at: index)?.bounds(for: .cropBox) ?? .zero
            changes.append(Change(kind: .added, oldPage: nil, newPage: index, oldText: "", newText: String(newTexts[index].prefix(80)), oldRects: [], newRects: [box], wholePage: true))
        }
        result.changes = changes.sorted { ($0.newPage ?? $0.oldPage ?? 0, $0.oldPage ?? 0) < ($1.newPage ?? $1.oldPage ?? 0, $1.oldPage ?? 0) }
        return result
    }

    static let highlightName = "macpdf.compare.mark"

    /// Paints the differences on display copies of the documents (red removed, green added, yellow changed).
    @MainActor static func paint(_ result: Result, old: PDFDocument, new: PDFDocument) {
        func mark(_ rects: [CGRect], on page: PDFPage?, color: NSColor) {
            guard let page else { return }
            for rect in rects {
                let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
                annotation.color = color.withAlphaComponent(0.9)
                annotation.interiorColor = color.withAlphaComponent(0.28)
                let border = PDFBorder(); border.lineWidth = 0.8; annotation.border = border
                annotation.userName = highlightName
                page.addAnnotation(annotation)
            }
        }
        for change in result.changes where !change.wholePage {
            let oldColor: NSColor = change.kind == .modified ? .systemYellow : .systemRed
            let newColor: NSColor = change.kind == .modified ? .systemYellow : .systemGreen
            mark(change.oldRects, on: change.oldPage.flatMap { old.page(at: $0) }, color: oldColor)
            mark(change.newRects, on: change.newPage.flatMap { new.page(at: $0) }, color: newColor)
        }
    }
}
