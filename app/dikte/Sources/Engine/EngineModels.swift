import Foundation

// Wire types for the engine API — keep in sync with app/engine/api.md.
// JSON uses snake_case; decode with `.convertFromSnakeCase` (see EngineJSON).

enum EngineJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

enum ModelState: String, Codable, Sendable {
    case notDownloaded = "not_downloaded"
    case downloading
    case paused
    case onDisk = "on_disk"
    case loading
    case loaded
}

struct ModelInfo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var repo: String
    var kind: String
    var custom: Bool
    var recommended: Bool
    var note: String
    var sizeBytes: Int64?
    var downloadedBytes: Int64
    var ramBytes: Int64?
    var state: ModelState
    var progress: Double?
    var error: String?
}

struct SystemInfo: Codable, Equatable, Sendable {
    var diskFreeBytes: Int64
    var minFreeBytes: Int64
    var ramTotalBytes: Int64
    var ramAvailableBytes: Int64
    var idleUnloadS: Int
    var idleUnloadAt: Double?
    var selectedModel: String?
}

struct Term: Codable, Hashable, Identifiable, Sendable {
    var term: String
    var accept: [String] = []
    var fix: [String] = []
    var id: String { term }
}

/// Body of `PUT /config` — every field optional.
struct EngineConfig: Codable, Equatable, Sendable {
    var selectedModel: String?
    var idleUnloadS: Int?
    var minFreeBytes: Int64?
    var silenceS: Double?
    var maxDurationS: Double?
    /// "auto" (Turkish or English, detected) | "tr" | "en"
    var language: String?
    /// "tr" | "en" — language of engine `message` texts.
    var uiLanguage: String?
    var terms: [Term]?
}

/// `{"error": code, "message": Turkish text, ...}` returned by failing HTTP calls.
struct EngineAPIError: Error, Codable, Equatable, Sendable, LocalizedError {
    var error: String
    var message: String
    var neededBytes: Int64?
    var freeBytes: Int64?
    var minFreeBytes: Int64?
    var availableBytes: Int64?
    var errorDescription: String? { message }
}

struct DictationResult: Equatable, Sendable {
    var rawText: String
    var text: String
    var fixes: [(wrong: String, right: String)]
    var audioSeconds: Double
    var transcribeSeconds: Double
    var model: String
    /// Language actually used: "tr" | "en".
    var language: String = "tr"
    /// Engine id of the kept audio, for `EngineController.retranscribe`.
    var dictationId: String? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.rawText == b.rawText && a.text == b.text && a.model == b.model && a.language == b.language
            && a.fixes.map { [$0.wrong, $0.right] } == b.fixes.map { [$0.wrong, $0.right] }
    }
}

enum DictationEndReason: String, Sendable {
    case silence, finish, maxDuration = "max_duration", noSpeech = "no_speech", cancel
}

/// Events coming back on `/dictate`.
enum DictationEvent: Equatable, Sendable {
    case modelLoading
    case modelReady
    case speechStart
    case ended(DictationEndReason)
    case transcribing
    case result(DictationResult)
    case error(code: String, message: String)
    /// Socket closed (normally after result / end without transcription, or on failure).
    case closed
}
