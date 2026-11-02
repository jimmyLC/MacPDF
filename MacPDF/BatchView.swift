import SwiftUI
import UniformTypeIdentifiers

struct BatchView: View {
    let model: BatchModel
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            AmbientBackground()
            VStack(alignment: .leading, spacing: 14) {
                Label("批次處理", systemImage: "square.stack.3d.down.right").font(.title3.weight(.semibold))
                HStack(alignment: .top, spacing: 14) {
                    fileList
                    VStack(alignment: .leading, spacing: 12) {
                        stepsCard(options: $model.options)
                        folderCard
                        Spacer(minLength: 0)
                        runButtons
                    }.frame(width: 300)
                }
            }
            .padding(20).padding(.top, 14)
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 480)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: L("檔案（%ld）"), model.files.count)).font(.subheadline.weight(.medium))
                Spacer()
                Button("加入 PDF…") { model.chooseFiles() }.controlSize(.small).disabled(model.running)
            }.padding(12)
            if model.files.isEmpty {
                ContentUnavailableView("拖曳 PDF 到這裡", systemImage: "arrow.down.doc").frame(maxHeight: .infinity)
            } else {
                List(model.files, id: \.self) { url in
                    HStack(spacing: 8) {
                        statusIcon(model.outcomes[url] ?? .waiting)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let detail = detail(model.outcomes[url]) { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        if !model.running {
                            Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("移除")
                        }
                    }.listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
    }

    @ViewBuilder private func statusIcon(_ outcome: BatchProcessor.Outcome) -> some View {
        switch outcome {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func detail(_ outcome: BatchProcessor.Outcome?) -> String? {
        switch outcome {
        case .done(let text), .skipped(let text), .failed(let text): text
        default: nil
        }
    }

    private func stepsCard(options: Binding<BatchProcessor.Options>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("要做的事").font(.subheadline.weight(.medium))
            Toggle("文字辨識（OCR）", isOn: options.ocr)
            Toggle("壓縮掃描頁面", isOn: options.compress)
            if options.wrappedValue.compress {
                Picker("品質", selection: options.preset) {
                    Text("高品質").tag(PDFProcessing.Preset.high)
                    Text("標準").tag(PDFProcessing.Preset.standard)
                    Text("最小檔案").tag(PDFProcessing.Preset.small)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Toggle("扁平化表單", isOn: options.flatten)
            Text("依序進行：辨識 → 扁平化 → 壓縮。加密或有簽章的檔案會跳過。").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.running)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("輸出資料夾").font(.subheadline.weight(.medium))
            Text(model.folder?.path ?? L("尚未選擇")).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Button("選擇資料夾…") { model.chooseFolder() }.controlSize(.small).disabled(model.running)
            Text("每個結果存成「檔名-批次.pdf」，已有同名檔案時會加上編號，不會覆寫。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var runButtons: some View {
        HStack {
            if model.running { Button("取消") { model.cancel() } }
            Button { model.start() } label: {
                Label(model.finished ? "再執行一次" : "開始", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .prominentGlassButton().controlSize(.large).disabled(!model.canStart)
        }
    }
}
