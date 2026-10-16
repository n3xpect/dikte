import AppKit
import Observation
import SwiftUI

// CONTRACT — implemented by agent "ui". Main window: sidebar Ayarlar / Kayıt / Metin aktarımı / İzinler /
// Modeller / Terimler / Geçmiş, with Hakkında pinned at the bottom.

enum MainTab: String, CaseIterable, Identifiable {
    case settings, recording, delivery, permissions, models, terms, history, about
    var id: String { rawValue }
}

extension MainTab {
    var title: String {
        switch self {
        case .settings: L("Ayarlar")
        case .recording: L("Kayıt")
        case .delivery: L("Metin aktarımı")
        case .permissions: L("İzinler")
        case .models: L("Modeller")
        case .terms: L("Terimler")
        case .history: L("Geçmiş")
        case .about: L("Hakkında")
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .recording: "waveform"
        case .delivery: "paperplane"
        case .permissions: "lock.shield"
        case .models: "cpu"
        case .terms: "character.book.closed"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }

    /// Tabs shown for the current UI language: Terimler only with the Turkish UI.
    /// (Terms still apply to every dictation; they're just not editable from the English UI.)
    static var visible: [MainTab] {
        allCases.filter { $0 != .terms || Localizer.shared.language == .tr }
    }

    var isVisible: Bool { Self.visible.contains(self) }

    /// Sidebar list; Hakkında sits apart at the bottom.
    static var listed: [MainTab] { visible.filter { $0 != .about } }
}

final class MainWindowController {
    static let shared = MainWindowController()
    private init() {}

    private var window: NSWindow?
    private let navigation = MainNavigation()

    /// Create (once) and bring the window to front, activating the app.
    func show(tab: MainTab? = nil) {
        if let tab, tab.isVisible { navigation.tab = tab }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LiveMainView(navigation: navigation, state: .shared))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Dikte"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.setContentSize(NSSize(width: 900, height: 660))
        window.center()
        window.setFrameAutosaveName("DikteMainWindow")
        return window
    }
}

@Observable
final class MainNavigation {
    var tab: MainTab = .settings
}

/// Sidebar + detail; the detail content is injected so previews can use fake data.
struct MainSplitView<Detail: View>: View {
    @Binding var tab: MainTab
    @ViewBuilder var detail: (MainTab) -> Detail

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: selection(where: { $0 != .about })) {
                    ForEach(MainTab.listed) { t in
                        Label(t.title, systemImage: t.symbol).tag(t)
                    }
                }
                // Hakkında: its own one-row list so it looks like the rows above but stays at the bottom.
                Divider().padding(.horizontal, 12)
                List(selection: selection(where: { $0 == .about })) {
                    Label(MainTab.about.title, systemImage: MainTab.about.symbol).tag(MainTab.about)
                }
                .scrollDisabled(true)
                .frame(height: 48)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            let shown = tab.isVisible ? tab : .settings
            detail(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(shown.title)
        }
        // Leaving a tab that the new UI language hides (Terimler) falls back to Ayarlar.
        .onChange(of: Localizer.shared.language) { _, _ in
            if !tab.isVisible { tab = .settings }
        }
        // System-formatted values (number fields, controls) follow the app's UI language.
        .environment(\.locale, Localizer.shared.language.locale)
    }

    /// Selection for one of the two sidebar lists: shows `tab` only if it belongs there.
    private func selection(where belongs: @escaping (MainTab) -> Bool) -> Binding<MainTab?> {
        Binding(get: { belongs(tab) ? tab : nil }, set: { if let t = $0 { tab = t } })
    }
}

private struct LiveMainView: View {
    @Bindable var navigation: MainNavigation
    let state: AppState

    var body: some View {
        MainSplitView(tab: $navigation.tab) { tab in
            switch tab {
            case .settings: SettingsTab(state: state)
            case .recording: RecordingTab(state: state)
            case .delivery: DeliveryTab(state: state)
            case .permissions: PermissionsTab(state: state)
            case .models: ModelsTab(state: state)
            case .terms: TermsTab(state: state)
            case .history: HistoryTab(state: state)
            case .about: AboutTab(state: state)
            }
        }
    }
}
