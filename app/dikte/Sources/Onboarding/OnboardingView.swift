import AppKit
import KeyboardShortcuts
import SwiftUI

// Welcome window content: step indicator, the current step, Geri / Devam buttons.
// Every text goes through `L(...)`, so the whole flow re-renders when step 1 changes the UI language.

struct OnboardingView: View {
    @Bindable var flow: OnboardingFlow

    static let size = CGSize(width: 640, height: 520)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(current: flow.step)
                .padding(.vertical, 14)
            Divider()
            Group {
                switch flow.step {
                case .language: OnboardingLanguageStep(flow: flow)
                case .model: OnboardingModelStep(flow: flow)
                case .permissions: OnboardingPermissionsStep(flow: flow)
                case .shortcut: OnboardingShortcutStep(flow: flow)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .navigationTitle(L("Dikte'ye hoş geldin"))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings → pick up changed permissions.
            flow.backend.refreshMicPermission()
            flow.backend.refreshAccessibility()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if flow.step.previous != nil {
                Button(L("Geri"), action: flow.goBack)
            }
            Spacer()
            if flow.step == .shortcut {
                Button(L("Bitir"), action: flow.finish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(continueTitle, action: flow.goNext)
                    .keyboardShortcut(.defaultAction)
                    // Microphone access is required to get past the permissions step.
                    .disabled(flow.step == .permissions && flow.backend.micPermission != .granted)
            }
        }
        .controlSize(.large)
    }

    private var continueTitle: String {
        switch flow.step {
        case .model:
            switch flow.modelPhase {
            case .ready, .downloading: break
            case .engine, .waitingForCatalog, .notDownloaded: return L("Şimdilik atla")
            }
        default:
            break
        }
        return L("Devam")
    }
}

// MARK: - Shared pieces

private struct OnboardingStepIndicator: View {
    var current: OnboardingStep

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingStep.allCases) { step in
                if step.previous != nil {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color(nsColor: .separatorColor))
                        .frame(width: 32, height: 2)
                        .padding(.horizontal, 10)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.clear)
                        Circle().strokeBorder(step.rawValue <= current.rawValue
                                              ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text(verbatim: "\(step.number)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(step == current ? Color.white : Color.secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(step.title)
                        .font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
    }
}

private struct StepHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct Note: View {
    var text: String
    var systemImage = "info.circle"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 1. Language

private struct OnboardingLanguageStep: View {
    var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                StepHeader(title: L("Dikte'ye hoş geldin"),
                           subtitle: L("Konuşmanı yazıya çevirir; ses bu Mac'ten dışarı çıkmaz. Başlamadan önce birkaç şeyi ayarlayalım."))
            }
            OnboardingCard {
                Text(L("Arayüz dili")).font(.headline)
                Picker(L("Arayüz dili"), selection: Binding(get: { flow.backend.uiLanguage },
                                                             set: { flow.backend.uiLanguage = $0 })) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(L("Menüler, pencereler ve mesajlar bu dilde görünür."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            OnboardingCard {
                Text(L("Dikte dili")).font(.headline)
                Picker(L("Dikte dili"), selection: Binding(get: { flow.backend.dictationLanguage },
                                                            set: { flow.backend.dictationLanguage = $0 })) {
                    Text(L("Otomatik (Türkçe + English)")).tag(DictationLanguage.auto)
                    Text(AppLanguage.tr.nativeName).tag(DictationLanguage.tr)
                    Text(AppLanguage.en.nativeName).tag(DictationLanguage.en)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(dictationHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dictationHint: String {
        switch flow.backend.dictationLanguage {
        case .auto: L("Her diktede Türkçe mi İngilizce mi konuştuğunu kendisi anlar.")
        case .tr: L("Konuşmanı her zaman Türkçe olarak yazıya çevirir.")
        case .en: L("Konuşmanı her zaman İngilizce olarak yazıya çevirir.")
        }
    }
}

// MARK: - 2. Model

private struct OnboardingModelStep: View {
    var flow: OnboardingFlow

    private var model: ModelInfo? { flow.backend.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: L("Konuşma modeli"),
                       subtitle: L("Dikte, konuşmanı bu Mac'te bir Whisper modeliyle yazıya çevirir. Modeli bir kez indirmen yeterli; sonra internet gerekmez."))
            OnboardingCard {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model?.label ?? "Whisper large-v3").font(.headline)
                    Badge(text: L("Önerilen"), systemImage: "star.fill", color: .accentColor)
                    Spacer(minLength: 8)
                    stateBadge
                }
                Text(L("Türkçe ve İngilizce için en iyi sonucu veren model."))
                    .font(.callout).foregroundStyle(.secondary)
                if let size = model?.sizeBytes {
                    Text(sizeLine(size: size, ram: model?.ramBytes))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                phaseContent
            }
            phaseNote
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch flow.modelPhase {
        case .ready:
            Badge(text: L("Hazır"), systemImage: "checkmark.circle.fill", color: Palette.loaded, style: .filled)
        case .downloading(let progress):
            Badge(text: L("İndiriliyor %@", Fmt.percent(progress)), systemImage: "arrow.down.circle",
                  color: Palette.downloading)
        case .notDownloaded(_, let reason) where reason != nil:
            Badge(text: L("Duraklatıldı"), systemImage: "pause.circle", color: Palette.downloading, style: .outline)
        default:
            EmptyView()
        }
    }

    private func sizeLine(size: Int64, ram: Int64?) -> String {
        guard let ram else { return L("%@ indirme", Fmt.gb(size)) }
        return L("%@ indirme · bellekte ~%@", Fmt.gb(size), Fmt.gb(ram))
    }

    @ViewBuilder private var phaseContent: some View {
        switch flow.modelPhase {
        case .engine(let status):
            OnboardingEngineStatus(status: status, retry: flow.backend.restartEngine)
        case .waitingForCatalog:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Model bilgisi alınıyor…")).font(.callout).foregroundStyle(.secondary)
            }
        case .notDownloaded(let partial, let reason):
            diskLine
            if let reason {
                Label(reason, systemImage: "pause.circle").font(.callout).foregroundStyle(Palette.loading)
            }
            if let error = flow.downloadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if flow.downloadRequested { ProgressView().controlSize(.small) }
                Button(partial ? L("Devam et") : L("İndir"), systemImage: "arrow.down.circle",
                       action: flow.startDownload)
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.downloadRequested || !(flow.diskPlan?.allowsDownload ?? true))
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress).tint(Palette.downloading)
                if let model, let size = model.sizeBytes {
                    Text(verbatim: "\(Fmt.gb(model.downloadedBytes)) / \(Fmt.gb(size))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .ready:
            Label(L("Model indirildi ve kullanıma hazır."), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(Palette.loadedText)
        }
    }

    @ViewBuilder private var diskLine: some View {
        if let plan = flow.diskPlan {
            Text(plan.after >= 0
                 ? L("%@ inecek · %@ boş · indirme sonrası %@ kalır", Fmt.gb(plan.needed), Fmt.gb(plan.free), Fmt.gb(plan.after))
                 : L("%@ inecek · %@ boş · %@ sığmıyor", Fmt.gb(plan.needed), Fmt.gb(plan.free), Fmt.gb(-plan.after)))
                .font(.callout).foregroundStyle(.secondary)
            if !plan.allowsDownload {
                Label(L("Yetersiz alan: en az %@ daha yer açmalısın (en az %@ boş kalmalı).",
                        Fmt.gb(plan.minFree - plan.after), Fmt.gb(plan.minFree)),
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let system = flow.backend.system {
            Text(L("Boyut henüz bilinmiyor · %@ boş", Fmt.gb(system.diskFreeBytes)))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var phaseNote: some View {
        switch flow.modelPhase {
        case .downloading:
            Note(text: L("İndirme arka planda sürecek; bu arada devam edebilirsin."))
        case .notDownloaded:
            Note(text: L("İstersen modeli daha sonra Modeller bölümünden de indirebilirsin."))
        case .engine, .waitingForCatalog, .ready:
            EmptyView()
        }
    }
}

private struct OnboardingEngineStatus: View {
    var status: EngineStatus
    var retry: () -> Void

    var body: some View {
        let display = status.display
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if status == .starting {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(display.color).frame(width: 8, height: 8)
                }
                Text(display.text)
                    .font(.callout)
                    .foregroundStyle(status == .starting ? Color.secondary : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status != .starting {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Model indirmek için motorun çalışması gerekiyor. Sorun sürerse uygulamayı yeniden başlat."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Tekrar dene"), systemImage: "arrow.clockwise", action: retry)
                }
            }
        }
    }
}

// MARK: - 3. Permissions

private struct OnboardingPermissionsStep: View {
    var flow: OnboardingFlow

    private var permission: MicPermission { flow.backend.micPermission }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: L("İzinler"),
                       subtitle: L("Dikte yalnızca kısayola bastığında dinler. Ses bu Mac'te işlenir, hiçbir yere gönderilmez."))
            OnboardingCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundStyle(color)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 6) { content }
                    Spacer(minLength: 0)
                }
            }
            OnboardingAccessibilityCard(flow: flow)
            if permission != .granted {
                Note(text: L("Devam etmek için mikrofon izni gerekli; Erişilebilirlik isteğe bağlı."))
            }
        }
    }

