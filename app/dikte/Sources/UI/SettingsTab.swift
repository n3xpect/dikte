import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Ayarlar wired to the live stores.
struct SettingsTab: View {
    let state: AppState

    var body: some View {
        @Bindable var settings = state.settings
        SettingsView(settings: $settings.settings, launchAtLogin: .system)
    }
}

/// Login item access, injectable for previews.
struct LaunchAtLogin {
    var status: () -> SMAppService.Status
    var setEnabled: (Bool) throws -> Void

    static let system = LaunchAtLogin(
        status: { SMAppService.mainApp.status },
        setEnabled: { on in
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    )
}

/// Ayarlar: Genel (launch at login, dictation shortcut), Dil / Language, Geçmiş.
struct SettingsView: View {
    @Binding var settings: AppSettings
    var launchAtLogin: LaunchAtLogin
    /// Stored dictation shortcut (previews pass fixed values).
    var loadShortcut: () -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: .dictate) }
    var saveShortcut: (KeyboardShortcuts.Shortcut?) -> Void = { KeyboardShortcuts.setShortcut($0, for: .dictate) }

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var dictateShortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        Form {
            generalSection
            languageSection

            Section {
                LabeledContent(L("Geçmiş sınırı")) {
                    HStack(spacing: 6) {
                        if settings.historyLimit == 0 {
                            Text(L("Sınırsız")).foregroundStyle(.secondary)
                        }
                        TextField("", value: $settings.historyLimit, format: .number.locale(Fmt.locale))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Stepper("", value: $settings.historyLimit, in: 0...100_000, step: 10)
                            .labelsHidden()
                        Text(L("kayıt"))
                    }
                }
            } header: {
                Text(L("Geçmiş"))
            } footer: {
                Text(L("0 = Sınırsız. Sınır aşılınca en eski kayıtlar silinir."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.historyLimit) { _, v in
            if v < 0 { settings.historyLimit = 0 }
        }
        .onAppear {
            refreshLoginStatus()
            dictateShortcut = loadShortcut()
        }
    }

    private var generalSection: some View {
        Section(L("Genel")) {
            Toggle(L("Açılışta başlat"), isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setLaunchAtLogin
            ))
            if loginStatus == .requiresApproval {
                HStack {
                    Text(L("Sistem Ayarları'nda onay bekliyor.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Giriş Öğeleri'ni aç")) { SMAppService.openSystemSettingsLoginItems() }
                }
                .font(.callout)
            }
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.danger)
                    .font(.callout)
            }
            LabeledContent {
                ShortcutField(shortcut: $dictateShortcut, save: saveShortcut)
            } label: {
                Text(L("Dikte kısayolu"))
                if dictateShortcut == nil {
                    Text(L("Kısayol yok; dikteyi menü çubuğundan başlatabilirsin."))
                }
            }
            if dictateShortcut == nil, let initial = KeyboardShortcuts.Name.dictate.defaultShortcut {
                HStack {
                    Spacer()
                    Button(L("Varsayılana dön (%@)", initial.description)) {
                        dictateShortcut = initial
                        saveShortcut(initial)
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }

    private var languageSection: some View {
        Section {
            Picker(L("Arayüz dili"), selection: $settings.uiLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            Picker(L("Dikte dili"), selection: $settings.dictationLanguage) {
                ForEach(DictationLanguage.allCases, id: \.self) { lang in
                    Text(lang.title).tag(lang)
                }
            }
        } header: {
            // Bilingual on purpose: findable after switching to a language one can't read.
            Text(verbatim: "Dil / Language")
        } footer: {
            Text(settings.dictationLanguage.hint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshLoginStatus() {
        loginStatus = launchAtLogin.status()
        let on = loginStatus == .enabled
        if settings.launchAtLogin != on { settings.launchAtLogin = on }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try launchAtLogin.setEnabled(on)
            loginError = nil
        } catch {
            loginError = on
                ? L("Açılışta başlatma açılamadı: %@", error.localizedDescription)
                : L("Açılışta başlatma kapatılamadı: %@", error.localizedDescription)
        }
        refreshLoginStatus()
    }
}

extension DictationLanguage {
    var title: String {
        switch self {
        case .auto: L("Otomatik (Türkçe + English)")
        case .tr: L("Türkçe")
        case .en: L("English")
        }
    }

    var hint: String {
        switch self {
        case .auto: L("Her diktede dil algılanır; panelde TR/EN düğmesiyle değiştirebilirsin.")
        case .tr: L("Her dikte Türkçe olarak yazıya çevrilir.")
        case .en: L("Her dikte İngilizce olarak yazıya çevrilir.")
        }
    }
}
