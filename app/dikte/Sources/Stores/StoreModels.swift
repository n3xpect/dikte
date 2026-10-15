import Foundation

/// settings.json — owned by the app; relevant fields are pushed to the engine via PUT /config.
struct AppSettings: Codable, Equatable, Sendable {
    var silenceSeconds: Double = 3.0
    var maxDurationSeconds: Double = 120
    /// AVCaptureDevice uniqueID; nil = system default input.
    var microphoneUID: String? = nil
    var launchAtLogin: Bool = false
    var soundsEnabled: Bool = true
    var idleUnloadMinutes: Int = 5
    /// 0 = unlimited.
    var historyLimit: Int = 0
    var minFreeDiskGB: Int = 10
    var selectedModel: String = "large-v3"
    /// App UI language. Fresh installs: macOS language (tr, else en); chosen in onboarding.
    var uiLanguage: AppLanguage = .systemDefault
    /// Dictation language: auto (tr vs en detected) | tr | en.
    var dictationLanguage: DictationLanguage = .auto
    /// Fresh installs show the welcome flow until this is set.
    var onboardingCompleted: Bool = false
    /// Default delivery target (the send key): nil = copy to the clipboard only, else an app
    /// bundle identifier the text is pasted into.
    var deliveryDefaultApp: String? = nil
    /// Panel key that sends the text to the default target; the other one inserts a new line.
    var sendKey: SendKey = .enter
    /// Favourite target apps (bundle identifiers); shown after the default, alphabetically.
    var deliveryFavorites: [String] = []
    /// Running, non-favourite apps listed in the panel before "+ N more".
    var deliveryOtherLimit: Int = 5
    /// Put the previous clipboard contents back after pasting into an app.
    var restoreClipboardAfterPaste: Bool = true
    /// Tips dismissed with "Bir daha gösterme" (see `Tip`).
    var dismissedTips: [String] = []

    /// Catalog entries dropped in later versions; a saved selection falls back to the default.
    static let removedModels: Set<String> = ["qwen3-1.7b"]

    init() {}

    // Tolerate missing keys so new settings don't break old files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        silenceSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? d.silenceSeconds
        maxDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .maxDurationSeconds) ?? d.maxDurationSeconds
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? d.soundsEnabled
        idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        minFreeDiskGB = try c.decodeIfPresent(Int.self, forKey: .minFreeDiskGB) ?? d.minFreeDiskGB
        selectedModel = try c.decodeIfPresent(String.self, forKey: .selectedModel) ?? d.selectedModel
        if Self.removedModels.contains(selectedModel) { selectedModel = d.selectedModel }
        // Files written before 0.2.0 lack these keys: keep the old behaviour (Turkish UI and
        // dictation, no welcome flow) instead of the fresh-install defaults.
        uiLanguage = try c.decodeIfPresent(AppLanguage.self, forKey: .uiLanguage) ?? .tr
        dictationLanguage = try c.decodeIfPresent(DictationLanguage.self, forKey: .dictationLanguage) ?? .tr
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
        deliveryDefaultApp = try c.decodeIfPresent(String.self, forKey: .deliveryDefaultApp)
        // Missing (files before 0.3.x) or unknown → Enter sends, for existing installs too.
        sendKey = (try? c.decodeIfPresent(SendKey.self, forKey: .sendKey)) ?? .enter
        deliveryFavorites = try c.decodeIfPresent([String].self, forKey: .deliveryFavorites) ?? []
        deliveryOtherLimit = try c.decodeIfPresent(Int.self, forKey: .deliveryOtherLimit) ?? d.deliveryOtherLimit
        restoreClipboardAfterPaste = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboardAfterPaste)
            ?? d.restoreClipboardAfterPaste
        dismissedTips = try c.decodeIfPresent([String].self, forKey: .dismissedTips) ?? []
    }

    var engineConfig: EngineConfig {
        EngineConfig(selectedModel: selectedModel,
                     idleUnloadS: idleUnloadMinutes * 60,
                     minFreeBytes: Int64(minFreeDiskGB) * 1_073_741_824,
                     silenceS: silenceSeconds,
                     maxDurationS: maxDurationSeconds,
                     language: dictationLanguage.rawValue,
                     uiLanguage: uiLanguage.rawValue)
    }
}

/// One item of history.json.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    /// Model output before term fixes.
    var rawText: String
    /// Text after term fixes and the user's edits (what was copied, or the final state on Esc).
    var editedText: String
    var copied: Bool
    var model: String
    var audioSeconds: Double
    var transcribeSeconds: Double
    /// "tr" | "en"; nil for entries written before 0.2.0 (Turkish).
    var language: String? = nil
    /// Bundle identifier of the app the text was pasted into (nil: clipboard only / not copied).
    var deliveredTo: String? = nil
}

/// One-off hints that can be dismissed with "Bir daha gösterme".
enum Tip: String, CaseIterable, Sendable {
    /// Explanation under the panel's AKTAR list.
    case deliveryList
}

/// Which Return sends in the panel's editing phase: `.enter` = ↩ sends, ⇧↩ new line;
/// `.shiftEnter` = ⇧↩ sends, ↩ new line.
enum SendKey: String, Codable, CaseIterable, Sendable {
    case enter, shiftEnter

    /// Key label in the panel ("↩" / "⇧↩").
    var symbol: String { self == .enter ? "↩" : "⇧↩" }
    /// The other key, which inserts a new line.
    var newlineSymbol: String { self == .enter ? "⇧↩" : "↩" }
    /// Name in Settings (not translated: key names).
    var name: String { self == .enter ? "Enter" : "Shift+Enter" }
}

enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case auto, tr, en
}
