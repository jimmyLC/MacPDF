import SwiftUI
import AppKit

/// User preferences kept in UserDefaults. Nothing here is sent anywhere.
enum Preferences {
    static let appearanceKey = "appearance"
    static let tabsKey = "openInTabs"
    static let languageKey = "interfaceLanguage"

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

    var body: some View {
        Form {
            Picker("外觀", selection: $appearance) {
                Text("跟隨系統").tag("system"); Text("淺色").tag("light"); Text("深色").tag("dark")
            }
            .onChange(of: appearance) { _, _ in Preferences.applyAppearance() }
            Picker("語言", selection: $language) {
                Text("跟隨系統").tag("system"); Text("繁體中文").tag("zh-Hant"); Text("English").tag("en")
            }
            .onChange(of: language) { _, new in Preferences.setLanguage(new) }
            Text("語言設定會在下次開啟 MacPDF 時生效。").font(.caption).foregroundStyle(.secondary)
            Toggle("用分頁開啟文件", isOn: $openInTabs)
            Text("開啟新文件時，併入現有視窗的分頁，而不是另開視窗。").font(.caption).foregroundStyle(.secondary)
            Section("隱私") {
                Text("MacPDF 不會收集任何使用資料，也不會把文件傳到網路上。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}
