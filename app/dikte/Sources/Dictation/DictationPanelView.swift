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
                TimelineView(.periodic(from: controller.recordingStartedAt, by: 1)) { ctx in
                    Text(verbatim: Fmt.recordingClock(elapsed: ctx.date.timeIntervalSince(controller.recordingStartedAt),
                                                      limit: controller.recordingLimit))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                WaveformView(levels: controller.levels, active: controller.speechDetected)
                    .frame(height: 44)
                AutoSendButton(controller: controller)
            }
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
            DictationTextView(text: $controller.text, isEditable: !controller.retranscribing,
                              cornerExclusion: AutoSendButton.textExclusion)
                .overlay(alignment: .topTrailing) {
                    AutoSendButton(controller: controller).padding(6)
                }
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
            if controller.autoSend != .off {
                AutoSendBar(controller: controller)
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

/// Countdown before the text goes to the default target; after a key or click, a note that it stopped.
private struct AutoSendBar: View {
    let controller: DictationController

    var body: some View {
        let target = controller.shownDeliveryEntries.first?.app?.name
        let send = controller.sendKey.symbol
        HStack(spacing: 10) {
            switch controller.autoSend {
            case .counting(let until, let total):
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let left = max(0, until.timeIntervalSince(ctx.date))
                    CountdownRing(progress: total > 0 ? left / total : 0, label: "\(Int(left.rounded(.up)))")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.map { L("Gönderiliyor: %@", $0) } ?? L("Panoya kopyalanıyor…"))
                        .font(.callout.weight(.medium))
                    Text(L("Durdurmak için bir tuşa bas ya da tıkla · %@ hemen gönder", send))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .stopped, .off:
                Image(systemName: "pause.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Otomatik gönderme durduruldu")).font(.callout)
                    Text(L("%@ ile gönder ya da listeden seç", send))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(controller.autoSendCounting ? Color.accentColor.opacity(0.13) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(controller.autoSendCounting ? Color.accentColor.opacity(0.35) : .primary.opacity(0.1))
        }
    }
}

/// ⏱ with the wait (or "—" when off); click opens on/off + wait, the Metin aktarımı setting itself.
private struct AutoSendButton: View {
    let controller: DictationController
    @State private var open = false

    static let height: CGFloat = 22
    /// Text-container corner left free under the button over the text area (button + margins
    /// minus the text view's inset).
    static let textExclusion = CGSize(width: 56, height: 22)

    var body: some View {
        let setting = controller.autoSendSetting
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text(verbatim: setting.enabled ? "\(Int(setting.seconds))" : "—")
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(setting.enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(setting.enabled ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(setting.enabled ? Color.accentColor.opacity(0.45) : .primary.opacity(0.12))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L("Otomatik gönder"))
        .accessibilityLabel(L("Otomatik gönder"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AutoSendPopover(controller: controller)
        }
    }
}

/// Inside ⏱: the same switch and wait as Ayarlar › Metin aktarımı.
struct AutoSendPopover: View {
    let controller: DictationController

    var body: some View {
        let setting = controller.autoSendSetting
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Otomatik gönder"), isOn: Binding(get: { setting.enabled },
                                                       set: { controller.setAutoSend(enabled: $0) }))
                .toggleStyle(.switch)
                .font(.callout.weight(.semibold))
            HStack {
                Slider(value: Binding(get: { setting.seconds }, set: { controller.setAutoSendSeconds($0) }),
                       in: AppSettings.autoSendRange, step: AppSettings.autoSendStep)
                Text(Fmt.seconds(setting.seconds))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!setting.enabled)
            Text(L("Metin geldikten sonra bu kadar beklenir, sonra varsayılan hedefe gönderilir. Ayarlar › Metin aktarımı ile aynı ayar."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260)
    }
}

private struct CountdownRing: View {
    let progress: Double
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: label)
                .font(.caption.weight(.bold).monospacedDigit())
        }
        .frame(width: 26, height: 26)
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
/// cursor at the end when it appears. The send key (↩ or ⇧↩) / ⌘1–9 / Esc are intercepted by
/// `DictationPanelController` before they reach it.
struct DictationTextView: NSViewRepresentable {
    @Binding var text: String
    /// Off while the text is being replaced (re-transcription).
    var isEditable = true
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = 260
    /// Kept free of text in the top-right corner (for a button over it), in text-container points.
    var cornerExclusion: CGSize = .zero

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
        tv.cornerExclusion = cornerExclusion
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
        container.exclusionPaths = Self.exclusionPaths(containerWidth: container.size.width, corner: cornerExclusion)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + 2 * Self.inset.height
        return CGSize(width: width, height: min(max(height.rounded(.up), minHeight), maxHeight))
    }

    static func exclusionPaths(containerWidth: CGFloat, corner: CGSize) -> [NSBezierPath] {
        guard corner.width > 0, corner.height > 0, containerWidth > corner.width else { return [] }
        return [NSBezierPath(rect: NSRect(x: containerWidth - corner.width, y: 0,
                                          width: corner.width, height: corner.height))]
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
    var cornerExclusion: CGSize = .zero { didSet { updateExclusion() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateExclusion()
    }

    private func updateExclusion() {
        guard let container = textContainer else { return }
        let paths = DictationTextView.exclusionPaths(containerWidth: container.size.width, corner: cornerExclusion)
        if container.exclusionPaths != paths { container.exclusionPaths = paths }
    }

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
#Preview("Aktar: ⇧↩ gönderir") { DictationPanelView(controller: .preview(.deliveryShiftEnter)).padding() }
#Preview("Aktar: hepsi") { DictationPanelView(controller: .preview(.deliveryExpanded)).padding() }
#Preview("Aktar: klavyeyle seçili") { DictationPanelView(controller: .preview(.deliverySelected)).padding() }
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
