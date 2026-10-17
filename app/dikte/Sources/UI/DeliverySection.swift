import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App lookup for the "Metin aktarımı" page, injectable for previews.
struct DeliveryOptions {
    var runningApps: () -> [TargetApp]
    var resolve: (String) -> TargetApp?
    var icon: (TargetApp) -> NSImage
    /// Lets the user pick an app bundle; nil if cancelled.
    var chooseApp: () -> TargetApp?

    static var live: DeliveryOptions {
        let service = AppState.shared.delivery
        return DeliveryOptions(
            runningApps: { service.runningApps() },
            resolve: { service.resolve(bundleID: $0) },
            icon: { service.icon(for: $0) },
            chooseApp: {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                panel.allowedContentTypes = [.applicationBundle]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.prompt = L("Seç")
                guard panel.runModal() == .OK, let url = panel.url,
                      let id = Bundle(url: url)?.bundleIdentifier else { return nil }
                return service.resolve(bundleID: id)
                    ?? TargetApp(bundleID: id, name: DeliveryService.bundleName(url), url: url, isRunning: false)
            }
        )
    }
}

/// Metin aktarımı wired to the live stores.
struct DeliveryTab: View {
    let state: AppState

    var body: some View {
        @Bindable var settings = state.settings
        Form { DeliverySection(settings: $settings.settings, options: .live) }
            .formStyle(.grouped)
    }
}

/// Metin aktarımı sections: the targets in the user's order (the first is the default), send key,
/// panel list size + clipboard restore. (Accessibility is on the İzinler page.)
struct DeliverySection: View {
    @Binding var settings: AppSettings
    var options: DeliveryOptions

    @State private var running: [TargetApp] = []

    var body: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(targetRows) { row in
                    TargetRow(row: row, icon: row.app.map(options.icon),
                              submit: submitBinding(row.id),
                              move: { settings.moveTarget(row.id, by: $0) },
                              remove: { settings.deliveryTargets.removeAll { $0 == row.id } })
                }
            }
            HStack {
                Spacer()
                addMenu
            }
        } header: {
            Text(L("Hedefler"))
        } footer: {
            Text(L("Sürükleyerek sırala. En üstteki varsayılan hedeftir (%@); altındakiler sırayla ⌘1, ⌘2… ile gönderilir. Çalışmayan uygulamalar açılır.",
                   settings.sendKey.symbol))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refreshRunning)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunning()
        }

        Section {
            Picker(selection: $settings.sendKey) {
                ForEach(SendKey.allCases, id: \.self) { key in
                    Text(verbatim: key.name).tag(key)
                }
            } label: {
                Text(L("Göndermek için"))
                Text(L("Diğer tuş yeni satır açar."))
            }
            Toggle(isOn: $settings.autoSendEnabled) {
                Text(L("Otomatik gönder"))
                Text(L("Metin panele geldikten sonra bekleme süresi dolunca varsayılan hedefe gönderilir. Bir tuşa basmak ya da tıklamak durdurur."))
            }
            // Always shown (just disabled — and visibly dimmed — when off), so the value stays visible.
            LabeledContent {
                HStack {
                    Slider(value: autoSendChoice, in: 0...Double(AppSettings.autoSendChoices.count - 1), step: 1)
                        .frame(maxWidth: 220)
                    AutoSendWaitLabel(seconds: settings.autoSendSeconds)
                }
                .dimmedWhenOff(!settings.autoSendEnabled)
            } label: {
                Text(L("Bekleme süresi"))
                    .foregroundStyle(settings.autoSendEnabled ? .primary : .tertiary)
            }
            .disabled(!settings.autoSendEnabled)
            if settings.autoSendEnabled && settings.autoSendSeconds == 0 {
                AutoSendNowWarning()
            }
        } header: {
            Text(L("Gönderme"))
        } footer: {
            Text(L("Panelde %@ metni varsayılan hedefe gönderir, ⌘1…⌘9 listedeki diğer uygulamalara. Metin panoya konur ve uygulamaya ⌘V ile yapıştırılır; aktarılamazsa metin panoda kalır.",
                   settings.sendKey.symbol))
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            LabeledContent(L("Panelde gösterilecek diğer uygulama sayısı")) {
                Stepper(value: $settings.deliveryOtherLimit, in: 0...9) {
                    Text(Fmt.int(settings.deliveryOtherLimit)).monospacedDigit()
                }
            }
            Toggle(L("Yapıştırdıktan sonra panoyu eski haline getir"), isOn: $settings.restoreClipboardAfterPaste)
        } header: {
            Text(L("Liste ve pano"))
        } footer: {
            Text(L("Favori olmayan, çalışan uygulamalardan bu kadarı listede doğrudan görünür; gerisi katlanır."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The slider moves over the choices (3 s … 5 min), not seconds.
    private var autoSendChoice: Binding<Double> {
        let choices = AppSettings.autoSendChoices
        return Binding(get: { Double(choices.firstIndex(of: settings.autoSendSeconds)
                                         ?? choices.firstIndex(of: AppSettings().autoSendSeconds) ?? 0) },
                       set: { settings.autoSendSeconds = choices[min(max(Int($0.rounded()), 0), choices.count - 1)] })
    }

    // MARK: Targets

    /// The targets with the key each gets in the panel: the first installed one the send key,
    /// the next ones ⌘1…⌘9; apps that aren't installed are skipped there, so they get none.
    private var targetRows: [TargetRow.Model] {
        var shown = 0
        return settings.deliveryTargets.enumerated().map { i, id in
            let app = id == AppSettings.clipboard ? nil : app(for: id)
            let installed = app.map(isInstalled) ?? true
            let isDefault = installed && shown == 0
            var key: String?
            if installed {
                key = isDefault ? settings.sendKey.symbol : shown <= 9 ? "⌘\(shown)" : nil
                shown += 1
            }
            return TargetRow.Model(id: id, app: app, installed: installed, key: key, isDefault: isDefault,
                                   isFirst: i == 0)
        }
    }

    private func submitBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.submitTargets.contains(id) },
            set: { on in
                settings.submitTargets.removeAll { $0 == id }
                if on { settings.submitTargets.append(id) }
            }
        )
    }

    private var addMenu: some View {
        Menu(L("Ekle…")) {
            let candidates = sortedByName(running.filter { !settings.deliveryTargets.contains($0.bundleID) })
            ForEach(candidates) { app in
                Button { addTarget(app.bundleID) } label: { appLabel(app) }
            }
            if !candidates.isEmpty { Divider() }
            if !settings.deliveryTargets.contains(AppSettings.lastApp) {
                Button { addTarget(AppSettings.lastApp) } label: {
                    Label(L("Son kullanılan uygulama"), systemImage: "arrow.uturn.backward.circle")
                }
                Divider()
            }
            Button(L("Başka bir uygulama seç…")) {
                if let app = options.chooseApp() { addTarget(app.bundleID) }
            }
        }
        .fixedSize()
    }

    private func addTarget(_ id: String) {
        guard !settings.deliveryTargets.contains(id) else { return }
        settings.deliveryTargets.append(id)
    }

    // MARK: Helpers

    private func appLabel(_ app: TargetApp) -> some View {
        Label {
            Text(app.name)
        } icon: {
            Image(nsImage: menuIcon(options.icon(app)))
        }
    }

    /// Menu items ignore frame modifiers: size the image itself.
    private func menuIcon(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// Running app, installed app, or a placeholder for one that is no longer installed.
    private func app(for id: String) -> TargetApp {
        if id == AppSettings.lastApp { return .lastApp }
        return running.first { $0.bundleID == id }
            ?? options.resolve(id)
            ?? TargetApp(bundleID: id, name: id, url: nil, isRunning: false)
    }

    private func isInstalled(_ app: TargetApp) -> Bool { app.isLastApp || app.url != nil || app.isRunning }

    private func sortedByName(_ apps: [TargetApp]) -> [TargetApp] {
        let locale = Fmt.locale
        return apps.sorted {
            $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: locale) == .orderedAscending
        }
    }

    private func refreshRunning() {
        running = options.runningApps()
    }
}

