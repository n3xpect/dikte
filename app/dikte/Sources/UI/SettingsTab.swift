import AppKit
import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Ayarlar wired to the live stores.
struct SettingsTab: View {
    let state: AppState
    @State private var microphones: [Microphone] = Microphone.all()

    var body: some View {
        @Bindable var settings = state.settings
        SettingsView(
            settings: $settings.settings,
            microphones: microphones,
            terms: state.terms.terms,
            termActions: TermActions(upsert: state.terms.upsert, delete: state.terms.delete(term:)),
            launchAtLogin: .system,
            engineStatus: state.engine.status,
            dataDir: Paths.dataDir
        )
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            microphones = Microphone.all()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            microphones = Microphone.all()
        }
    }
}

struct Microphone: Hashable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }

    static func all() -> [Microphone] {
        AudioCapture.availableMicrophones().map { Microphone(uid: $0.uid, name: $0.name) }
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

struct SettingsView: View {
    @Binding var settings: AppSettings
    var microphones: [Microphone]
    var terms: [Term]
    var termActions: TermActions
    var launchAtLogin: LaunchAtLogin
    var engineStatus: EngineStatus
    var dataDir: URL

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Dikte") {
                KeyboardShortcuts.Recorder("Dikte kısayolu", name: .dictate)
                microphonePicker
                LabeledContent("Sessizlik süresi") {
                    HStack {
                        Slider(value: $settings.silenceSeconds, in: 1...10, step: 0.5)
                            .frame(maxWidth: 220)
                        Text(Fmt.seconds(settings.silenceSeconds))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .help("Konuşma bittikten sonra bu kadar sessizlik olunca kayıt kendiliğinden biter.")
                Toggle("Ses efektleri", isOn: $settings.soundsEnabled)
            }

            Section {
                LabeledContent("Modelin boşta kalma süresi") {
                    Stepper(value: $settings.idleUnloadMinutes, in: 0...60) {
                        Text(settings.idleUnloadMinutes == 0 ? "Hiç" : "\(settings.idleUnloadMinutes) dk")
                            .monospacedDigit()
                    }
                }
                LabeledContent("En az boş disk alanı") {
                    Stepper(value: $settings.minFreeDiskGB, in: 1...100) {
                        Text("\(settings.minFreeDiskGB) GB").monospacedDigit()
                    }
                }
            } header: {
                Text("Model ve bellek")
            } footer: {
                Text(settings.idleUnloadMinutes == 0
                     ? "Model, sen boşaltana kadar bellekte kalır."
                     : "Son diktenin üzerinden bu kadar zaman geçince model bellekten boşaltılır. İndirmeler, sonrasında diskte bu kadar yer kalmayacaksa başlamaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Geçmiş sınırı") {
                    HStack(spacing: 6) {
                        if settings.historyLimit == 0 {
                            Text("Sınırsız").foregroundStyle(.secondary)
                        }
                        TextField("", value: $settings.historyLimit, format: .number.locale(Fmt.tr))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Stepper("", value: $settings.historyLimit, in: 0...100_000, step: 10)
                            .labelsHidden()
                        Text("kayıt")
                    }
                }
            } header: {
                Text("Geçmiş")
            } footer: {
                Text("0 = Sınırsız. Sınır aşılınca en eski kayıtlar silinir.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Genel") {
                Toggle("Açılışta başlat", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Sistem Ayarları'nda onay bekliyor.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Giriş Öğeleri'ni aç") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                        .font(.callout)
                }
            }

            TermsSection(terms: terms, actions: termActions)
        }
        .formStyle(.grouped)
        .onChange(of: settings.historyLimit) { _, v in
            if v < 0 { settings.historyLimit = 0 }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear(perform: refreshLoginStatus)
    }

    private var microphonePicker: some View {
        Picker("Mikrofon", selection: $settings.microphoneUID) {
            Text("Sistem varsayılanı").tag(String?.none)
            if !microphones.isEmpty { Divider() }
            ForEach(microphones) { mic in
                Text(mic.name).tag(Optional(mic.uid))
            }
            if let uid = settings.microphoneUID, !microphones.contains(where: { $0.uid == uid }) {
                Text("Bağlı olmayan mikrofon").tag(Optional(uid))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((dataDir.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button("Finder'da göster") { NSWorkspace.shared.open(dataDir) }
                .buttonStyle(.link)
            Spacer(minLength: 12)
            Circle().fill(engineStatus.display.color).frame(width: 8, height: 8)
            Text(engineStatus.display.text).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
            loginError = (on ? "Açılışta başlatma açılamadı: " : "Açılışta başlatma kapatılamadı: ")
                + error.localizedDescription
        }
        refreshLoginStatus()
    }
}
