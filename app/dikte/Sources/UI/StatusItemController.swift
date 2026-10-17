import AppKit
import KeyboardShortcuts
import Observation

// CONTRACT — implemented by agent "ui". NSStatusItem with state icon + menu
// (Dikteyi başlat/bitir, Ayarlar…, Modeli şimdi boşalt, Çıkış).
final class StatusItemController {
    static let shared = StatusItemController()
    private init() {}

    private var item: NSStatusItem?
    private weak var state: AppState?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusView = StatusLineView()
    private var countdownTimer: Timer?
    private var dictateItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var unloadItem: NSMenuItem?
    private var quitItem: NSMenuItem?
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
        // Titles are set in update() so they follow the UI language.
        // Same as the shortcut, so dictation can start even with no shortcut set.
        let dictate = menuTarget.item { [weak state] in state?.dictation.hotkeyPressed() }
        dictate.setShortcut(for: .dictate)
        dictateItem = dictate
        menu.addItem(dictate)
        let open = menuTarget.item { MainWindowController.shared.show(tab: .settings) }
        openItem = open
        menu.addItem(open)
        menu.addItem(.separator())
        statusLine.view = statusView
        menu.addItem(statusLine)
        let unload = menuTarget.item { [weak state] in
            guard let state else { return }
            Task { try? await state.engine.unload() }
        }
        unloadItem = unload
        menu.addItem(unload)
        menu.addItem(.separator())
        let quit = menuTarget.item(key: "q") { NSApp.terminate(nil) }
        quitItem = quit
        menu.addItem(quit)
        menu.delegate = menuTarget
        menuTarget.onOpen = { [weak self] in self?.startCountdown() }
        menuTarget.onClose = { [weak self] in self?.stopCountdown() }
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

        dictateItem?.title = state.dictation.phase == .listening ? L("Dikteyi bitir") : L("Dikteyi başlat")
        openItem?.title = L("Ayarlar…")
        unloadItem?.title = L("Modeli şimdi boşalt")
        quitItem?.title = L("Çıkış")
        let line = Self.statusText(engine: engine, selected: state.settings.settings.selectedModel)
        statusView.name = line
        refreshCountdown()
        button.toolTip = "Dikte — " + line
        // Nothing to unload when the model isn't in memory.
        unloadItem?.isHidden = loaded == nil
        unloadItem?.isEnabled = loaded != nil
    }

    /// Time left before the idle unload, on the right of the model line while the menu is open.
    private func refreshCountdown() {
        guard let engine = state?.engine, engine.loadedModel != nil,
              let at = engine.system?.idleUnloadAt else {
            statusView.time = ""
            return
        }
        let left = at - Date().timeIntervalSince1970
        statusView.time = left > 0 ? Fmt.countdown(left) : ""
    }

    private func startCountdown() {
        refreshCountdown()
        countdownTimer?.invalidate()
        // .common: a plain timer doesn't fire while the menu is tracking.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    static func statusText(engine: EngineController, selected: String) -> String {
        guard engine.isRunning else { return engine.status.display.text }
        if let m = engine.loadedModel { return L("Model: %@", m.label) }
        if let m = engine.models.first(where: { $0.state == .loading }) {
            return L("Model: %@ · %@", m.label, L("Yükleniyor…"))
        }
        guard let m = engine.models.first(where: { $0.id == selected }) else { return L("Model seçilmedi") }
        let s: String = switch m.state {
        case .notDownloaded: L("İndirilmedi")
        case .downloading: L("İndiriliyor %@", Fmt.percent(m.progress ?? 0))
        case .paused: L("İndirme duraklatıldı")
        case .onDisk: ""
        case .loading: L("Yükleniyor…")
        case .loaded: L("Bellekte")
        }
        return s.isEmpty ? L("Model: %@", m.label) : L("Model: %@ · %@", m.label, s)
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

/// The model line: the status on the left, the idle-unload countdown on the right (like a
/// shortcut), both in the disabled-item colour.
private final class StatusLineView: NSView {
    private let nameField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 24

    var name = "" { didSet { if name != oldValue { nameField.stringValue = name; relayout() } } }
    var time = "" { didSet { if time != oldValue { timeField.stringValue = time; relayout() } } }

    init() {
        super.init(frame: .zero)
        autoresizingMask = [.width]
        let font = NSFont.menuFont(ofSize: 0)
        nameField.font = font
        timeField.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        for field in [nameField, timeField] {
            field.textColor = .disabledControlTextColor
            field.lineBreakMode = .byClipping
            addSubview(field)
        }
        timeField.alignment = .right
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Text widths measured from the strings, not from the fields (their intrinsic size lags
    /// behind a changed string). The time always reserves the width of "00:00" so the menu keeps
    /// its width while counting down.
    private func width(of text: String, font: NSFont?) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font as Any]).width) + 2
    }

    private var timeSlot: CGFloat {
        time.isEmpty ? 0 : width(of: "00:00", font: timeField.font)
    }

    private func relayout() {
        let wanted = Self.inset * 2 + width(of: name, font: nameField.font)
            + (timeSlot > 0 ? Self.gap + timeSlot : 0)
        setFrameSize(NSSize(width: max(frame.width, wanted), height: 22))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let slot = timeSlot
        let h = ceil(nameField.intrinsicContentSize.height)
        let y = ((bounds.height - h) / 2).rounded()
        timeField.frame = NSRect(x: bounds.width - Self.inset - slot, y: y, width: slot, height: h)
        let nameMax = bounds.width - Self.inset * 2 - (slot > 0 ? slot + Self.gap : 0)
        nameField.frame = NSRect(x: Self.inset, y: y, width: max(0, nameMax), height: h)
    }
}

/// Target for menu items that run closures; also the menu's delegate (open / close).
private final class MenuTarget: NSObject, NSMenuDelegate {
    private var handlers: [Int: () -> Void] = [:]
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) { onOpen?() }
    func menuDidClose(_ menu: NSMenu) { onClose?() }

    func item(key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(fire(_:)), keyEquivalent: key)
        item.target = self
        item.tag = handlers.count
        handlers[item.tag] = handler
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}
