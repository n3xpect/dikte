import AppKit
import SwiftUI

/// Borderless floating panel that takes keyboard focus without activating Dikte (Spotlight-style),
/// visible on all Spaces and over full-screen apps.
final class DictationPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: DictationPanelView.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
    }

    /// Bottom-center point the panel is pinned to. SwiftUI resizes the window to its content keeping
    /// the top edge; pinning here keeps the bottom edge in place so the panel grows upwards.
    var bottomCenter: NSPoint?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let bottomCenter {
            rect.origin = NSPoint(x: (bottomCenter.x - rect.width / 2).rounded(), y: bottomCenter.y.rounded())
        }
        super.setFrame(rect, display: flag)
        invalidateShadow()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows/positions the panel and routes ↩ / ⇧↩ / ⌘1–9 / ⌘C / Esc / ⌘L to the controller.
final class DictationPanelController {
    /// Distance between the panel's bottom edge and the bottom of the visible frame (Dock).
    static let bottomMargin: CGFloat = 80

    private let panel = DictationPanel()
    private let hostingView: NSHostingView<DictationPanelView>
    private unowned let controller: DictationController
    private var keyMonitor: Any?
    private var contentHeight: CGFloat = 110

    init(controller: DictationController) {
        self.controller = controller
        hostingView = NSHostingView(rootView: DictationPanelView(controller: controller))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        hostingView.rootView = DictationPanelView(controller: controller) { [weak self] height in
            self?.contentHeightChanged(height)
        }
    }

    /// Show at the bottom center of the screen with the mouse (if hidden) and take key focus.
    func show() {
        if !panel.isVisible {
            panel.bottomCenter = Self.anchor()
            applyFrame()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: - Layout

    private static func anchor() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX, y: visible.minY + bottomMargin)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        // May arrive during a layout pass inside `setFrame`; apply afterwards.
        DispatchQueue.main.async { self.applyFrame() }
    }

    private func applyFrame() {
        panel.setFrame(NSRect(x: 0, y: 0, width: DictationPanelView.width, height: contentHeight.rounded(.up)),
                       display: true)
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    enum Key {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        /// Top-row 1…9 (physical keys, so ⌘1–9 work on any layout).
        static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// 1…9 for the top-row digit keys, else nil.
    static func shortcutNumber(keyCode: UInt16) -> Int? {
        Key.digits.firstIndex(of: keyCode).map { $0 + 1 }
    }

    /// Returns true when the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch controller.phase {
        case .idle:
            return false
        case .editing:
            let tv = panel.firstResponder as? NSTextView
            let bareDown = event.keyCode == Key.down && flags.intersection(PanelKeyAction.modifiers).isEmpty
            let context = PanelKeyAction.Context(
                sendKey: controller.sendKey,
                hasMarkedText: tv?.hasMarkedText() ?? false,
                suggestionsShown: !controller.suggestions.isEmpty,
                retranscribing: controller.retranscribing,
                confirmingLanguageSwitch: controller.confirmingLanguageSwitch,
                listSelected: controller.listSelection != nil,
                listAvailable: controller.navigableRowCount > 0,
                // Layout work only for the one key that needs it.
                caretOnLastLine: bareDown && tv.map(Self.caretOnLastLine) == true,
                hasTextSelection: (tv?.selectedRange().length ?? 0) > 0,
                secondsSinceEditing: controller.secondsSinceEditingBegan)
            let action = PanelKeyAction.editing(keyCode: event.keyCode, flags: flags,
                                                characters: event.charactersIgnoringModifiers?.lowercased() ?? "",
                                                context: context)
            return perform(action, event: event, textView: tv, shift: flags.contains(.shift))
        case .listening, .transcribing, .failed:
            if event.keyCode == Key.escape { controller.escapePressed() }
            else if PanelKeyAction.isReturn(event.keyCode) { controller.enterPressed() }
            // Swallow everything else: nothing in these phases takes typing (no beeps).
            return true
        }
    }

    /// Runs a decided action; true = the event was consumed.
    private func perform(_ action: PanelKeyAction, event: NSEvent, textView: NSTextView?, shift: Bool) -> Bool {
        switch action {
        case .pass: return false
        case .ignore: break
        case .deliverDefault: controller.deliverToDefault()
        case .newline: textView?.insertNewline(nil)
        case .deliverShortcut(let n): controller.deliver(shortcut: n)
        case .copyOnly: controller.copyOnly()
        case .switchLanguage: controller.switchLanguage()
        case .dismissSuggestions: controller.dismissSuggestions()
        case .escape: controller.escapePressed()
        case .enterList: controller.enterList()
        case .moveList(let delta): controller.moveListSelection(by: delta)
        case .activateList: controller.activateListSelection()
        case .leaveList: controller.leaveList()
        case .leaveListAndPass:
            controller.leaveList()
            return false
        case .editingCommand(let swallowOthers):
            return editingCommand(event, shift: shift) || swallowOthers
        }
        return true
    }

