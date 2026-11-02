import SwiftUI
import PDFKit

/// Defaults for new annotations (popover from the tool dock).
struct AnnotationStyleForm: View {
    let model: ReaderModel

    private func colorBinding(_ keyPath: WritableKeyPath<AnnotationStyle, String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.style[keyPath: keyPath]) ?? .black) },
                set: { model.style[keyPath: keyPath] = NSColor($0).hexString })
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("螢光筆與線條") {
                LabeledContent("螢光筆透明度") { Slider(value: $model.style.highlightOpacity, in: 0.1...1) }
                ColorPicker("底線／刪除線顏色", selection: colorBinding(\.lineColor))
            }
            Section("手繪") {
                ColorPicker("顏色", selection: colorBinding(\.inkColor))
                LabeledContent("粗細") { Slider(value: $model.style.inkWidth, in: 0.5...12) }
            }
            Section("文字方塊") {
                Picker("字型", selection: $model.style.textFont) {
                    ForEach(["Helvetica", "Times New Roman", "Courier", "PingFang TC", "Songti TC", "Kaiti TC"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("字級：\(Int(model.style.textSize))", value: $model.style.textSize, in: 6...72)
                ColorPicker("文字顏色", selection: colorBinding(\.textColor))
                Picker("對齊", selection: $model.style.textAlignment) {
                    Text("靠左").tag(AnnotationStyle.Alignment.left); Text("置中").tag(AnnotationStyle.Alignment.center); Text("靠右").tag(AnnotationStyle.Alignment.right)
                }.pickerStyle(.segmented)
            }
            Section("作者") { TextField("便條與標示上的作者名稱", text: $model.style.author) }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 470)
    }
}

/// Edits one existing annotation: colour, opacity, line width, text, font, author; or deletes it.
struct AnnotationInspector: View {
    let model: ReaderModel
    @State private var color = Color.yellow
    @State private var opacity = 1.0
    @State private var width = 1.0
    @State private var contents = ""
    @State private var author = ""
    @State private var fontSize = 14.0
    @State private var loadedFor: ReaderModel.AnnotationRef?

    private var annotation: PDFAnnotation? { model.inspectedAnnotation }
    private var type: String { annotation?.type ?? "" }
    private var hasWidth: Bool { ["Ink", "Square", "Circle", "Line", "Underline", "StrikeOut"].contains(type) }
    private var hasText: Bool { ["Text", "FreeText"].contains(type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("註解屬性", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("完成") { model.setInspectMode(false) }.controlSize(.small)
            }
            if let annotation {
                Text(String(format: L("%@，第 %ld 頁"), typeName, (model.inspected?.page ?? 0) + 1)).font(.caption).foregroundStyle(.secondary)
                if type != "FreeText" { ColorPicker("顏色", selection: $color) }
                else { ColorPicker("文字顏色", selection: $color) }
                if type != "FreeText" { LabeledContent("透明度") { Slider(value: $opacity, in: 0.1...1) } }
                if hasWidth { LabeledContent("線寬") { Slider(value: $width, in: 0.5...12) } }
                if type == "FreeText" { Stepper("字級：\(Int(fontSize))", value: $fontSize, in: 6...96) }
                if hasText { TextField("內容", text: $contents, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder) }
                TextField("作者", text: $author).textFieldStyle(.roundedBorder)
                HStack {
                    Button("刪除", role: .destructive) { model.deleteInspected() }
                    Spacer()
                    Button("套用") { apply(to: annotation) }.prominentGlassButton()
                }
            } else {
                Text("點一下頁面上的標示、便條、文字方塊或手繪，就能在這裡修改它。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onChange(of: model.inspected, initial: true) { _, _ in load() }
    }

    private var typeName: String {
        switch type {
        case "Highlight": L("螢光筆"); case "Underline": L("底線"); case "StrikeOut": L("刪除線"); case "Text": L("便條")
        case "FreeText": L("文字方塊"); case "Ink": L("手繪"); case "Square": L("方框"); default: type
        }
    }

    private func load() {
        guard let annotation, loadedFor != model.inspected else { return }
        loadedFor = model.inspected
        let base = type == "FreeText" ? (annotation.fontColor ?? .black) : annotation.color
        color = Color(nsColor: base.withAlphaComponent(1))
        opacity = Double(annotation.color.alphaComponent == 0 ? 1 : annotation.color.alphaComponent)
        width = Double(annotation.border?.lineWidth ?? 1)
        contents = annotation.contents ?? ""
        author = annotation.userName ?? ""
        fontSize = Double(annotation.font?.pointSize ?? 14)
    }

    private func apply(to annotation: PDFAnnotation) {
        let chosen = NSColor(color), alpha = CGFloat(opacity), lineWidth = CGFloat(width), text = contents, name = author, size = CGFloat(fontSize)
        let kind = type
        model.updateInspected { target in
            if kind == "FreeText" {
                target.applyTextStyle(font: NSFont(name: target.font?.fontName ?? "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size), color: chosen)
            } else { target.color = chosen.withAlphaComponent(alpha) }
            if ["Ink", "Square", "Circle", "Line", "Underline", "StrikeOut"].contains(kind) {
                let border = target.border ?? PDFBorder(); border.lineWidth = lineWidth; target.border = border
            }
            if ["Text", "FreeText"].contains(kind) { target.contents = text }
            target.userName = name.isEmpty ? nil : name
        }
        loadedFor = nil
    }
}
