import AppKit
import Observation

// CONTRACT — implemented by agent "ui". NSStatusItem with state icon + menu
// (Dikte'yi aç, Modeli şimdi boşalt, Çıkış).
final class StatusItemController {
    static let shared = StatusItemController()
    private init() {}

    private var item: NSStatusItem?
    private weak var state: AppState?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var unloadItem: NSMenuItem?
    private var shownIcon: StatusIcon?
    private let menuTarget = MenuTarget()

    func install(state: AppState) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--render-ui-previews") {
            UIPreviewRenderer.renderAllAndQuit()
            return
        }
        #endif
        guard item == nil else { return }
        self.state = state
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuTarget.item("Dikte'yi aç") { MainWindowController.shared.show() })
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let unload = menuTarget.item("Modeli şimdi boşalt") { [weak state] in
            guard let state else { return }
            Task { try? await state.engine.unload() }
        }
        unloadItem = unload
        menu.addItem(unload)
        menu.addItem(.separator())
        menu.addItem(menuTarget.item("Çıkış", key: "q") { NSApp.terminate(nil) })
        item.menu = menu

        observe()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        guard let state, let button = item?.button else { return }
        let engine = state.engine
        let loaded = engine.loadedModel
        let loading = engine.models.first { $0.state == .loading }

        let icon: StatusIcon
        switch state.dictation.phase {
        case .listening: icon = .listening
        case .transcribing: icon = .transcribing
        default:
            switch engine.status {
            case .stopped, .failed: icon = .engineDown
            case .starting: icon = .starting
            case .running:
                icon = loaded != nil ? .loaded : (loading != nil || state.dictation.modelLoading) ? .loading : .idle
            }
        }
        if icon != shownIcon {
            shownIcon = icon
            button.image = icon.image
            button.appearsDisabled = icon == .starting
        }

        let line = Self.statusText(engine: engine, selected: state.settings.settings.selectedModel)
        statusLine.title = line
        button.toolTip = "Dikte — " + line
        unloadItem?.isEnabled = loaded != nil
    }

    static func statusText(engine: EngineController, selected: String) -> String {
        guard engine.isRunning else { return engine.status.display.text }
        if let m = engine.loadedModel { return "Model: \(m.label) · Bellekte" }
        if let m = engine.models.first(where: { $0.state == .loading }) { return "Model: \(m.label) · Yükleniyor…" }
        guard let m = engine.models.first(where: { $0.id == selected }) else { return "Model seçilmedi" }
        let s: String = switch m.state {
        case .notDownloaded: "İndirilmedi"
        case .downloading: "İndiriliyor \(Fmt.percent(m.progress ?? 0))"
        case .paused: "İndirme duraklatıldı"
        case .onDisk: "Diskte"
        case .loading: "Yükleniyor…"
        case .loaded: "Bellekte"
        }
        return "Model: \(m.label) · \(s)"
    }
}

enum StatusIcon: CaseIterable {
    case idle, starting, loading, loaded, engineDown, listening, transcribing

    var image: NSImage {
        switch self {
        case .idle, .starting: Self.template("mic")
        case .transcribing: Self.template("waveform")
        case .listening: Self.drawn("mic.fill", symbolColor: .systemRed, dot: nil)
        case .loaded: Self.drawn("mic", symbolColor: .labelColor, dot: .systemGreen)
        case .loading: Self.drawn("mic", symbolColor: .labelColor, dot: .systemOrange)
        case .engineDown: Self.drawn("mic", symbolColor: .labelColor, dot: .systemRed)
        }
    }

    private static let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: "Dikte")?.withSymbolConfiguration(config)
            ?? NSImage()
    }

    private static func template(_ name: String) -> NSImage {
        let image = symbol(name)
        image.isTemplate = true
        return image
    }

    /// Non-template image so the state colors show; `labelColor` resolves against the menu bar
    /// appearance at draw time.
    private static func drawn(_ name: String, symbolColor: NSColor, dot: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let tinted = NSImage(systemSymbolName: name, accessibilityDescription: "Dikte")?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [symbolColor])))
            if let tinted {
                let s = tinted.size
                let x = dot == nil ? (rect.width - s.width) / 2 : (rect.width - s.width) / 2 - 2
                tinted.draw(in: NSRect(x: x.rounded(), y: ((rect.height - s.height) / 2).rounded(),
                                       width: s.width, height: s.height))
            }
            if let dot {
                let r = NSRect(x: rect.maxX - 8, y: 1, width: 7, height: 7)
                dot.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Dikte"
        return image
    }
}

/// Target for menu items that run closures.
private final class MenuTarget: NSObject {
    private var handlers: [Int: () -> Void] = [:]

    func item(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        item.target = self
        item.tag = handlers.count
        handlers[item.tag] = handler
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}
