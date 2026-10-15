import AppKit
import AVFoundation
import Observation
import SwiftUI

// Launch-time permission check: if the microphone was refused, or Accessibility is missing while
// a target app is set up, one required window (no close button) lists what is missing with a way to fix it and closes
// by itself once everything is granted.
// The welcome flow asks for both itself, so this only runs after it.

/// A permission the check can ask for.
enum AppPermission: CaseIterable, Identifiable, Sendable {
    case microphone, accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: L("Mikrofon")
        case .accessibility: L("Erişilebilirlik")
        }
    }

    var purpose: String {
        switch self {
        case .microphone: L("Konuşmanı duymak için.")
        case .accessibility: L("Metni seçtiğin uygulamaya yapıştırmak için.")
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        }
    }
}

enum PermissionCheck {
    /// What's missing. Microphone: only an explicit refusal (not asked yet = asked on the first
    /// dictation). Accessibility: only when an app target is configured (else the clipboard is used).
    static func missing(microphone: AVAuthorizationStatus, accessibilityTrusted: Bool,
                        settings: AppSettings) -> [AppPermission] {
        var out: [AppPermission] = []
        if microphone == .denied || microphone == .restricted { out.append(.microphone) }
        let hasTargetApp = settings.deliveryDefaultApp != nil || !settings.deliveryFavorites.isEmpty
        if !accessibilityTrusted && hasTargetApp { out.append(.accessibility) }
        return out
    }

    /// After launch (not with the welcome flow): shows the window if anything is missing.
    static func runAtLaunch(state: AppState) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let path = env["DIKTE_PERMISSION_SNAPSHOT"], !path.isEmpty {
            RunLoop.main.perform { MainActor.assumeIsolated {
                // Quits by itself once the snapshot is written.
                show(AppPermission.allCases, state: state, snapshot: URL(fileURLWithPath: path))
            } }
            return
        }
        // Snapshot / self-test runs render and quit on their own.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--render-ui-previews") || args.contains("--selftest")
            || env["DIKTE_DICTATION_SNAPSHOTS"]?.isEmpty == false { return }
        #endif
        // Let launch finish first (status item, hotkey, engine start).
        RunLoop.main.perform { MainActor.assumeIsolated {
            state.delivery.refreshTrust()
            let missing = missing(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                                  accessibilityTrusted: state.delivery.accessibilityTrusted,
                                  settings: state.settings.settings)
            show(missing, state: state)
        } }
    }

    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    /// Window for `missing` (nothing if empty or already shown). Not modal: dictation (⌥Space) and
    /// the rest of the app keep working while it's open.
    static func show(_ missing: [AppPermission], state: AppState, snapshot: URL? = nil) {
        guard !missing.isEmpty, window == nil else { return }
        let delivery = state.delivery
        let model = PermissionAlertModel(
            missing: missing,
            isGranted: { permission in
                switch permission {
                case .microphone:
                    return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                case .accessibility:
                    delivery.refreshTrust()
                    // Also satisfied once no target app is set up any more (it's only needed then).
                    let s = state.settings.settings
                    return delivery.accessibilityTrusted
                        || (s.deliveryDefaultApp == nil && s.deliveryFavorites.isEmpty)
                }
            },
            open: { permission in
                switch permission {
                case .microphone: NSWorkspace.shared.open(OnboardingFlow.microphoneSettingsURL)
                // System prompt + Privacy › Accessibility, then polls for the grant.
                case .accessibility: delivery.requestAccessibility()
                }
            })
        let hosting = NSHostingController(rootView: PermissionAlertView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        // Required: no close button; it closes by itself once everything is granted.
        window.styleMask = [.titled]
        window.title = "Dikte"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        model.close = { [weak window] in window?.close() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let o = Self.closeObserver { NotificationCenter.default.removeObserver(o) }
                Self.closeObserver = nil
                Self.window = nil
            }
        }
        #if DEBUG
        if let snapshot {
            window.setFrameOrigin(NSPoint(x: -30_000, y: 0))
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let view = window.contentView { writeSnapshot(view, to: snapshot) }
                print("permission window: size=\(window.frame.size)")
                model.close()
                exit(0)
            }
        }
        #endif
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    private static func writeSnapshot(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot:", url.path)
    }
    #endif
}

/// Rows of the window and whether each has been granted meanwhile (polled while it is open).
@Observable
final class PermissionAlertModel {
    let missing: [AppPermission]
    private(set) var granted: Set<AppPermission> = []
    @ObservationIgnored private let isGranted: (AppPermission) -> Bool
    @ObservationIgnored let open: (AppPermission) -> Void
    @ObservationIgnored var close: () -> Void = {}

    init(missing: [AppPermission], isGranted: @escaping (AppPermission) -> Bool,
         open: @escaping (AppPermission) -> Void) {
        self.missing = missing
        self.isGranted = isGranted
        self.open = open
        refresh()
    }

    var allGranted: Bool { missing.allSatisfy(granted.contains) }

    func refresh() {
        let now = Set(missing.filter(isGranted))
        if now != granted { granted = now }
    }
}

struct PermissionAlertView: View {
    let model: PermissionAlertModel

    static let width: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.missing.count == 1 ? L("Dikte'nin bir izne ihtiyacı var")
                                                  : L("Dikte'nin bazı izinlere ihtiyacı var"))
                        .font(.title3.weight(.semibold))
                    Text(L("Devam etmek için bu izinleri vermelisin. İzin verildiğinde bu pencere kendiliğinden kapanır."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.missing.enumerated()), id: \.element) { i, permission in
                    if i > 0 { Divider().padding(.leading, 52) }
                    row(permission)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(20)
        .frame(width: Self.width)
        .task {
            // Picks up a grant made in System Settings while the window is open.
            while !Task.isCancelled {
                model.refresh()
                if model.allGranted { model.close(); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ permission: AppPermission) -> some View {
        HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.body.weight(.semibold))
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if model.granted.contains(permission) {
                Label(L("Verildi"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.loadedText)
            } else {
                Button(L("Sistem Ayarları'nı aç")) { model.open(permission) }
                    .fixedSize()
            }
        }
        .padding(12)
    }
}

#if DEBUG
extension PermissionAlertModel {
    /// Frozen rows for previews and snapshots.
    static func preview(_ missing: [AppPermission], granted: Set<AppPermission> = []) -> PermissionAlertModel {
        PermissionAlertModel(missing: missing, isGranted: { granted.contains($0) }, open: { _ in })
    }
}

#Preview("İzinler: ikisi") { PermissionAlertView(model: .preview(AppPermission.allCases)) }
#Preview("İzinler: erişilebilirlik") { PermissionAlertView(model: .preview([.accessibility])) }
#Preview("İzinler: verildi") {
    PermissionAlertView(model: .preview(AppPermission.allCases, granted: [.accessibility]))
}
#endif
