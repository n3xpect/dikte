import AppKit

/// Short, quiet system sounds at the start and end of a recording (`settings.soundsEnabled`).
enum DictationSounds {
    static func start() { play("Tink") }
    static func end() { play("Pop") }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.volume = 0.35
        sound.play()
    }
}
