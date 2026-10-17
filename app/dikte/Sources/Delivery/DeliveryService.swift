import AppKit
import ApplicationServices
import Observation
import OSLog
import UniformTypeIdentifiers

// CONTRACT — implemented by agent "delivery". Sends dictated text to the clipboard or pastes it
// into another app (activate/launch the app, ⌘V via CGEvent — needs Accessibility permission).

/// An app the text can be delivered to.
struct TargetApp: Identifiable, Equatable, Sendable {
    var bundleID: String
    var name: String
    var url: URL?
    var isRunning: Bool
    var id: String { bundleID }
}

/// A row of the panel's AKTAR list.
struct DeliveryEntry: Identifiable, Equatable, Sendable {
    /// `defaultTarget` = first of the user's list, `favorite` = the rest of it (both can be
    /// reordered), `other` = running apps that aren't in the list.
    enum Role: Sendable { case defaultTarget, favorite, other }
    /// nil = "Panoya kopyala".
    var app: TargetApp?
    var role: Role
    var isFavorite: Bool
    /// ⌘1…⌘9 for non-default rows in display order (nil beyond 9); the default row uses the send key.
    var shortcut: Int?
    /// Its `AppSettings.deliveryTargets` entry (bundle id or `AppSettings.clipboard`).
    var id: String { app?.bundleID ?? AppSettings.clipboard }
    /// In the user's list, so it can be moved.
    var isMovable: Bool { role != .other }
}

enum DeliveryError: Error, Equatable, Sendable {
    case accessibilityDenied
    case appNotFound
    case launchFailed
    case activationTimeout
    /// Launched, but nothing that takes text got focus in time.
    case notReady
    case pasteFailed
}

@Observable
final class DeliveryService {
    /// Whether Dikte may post ⌘V to other apps (AXIsProcessTrusted). Refreshed by `refreshTrust()`.
    private(set) var accessibilityTrusted = false

    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.mehmetcaykara.dikte", category: "delivery")
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var trustPoll: Task<Void, Never>?

