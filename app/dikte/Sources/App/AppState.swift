import Foundation
import Observation

/// Single composition root. Views read it from the environment.
@Observable
final class AppState {
    static let shared = AppState()

    let settings = SettingsStore()
    let history = HistoryStore()
    let terms = TermsStore()
    let engine = EngineController()
    let dictation = DictationController()

    private init() {}

    /// Called once at launch.
    func bootstrap() {
        history.limit = { [unowned self] in settings.settings.historyLimit }
        Localizer.shared.language = settings.settings.uiLanguage
        settings.onChange = { [unowned self] s in
            Localizer.shared.language = s.uiLanguage
            engine.pushConfig(s.engineConfig)
        }
        terms.onChange = { [unowned self] t in
            engine.pushConfig(EngineConfig(terms: t))
        }
        var config = settings.settings.engineConfig
        config.terms = terms.terms
        engine.pushConfig(config)
        engine.start()

        // First run only (no terms.json yet): seed from the engine's bundled default list.
        // An intentionally emptied list is left alone.
        if !FileManager.default.fileExists(atPath: Paths.termsFile.path) {
            Task { [weak self] in
                for _ in 0..<30 {
                    guard let self else { return }
                    if self.engine.isRunning, let t = try? await self.engine.defaultTerms(), !t.isEmpty {
                        self.terms.replaceAll(t)
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func shutdown() {
        engine.stop()
    }
}
