import AVFoundation
import SwiftUI

/// Kayıt wired to the live stores.
struct RecordingTab: View {
    let state: AppState
    @State private var microphones: [Microphone] = Microphone.all()

    var body: some View {
        @Bindable var settings = state.settings
        RecordingView(settings: $settings.settings, microphones: microphones)
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
                microphones = Microphone.all()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
                microphones = Microphone.all()
            }
    }
}

struct Microphone: Hashable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }

    static func all() -> [Microphone] {
        AudioCapture.availableMicrophones().map { Microphone(uid: $0.uid, name: $0.name) }
    }
}

/// Kayıt: microphone, when recording stops (silence, longest recording), sound effects.
struct RecordingView: View {
    @Binding var settings: AppSettings
    var microphones: [Microphone]

    var body: some View {
        Form {
            Section(L("Mikrofon")) {
                Picker(L("Mikrofon"), selection: $settings.microphoneUID) {
                    Text(L("Sistem varsayılanı")).tag(String?.none)
                    if !microphones.isEmpty { Divider() }
                    ForEach(microphones) { mic in
                        Text(mic.name).tag(Optional(mic.uid))
                    }
                    if let uid = settings.microphoneUID, !microphones.contains(where: { $0.uid == uid }) {
                        Text(L("Bağlı olmayan mikrofon")).tag(Optional(uid))
                    }
                }
            }

            Section {
                LabeledContent(L("Sessizlik süresi")) {
                    slider(value: $settings.silenceSeconds, in: 1...10, step: 0.5,
                           label: Fmt.seconds(settings.silenceSeconds))
                }
                .help(L("Konuşma bittikten sonra bu kadar sessizlik olunca kayıt kendiliğinden biter."))
                LabeledContent(L("En uzun kayıt süresi")) {
                    slider(value: maxMinutes, in: 1...20, step: 1,
                           label: L("%@ dk", Fmt.int(Int(maxMinutes.wrappedValue))))
                }
            } header: {
                Text(L("Kayıt süresi"))
            } footer: {
                Text(L("Kayıt, sessizlik süresi dolunca ya da en uzun süreye ulaşınca kendiliğinden biter."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Ses")) {
                Toggle(L("Ses efektleri"), isOn: $settings.soundsEnabled)
            }
        }
        .formStyle(.grouped)
    }

    /// The setting is in seconds; the slider moves in whole minutes.
    private var maxMinutes: Binding<Double> {
        Binding(
            get: { (settings.maxDurationSeconds / 60).rounded() },
            set: { settings.maxDurationSeconds = AppSettings.clampedMaxDuration($0 * 60) }
        )
    }

    private func slider(value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        label: String) -> some View {
        HStack {
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: 220)
            Text(label)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}
