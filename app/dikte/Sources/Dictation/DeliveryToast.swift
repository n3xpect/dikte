import AppKit
import SwiftUI

/// A failed delivery: what the toast says and whether clicking it asks for Accessibility access.
struct DeliveryToastContent: Equatable {
    var message: String
    var asksForAccessibility: Bool

    static func failure(_ error: Error, appName: String) -> DeliveryToastContent {
        if (error as? DeliveryError) == .accessibilityDenied {
            return DeliveryToastContent(message: L("Erişilebilirlik izni gerekli — metin panoda"),
                                        asksForAccessibility: true)
        }
        if (error as? DeliveryError) == .notReady {
            return DeliveryToastContent(message: L("%@ açıldı ama yazı alanı hazır değildi — metin panoda (⌘V)", appName),
                                        asksForAccessibility: false)
        }
        return DeliveryToastContent(message: L("%@ uygulamasına aktarılamadı — metin panoda (⌘V)", appName),
                                    asksForAccessibility: false)
    }
}

struct DeliveryToastView: View {
    let content: DeliveryToastContent
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: content.asksForAccessibility ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(content.message)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if content.asksForAccessibility {
                Text(L("İzin ver"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background { ToastBackground() }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .onTapGesture { onClick() }
        .onHover(perform: onHover)
    }
}

private struct ToastBackground: View {
    @Environment(\.solidPanelBackground) private var solid

    var body: some View {
        if solid {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ToastEffectView()
        }
    }
}

private struct ToastEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Non-activating HUD near the bottom center of the screen with the mouse; hides by itself.
final class DeliveryToastController {
    static let duration: Duration = .seconds(3)

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hovering = false

    func show(_ content: DeliveryToastContent, onClick: @escaping () -> Void) {
        hide()
        let host = FirstMouseHostingView(rootView: DeliveryToastView(
            content: content,
            onClick: { [weak self] in
                onClick()
                self?.hide()
            },
            onHover: { [weak self] inside in
                self?.hovering = inside
                if !inside { self?.scheduleHide() }
            }))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = !content.asksForAccessibility
        panel.contentView = host
        panel.setFrameOrigin(Self.origin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        hovering = false
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }

    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(x: (visible.midX - size.width / 2).rounded(),
                       y: (visible.minY + DictationPanelController.bottomMargin).rounded())
    }
}

/// Clicks land on the first try although the toast never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
