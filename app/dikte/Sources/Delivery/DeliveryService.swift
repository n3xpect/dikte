import AppKit
import Observation

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
    enum Role: Sendable { case defaultTarget, favorite, other }
    /// nil = "Panoya kopyala" (only ever the default row).
    var app: TargetApp?
    var role: Role
    var isFavorite: Bool
    /// ⌘1…⌘9 for non-default rows in display order (nil beyond 9); the default row uses ⇧↩.
    var shortcut: Int?
    var id: String { app?.bundleID ?? "clipboard" }
}

enum DeliveryError: Error, Equatable, Sendable {
    case accessibilityDenied
    case appNotFound
    case launchFailed
    case activationTimeout
    case pasteFailed
}

@Observable
final class DeliveryService {
    /// Whether Dikte may post ⌘V to other apps (AXIsProcessTrusted). Refreshed by `refreshTrust()`.
    private(set) var accessibilityTrusted = false

    init() {}

    func refreshTrust() {}
    /// Shows the system prompt / opens Privacy › Accessibility.
    func requestAccessibility() {}

    /// Running regular apps with a UI, excluding Dikte itself.
    func runningApps() -> [TargetApp] { [] }
    /// Installed or running app for a bundle id (favourites may be closed).
    func resolve(bundleID: String) -> TargetApp? { nil }
    func icon(for app: TargetApp) -> NSImage { NSImage() }

    /// AKTAR rows per the agreed order: default (app or clipboard) → favourites (A–Z, UI locale)
    /// → other running apps (A–Z), `settings.deliveryOtherLimit` of them visible; the rest in `more`.
    func entries(for settings: AppSettings) -> (visible: [DeliveryEntry], more: [DeliveryEntry]) { ([], []) }

    func copyToClipboard(_ text: String) {}

    /// Put `text` on the clipboard, bring `bundleID` to the front (launching it if needed), paste
    /// with ⌘V and — if `restoreClipboard` — restore the previous clipboard afterwards. On failure
    /// the text stays on the clipboard.
    func deliver(_ text: String, to bundleID: String, restoreClipboard: Bool) async throws {}
}
