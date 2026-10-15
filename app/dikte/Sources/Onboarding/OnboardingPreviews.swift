#if DEBUG
import AppKit
import ObjectiveC
import Observation
import SwiftUI

// Fake data, #Previews and a PNG renderer for the welcome flow.
//
// Snapshots: launch with env `DIKTE_ONBOARDING_SNAPSHOTS=<dir>` (and a fresh `DIKTE_DATA_DIR`, so the
// flow is shown) → every scenario is rendered in Turkish and English to `<dir>/<lang>-<scenario>.png`
// and the app quits. With `DIKTE_ONBOARDING_LIVE=1` the real window (live engine data) is rendered
// too, as `live-<step>.png`.

@Observable
final class PreviewOnboardingBackend: OnboardingBackend {
    var uiLanguage: AppLanguage = Localizer.shared.language {
        didSet { Localizer.shared.language = uiLanguage }
    }
    var dictationLanguage: DictationLanguage = .auto
    var model: ModelInfo?
    var system: SystemInfo?
    var minFreeBytes: Int64 = 10 * 1_073_741_824
    var engineStatus: EngineStatus = .running(port: 1)
    var silenceSeconds: Double = 3
    var micPermission: MicPermission = .notDetermined

    init() {}

    func refreshMicPermission() {}
    func requestMicPermission() async { micPermission = .granted }
    func download() async throws {
        model?.state = .downloading
        model?.progress = 0
    }
    func restartEngine() { engineStatus = .starting }
    func startTestDictation() {}
    func markCompleted() {}
}

enum OnboardingPreviewScenario: String, CaseIterable {
    case language
    case modelNotDownloaded = "model-not-downloaded"
    case modelDownloading = "model-downloading"
    case modelReady = "model-ready"
    case modelInsufficientDisk = "model-insufficient-disk"
    case modelPaused = "model-paused"
    case modelEngineStarting = "model-engine-starting"
    case modelEngineFailed = "model-engine-failed"
    case micNotDetermined = "mic-not-determined"
    case micGranted = "mic-granted"
    case micDenied = "mic-denied"
    case shortcutReady = "shortcut-ready"
    case shortcutNotReady = "shortcut-not-ready"

    static let gib: Int64 = 1_073_741_824

    static func fakeModel(_ state: ModelState, progress: Double? = nil) -> ModelInfo {
        let size: Int64 = 3_084_000_000
        return ModelInfo(id: "large-v3", label: "Whisper large-v3", repo: "mlx-community/whisper-large-v3-mlx",
                         kind: "mlx-whisper", custom: false, recommended: true, note: "",
                         sizeBytes: size, downloadedBytes: Int64(Double(size) * (progress ?? (state == .onDisk ? 1 : 0))),
                         ramBytes: 3_700_000_000, state: state, progress: state == .downloading ? progress : nil,
                         error: nil)
    }

    static func fakeSystem(free: Int64 = 415 * gib) -> SystemInfo {
        SystemInfo(diskFreeBytes: free, minFreeBytes: 10 * gib, ramTotalBytes: 24 * gib,
                   ramAvailableBytes: 14 * gib, idleUnloadS: 300, idleUnloadAt: nil, selectedModel: "large-v3")
    }

    @MainActor func flow() -> OnboardingFlow {
        let b = PreviewOnboardingBackend()
        b.system = Self.fakeSystem()
        b.model = Self.fakeModel(.notDownloaded)
        let step: OnboardingStep
        switch self {
        case .language:
            step = .language
        case .modelNotDownloaded:
            step = .model
        case .modelDownloading:
            step = .model
            b.model = Self.fakeModel(.downloading, progress: 0.4)
        case .modelReady:
            step = .model
            b.model = Self.fakeModel(.onDisk)
        case .modelInsufficientDisk:
            step = .model
            b.system = Self.fakeSystem(free: 12 * Self.gib)
        case .modelPaused:
            step = .model
            var m = Self.fakeModel(.paused, progress: 0.62)
            m.error = "İnternet bağlantısı koptu; indirme duraklatıldı."
            b.model = m
        case .modelEngineStarting:
            step = .model
            b.engineStatus = .starting
            b.model = nil
            b.system = nil
        case .modelEngineFailed:
            step = .model
            b.engineStatus = .failed("Motor 60 saniye içinde hazır olmadı. Ayrıntılar: logs/engine.log")
            b.model = nil
            b.system = nil
        case .micNotDetermined:
            step = .microphone
        case .micGranted:
            step = .microphone
            b.micPermission = .granted
        case .micDenied:
            step = .microphone
            b.micPermission = .denied
        case .shortcutReady:
            step = .shortcut
            b.model = Self.fakeModel(.onDisk)
            b.micPermission = .granted
        case .shortcutNotReady:
            step = .shortcut
            b.model = Self.fakeModel(.downloading, progress: 0.4)
            b.micPermission = .granted
        }
        return OnboardingFlow(backend: b, step: step)
    }
}

private struct ScenarioPreview: View {
    var scenario: OnboardingPreviewScenario
    var language: AppLanguage
    var body: some View {
        OnboardingView(flow: scenario.flow())
            .onAppear {
                OnboardingDebug.installEnglishFallback()
                Localizer.shared.language = language
            }
    }
}

