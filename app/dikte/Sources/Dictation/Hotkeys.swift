import KeyboardShortcuts

// CONTRACT — implemented by agent "dictation".

extension KeyboardShortcuts.Name {
    /// Default ⌥Space; user-changeable in Ayarlar (KeyboardShortcuts.Recorder).
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
}

enum Hotkeys {
    static func install(dictation: DictationController) {
        KeyboardShortcuts.onKeyDown(for: .dictate) {
            dictation.hotkeyPressed()
        }
        #if DEBUG
        DictationDebug.runIfRequested()
        #endif
    }
}
