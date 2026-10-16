import AppKit
import SwiftUI

/// Hakkında wired to the live app.
struct AboutTab: View {
    let state: AppState

    var body: some View {
        let selected = state.settings.settings.selectedModel
        AboutView(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            modelLabel: state.engine.models.first { $0.id == selected }?.label ?? selected,
            engineStatus: state.engine.status,
            dataDir: Paths.dataDir
        )
    }
}

/// Hakkında: version, what Dikte is, links, model / engine / data folder.
struct AboutView: View {
    var version: String
    var modelLabel: String
    var engineStatus: EngineStatus
    var dataDir: URL

    static let repository = URL(string: "https://github.com/n3xpect/dikte")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    Text(verbatim: "Dikte").font(.title2.weight(.semibold))
                    Text(L("Sürüm %@", version))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(L("Mac'inde çalışan Türkçe ve İngilizce dikte. Ses hiçbir yere gönderilmez."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    HStack {
                        Link(destination: Self.repository) { Text(verbatim: "GitHub") }
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Link(destination: Self.repository.appending(path: "releases/tag/v\(version)")) {
                            Text(L("Sürüm notları"))
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                LabeledContent(L("Model"), value: modelLabel)
                LabeledContent(L("Motor")) {
                    HStack(spacing: 6) {
                        Circle().fill(engineStatus.display.color).frame(width: 8, height: 8)
                        Text(engineStatus.display.text).lineLimit(1).truncationMode(.tail)
                    }
                }
                LabeledContent {
                    Button(L("Finder'da göster")) { NSWorkspace.shared.open(dataDir) }
                } label: {
                    Text(L("Veri klasörü"))
                    Text((dataDir.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
