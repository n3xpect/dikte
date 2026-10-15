import AppKit
import AVFoundation
import Observation

// CONTRACT — implemented by agent "dictation".
// Owns the ⌥Space flow: hotkey → floating panel → mic capture → /dictate → editable text →
// Shift+Enter copy (+ learning banner) / Esc close → history.

enum DictationPhase: Equatable {
    case idle            // panel hidden
    case listening       // recording; waveform visible
    case transcribing    // recording ended, waiting for result
    case editing         // result shown in the text area
    case failed(String)  // Turkish message; Esc closes
}

/// A word-level correction the user made in the text area that could become a term fix.
struct FixSuggestion: Identifiable, Equatable {
    var wrong: String
    var right: String
    var id: String { wrong + "→" + right }
}

@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    /// True while the engine is loading the model for this dictation.
    private(set) var modelLoading = false
    private(set) var speechDetected = false
    /// Recent mic levels 0…1 for the waveform (newest last).
    private(set) var levels: [Float] = []
    /// Editable text bound to the text area in `.editing`.
    var text = ""
    /// Shown after Shift+Enter when the user changed words; panel closes when resolved.
    private(set) var suggestions: [FixSuggestion] = []

    /// Second line under the `.failed` message (how to fix it).
    private(set) var failureHint: String?
    private(set) var failureAction: FailureAction?
    /// `.failed` used as a short notice ("Konuşma algılanmadı") that closes by itself.
    private(set) var isNotice = false

    enum FailureAction: Equatable {
        case openMicrophoneSettings, openModels
        var title: String {
            switch self {
            case .openMicrophoneSettings: "Sistem Ayarları'nı aç"
            case .openModels: "Modeller'i aç"
            }
        }
    }

    static let waveformBarCount = 56

    @ObservationIgnored private var panelController: DictationPanelController?
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var result: DictationResult?
    /// Bumped on every start/teardown; callbacks from older recordings are ignored.
    @ObservationIgnored private var generation = 0
    /// Audio captured before the engine session exists (engine still starting).
    @ObservationIgnored private var pending: [Float] = []
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var recordingEnded = false
    @ObservationIgnored private var historyWritten = false
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var lastHotkey = Date.distantPast

    init() {}

    private var app: AppState { AppState.shared }
    private var soundsEnabled: Bool { app.settings.settings.soundsEnabled }

    // MARK: - User actions

    /// ⌥Space: start when idle; finish recording when listening.
    func hotkeyPressed() {
        let now = Date()
        guard now.timeIntervalSince(lastHotkey) > 0.25 else { return }
        lastHotkey = now
        switch phase {
        case .idle: begin()
        case .listening: finishRecording()
        case .failed: close()
        case .transcribing, .editing: panelController?.show()
        }
    }

    /// Enter while listening = finish. (In `.editing`, Enter inserts a newline — handled by the text view.)
    func enterPressed() {
        switch phase {
        case .listening: finishRecording()
        case .failed: close()
        default: break
        }
    }

    /// Shift+Enter in `.editing`: copy to clipboard, write history, show suggestions or close.
    func copyAndClose() {
        guard phase == .editing, suggestions.isEmpty else { return }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else {
            writeHistory(final, copied: false)
            close()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(final, forType: .string)
        writeHistory(final, copied: true)
        let found = result.map {
            FixLearning.suggestions(original: $0.text, edited: final, terms: app.terms.terms)
        } ?? []
        if found.isEmpty {
            close()
        } else {
            suggestions = found
        }
    }

    /// Esc: cancel recording / close panel (history is still written after a result).
    func escapePressed() {
        switch phase {
        case .idle:
            break
        case .listening, .transcribing:
            session?.cancel()
            close()
        case .editing:
            writeHistory(text.trimmingCharacters(in: .whitespacesAndNewlines), copied: false)
            close()
        case .failed:
            close()
        }
    }

    func acceptSuggestion(_ s: FixSuggestion) {
        app.terms.addFix(wrong: s.wrong, right: s.right)
        resolve(s)
    }

    /// "Geç" on one row.
    func skipSuggestion(_ s: FixSuggestion) {
        resolve(s)
    }

    func dismissSuggestions() {
        suggestions = []
        close()
    }

    func performFailureAction() {
        guard let action = failureAction else { return }
        close()
        switch action {
        case .openMicrophoneSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .openModels:
            MainWindowController.shared.show(tab: .models)
        }
    }

    private func resolve(_ s: FixSuggestion) {
        suggestions.removeAll { $0 == s }
        if suggestions.isEmpty { close() }
    }

    // MARK: - Recording

    private func begin() {
        teardown(cancelSession: true)
        resetState()
        let gen = generation
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        phase = .listening
        panel.show()
        if soundsEnabled { DictationSounds.start() }
        startMicrophone(gen)
        runTask = Task { await self.run(gen) }
    }

    private func finishRecording() {
        guard phase == .listening else { return }
        endRecordingLocally()
        phase = .transcribing
        if let session {
            session.finish()
        } else {
            finishRequested = true
        }
    }

    private func endRecordingLocally() {
        stopCapture()
        if !recordingEnded, soundsEnabled { DictationSounds.end() }
        recordingEnded = true
    }

    private func startMicrophone(_ gen: Int) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            openMicrophone(gen)
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard self.generation == gen else { return }
                if granted { self.openMicrophone(gen) } else { self.failMicrophonePermission() }
            }
        default:
            failMicrophonePermission()
        }
    }

    private func openMicrophone(_ gen: Int) {
        guard phase == .listening else { return }
        let capture = AudioCapture(
            onSamples: { samples in
                DispatchQueue.main.async { self.receive(samples: samples, gen) }
            },
            onLevels: { levels in
                DispatchQueue.main.async { self.receive(levels: levels, gen) }
            },
            onInterrupted: {
                DispatchQueue.main.async {
                    guard self.generation == gen, self.phase == .listening else { return }
                    self.fail("Mikrofon bağlantısı kesildi.", hint: "Mikrofonu kontrol edip tekrar dene.")
                }
            }
        )
        do {
            try capture.start(deviceUID: app.settings.settings.microphoneUID)
            self.capture = capture
        } catch {
            fail(error.localizedDescription, hint: "Ayarlar'da başka bir mikrofon seçmeyi dene.")
        }
    }

    private func failMicrophonePermission() {
        fail("Mikrofon izni yok — Sistem Ayarları › Gizlilik › Mikrofon",
             hint: "Dikte'ye mikrofon izni verip tekrar dene.", action: .openMicrophoneSettings)
    }

    private func receive(samples: [Float], _ gen: Int) {
        guard gen == generation, phase == .listening else { return }
        if let session {
            session.send(samples: samples)
        } else if pending.count < Int(AudioCapture.sampleRate) * 130 {
            pending.append(contentsOf: samples)
        }
    }

    private func receive(levels new: [Float], _ gen: Int) {
        guard gen == generation, phase == .listening else { return }
        var l = levels
        l.append(contentsOf: new)
        if l.count > Self.waveformBarCount { l.removeFirst(l.count - Self.waveformBarCount) }
        levels = l
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
    }

    // MARK: - Engine session

    private func run(_ gen: Int) async {
        let engine = app.engine
        if !engine.isRunning {
            if engine.status == .stopped { engine.start() }
            let deadline = Date().addingTimeInterval(20)
            while !engine.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
                guard generation == gen else { return }
                if Date() > deadline {
                    if case .failed(let message) = engine.status {
                        fail(message, hint: "Sorun sürerse Dikte'yi yeniden başlat.")
                    } else {
                        fail("Motor başlatılamadı.", hint: "Sorun sürerse Dikte'yi yeniden başlat.")
                    }
                    return
                }
            }
        }
        guard generation == gen else { return }
        let session = engine.makeDictation()
        self.session = session
        session.start()
        if !pending.isEmpty {
            session.send(samples: pending)
            pending = []
        }
        if finishRequested { session.finish() }
        for await event in session.events {
            guard generation == gen else { return }
            handle(event)
        }
        guard generation == gen else { return }
        sessionClosed()
    }

    private func handle(_ event: DictationEvent) {
        switch event {
        case .modelLoading:
            modelLoading = true
        case .modelReady:
            modelLoading = false
        case .speechStart:
            speechDetected = true
        case .ended(let reason):
            recordingDidEnd(reason)
        case .transcribing:
            modelLoading = false
            if phase == .listening { endRecordingLocally() }
            if phase == .listening || phase == .transcribing { phase = .transcribing }
        case .result(let r):
            show(r)
        case .error(let code, let message):
            let (hint, action) = Self.hint(forEngineError: code)
            fail(message.isEmpty ? "Motor hatası (\(code))." : message, hint: hint, action: action)
        case .closed:
            sessionClosed()
        }
    }

    private func recordingDidEnd(_ reason: DictationEndReason) {
        switch reason {
        case .noSpeech:
            stopCapture()
            notice("Konuşma algılanmadı")
        case .cancel:
            if phase == .listening || phase == .transcribing { close() }
        case .silence, .finish, .maxDuration:
            guard phase == .listening || phase == .transcribing else { return }
            endRecordingLocally()
            phase = .transcribing
        }
    }

    private func show(_ r: DictationResult) {
        guard phase == .listening || phase == .transcribing else { return }
        stopCapture()
        modelLoading = false
        let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            notice("Konuşma algılanmadı")
            return
        }
        result = r
        text = t
        phase = .editing
        panel.show()
    }

    /// Socket closed (or stream ended) — only an error if we were still waiting for something.
    private func sessionClosed() {
        session = nil
        guard phase == .listening || phase == .transcribing else { return }
        if recordingEnded && !speechDetected {
            notice("Konuşma algılanmadı")
        } else {
            fail("Motorla bağlantı kesildi.", hint: "Tekrar dene; sorun sürerse Dikte'yi yeniden başlat.")
        }
    }

    private static func hint(forEngineError code: String) -> (String?, FailureAction?) {
        switch code {
        case "model_not_downloaded", "no_model_selected":
            ("Modeller sekmesinden bir model indirip seç.", .openModels)
        case "insufficient_ram":
            ("Bazı uygulamaları kapatıp tekrar dene ya da daha küçük bir model seç.", .openModels)
        default:
            ("Sorun sürerse Dikte'yi yeniden başlat.", nil)
        }
    }

    // MARK: - Ending

    private func fail(_ message: String, hint: String? = nil, action: FailureAction? = nil) {
        teardown(cancelSession: phase == .listening || phase == .transcribing)
        modelLoading = false
        failureHint = hint
        failureAction = action
        isNotice = false
        phase = .failed(message)
        panel.show()
    }

    private func notice(_ message: String) {
        teardown(cancelSession: false)
        modelLoading = false
        failureHint = nil
        failureAction = nil
        isNotice = true
        phase = .failed(message)
        let gen = generation
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard self.generation == gen, self.isNotice else { return }
            self.close()
        }
    }

    private func close() {
        teardown(cancelSession: false)
        resetState()
        phase = .idle
        panelController?.hide()
        if let previous = previousApp, !previous.isTerminated {
            if NSApp.isActive { NSApp.yieldActivation(to: previous) }
            previous.activate()
        }
        previousApp = nil
    }

    /// Stops everything belonging to the current recording; later callbacks are ignored.
    private func teardown(cancelSession: Bool) {
        generation += 1
        if cancelSession { session?.cancel() }
        session = nil
        runTask?.cancel()
        runTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        stopCapture()
        pending = []
    }

    private func resetState() {
        modelLoading = false
        speechDetected = false
        levels = []
        text = ""
        suggestions = []
        failureHint = nil
        failureAction = nil
        isNotice = false
        result = nil
        finishRequested = false
        recordingEnded = false
        historyWritten = false
    }

    private func writeHistory(_ final: String, copied: Bool) {
        guard let r = result, !historyWritten else { return }
        historyWritten = true
        app.history.add(HistoryEntry(rawText: r.rawText, editedText: final, copied: copied, model: r.model,
                                     audioSeconds: r.audioSeconds, transcribeSeconds: r.transcribeSeconds))
    }

    private var panel: DictationPanelController {
        if let panelController { return panelController }
        let p = DictationPanelController(controller: self)
        panelController = p
        return p
    }
}