    private var icon: String {
        switch permission {
        case .notDetermined: "mic"
        case .granted: "checkmark.circle.fill"
        case .denied: "mic.slash"
        }
    }

    private var color: Color {
        switch permission {
        case .notDetermined: .accentColor
        case .granted: Palette.loaded
        case .denied: Palette.danger
        }
    }

    @ViewBuilder private var content: some View {
        // Same layout as the Accessibility card: title + status on the right, then hint and action.
        HStack(alignment: .firstTextBaseline) {
            Text(L("Mikrofon izni")).font(.headline)
            Spacer(minLength: 8)
            switch permission {
            case .granted:
                Label(L("Verildi"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.loadedText)
            case .notDetermined:
                Label { Text(L("Verilmedi")) } icon: { Image(systemName: "circle.fill").imageScale(.small) }
                    .foregroundStyle(Palette.loading)
            case .denied:
                Label { Text(L("Reddedildi")) } icon: { Image(systemName: "circle.fill").imageScale(.small) }
                    .foregroundStyle(Palette.danger)
            }
        }
        .font(.callout)
        switch permission {
        case .notDetermined:
            Text(L("Dikte için gerekli. “İzin ver”e bastığında macOS sana soracak."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("İzin ver"), systemImage: "mic.fill", action: flow.requestMicrophone)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        case .granted:
            Text(L("Dikte mikrofonu kullanabilir.")).font(.callout).foregroundStyle(.secondary)
        case .denied:
            Text(L("Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon bölümünde Dikte'yi aç, sonra bu pencereye dön."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Sistem Ayarları'nı aç"), systemImage: "gearshape", action: flow.openMicrophoneSettings)
                .padding(.top, 4)
        }
    }
}

/// Accessibility: only needed to paste into an app, so it never blocks "Devam".
private struct OnboardingAccessibilityCard: View {
    var flow: OnboardingFlow

    var body: some View {
        let trusted = flow.backend.accessibilityTrusted
        OnboardingCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "accessibility")
                    .font(.system(size: 28))
                    .foregroundStyle(trusted ? Palette.loaded : Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Erişilebilirlik izni")).font(.headline)
                        Spacer(minLength: 8)
                        if trusted {
                            Label(L("Verildi"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Palette.loadedText)
                        } else {
                            Label {
                                Text(L("Verilmedi"))
                            } icon: {
                                Image(systemName: "circle.fill").imageScale(.small)
                            }
                            .foregroundStyle(Palette.loading)
                        }
                    }
                    .font(.callout)
                    Text(L("Metni bir uygulamaya yapıştırmak için gerekli; sadece panoyu kullanacaksan gerekmez."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !trusted {
                        Button(L("İzin ver…"), systemImage: "accessibility", action: flow.backend.requestAccessibility)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }
}

// MARK: - 4. Shortcut

private struct OnboardingShortcutStep: View {
    var flow: OnboardingFlow
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .dictate)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: L("Kısayol"),
                       subtitle: L("Dikteyi her uygulamadan tek bir kısayolla başlatırsın."))
            OnboardingCard {
                HStack {
                    Text(L("Dikte kısayolu")).font(.headline)
                    Spacer()
                    ShortcutField(shortcut: $shortcut)
                }
                Divider().padding(.vertical, 2)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        keys { Keycap(text: shortcut?.description ?? L("Kısayol yok")) }
                        Text(L("Dinlemeye başlar; konuşmaya başla."))
                    }
                    GridRow {
                        keys {
                            Keycap(text: L("%@ sn sessizlik", Fmt.number(flow.backend.silenceSeconds)), plain: true)
                            Text(L("ya da")).foregroundStyle(.secondary)
                            Keycap(text: "↩")
                        }
                        Text(L("Kaydı bitirir; metin düzenlenebilir hâlde gelir."))
                    }
                    GridRow {
                        keys { Keycap(text: flow.backend.sendKey.symbol) }
                        Text(L("Metni panoya kopyalar ve paneli kapatır."))
                    }
                    GridRow {
                        keys { Keycap(text: flow.backend.sendKey.newlineSymbol) }
                        Text(L("Metne yeni satır ekler."))
                    }
                    GridRow {
                        keys { Keycap(text: "esc") }
                        Text(L("Vazgeçer; hiçbir şey kopyalanmaz."))
                    }
                }
                .font(.callout)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button(L("Deneme diktesi yap"), systemImage: "mic.fill", action: flow.backend.startTestDictation)
                    .disabled(!flow.canTestDictation)
                Text(testHint)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keys(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }.gridColumnAlignment(.trailing)
    }

    private var testHint: String {
        switch flow.modelPhase {
        case .ready:
            break
        case .downloading(let progress):
            return L("Model inince deneyebilirsin (%@).", Fmt.percent(progress))
        case .engine, .waitingForCatalog:
            return L("Motor hazır olunca deneyebilirsin.")
        case .notDownloaded:
            return L("Denemek için önce modeli indir (2. adım).")
        }
        if flow.backend.micPermission != .granted {
            return L("Denemek için mikrofon izni gerekiyor (3. adım).")
        }
        return L("Panel açılır; bir şey söyle, sonra sus.")
    }
}

private struct Keycap: View {
    var text: String
    /// Plain text in a keycap row (no key frame).
    var plain = false

    var body: some View {
        Text(text)
            .font(plain ? .callout : .callout.weight(.medium))
            .padding(.horizontal, plain ? 0 : 7)
            .padding(.vertical, plain ? 0 : 2)
            .background {
                if !plain {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor))
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor))
                }
            }
            .fixedSize()
    }
}
