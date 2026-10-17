import Foundation

/// settings.json — owned by the app; relevant fields are pushed to the engine via PUT /config.
struct AppSettings: Codable, Equatable, Sendable {
    var silenceSeconds: Double = 3.0
    /// Recording stops by itself after this long; whole minutes within `maxDurationRange`.
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
    /// Delivery targets in the user's order: app bundle identifiers and `AppSettings.clipboard`
    /// (always there exactly once). The first is the default (send key), the next ones get ⌘1… in
    /// the panel. Apps here are the "favourites" (★).
    var deliveryTargets: [String] = [AppSettings.clipboard]
    /// Targets (from `deliveryTargets`) that get Return pressed after the text is pasted, so the
    /// app sends it right away.
    var submitTargets: [String] = []
    /// Panel key that sends the text to the default target; the other one inserts a new line.
    var sendKey: SendKey = .enter
    /// After the text appears in the panel, count down `autoSendSeconds` and send it to the default
    /// target unless the user presses a key or clicks first.
    var autoSendEnabled: Bool = true
    /// One of `autoSendChoices`.
    var autoSendSeconds: Double = 30
    /// Running, non-favourite apps listed in the panel before "+ N more".
    var deliveryOtherLimit: Int = 5
    /// Put the previous clipboard contents back after pasting into an app.
    var restoreClipboardAfterPaste: Bool = true

    /// Catalog entries dropped in later versions; a saved selection falls back to the default.
    static let removedModels: Set<String> = ["qwen3-1.7b"]
    /// The "Panoya kopyala" entry of `deliveryTargets` (bundle identifiers always contain a dot).
    static let clipboard = "clipboard"
    /// The "Son kullanılan uygulama" entry: whichever app was in front when dictation started
    /// (resolved when sending; not a bundle identifier, there is no dot in it).
    static let lastApp = "lastApp"
    /// Allowed longest recording, seconds (1–20 min; the engine accepts up to 1200 too).
    static let maxDurationRange: ClosedRange<Double> = 60...1200
    /// The auto-send waits offered: 0 = right away (the text isn't shown), 3 s, 30 s, 1, 3, 5 min.
    static let autoSendChoices: [Double] = [0, 3, 30, 60, 180, 300]

    /// `seconds` rounded to whole minutes and kept within `maxDurationRange`.
    static func clampedMaxDuration(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return AppSettings().maxDurationSeconds }
        let minutes = (seconds / 60).rounded() * 60
        return min(max(minutes, maxDurationRange.lowerBound), maxDurationRange.upperBound)
    }

    init() {}

    // Tolerate missing keys so new settings don't break old files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        silenceSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? d.silenceSeconds
        maxDurationSeconds = Self.clampedMaxDuration(
            try c.decodeIfPresent(Double.self, forKey: .maxDurationSeconds) ?? d.maxDurationSeconds)
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
        // Files before 0.4.3 keep a default app + favourites instead; SettingsStore converts them.
        deliveryTargets = Self.normalizedTargets(
            try c.decodeIfPresent([String].self, forKey: .deliveryTargets) ?? d.deliveryTargets)
        submitTargets = try c.decodeIfPresent([String].self, forKey: .submitTargets) ?? d.submitTargets
        // Missing (files before 0.3.x) or unknown → Enter sends, for existing installs too.
        sendKey = (try? c.decodeIfPresent(SendKey.self, forKey: .sendKey)) ?? .enter
        // Missing (files before 0.4.4) → on, for existing installs too.
        autoSendEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSendEnabled) ?? d.autoSendEnabled
        autoSendSeconds = Self.clampedAutoSend(
            try c.decodeIfPresent(Double.self, forKey: .autoSendSeconds) ?? d.autoSendSeconds)
        deliveryOtherLimit = try c.decodeIfPresent(Int.self, forKey: .deliveryOtherLimit) ?? d.deliveryOtherLimit
        restoreClipboardAfterPaste = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboardAfterPaste)
            ?? d.restoreClipboardAfterPaste
    }

    /// The nearest of `autoSendChoices` (the shorter one on a tie).
    static func clampedAutoSend(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return AppSettings().autoSendSeconds }
        return autoSendChoices.min { abs($0 - seconds) < abs($1 - seconds) } ?? AppSettings().autoSendSeconds
    }

    // MARK: Delivery targets

    /// The send key's target: an app bundle identifier or `clipboard`.
    var defaultTarget: String { deliveryTargets.first ?? Self.clipboard }
    /// Whether any app is a target (pasting into it needs Accessibility).
    var hasTargetApp: Bool { deliveryTargets.contains { $0 != Self.clipboard } }

    /// Without duplicates, with `clipboard` exactly once (appended if missing).
    static func normalizedTargets(_ targets: [String]) -> [String] {
        var seen: Set<String> = []
        var out = targets.filter { !$0.isEmpty && seen.insert($0).inserted }
        if !seen.contains(clipboard) { out.append(clipboard) }
        return out
    }

    /// Order for a pre-0.4.3 file, as its panel showed it: the default (app or clipboard), then the
    /// favourites A–Z by `name` (bundle id if unknown). With an app default the clipboard goes last,
    /// so the ⌘ numbers stay the same.
    static func migratedTargets(defaultApp: String?, favorites: [String], locale: Locale,
                                name: (String) -> String?) -> [String] {
        var seen: Set<String> = defaultApp.map { [$0] } ?? []
        let favs = favorites.filter { $0 != clipboard && seen.insert($0).inserted }
            .map { (id: $0, name: name($0) ?? $0) }
            .sorted {
                switch $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: locale) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: $0.id < $1.id
                }
            }
            .map(\.id)
        if let defaultApp { return [defaultApp] + favs + [clipboard] }
        return [clipboard] + favs
    }

    /// Moves `id` one place per step towards `delta`'s sign, past entries in `among` only (the
    /// panel skips apps that aren't installed). False when it is already at that end.
    @discardableResult
    mutating func moveTarget(_ id: String, by delta: Int, among visible: Set<String>? = nil) -> Bool {
        guard delta != 0, var i = deliveryTargets.firstIndex(of: id) else { return false }
        var moved = false
        for _ in 0..<abs(delta) {
            let step = delta > 0 ? 1 : -1
            var j = i + step
            while deliveryTargets.indices.contains(j), let v = visible, !v.contains(deliveryTargets[j]) { j += step }
            guard deliveryTargets.indices.contains(j) else { break }
            deliveryTargets.remove(at: i)
            deliveryTargets.insert(id, at: j)
            i = j
            moved = true
        }
        return moved
    }

    /// Puts `id` first (adding it if it isn't a target yet): it becomes the default.
    mutating func makeDefaultTarget(_ id: String) {
        deliveryTargets.removeAll { $0 == id }
        deliveryTargets.insert(id, at: 0)
    }

    /// ★: removes an app from the targets, or adds it at the end.
    mutating func toggleTarget(_ id: String) {
        guard id != Self.clipboard else { return }
        if deliveryTargets.contains(id) {
            deliveryTargets.removeAll { $0 == id }
        } else {
            deliveryTargets.append(id)
        }
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
    /// Model output before term fixes; nil when it equals `editedText` (stored once — see `compacted`).
    var rawText: String?
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

    /// Model output before term fixes (the final text when nothing was changed).
    var raw: String { rawText ?? editedText }
    /// Whether the final text differs from the model output.
    var changed: Bool { raw != editedText }
    /// Same entry with the model output dropped when it equals the final text.
    var compacted: HistoryEntry {
        var e = self
        if e.rawText == e.editedText { e.rawText = nil }
        return e
    }
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
