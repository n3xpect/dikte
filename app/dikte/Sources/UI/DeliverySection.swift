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

/// Metin aktarımı sections: default target + send key, favourites, panel list size + clipboard restore.
/// (Accessibility is on the İzinler page.)
struct DeliverySection: View {
    @Binding var settings: AppSettings
    var options: DeliveryOptions

    @State private var running: [TargetApp] = []

    private enum Choice: Hashable { case clipboard, app(String), choose }

    var body: some View {
        Section {
            defaultPicker
            Picker(selection: $settings.sendKey) {
                ForEach(SendKey.allCases, id: \.self) { key in
                    Text(verbatim: key.name).tag(key)
                }
            } label: {
                Text(L("Göndermek için"))
                Text(L("Diğer tuş yeni satır açar."))
            }
        } header: {
            Text(L("Varsayılan hedef"))
        } footer: {
            Text(L("Panelde %@ metni varsayılan hedefe gönderir, ⌘1…⌘9 listedeki diğer uygulamalara. Metin panoya konur ve uygulamaya ⌘V ile yapıştırılır; aktarılamazsa metin panoda kalır.",
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
            favoritesRow
        } header: {
            Text(L("Favoriler"))
        } footer: {
            Text(L("Favoriler panelde varsayılan hedeften hemen sonra listelenir; çalışmıyorlarsa açılırlar."))
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

    // MARK: Default target

    private var defaultPicker: some View {
        Picker(L("Varsayılan hedef"), selection: Binding<Choice>(
            get: { settings.deliveryDefaultApp.map(Choice.app) ?? .clipboard },
            set: { choice in
                switch choice {
                case .clipboard: settings.deliveryDefaultApp = nil
                case .app(let id): settings.deliveryDefaultApp = id
                case .choose: if let app = options.chooseApp() { settings.deliveryDefaultApp = app.bundleID }
                }
            }
        )) {
            Label {
                Text(L("Panoya kopyala"))
            } icon: {
                Image(systemName: "doc.on.clipboard")
            }
            .tag(Choice.clipboard)
            Divider()
            ForEach(defaultCandidates) { app in
                appLabel(app).tag(Choice.app(app.bundleID))
            }
            if !defaultCandidates.isEmpty { Divider() }
            Text(L("Başka bir uygulama seç…")).tag(Choice.choose)
        }
    }

    /// Favourites + running apps (+ the current default if it is neither), A–Z.
    private var defaultCandidates: [TargetApp] {
        var ids = settings.deliveryFavorites + running.map(\.bundleID)
        if let id = settings.deliveryDefaultApp { ids.append(id) }
        var seen: Set<String> = []
        let apps = ids.filter { seen.insert($0).inserted }.map { app(for: $0) }
        return sortedByName(apps)
    }

    // MARK: Favourites

    private var favoritesRow: some View {
        HStack(alignment: .top) {
            if settings.deliveryFavorites.isEmpty {
                Text(L("Henüz favori yok.")).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    // Uninstalled ones (bundle id as name) last.
                    let apps = sortedByName(settings.deliveryFavorites.map { app(for: $0) })
                    ForEach(apps.filter(isInstalled) + apps.filter { !isInstalled($0) }) { app in
                        favoriteChip(app)
                    }
                }
            }
            Spacer(minLength: 12)
            addMenu
        }
    }

    private var addMenu: some View {
        Menu(L("Ekle…")) {
            let candidates = sortedByName(running.filter { !settings.deliveryFavorites.contains($0.bundleID) })
            ForEach(candidates) { app in
                Button { addFavorite(app.bundleID) } label: { appLabel(app) }
            }
            if !candidates.isEmpty { Divider() }
            Button(L("Başka bir uygulama seç…")) {
                if let app = options.chooseApp() { addFavorite(app.bundleID) }
            }
        }
        .fixedSize()
    }

    private func favoriteChip(_ app: TargetApp) -> some View {
        let installed = isInstalled(app)
        return HStack(spacing: 5) {
            Image(nsImage: options.icon(app))
                .resizable()
                .frame(width: 16, height: 16)
                .opacity(installed ? 1 : 0.4)
            Text(app.name)
                .foregroundStyle(installed ? .primary : .secondary)
            if !installed {
                Text(L("yüklü değil")).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                settings.deliveryFavorites.removeAll { $0 == app.bundleID }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Favorilerden çıkar"))
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func addFavorite(_ id: String) {
        guard !settings.deliveryFavorites.contains(id) else { return }
        settings.deliveryFavorites.append(id)
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
