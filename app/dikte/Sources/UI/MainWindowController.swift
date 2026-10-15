import AppKit
import Observation
import SwiftUI

// CONTRACT — implemented by agent "ui". Main window with tabs Ayarlar / Modeller / Geçmiş.

enum MainTab: String, CaseIterable, Identifiable {
    case settings, models, history
    var id: String { rawValue }
}

extension MainTab {
    var title: String {
        switch self {
        case .settings: "Ayarlar"
        case .models: "Modeller"
        case .history: "Geçmiş"
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .models: "cpu"
        case .history: "clock.arrow.circlepath"
        }
    }
}

final class MainWindowController {
    static let shared = MainWindowController()
    private init() {}

    private var window: NSWindow?
    private let navigation = MainNavigation()

    /// Create (once) and bring the window to front, activating the app.
    func show(tab: MainTab? = nil) {
        if let tab { navigation.tab = tab }
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
            List(selection: Binding<MainTab?>(get: { tab }, set: { if let t = $0 { tab = t } })) {
                ForEach(MainTab.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(tab.title)
        }
    }
}

private struct LiveMainView: View {
    @Bindable var navigation: MainNavigation
    let state: AppState

    var body: some View {
        MainSplitView(tab: $navigation.tab) { tab in
            switch tab {
            case .settings: SettingsTab(state: state)
            case .models: ModelsTab(state: state)
            case .history: HistoryTab(state: state)
            }
        }
    }
}
