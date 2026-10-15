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

/// Shows/positions the panel and routes Enter / Shift+Enter / Esc to the controller.
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
            if isEscape { controller.escapePressed(); return true }
            if isReturn && flags.contains(.shift) { controller.copyAndClose(); return true }
            if flags.contains(.command), editingCommand(event, shift: flags.contains(.shift)) { return true }
            return false
        case .listening, .transcribing, .failed:
            if isEscape { controller.escapePressed() }
            else if isReturn { controller.enterPressed() }
            // Swallow everything else: nothing in these phases takes typing (no beeps).
            return true
        }
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
