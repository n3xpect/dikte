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
        if let loaded = StoreJSON.load(AppSettings.self, from: url) {
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
