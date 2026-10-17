import AppKit
import Foundation
import Observation

/// settings.json
@Observable
final class SettingsStore {
    /// Mutate freely; changes are saved (debounced) and `onChange` fires.
    var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            onChange?(settings)
            scheduleSave()
        }
    }
    /// Set by AppState to push engine config when settings change.
    @ObservationIgnored var onChange: ((AppSettings) -> Void)?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        url = Paths.settingsFile
        if var loaded = StoreJSON.load(AppSettings.self, from: url) {
            if let legacy = Self.legacyDelivery(at: url) {
                // Before 0.4.3: a default app + favourites shown A–Z; keep what the panel showed.
                loaded.deliveryTargets = AppSettings.migratedTargets(
                    defaultApp: legacy.defaultApp, favorites: legacy.favorites,
                    locale: loaded.uiLanguage.locale, name: DeliveryService.installedName)
                StoreJSON.save(loaded, to: url)
            }
            settings = loaded
        } else {
            StoreJSON.save(settings, to: url)
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// The old delivery keys of a file without `deliveryTargets`; nil if there is nothing to convert.
    private static func legacyDelivery(at url: URL) -> (defaultApp: String?, favorites: [String])? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["deliveryTargets"] == nil else { return nil }
        let defaultApp = dict["deliveryDefaultApp"] as? String
        let favorites = dict["deliveryFavorites"] as? [String] ?? []
        guard defaultApp != nil || !favorites.isEmpty else { return nil }
        return (defaultApp, favorites)
    }

    /// Write pending changes now.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        StoreJSON.save(settings, to: url)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            StoreJSON.save(self.settings, to: self.url)
        }
    }
}
