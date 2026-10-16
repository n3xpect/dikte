import AppKit
import AVFoundation
import SwiftUI

/// İzinler wired to the live system state; polled while the page is open so a change made in
/// System Settings shows up without leaving it.
struct PermissionsTab: View {
    let state: AppState
    @State private var microphone = MicPermission.current

    var body: some View {
        let delivery = state.delivery
        PermissionsView(
            microphone: microphone,
            accessibilityTrusted: delivery.accessibilityTrusted,
            requestMicrophone: {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    microphone = .current
                }
            },
            openMicrophoneSettings: { NSWorkspace.shared.open(OnboardingFlow.microphoneSettingsURL) },
            requestAccessibility: delivery.requestAccessibility
        )
        .task {
            while !Task.isCancelled {
                microphone = .current
                delivery.refreshTrust()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// İzinler: microphone (required for dictation) and Accessibility (pasting into an app).
struct PermissionsView: View {
    var microphone: MicPermission
    var accessibilityTrusted: Bool
    var requestMicrophone: () -> Void
    var openMicrophoneSettings: () -> Void
    var requestAccessibility: () -> Void

    var body: some View {
        Form {
            Section {
                microphoneRow
                accessibilityRow
            } footer: {
                Text(L("Durum, izni Sistem Ayarları'nda değiştirdiğinde kendiliğinden güncellenir."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var microphoneRow: some View {
        PermissionRow(
            symbol: microphone == .denied ? "mic.slash.fill" : "mic.fill",
            symbolColor: microphone == .denied ? Palette.danger : .accentColor,
            title: L("Mikrofon izni"),
            status: microphone == .granted ? .granted : microphone == .denied ? .denied : .notGranted,
            text: microphoneText
        ) {
            switch microphone {
            case .granted: EmptyView()
            case .notDetermined:
                Button(L("İzin ver"), systemImage: "mic.fill", action: requestMicrophone)
                    .buttonStyle(.borderedProminent)
            case .denied:
                Button(L("Sistem Ayarları'nı aç"), systemImage: "gearshape", action: openMicrophoneSettings)
            }
        }
    }

    private var microphoneText: String {
        switch microphone {
        case .granted: L("Dikte mikrofonu yalnızca kısayola bastığında kullanır.")
        case .notDetermined: L("Dikte için gerekli. “İzin ver”e bastığında macOS sana soracak.")
        case .denied: L("Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon bölümünde Dikte'yi aç.")
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(
            symbol: "accessibility",
            symbolColor: .accentColor,
            title: L("Erişilebilirlik izni"),
            status: accessibilityTrusted ? .granted : .notGranted,
            text: L("Metni bir uygulamaya yapıştırmak için gerekli; sadece panoyu kullanacaksan gerekmez.")
        ) {
            if !accessibilityTrusted {
                Button(L("İzin ver…"), action: requestAccessibility)
            }
        }
    }
}

private struct PermissionRow<Action: View>: View {
    enum Status { case granted, notGranted, denied }

    var symbol: String
    var symbolColor: Color
    var title: String
    var status: Status
    var text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 22))
                .foregroundStyle(status == .granted ? Palette.loaded : symbolColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    statusLabel.font(.callout)
                }
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .granted:
            Label(L("Verildi"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.loadedText)
        case .notGranted:
            Label { Text(L("Verilmedi")) } icon: { Image(systemName: "circle.fill").imageScale(.small) }
                .foregroundStyle(Palette.loading)
        case .denied:
            Label { Text(L("Reddedildi")) } icon: { Image(systemName: "circle.fill").imageScale(.small) }
                .foregroundStyle(Palette.danger)
        }
    }
}
