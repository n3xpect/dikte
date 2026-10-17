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

    private var addMenu: some View {
        Menu(L("Ekle…")) {
            let candidates = sortedByName(running.filter { !settings.deliveryTargets.contains($0.bundleID) })
            ForEach(candidates) { app in
                Button { addTarget(app.bundleID) } label: { appLabel(app) }
            }
            if !candidates.isEmpty { Divider() }
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
        running.first { $0.bundleID == id }
            ?? options.resolve(id)
            ?? TargetApp(bundleID: id, name: id, url: nil, isRunning: false)
    }

    private func isInstalled(_ app: TargetApp) -> Bool { app.url != nil || app.isRunning }

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
