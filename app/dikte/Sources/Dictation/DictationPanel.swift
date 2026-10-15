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

/// Shows/positions the panel and routes Enter / Shift+Enter / ⌘1–9 / ⌘C / Esc / ⌘L to the controller.
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

    private enum Key {
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
        let isReturn = event.keyCode == Key.returnKey || event.keyCode == Key.keypadEnter
        let isEscape = event.keyCode == Key.escape
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch controller.phase {
        case .idle:
            return false
        case .editing:
            if let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
            if !controller.suggestions.isEmpty {
                if isEscape { controller.dismissSuggestions(); return true }
                return false
            }
            let command = flags.contains(.command)
            if command, event.charactersIgnoringModifiers?.lowercased() == "l" {
                controller.switchLanguage()
                return true
            }
            if controller.retranscribing {
                // Text is read-only meanwhile; Esc stops, ⌘C/⌘A still work, the rest is swallowed.
                if isEscape { controller.escapePressed() }
                else if command { _ = editingCommand(event, shift: flags.contains(.shift)) }
                return true
            }
            if controller.confirmingLanguageSwitch, isReturn, !flags.contains(.shift) {
                controller.switchLanguage()
                return true
            }
            // ↑/↓ list navigation: ↓ on the text's last line enters the AKTAR list; there ↑/↓ move,
            // ↩ delivers, Esc (or typing) hands the keys back to the text.
            let bare = flags.intersection([.command, .option, .control, .shift]).isEmpty
            if controller.listSelection != nil {
                if bare && event.keyCode == Key.down { controller.moveListSelection(by: 1); return true }
                if bare && event.keyCode == Key.up { controller.moveListSelection(by: -1); return true }
                if isEscape { controller.leaveList(); return true }
                if isReturn && bare { controller.activateListSelection(); return true }
                if !command && !isReturn { controller.leaveList(); return false }
            } else if bare, event.keyCode == Key.down, let tv = panel.firstResponder as? NSTextView,
                      Self.caretOnLastLine(tv), controller.enterList() {
                return true
            }
            if isEscape { controller.escapePressed(); return true }
            if isReturn && flags.contains(.shift) { controller.deliverToDefault(); return true }
            if command, !flags.contains(.shift), let n = Self.shortcutNumber(keyCode: event.keyCode) {
                controller.deliver(shortcut: n)
                return true
            }
            if command, !flags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "c",
               let tv = panel.firstResponder as? NSTextView, tv.selectedRange().length == 0 {
                controller.copyOnly()
                return true
            }
            if command, editingCommand(event, shift: flags.contains(.shift)) { return true }
            return false
        case .listening, .transcribing, .failed:
            if isEscape { controller.escapePressed() }
            else if isReturn { controller.enterPressed() }
            // Swallow everything else: nothing in these phases takes typing (no beeps).
            return true
        }
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
