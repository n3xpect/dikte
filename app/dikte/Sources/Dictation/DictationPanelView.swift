import AppKit
import SwiftUI

/// Content of the floating dictation panel, one layout per phase.
struct DictationPanelView: View {
    static let width: CGFloat = 560
    static let cornerRadius: CGFloat = 18

    @Bindable var controller: DictationController
    /// Ideal height of the content; the panel resizes itself to it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(width: Self.width, alignment: .leading)
            .background { PanelBackground() }
            .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle, .listening:
            ListeningContent(controller: controller)
        case .transcribing:
            TranscribingContent(modelLoading: controller.modelLoading)
        case .editing:
            if controller.suggestions.isEmpty {
                EditingContent(controller: controller)
            } else {
                SuggestionsContent(controller: controller)
            }
        case .failed(let message):
            FailedContent(controller: controller, message: message)
        }
    }
}

// MARK: - Phases

private struct ListeningContent: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !controller.speechDetected)
                Text(controller.speechDetected ? L("Konuşma algılandı") : L("Dinliyorum…"))
                    .font(.headline)
                Spacer(minLength: 8)
                if controller.modelLoading { ModelLoadingBadge() }
            }
            WaveformView(levels: controller.levels, active: controller.speechDetected)
                .frame(height: 44)
            HintText(L("**Enter**: bitir · **Esc**: vazgeç"))
        }
    }
}

private struct TranscribingContent: View {
    let modelLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(modelLoading ? L("Model hazırlanıyor…") : L("Çevriliyor…")).font(.headline)
                Spacer(minLength: 0)
            }
            HintText(L("**Esc**: vazgeç"))
        }
    }
}

private struct EditingContent: View {
    @Bindable var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DictationTextView(text: $controller.text, isEditable: !controller.retranscribing)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                }
                .overlay {
                    if controller.retranscribing { RetranscribingOverlay(target: controller.otherLanguage) }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                }
            if let error = controller.languageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if !controller.shownDeliveryEntries.isEmpty {
                DeliveryListView(controller: controller)
            }
            if controller.confirmingLanguageSwitch {
                ConfirmSwitchRow(controller: controller)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    if controller.retranscribing {
                        HintText(L("**Esc**: vazgeç"))
                    } else {
                        Text(DeliveryHint.attributed(controller.editingHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    LanguageBadge(controller: controller)
                }
            }
        }
    }
}

/// Detected language ("TR" / "EN"); click = transcribe again in the other language (⌘L).
private struct LanguageBadge: View {
    let controller: DictationController