#Preview("1 Dil") { ScenarioPreview(scenario: .language, language: .tr) }
#Preview("1 Language (en)") { ScenarioPreview(scenario: .language, language: .en) }
#Preview("2 Model — indirilmedi") { ScenarioPreview(scenario: .modelNotDownloaded, language: .tr) }
#Preview("2 Model — %40") { ScenarioPreview(scenario: .modelDownloading, language: .tr) }
#Preview("2 Model — hazır") { ScenarioPreview(scenario: .modelReady, language: .tr) }
#Preview("2 Model — az disk") { ScenarioPreview(scenario: .modelInsufficientDisk, language: .tr) }
#Preview("2 Model — motor yok") { ScenarioPreview(scenario: .modelEngineFailed, language: .tr) }
#Preview("2 Model — disk (en)") { ScenarioPreview(scenario: .modelInsufficientDisk, language: .en) }
#Preview("3 Mikrofon — sorulmadı") { ScenarioPreview(scenario: .micNotDetermined, language: .tr) }
#Preview("3 Mikrofon — verildi") { ScenarioPreview(scenario: .micGranted, language: .tr) }
#Preview("3 Mikrofon — reddedildi") { ScenarioPreview(scenario: .micDenied, language: .tr) }
#Preview("4 Kısayol — hazır") { ScenarioPreview(scenario: .shortcutReady, language: .tr) }
#Preview("4 Kısayol — model iniyor") { ScenarioPreview(scenario: .shortcutNotReady, language: .en) }

enum OnboardingDebug {
    /// Renders the snapshots and quits when `DIKTE_ONBOARDING_SNAPSHOTS` is set.
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DIKTE_ONBOARDING_SNAPSHOTS"], !dir.isEmpty else { return false }
        installEnglishFallback()
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let live = env["DIKTE_ONBOARDING_LIVE"] == "1"
        // RunLoop (not GCD) so the nested run loops below can still drain the main queue.
        RunLoop.main.perform { MainActor.assumeIsolated {
            let original = Localizer.shared.language
            for language in AppLanguage.allCases {
                Localizer.shared.language = language
                for scenario in OnboardingPreviewScenario.allCases {
                    renderView(OnboardingView(flow: scenario.flow()),
                               to: folder.appendingPathComponent("\(language.rawValue)-\(scenario.rawValue).png"))
                }
            }
            Localizer.shared.language = .en
            renderView(OnboardingView(flow: OnboardingPreviewScenario.modelDownloading.flow()),
                       appearance: .darkAqua, to: folder.appendingPathComponent("en-model-downloading-dark.png"))
            Localizer.shared.language = original
            if live { renderLive(to: folder) }
            exit(0)
        } }
        return true
    }

    private static func renderView(_ view: some View, appearance: NSAppearance.Name = .aqua, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -3000, y: -3000), size: OnboardingView.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        write(host, to: url)
        window.orderOut(nil)
    }

    /// The real window on live engine data: waits for the engine catalog, then renders every step.
    private static func renderLive(to folder: URL) {
        let flow = OnboardingFlow(backend: LiveOnboardingBackend(state: .shared))
        let window = OnboardingWindowController.makeWindow(flow: flow)
        window.setFrameOrigin(CGPoint(x: -3000, y: -3000))
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(90)
        while flow.backend.model == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        print("live: engine=\(flow.backend.engineStatus) model=\(String(describing: flow.backend.model?.state))",
              "title=\(window.title)")
        func capture(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if let view = window.contentView { write(view, to: folder.appendingPathComponent("live-\(name).png")) }
        }
        for step in OnboardingStep.allCases {
            flow.step = step
            capture("\(step.number)")
        }
        // Switching the UI language in step 1 re-renders everything at once (window title too).
        flow.step = .language
        let original = flow.backend.uiLanguage
        flow.backend.uiLanguage = original == .tr ? .en : .tr
        capture("1-switched")
        print("live: switched to \(flow.backend.uiLanguage.rawValue), title=\(window.title)")
        flow.backend.uiLanguage = original

        // Optional: start the real download, show it, then cancel and delete the partial files.
        if ProcessInfo.processInfo.environment["DIKTE_ONBOARDING_LIVE_DOWNLOAD"] == "1" {
            flow.step = .model
            flow.startDownload()
            let until = Date().addingTimeInterval(20)
            while Date() < until, flow.downloadError == nil {
                if case .downloading(let progress) = flow.modelPhase, progress > 0 { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            print("live download: phase=\(flow.modelPhase) error=\(flow.downloadError ?? "-")")
            capture("2-downloading")
            flow.step = .shortcut
            capture("4-downloading")
            let engine = AppState.shared.engine
            Task {
                try? await engine.cancelDownload(LiveOnboardingBackend.modelID)
                try? await engine.delete(LiveOnboardingBackend.modelID)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            print("live download cleanup: state=\(String(describing: flow.backend.model?.state))")
        }
        window.orderOut(nil)
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The hosting view draws no background of its own: put it on the window background color.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return }
        let pixels = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            pixels.fill()
        }
        rep.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        out.size = rep.size
        try? out.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot:", url.path)
    }

    private static var fallbackInstalled = false

    /// English for keys the app bundle doesn't translate yet: read from `i18n/onboarding.json` in
    /// the repo (until the lead merges it into the String Catalog).
    static func installEnglishFallback() {
        guard !fallbackInstalled else { return }
        fallbackInstalled = true
        guard let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let replacement = class_getInstanceMethod(Bundle.self,
                                                        #selector(Bundle.onboardingFallbackString(forKey:value:table:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

private nonisolated enum OnboardingFallbackTable {
    static let english: [String: String] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("i18n/onboarding.json")
        guard let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()
}

extension Bundle {
    /// Swapped with `localizedString(forKey:value:table:)`, so calling it runs the original.
    @objc nonisolated fileprivate func onboardingFallbackString(forKey key: String, value: String?,
                                                               table: String?) -> String {
        let s = onboardingFallbackString(forKey: key, value: value, table: table)
        guard s == key, bundlePath.hasSuffix("/en.lproj"), let english = OnboardingFallbackTable.english[key] else { return s }
        return english
    }
}
#endif