/// The wait next to its slider: one line, as wide as the longest choice ("Right away" in English),
/// so the slider doesn't move or wrap as the value changes.
struct AutoSendWaitLabel: View {
    let seconds: Double

    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(AppSettings.autoSendChoices, id: \.self) { Text(Fmt.autoSendWait($0)).hidden() }
            Text(Fmt.autoSendWait(seconds))
        }
        .lineLimit(1)
        .fixedSize()
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Fmt.autoSendWait(seconds))
    }
}

extension View {
    /// A disabled control in a Form barely changes colour on macOS: fade it so "off" is obvious.
    func dimmedWhenOff(_ off: Bool) -> some View {
        opacity(off ? 0.4 : 1)
    }
}

/// Under the wait when it is "Hemen": nothing to look at or stop before it goes.
struct AutoSendNowWarning: View {
    var body: some View {
        Label(L("Hemen: metin gösterilmeden gönderilir; durdurma şansı yoktur."),
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of the Hedefler list: ≡ handle, icon, name, the key it gets in the panel, ⓧ for apps.
private struct TargetRow: View {
    struct Model: Identifiable {
        var id: String
        /// nil = "Panoya kopyala".
        var app: TargetApp?
        var installed: Bool
        var key: String?
        var isDefault: Bool
        var isFirst: Bool
    }

    static let height: CGFloat = 34

    let row: Model
    let icon: NSImage?
    @Binding var submit: Bool
    /// Moves the row by that many places; false when it can't go further.
    let move: (Int) -> Bool
    let remove: () -> Void

    @State private var dragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var consumed: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: Self.height)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            dragging = true
                            let h = Self.height
                            var dy = value.translation.height - consumed
                            while dy > h / 2, move(1) { consumed += h; dy -= h }
                            while dy < -h / 2, move(-1) { consumed -= h; dy += h }
                            dragOffset = dy
                        }
                        .onEnded { _ in
                            dragging = false
                            dragOffset = 0
                            consumed = 0
                        }
                )
                .help(L("Sıralamak için sürükle"))
            iconView
            Text(row.app?.name ?? L("Panoya kopyala"))
                .foregroundStyle(row.installed ? .primary : .secondary)
                .lineLimit(1)
            if !row.installed {
                Text(L("yüklü değil")).font(.caption).foregroundStyle(.secondary)
            }
            if row.isDefault {
                Text(L("Varsayılan"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: .capsule)
            }
            Spacer(minLength: 8)
            if row.app != nil {
                Toggle(L("Uygulamada da gönder"), isOn: $submit)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: row.key ?? "")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(row.isDefault ? Color.accentColor : .secondary)
                .frame(width: 34, height: 20)
                .background {
                    if row.key != nil {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.07))
                    }
                }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Listeden çıkar"))
            .opacity(row.app == nil ? 0 : 1)
            .disabled(row.app == nil)
        }
        .frame(height: Self.height)
        .background {
            if dragging {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
        }
        .overlay(alignment: .top) { if !dragging && !row.isFirst { Divider().opacity(0.6) } }
        .offset(y: dragOffset)
        .zIndex(dragging ? 1 : 0)
    }

    @ViewBuilder private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
                .opacity(row.installed ? 1 : 0.4)
        } else {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }
}