#if DEBUG
extension DictationController {
    enum PreviewState: String, CaseIterable {
        case listening, listeningModelLoading, transcribing, editing, suggestions, failed, notice
    }

    /// Controller frozen in a phase, for `#Preview` and snapshot rendering.
    static func preview(_ state: PreviewState) -> DictationController {
        let c = DictationController()
        c.levels = (0..<waveformBarCount).map { i in
            let x = Float(i) / Float(waveformBarCount)
            return max(0.04, abs(sin(x * 19)) * (0.25 + 0.75 * x) * (i % 7 == 0 ? 0.5 : 1))
        }
        switch state {
        case .listening:
            c.phase = .listening
            c.speechDetected = true
        case .listeningModelLoading:
            c.phase = .listening
            c.modelLoading = true
            c.levels = c.levels.map { $0 * 0.3 }
        case .transcribing:
            c.phase = .transcribing
        case .editing:
            c.phase = .editing
            c.text = "Redis cache'ini temizledikten sonra branch'i main'e merge edip pull request açalım."
        case .suggestions:
            c.phase = .editing
            c.suggestions = [FixSuggestion(wrong: "cage", right: "cache"),
                             FixSuggestion(wrong: "get hub", right: "GitHub")]
        case .failed:
            c.phase = .failed("Seçili model indirilmemiş.")
            c.failureHint = "Modeller sekmesinden bir model indirip seç."
            c.failureAction = .openModels
        case .notice:
            c.phase = .failed("Konuşma algılanmadı")
            c.isNotice = true
        }
        return c
    }
}
#endif