    init() {
        accessibilityTrusted = AXIsProcessTrusted()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
    }

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    /// Shows the system prompt / opens Privacy › Accessibility.
    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt; the literal avoids the global's concurrency warning.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        guard !accessibilityTrusted else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // An agent app isn't re-activated when the user comes back from System Settings, so
        // also poll for a while.
        trustPoll?.cancel()
        trustPoll = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshTrust()
                if self.accessibilityTrusted { return }
            }
        }
    }

    /// Running regular apps with a UI, excluding Dikte itself.
    func runningApps() -> [TargetApp] {
        let own = Bundle.main.bundleIdentifier
        var seen: Set<String> = []
        var apps: [TargetApp] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { continue }
            let name = app.localizedName ?? app.bundleURL.map(Self.bundleName) ?? id
            apps.append(TargetApp(bundleID: id, name: name, url: app.bundleURL, isRunning: true))
        }
        return apps
    }

    /// Installed or running app for a bundle id (favourites may be closed).
    func resolve(bundleID: String) -> TargetApp? {
        if let app = runningApps().first(where: { $0.bundleID == bundleID }) { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return TargetApp(bundleID: bundleID, name: Self.bundleName(url), url: url, isRunning: false)
    }

    /// Display name of an installed app; nil if it isn't installed.
    static func installedName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(bundleName)
    }

    func icon(for app: TargetApp) -> NSImage {
        if let cached = icons[app.bundleID] { return cached }
        let url = app.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        guard let url else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[app.bundleID] = image
        return image
    }

    /// AKTAR rows: the user's targets in their order (the first is the default) → other running
    /// apps (A–Z, UI locale), `settings.deliveryOtherLimit` of them visible; the rest in `more`.
    func entries(for settings: AppSettings) -> (visible: [DeliveryEntry], more: [DeliveryEntry]) {
        let running = runningApps()
        return Self.entries(targets: settings.deliveryTargets,
                            running: running, locale: Localizer.shared.language.locale,
                            limit: settings.deliveryOtherLimit) { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return TargetApp(bundleID: id, name: Self.bundleName(url), url: url, isRunning: false)
        }
    }

    /// Pure ordering behind `entries(for:)`. `running` apps win over `resolve` (installed apps,
    /// nil = not installed). Targets that aren't installed are skipped, so the next one can become
    /// the default.
    static func entries(targets: [String], running: [TargetApp], locale: Locale,
                        limit: Int, resolve: (String) -> TargetApp?)
        -> (visible: [DeliveryEntry], more: [DeliveryEntry]) {
        var runningByID: [String: TargetApp] = [:]
        for app in running where runningByID[app.bundleID] == nil { runningByID[app.bundleID] = app }
        func lookup(_ id: String) -> TargetApp? { runningByID[id] ?? resolve(id) }

        var used: Set<String> = []
        var visible: [DeliveryEntry] = []
        for id in AppSettings.normalizedTargets(targets) where used.insert(id).inserted {
            let role: DeliveryEntry.Role = visible.isEmpty ? .defaultTarget : .favorite
            if id == AppSettings.clipboard {
                visible.append(DeliveryEntry(app: nil, role: role, isFavorite: false, shortcut: nil))
            } else if let app = lookup(id) {
                visible.append(DeliveryEntry(app: app, role: role, isFavorite: true, shortcut: nil))
            }
        }

        let others = running.filter { used.insert($0.bundleID).inserted }.sorted {
            switch $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: locale) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.bundleID < $1.bundleID
            }
        }
        let shown = max(0, limit)
        visible += others.prefix(shown).map { DeliveryEntry(app: $0, role: .other, isFavorite: false, shortcut: nil) }
        let more = others.dropFirst(shown).map { DeliveryEntry(app: $0, role: .other, isFavorite: false, shortcut: nil) }

        for i in 1..<min(visible.count, 10) { visible[i].shortcut = i }
        return (visible, more)
    }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Put `text` on the clipboard, bring `bundleID` to the front (launching it if needed), paste
    /// with ⌘V and — if `restoreClipboard` — restore the previous clipboard afterwards. On failure
    /// the text stays on the clipboard.
    func deliver(_ text: String, to bundleID: String, restoreClipboard: Bool) async throws {
        refreshTrust()
        guard accessibilityTrusted else {
            copyToClipboard(text)
            throw DeliveryError.accessibilityDenied
        }

        let pb = NSPasteboard.general
        let snapshot = Self.snapshot(pb)
        copyToClipboard(text)
        let ours = pb.changeCount

        let start = Date()
        let launched: Bool
        do {
            launched = try await bringToFront(bundleID)
        } catch {
            log.error("deliver \(bundleID, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        // Paste only once something that takes text has focus: a fresh launch (Electron apps
        // especially) needs seconds for its window and text field. A running app is usually ready;
        // if focus can't be told there, paste anyway as before.
        let ready = await waitUntilReady(bundleID, timeout: launched ? 15 : 1.5)
        log.info("deliver \(bundleID, privacy: .public): launched=\(launched) ready=\(ready) after \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        if !ready && launched { throw DeliveryError.notReady }
        try? await Task.sleep(for: .milliseconds(launched ? 250 : 120))

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { throw DeliveryError.pasteFailed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        guard restoreClipboard else { return }
        // The target reads the pasteboard while handling ⌘V; restore only afterwards and only
        // if nobody else wrote to it in the meantime.
        try? await Task.sleep(for: .milliseconds(250))
        if pb.changeCount == ours { Self.restore(snapshot, to: pb) }
    }

    /// Activates (or launches) the app and waits until it is frontmost. Returns whether it was launched.
    private func bringToFront(_ bundleID: String) async throws -> Bool {
        var launched = false
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateAllWindows])
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw DeliveryError.appNotFound
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            } catch {
                throw DeliveryError.launchFailed
            }
            launched = true
        }

        // A launch can take a few seconds before the app is frontmost.
        let deadline = Date().addingTimeInterval(launched ? 10 : 3)
        var nudged = launched
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            guard Date() < deadline else { throw DeliveryError.activationTimeout }
            // Activation can be refused (e.g. no windows); asking LaunchServices to open the app
            // again reactivates it and lets it reopen a window.
            if !nudged, deadline.timeIntervalSinceNow < 2,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                nudged = true
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return launched
    }

    /// Until the app has finished launching, is frontmost and focuses something that takes text.
    private func waitUntilReady(_ bundleID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var askedForTree = false
        while true {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }), app.isFinishedLaunching,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                if !askedForTree {
                    // Electron / Chromium apps build their accessibility tree only when asked.
                    AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    askedForTree = true
                }
                if Self.focusesText(element) { return true }
            }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Whether the app's focused element takes typed text (a text field / area, or a settable value).
    static func focusesText(_ app: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String,
           [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let items = snapshot.filter { !$0.isEmpty }.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Display name from an app bundle: CFBundleDisplayName → CFBundleName → file name.
    static func bundleName(_ url: URL) -> String {
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? [:]
        let base = bundle?.infoDictionary ?? [:]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info[key] ?? base[key]) as? String, !name.isEmpty { return name }
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
