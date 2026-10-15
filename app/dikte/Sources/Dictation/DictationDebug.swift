#if DEBUG
import AppKit
import SwiftUI

/// Debug-only hook: launching with env `DIKTE_DICTATION_SNAPSHOTS=<dir>` runs `DictationSelfCheck`,
/// renders every panel phase and the delivery toasts to `<dir>/<state>[-en][-dark].png` (Turkish and English UI) and quits.
enum DictationDebug {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["DIKTE_DICTATION_SNAPSHOTS"], !dir.isEmpty else { return }
        let failures = DictationSelfCheck.run()
        print("DictationSelfCheck:", failures.isEmpty ? "OK" : "\(failures.count) failure(s)")
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // RunLoop (not GCD) so the nested run loops below can still drain the main queue.
        RunLoop.main.perform { MainActor.assumeIsolated {
            let uiLanguage = Localizer.shared.language
            for language in AppLanguage.allCases {
                Localizer.shared.language = language
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for state in DictationController.PreviewState.allCases {
                        render(DictationPanelView(controller: .preview(state)), name: state.rawValue,
                               appearance: appearance, to: folder)
                    }
                    let toasts: [(String, DeliveryError)] = [("toastError", .activationTimeout),
                                                             ("toastAccessibility", .accessibilityDenied)]
                    for (name, error) in toasts {
                        render(DeliveryToastView(content: .failure(error, appName: "Slack")).padding(20),
                               name: name, appearance: appearance, to: folder)
                    }
                }
            }
            Localizer.shared.language = uiLanguage
            checkRealPanel()
            exit(failures.isEmpty ? 0 : 1)
        } }
    }

    /// Shows the real panel in two phases and prints its frame, key state and first responder.
    private static func checkRealPanel() {
        for state in [DictationController.PreviewState.listening, .editing] {
            let controller = DictationController.preview(state)
            let panel = DictationPanelController(controller: controller)
            panel.show()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let window = NSApp.windows.first { $0 is DictationPanel && $0.isVisible }
            print("panel \(state.rawValue): frame=\(window?.frame ?? .zero) key=\(window?.isKeyWindow ?? false)",
                  "firstResponder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")",
                  "screen.visible=\(window?.screen?.visibleFrame ?? .zero)")
            panel.hide()
        }
    }

    private static func render(_ content: some View, name: String, appearance: NSAppearance.Name, to folder: URL) {
        let view = content.environment(\.solidPanelBackground, true)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: DictationPanelView.width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let suffix = (Localizer.shared.language == .en ? "-en" : "") + (appearance == .darkAqua ? "-dark" : "")
        let url = folder.appendingPathComponent("\(name)\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot:", url.path, size)
        window.orderOut(nil)
    }
}
#endif
