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
    }

    var engineConfig: EngineConfig {
        EngineConfig(selectedModel: selectedModel,
                     idleUnloadS: idleUnloadMinutes * 60,
                     minFreeBytes: Int64(minFreeDiskGB) * 1_073_741_824,
                     silenceS: silenceSeconds,
                     maxDurationS: maxDurationSeconds,
                     language: "tr")
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
}