    /// True when ↓ would leave the text: no selection and the caret is on the last visual line
    /// (wrapped lines count; an empty line after a trailing newline is the last line).
    static func caretOnLastLine(_ tv: NSTextView) -> Bool {
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let length = (tv.string as NSString).length
        guard length > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { return true }
        lm.ensureLayout(for: tc)
        let hasEmptyLastLine = !lm.extraLineFragmentRect.isEmpty
        if sel.location >= length { return true }
        if hasEmptyLastLine { return false }
        let caretLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: sel.location),
                                            effectiveRange: nil)
        let lastLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: length - 1),
                                           effectiveRange: nil)
        return caretLine.minY >= lastLine.minY - 0.5
    }

    /// ⌘C/V/X/A/Z work even when Dikte is not the active app (no main menu in play).
    private func editingCommand(_ event: NSEvent, shift: Bool) -> Bool {
        let action: String
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": action = "copy:"
        case "v": action = "paste:"
        case "x": action = "cut:"
        case "a": action = "selectAll:"
        case "z": action = shift ? "redo:" : "undo:"
        default: return false
        }
        return NSApp.sendAction(Selector(action), to: nil, from: panel)
    }
}

/// What a key press in the editing phase does. Pure, so the mapping is checked in
/// `DictationSelfCheck` for both send keys.
enum PanelKeyAction: Equatable {
    /// Not ours: the text view gets the key.
    case pass
    /// Consumed, nothing happens.
    case ignore
    case deliverDefault
    /// New line typed into the text (⇧↩ when ↩ sends).
    case newline
    case deliverShortcut(Int)
    case copyOnly
    case switchLanguage
    case dismissSuggestions
    case escape
    case enterList
    case moveList(Int)
    case activateList
    case leaveList
    /// Typing while a row is selected: back to the text, which gets the key.
    case leaveListAndPass
    /// ⌘C/V/X/A/Z through the responder chain; any other ⌘ key passes unless `swallowOthers`.
    case editingCommand(swallowOthers: Bool)

    /// The send key right after the result appeared (or was replaced) is ignored: the press that
    /// ended the recording with ↩ shouldn't be followed by an accidental send.
    static let sendGuard: TimeInterval = 0.3
    static let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    struct Context {
        var sendKey: SendKey
        var hasMarkedText = false
        var suggestionsShown = false
        var retranscribing = false
        var confirmingLanguageSwitch = false
        /// A row of the AKTAR list is selected with ↑/↓.
        var listSelected = false
        /// There are rows to reach with ↓.
        var listAvailable = false
        var caretOnLastLine = false
        var hasTextSelection = false
        var secondsSinceEditing: TimeInterval = .infinity
    }

    static func isReturn(_ keyCode: UInt16) -> Bool {
        keyCode == DictationPanelController.Key.returnKey || keyCode == DictationPanelController.Key.keypadEnter
    }

    /// `characters` = `charactersIgnoringModifiers`, lowercased.
    static func editing(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String,
                        context c: Context) -> PanelKeyAction {
        typealias Key = DictationPanelController.Key
        let isReturn = isReturn(keyCode)
        let isEscape = keyCode == Key.escape
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let bare = flags.intersection(modifiers).isEmpty
        let shiftOnly = flags.intersection(modifiers) == .shift

        if c.hasMarkedText { return .pass }   // IME composition owns ↩ / Esc
        if c.suggestionsShown { return isEscape ? .dismissSuggestions : .pass }
        if command, characters == "l" { return .switchLanguage }
        if c.retranscribing {
            // Text is read-only meanwhile; Esc stops, ⌘C/⌘A still work, the rest is swallowed.
            if isEscape { return .escape }
            return command ? .editingCommand(swallowOthers: true) : .ignore
        }
        if c.confirmingLanguageSwitch, isReturn, !shift { return .switchLanguage }
        // ↑/↓ list navigation: ↓ on the text's last line enters the AKTAR list; there ↑/↓ move,
        // ↩ delivers, ⇧↩ does nothing, Esc (or typing) hands the keys back to the text.
        if c.listSelected {
            if bare && keyCode == Key.down { return .moveList(1) }
            if bare && keyCode == Key.up { return .moveList(-1) }
            if isEscape { return .leaveList }
            if isReturn && bare { return .activateList }
            if isReturn && shift { return .ignore }
            if !command && !isReturn { return .leaveListAndPass }
        } else if bare, keyCode == Key.down, c.caretOnLastLine, c.listAvailable {
            return .enterList
        }
        if isEscape { return .escape }
        if isReturn {
            let sends = c.sendKey == .enter ? bare : shiftOnly
            let breaksLine = c.sendKey == .enter ? shiftOnly : bare
            if sends { return c.secondsSinceEditing < sendGuard ? .ignore : .deliverDefault }
            // ↩ is the text view's own newline; ⇧↩ isn't one everywhere, so type it ourselves.
            if breaksLine { return c.sendKey == .enter ? .newline : .pass }
            return .pass   // ⌥↩ / ⌃↩: whatever the text view does with them
        }
        if command, !shift, let n = DictationPanelController.shortcutNumber(keyCode: keyCode) {
            return .deliverShortcut(n)
        }
        if command, !shift, characters == "c", !c.hasTextSelection { return .copyOnly }
        if command { return .editingCommand(swallowOthers: false) }
        return .pass
    }
}
