import KeyboardShortcuts

// CONTRACT — implemented by agent "dictation".

extension KeyboardShortcuts.Name {
    /// Default ⌥Space; user-changeable in Ayarlar (KeyboardShortcuts.Recorder).
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
}

enum Hotkeys {
    /// The current dictation shortcut as shown in menus, e.g. "⌥Space"; "—" if none is set.
    static var dictateDisplay: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "—"
    }

    static func install(dictation: DictationController) {
        KeyboardShortcuts.onKeyDown(for: .dictate) {
            dictation.hotkeyPressed()
        }
        #if DEBUG
        DictationDebug.runIfRequested()
        #endif
    }
}
