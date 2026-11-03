import SwiftUI
import AppKit

/// User preferences kept in UserDefaults. Nothing here is sent anywhere.
enum Preferences {
    static let appearanceKey = "appearance"
    static let tabsKey = "openInTabs"
    static let languageKey = "interfaceLanguage"
    static let ocrKey = "ocrLanguages"
    static let recentLimitKey = "recentLimit"
    static let viewModeKey = "defaultViewMode"

    static var recentLimit: Int { let value = UserDefaults.standard.integer(forKey: recentLimitKey); return value > 0 ? value : 8 }
    static var defaultViewMode: ViewMode { ViewMode(rawValue: UserDefaults.standard.string(forKey: viewModeKey) ?? "") ?? .continuous }

    /// Puts every preference back to its default.
    static func reset() {
        for key in [appearanceKey, tabsKey, languageKey, ocrKey, recentLimitKey, viewModeKey, "AppleLanguages", AnnotationStyle.key] { UserDefaults.standard.removeObject(forKey: key) }
        applyAppearance()
    }

    static func applyAppearance() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACPDF_APPEARANCE"] != nil { return }
        #endif
        switch UserDefaults.standard.string(forKey: appearanceKey) ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Takes effect the next time the app starts.
    static func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: languageKey)
        if code == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.appearanceKey) private var appearance = "system"
    @AppStorage(Preferences.tabsKey) private var openInTabs = false
    @AppStorage(Preferences.languageKey) private var language = "system"
    @AppStorage(Preferences.recentLimitKey) private var recentLimit = 8
    @AppStorage(Preferences.viewModeKey) private var viewMode = ViewMode.continuous.rawValue
    @State private var ocr: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Preferences.ocrKey) ?? PDFProcessing.defaultOCRLanguages)
    @State private var confirmReset = false
    private let ocrChoices: [(code: String, name: String)] = [("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어")]

    var body: some View {
        Form {
            Section("一般") {
                Picker("外觀", selection: $appearance) { Text("跟隨系統").tag("system"); Text("淺色").tag("light"); Text("深色").tag("dark") }
                    .onChange(of: appearance) { _, _ in Preferences.applyAppearance() }
                Picker("語言", selection: $language) { Text("跟隨系統").tag("system"); Text("繁體中文").tag("zh-Hant"); Text("English").tag("en") }
                    .onChange(of: language) { _, new in Preferences.setLanguage(new) }
                Text("語言設定會在下次開啟 MacPDF 時生效。").font(.caption).foregroundStyle(.secondary)
                Toggle("用分頁開啟文件", isOn: $openInTabs)
            }
            Section("閱讀") {
                Picker("預設版面", selection: $viewMode) { ForEach(ViewMode.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("最近文件保留", selection: $recentLimit) { Text("5 份").tag(5); Text("8 份").tag(8); Text("15 份").tag(15); Text("30 份").tag(30) }
            }
            Section("掃描檔的文字辨識語言") {
                HStack(spacing: 12) {
                    ForEach(ocrChoices, id: \.code) { choice in
                        Toggle(choice.name, isOn: Binding(get: { ocr.contains(choice.code) }, set: { on in
                            if on { ocr.insert(choice.code) } else if ocr.count > 1 { ocr.remove(choice.code) }
                            UserDefaults.standard.set(ocrChoices.map(\.code).filter { ocr.contains($0) }, forKey: Preferences.ocrKey)
                        })).toggleStyle(.checkbox)
                    }
                }
                Text("勾選你的文件常用的語言，辨識會更準。").font(.caption).foregroundStyle(.secondary)
            }
            Section("關於") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("MacPDF 全程在這台 Mac 上處理文件，不會收集任何使用資料，也不會把文件傳到網路上。文字辨識使用 macOS 內建的功能，不需要 Apple Intelligence。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("重設所有設定…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .alert("重設所有設定？", isPresented: $confirmReset) {
            Button("重設", role: .destructive) { Preferences.reset(); appearance = "system"; openInTabs = false; language = "system"; recentLimit = 8; viewMode = ViewMode.continuous.rawValue; ocr = Set(PDFProcessing.defaultOCRLanguages) }
            Button("取消", role: .cancel) {}
        } message: { Text("外觀、語言、版面、辨識語言與標註樣式會回到預設值。你的文件不受影響。") }
    }
}
