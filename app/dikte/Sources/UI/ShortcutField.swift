import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// Dictation shortcut recorder (replaces `KeyboardShortcuts.Recorder`, whose clear button didn't
/// work and which often missed the first click). Click → listens for the next key combination;
/// ⓧ or ⌫ clears it; Esc, a click elsewhere or leaving the app cancels. While recording, the
/// dictation hotkey is off so pressing the current shortcut records it instead of starting dictation.
struct ShortcutField: View {
    @Binding var shortcut: KeyboardShortcuts.Shortcut?
    /// Persists the change (previews pass a no-op).
    var save: (KeyboardShortcuts.Shortcut?) -> Void = { KeyboardShortcuts.setShortcut($0, for: .dictate) }
    /// Snapshots only: start in the recording state.
    var startRecording = false

    @State private var recording = false
    @State private var needsModifier = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(title)
                    .monospacedDigit()
                    .foregroundStyle(recording ? Color.accentColor : shortcut == nil ? .secondary : .primary)
                    .frame(minWidth: 120)
            }
            .overlay {
                if recording {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .help(L("Tıkla ve yeni kısayola bas. Esc vazgeçer, ⌫ siler."))
            if shortcut != nil, !recording {
                Button {
                    set(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Kısayolu sil"))
            }
        }
        .onAppear { if startRecording { recording = true } }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stop()
        }
    }

    private var title: String {
        if recording { return needsModifier ? L("⌘, ⌥ veya ⌃ ile birlikte bas") : L("Kısayola bas…") }
        return shortcut?.description ?? L("Kısayol yok")
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        guard !recording else { return }
        recording = true
        needsModifier = false
        KeyboardShortcuts.disable(.dictate)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) } ? event : nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { KeyboardShortcuts.enable(.dictate) }
        recording = false
        needsModifier = false
    }

    /// Whether the event goes on to the app (key presses are swallowed).
    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            // A click anywhere cancels; clicking the field itself starts again (its button action).
            stop()
            return true
        }
        switch ShortcutRule.outcome(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
        case .cancel:
            stop()
        case .clear:
            set(nil)
        case .needsModifier:
            needsModifier = true
            NSSound.beep()
        case .accept:
            guard let new = KeyboardShortcuts.Shortcut(event: event) else { NSSound.beep(); return false }
            set(new)
        }
        return false
    }

    private func set(_ new: KeyboardShortcuts.Shortcut?) {
        stop()
        shortcut = new
        save(new)
    }
}

/// What a key press does while recording (pure, for the self-check).
enum ShortcutRule {
    enum Outcome: Equatable { case cancel, clear, needsModifier, accept }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func outcome(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Outcome {
        // ⇧ alone doesn't make a usable global shortcut; F keys work without modifiers.
        let real = modifiers.intersection([.command, .option, .control])
        let plain = modifiers.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, keyCode == kVK_Escape { return .cancel }
        if plain, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete { return .clear }
        if real.isEmpty, !functionKeys.contains(keyCode) { return .needsModifier }
        return .accept
    }
}
