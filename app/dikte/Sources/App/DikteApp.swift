import AppKit
import SwiftUI

@main
struct DikteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All windows are AppKit-managed (menu bar item, floating panel, main window);
        // SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }  // headless `--selftest <wav>` mode
        let state = AppState.shared
        state.bootstrap()
        StatusItemController.shared.install(state: state)
        Hotkeys.install(dictation: state.dictation)
        if ProcessInfo.processInfo.arguments.contains("--show-main") {
            MainWindowController.shared.show()
        }
    }

    /// Launching the app again (Finder / Spotlight) while it runs opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
