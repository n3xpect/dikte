import AppKit
import AVFoundation
import Observation

// State of the welcome flow. Views read everything through `OnboardingBackend`, so previews and
// snapshots run on fake data while the real window uses `AppState`.

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case language, model, permissions, shortcut

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    var title: String {
        switch self {
        case .language: L("Dil")
        case .model: L("Model")
        case .permissions: L("İzinler")
        case .shortcut: L("Kısayol")
        }
    }
}

enum MicPermission: Equatable {
    case notDetermined, granted, denied

    static var current: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// What the welcome flow reads and does.
protocol OnboardingBackend: AnyObject {
    var uiLanguage: AppLanguage { get set }
    var dictationLanguage: DictationLanguage { get set }
    /// The recommended model's catalog entry; nil until the engine sent its first snapshot.
    var model: ModelInfo? { get }
    var system: SystemInfo? { get }
    /// Disk space that must stay free (engine value when known, else from settings).
    var minFreeBytes: Int64 { get }
    var engineStatus: EngineStatus { get }
    var silenceSeconds: Double { get }
    var micPermission: MicPermission { get }
    /// Dikte may paste into other apps (AXIsProcessTrusted).
    var accessibilityTrusted: Bool { get }
    /// Panel key that sends the text (shown in the shortcut table).
    var sendKey: SendKey { get }

    func refreshMicPermission()
    func requestMicPermission() async
    func refreshAccessibility()
    /// System prompt + Privacy › Accessibility; the status follows by polling.
    func requestAccessibility()
    func download() async throws
    func restartEngine()
    func startTestDictation()
    /// Sets `onboardingCompleted` (finishing, or closing the window early).
    func markCompleted()
}

@Observable
final class LiveOnboardingBackend: OnboardingBackend {
    static let modelID = "large-v3"

    @ObservationIgnored private let state: AppState
    private(set) var micPermission = MicPermission.current

    init(state: AppState) {
        self.state = state
    }

    private var settings: AppSettings {
        get { state.settings.settings }
        set { state.settings.settings = newValue }
    }

    var uiLanguage: AppLanguage {
        get { settings.uiLanguage }
        set {
            settings.uiLanguage = newValue
            Localizer.shared.language = newValue
        }
    }

    var dictationLanguage: DictationLanguage {
        get { settings.dictationLanguage }
        set { settings.dictationLanguage = newValue }
    }

    var model: ModelInfo? { state.engine.models.first { $0.id == Self.modelID } }
    var system: SystemInfo? { state.engine.system }
    var minFreeBytes: Int64 { system?.minFreeBytes ?? Int64(settings.minFreeDiskGB) * 1_073_741_824 }
    var engineStatus: EngineStatus { state.engine.status }
    var silenceSeconds: Double { settings.silenceSeconds }
    var accessibilityTrusted: Bool { state.delivery.accessibilityTrusted }
    var sendKey: SendKey { settings.sendKey }

    func refreshMicPermission() {
        let current = MicPermission.current
        if current != micPermission { micPermission = current }
    }

    func requestMicPermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicPermission()
    }

    func refreshAccessibility() {
        state.delivery.refreshTrust()
    }

    func requestAccessibility() {
        state.delivery.requestAccessibility()
    }

    func download() async throws {
        if settings.selectedModel != Self.modelID { settings.selectedModel = Self.modelID }
        try await state.engine.download(Self.modelID)
    }

    func restartEngine() {
        state.engine.start()
    }

    func startTestDictation() {
        state.dictation.hotkeyPressed()
    }

    func markCompleted() {
        if !settings.onboardingCompleted { settings.onboardingCompleted = true }
        state.settings.flush()
    }
}

/// Where the recommended model stands, as shown in step 2.
enum OnboardingModelPhase: Equatable {
    /// Engine not running (starting / failed / stopped).
    case engine(EngineStatus)
    /// Engine runs but its catalog hasn't arrived yet.
    case waitingForCatalog
    case notDownloaded(partial: Bool, pausedReason: String?)
    case downloading(progress: Double)
    /// On disk (or already loaded) — dictation can use it.
    case ready
}

/// The disk rule of the download: `free - needed >= minFree`.
struct OnboardingDiskPlan: Equatable {
    var needed: Int64
    var free: Int64
    var minFree: Int64

    var after: Int64 { free - needed }
    var allowsDownload: Bool { after >= minFree }
}

@Observable
final class OnboardingFlow {
    var step: OnboardingStep
    let backend: any OnboardingBackend
    /// POST …/download sent; cleared when the engine's snapshot shows the new state.
    private(set) var downloadRequested = false
    private(set) var downloadError: String?
    @ObservationIgnored var onFinish: () -> Void = {}

    init(backend: any OnboardingBackend, step: OnboardingStep = .language) {
        self.backend = backend
        self.step = step
    }

    var modelPhase: OnboardingModelPhase {
        guard case .running = backend.engineStatus else { return .engine(backend.engineStatus) }
        guard let model = backend.model else { return .waitingForCatalog }
        switch model.state {
        case .notDownloaded:
            return .notDownloaded(partial: model.downloadedBytes > 0, pausedReason: nil)
        case .paused:
            return .notDownloaded(partial: true, pausedReason: model.error)
        case .downloading:
            return .downloading(progress: model.progress ?? 0)
        case .onDisk, .loading, .loaded:
            return .ready
        }
    }

    /// nil while the model size or free space is unknown.
    var diskPlan: OnboardingDiskPlan? {
        guard let model = backend.model, let size = model.sizeBytes, let system = backend.system else { return nil }
        return OnboardingDiskPlan(needed: max(0, size - model.downloadedBytes), free: system.diskFreeBytes,
                                  minFree: backend.minFreeBytes)
    }

    var modelReady: Bool { modelPhase == .ready }

    var canTestDictation: Bool { modelReady && backend.micPermission == .granted }

    func startDownload() {
        guard !downloadRequested else { return }
        downloadError = nil
        downloadRequested = true
        Task {
            do {
                try await backend.download()
                // The /events snapshot with the new state follows right away.
                try? await Task.sleep(for: .seconds(2))
            } catch {
                downloadError = (error as? EngineAPIError)?.message ?? error.localizedDescription
            }
            downloadRequested = false
        }
    }

    func requestMicrophone() {
        Task { await backend.requestMicPermission() }
    }

    func goNext() {
        if let next = step.next { step = next }
    }

    func goBack() {
        if let previous = step.previous { step = previous }
    }

    func finish() {
        backend.markCompleted()
        onFinish()
    }

    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(Self.microphoneSettingsURL)
    }
}
