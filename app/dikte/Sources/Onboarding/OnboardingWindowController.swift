import AppKit
import SwiftUI

// Welcome flow shown on fresh installs (`settings.onboardingCompleted == false`): 1) UI + dictation
// language, 2) model download, 3) permissions (microphone, Accessibility), 4) shortcut intro + optional test
// dictation. Finishing — or closing the window at any step — sets `onboardingCompleted = true`;
// everything can be changed later in Ayarlar.

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private init() {}

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// Create (once) and bring the welcome window to front.
    func show() {
        #if DEBUG
        if OnboardingDebug.runIfRequested() { return }
        #endif
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let flow = OnboardingFlow(backend: LiveOnboardingBackend(state: .shared))
        let window = Self.makeWindow(flow: flow)
        flow.onFinish = { [weak window] in window?.close() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                flow.backend.markCompleted()
                self?.windowClosed()
            }
        }
        return window
    }

    private func windowClosed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }

    static func makeWindow(flow: OnboardingFlow) -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(flow: flow))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.title]
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Dikte'ye hoş geldin")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(OnboardingView.size)
        window.center()
        return window
    }
}
