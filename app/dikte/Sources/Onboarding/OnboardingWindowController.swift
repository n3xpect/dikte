import AppKit

// CONTRACT — implemented by agent "onboarding". Welcome flow shown on fresh installs
// (`settings.onboardingCompleted == false`): 1) UI + dictation language, 2) model download,
// 3) microphone permission, 4) shortcut intro + optional test dictation. Sets
// `onboardingCompleted = true` when finished.

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private init() {}

    /// Create (once) and bring the welcome window to front.
    func show() {}
}