    var body: some View {
        let enabled = controller.canSwitchLanguage && !controller.retranscribing
        Button { controller.switchLanguage() } label: {
            HStack(spacing: 4) {
                Text(verbatim: controller.language.uppercased())
                    .font(.caption.weight(.semibold))
                if controller.canSwitchLanguage {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(controller.language == "en" ? L("Dil: İngilizce") : L("Dil: Türkçe"))
    }

    private var help: String {
        guard controller.canSwitchLanguage else { return L("Bu kayıt yeniden çevrilemez") }
        return controller.otherLanguage == "en"
            ? L("İngilizce olarak yeniden çevir (⌘L)")
            : L("Türkçe olarak yeniden çevir (⌘L)")
    }
}

/// Covers the text area while the recording is transcribed again.
private struct RetranscribingOverlay: View {
    let target: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(target == "en" ? L("İngilizce olarak yeniden çevriliyor…") : L("Türkçe olarak yeniden çevriliyor…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The user edited the text; switching language would replace it.
private struct ConfirmSwitchRow: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L("Düzenlemen kaybolacak — yine de çevir?"))
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("Vazgeç")) { controller.cancelLanguageSwitch() }
            Button(L("Çevir")) { controller.switchLanguage() }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }
}

private struct SuggestionsContent: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = controller.pendingTarget {
                Label(L("%@ uygulamasına aktarılacak", target.name), systemImage: "arrow.up.forward.app.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            } else {
                Label(L("Panoya kopyalandı"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            ForEach(controller.suggestions) { s in
                HStack(spacing: 8) {
                    Text(L("«%@» → «%@» terimlere eklensin mi?", s.wrong, s.right))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("Ekle")) { controller.acceptSuggestion(s) }
                        .buttonStyle(.borderedProminent)
                    Button(L("Geç")) { controller.skipSuggestion(s) }
                }
                .controlSize(.small)
            }
            HintText(controller.pendingTarget == nil ? L("**Esc**: hepsini geç")
                                                     : L("**Esc**: hepsini geç ve aktar"))
        }
    }
}

private struct FailedContent: View {
    let controller: DictationController
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: controller.isNotice ? "waveform.slash" : "exclamationmark.triangle.fill")
                    .foregroundStyle(controller.isNotice ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Text(message)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = controller.failureHint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !controller.isNotice {
                HStack {
                    HintText(L("**Esc**: kapat"))
                    Spacer(minLength: 8)
                    if let action = controller.failureAction {
                        Button(action.title) { controller.performFailureAction() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct HintText: View {
    /// Already localized; `**bold**` marks the keys.
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ModelLoadingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(L("Model hazırlanıyor…")).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)
    }
}

/// Scrolling bars from mic levels, newest on the right; older bars fade out.
struct WaveformView: View {
    var levels: [Float]
    var active: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = DictationController.waveformBarCount
            let barWidth: CGFloat = 4
            let gap = (size.width - CGFloat(n) * barWidth) / CGFloat(n - 1)
            let recent = levels.suffix(n)
            let padded = [Float](repeating: 0, count: n - recent.count) + recent
            let color: Color = active ? .accentColor : .primary
            for (i, level) in padded.enumerated() {
                let h = max(3, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - h) / 2, width: barWidth, height: h)
                let opacity = 0.25 + 0.75 * Double(i) / Double(n - 1)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(color.opacity(active ? opacity : opacity * 0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Snapshot rendering can't draw behind-window blur; it swaps in a solid background.
private struct SolidPanelBackgroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var solidPanelBackground: Bool {
        get { self[SolidPanelBackgroundKey.self] }
        set { self[SolidPanelBackgroundKey.self] = newValue }
    }
}

private struct PanelBackground: View {
    @Environment(\.solidPanelBackground) private var solid

    var body: some View {
        if solid {
            Color(nsColor: .windowBackgroundColor)
        } else {
            VisualEffectBackground()
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active   // stay vibrant while Dikte is not the active app
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Text area

/// Plain-text NSTextView that sizes to its content (scrolls past `maxHeight`), takes focus with the
/// cursor at the end when it appears, and keeps Enter = newline. Shift+Enter / ⌘1–9 / Esc are intercepted
/// by `DictationPanelController` before they reach it.
struct DictationTextView: NSViewRepresentable {
    @Binding var text: String
    /// Off while the text is being replaced (re-transcription).
    var isEditable = true
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = 260

    static let font = NSFont.systemFont(ofSize: 15)
    static let inset = NSSize(width: 6, height: 8)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FocusingTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.drawsBackground = false
        tv.textContainerInset = Self.inset
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        tv.isEditable = isEditable
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.isEditable != isEditable { tv.isEditable = isEditable }
        if tv.string != text {
            // Replaced from outside (new transcription): caret back to the end.
            tv.string = text
            let end = NSRange(location: (text as NSString).length, length: 0)
            tv.setSelectedRange(end)
            tv.scrollRangeToVisible(end)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? DictationPanelView.width - 36
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: Self.font])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: max(width - 2 * Self.inset.width, 10),
                                                     height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + 2 * Self.inset.height
        return CGSize(width: width, height: min(max(height.rounded(.up), minHeight), maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

private final class FocusingTextView: NSTextView {
    private var focusOnAttach = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, window != nil else { return }
        focusOnAttach = false
        DispatchQueue.main.async {
            guard let window = self.window else { return }
            window.makeFirstResponder(self)
            let end = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: end, length: 0))
            self.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Dinliyorum") { DictationPanelView(controller: .preview(.listening)).padding() }
#Preview("Model hazırlanıyor") { DictationPanelView(controller: .preview(.listeningModelLoading)).padding() }
#Preview("Çevriliyor") { DictationPanelView(controller: .preview(.transcribing)).padding() }
#Preview("Düzenleme") { DictationPanelView(controller: .preview(.editing)).padding() }
#Preview("Düzenleme EN") { DictationPanelView(controller: .preview(.editingEnglish)).padding() }
#Preview("Yeniden çevriliyor") { DictationPanelView(controller: .preview(.retranscribing)).padding() }
#Preview("Dil değişimi onayı") { DictationPanelView(controller: .preview(.confirmSwitch)).padding() }
#Preview("Dil hatası") { DictationPanelView(controller: .preview(.languageError)).padding() }
#Preview("Aktar: uygulama") { DictationPanelView(controller: .preview(.deliveryApp)).padding() }
#Preview("Aktar: hepsi") { DictationPanelView(controller: .preview(.deliveryExpanded)).padding() }
#Preview("Aktar: ipucu yok") { DictationPanelView(controller: .preview(.deliveryTipDismissed)).padding() }
#Preview("Öneriler") { DictationPanelView(controller: .preview(.suggestions)).padding() }
#Preview("Öneriler: uygulama") { DictationPanelView(controller: .preview(.suggestionsApp)).padding() }
#Preview("Toast") {
    VStack {
        DeliveryToastView(content: .failure(DeliveryError.pasteFailed, appName: "Slack"))
        DeliveryToastView(content: .failure(DeliveryError.accessibilityDenied, appName: "Slack"))
    }
    .padding()
}
#Preview("Hata") { DictationPanelView(controller: .preview(.failed)).padding() }
#Preview("Konuşma yok") { DictationPanelView(controller: .preview(.notice)).padding() }
#endif
