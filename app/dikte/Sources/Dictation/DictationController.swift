import AppKit
import AVFoundation
import Observation

// CONTRACT — implemented by agent "dictation".
// Owns the ⌥Space flow: hotkey → floating panel → mic capture → /dictate → editable text →
// AKTAR (send key ↩ or ⇧↩ default target, ⌘1–9 / click other targets, ⌘C copy) (+ learning banner) /
// Esc close → history.

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
    /// When the current recording started and its longest allowed length (the setting when it
    /// started), for the panel's "00:42 / 02:00" counter.
    private(set) var recordingStartedAt = Date()
    private(set) var recordingLimit: TimeInterval = AppSettings().maxDurationSeconds
    /// Editable text bound to the text area in `.editing`.
    var text = ""
    /// Shown on delivery when the user changed words; the text is delivered when they're resolved.
    private(set) var suggestions: [FixSuggestion] = []
    /// "+ N uygulama daha…" was clicked: the AKTAR list shows every target.
    var showsAllDeliveryTargets = false
    /// Row selected with ↑/↓ in the AKTAR list (index into the shown rows, then "+ N more");
    /// nil = the keys go to the text area.
    var listSelection: Int?
    /// Where the suggestions banner's delivery goes (nil = clipboard).
    private(set) var pendingTarget: TargetApp?
    /// Countdown to sending the text to the default target (Metin aktarımı › Otomatik gönder).
    private(set) var autoSend = AutoSend.off

    enum AutoSend: Equatable {
        case off
        case counting(until: Date, total: TimeInterval)
        /// Stopped by a key or click; sending is up to the user now.
        case stopped
    }

    var autoSendCounting: Bool {
        if case .counting = autoSend { true } else { false }
    }

    /// Second line under the `.failed` message (how to fix it).
    private(set) var failureHint: String?
    private(set) var failureAction: FailureAction?
    /// `.failed` used as a short notice ("Konuşma algılanmadı") that closes by itself.
    private(set) var isNotice = false

    /// Language of the text shown in `.editing` ("tr" | "en"); the panel shows it as a badge.
    private(set) var language = "tr"
    /// The engine kept this recording, so it can be transcribed again in the other language.
    private(set) var canSwitchLanguage = false
    /// Re-transcription in the other language is running (spinner over the text area).
    private(set) var retranscribing = false
    /// Badge / ⌘L after the user edited the text: waiting for "Çevir" or "Vazgeç".
    private(set) var confirmingLanguageSwitch = false
    /// Inline error under the text area when re-transcription failed.
    private(set) var languageError: String?

    var otherLanguage: String { language == "en" ? "tr" : "en" }

    enum FailureAction: Equatable {
        case openMicrophoneSettings, openModels
        var title: String {
            switch self {
            case .openMicrophoneSettings: L("Sistem Ayarları'nı aç")
            case .openModels: L("Modeller'i aç")
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
    /// `text` as last filled in from a result; anything else counts as the user's edit.
    @ObservationIgnored private var shownText = ""
    /// When `text` was last filled in from a result (start of `.editing`, re-transcription).
    @ObservationIgnored private var editingBegan = Date.distantPast
    @ObservationIgnored private var retranscribeTask: Task<Void, Never>?
    @ObservationIgnored private var autoSendTask: Task<Void, Never>?
    /// Bumped on every start/teardown; callbacks from older recordings are ignored.
    @ObservationIgnored private var generation = 0
    /// Audio captured before the engine session exists (engine still starting).
    @ObservationIgnored private var pending: [Float] = []
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var recordingEnded = false
    @ObservationIgnored private var historyWritten = false
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var lastHotkey = Date.distantPast
    @ObservationIgnored private var deliveryPending = false
    /// AKTAR rows and the settings they depend on; previews swap in fake data.
    @ObservationIgnored var deliverySource = DeliverySource.live
    @ObservationIgnored private lazy var toast = DeliveryToastController()

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

    /// Enter while listening = finish. (`.editing` keys are decided by `PanelKeyAction`.)
    func enterPressed() {
        switch phase {
        case .listening: finishRecording()
        case .failed: close()
        default: break
        }
    }

    // MARK: - Delivery

    /// Rows on screen: the visible ones, plus the rest once "+ N uygulama daha…" was clicked.
    var shownDeliveryEntries: [DeliveryEntry] {
        let list = deliverySource.entries(deliverySource.settings())
        return showsAllDeliveryTargets ? list.visible + list.more : list.visible
    }

    /// Targets behind "+ N uygulama daha…" (0 once expanded).
    var hiddenDeliveryCount: Int {
        showsAllDeliveryTargets ? 0 : deliverySource.entries(deliverySource.settings()).more.count
    }

    func deliveryIcon(for target: TargetApp) -> NSImage {
        deliverySource.icon(target)
    }

    /// Rows reachable with ↑/↓: the shown targets, then "+ N uygulama daha…" if any.
    var navigableRowCount: Int {
        shownDeliveryEntries.count + (hiddenDeliveryCount > 0 ? 1 : 0)
    }

    /// ↓ from the text area's last line: select the first row. False when the list is empty.
    @discardableResult
    func enterList() -> Bool {
        guard navigableRowCount > 0 else { return false }
        listSelection = 0
        return true
    }

    /// ↑/↓ in the list; ↑ on the first row hands the keys back to the text area.
    func moveListSelection(by delta: Int) {
        guard let i = listSelection else { return }
        let next = i + delta
        listSelection = next < 0 ? nil : min(next, navigableRowCount - 1)
    }

    /// ↩ on the selected row: deliver there, or expand "+ N more" (selection stays on that slot,
    /// which is now the first newly shown app).
    func activateListSelection() {
        guard let i = listSelection else { return }
        let rows = shownDeliveryEntries
        if i < rows.count {
            deliver(rows[i])
        } else {
            showsAllDeliveryTargets = true
        }
    }

    func leaveList() {
        listSelection = nil
    }

    /// Key that sends to the default target (Metin aktarımı page).
    var sendKey: SendKey { deliverySource.settings().sendKey }

    /// Since the result was shown or replaced; the send key is ignored for a moment after it.
    var secondsSinceEditingBegan: TimeInterval { Date().timeIntervalSince(editingBegan) }

    /// Key hints for the editing phase (default target name, ⌘ numbers actually shown).
    var editingHint: [DeliveryHint.Item] {
        if let i = listSelection {
            let rows = shownDeliveryEntries
            return DeliveryHint.listItems(canMove: i < rows.count && rows[i].isMovable)
        }
        let rows = shownDeliveryEntries
        let defaultRow = rows.first { $0.role == .defaultTarget }
        return DeliveryHint.items(defaultName: defaultRow?.app?.name,
                                  shortcuts: rows.compactMap(\.shortcut).max() ?? 0,
                                  canSwitchLanguage: canSwitchLanguage,
                                  hasList: navigableRowCount > 0,
                                  sendKey: sendKey,
                                  autoSending: autoSendCounting)
    }

    func toggleFavorite(_ target: TargetApp) {
        deliverySource.update { $0.toggleTarget(target.bundleID) }
    }

    /// Context menu "Varsayılan yap": to the top of the list.
    func makeDefaultTarget(_ entry: DeliveryEntry) {
        deliverySource.update { $0.makeDefaultTarget(entry.id) }
    }

    /// Moves a row of the user's list past `delta` shown rows of it (drag or ⌥↑/⌥↓); the first
    /// row is the default. False when it can't move further.
    @discardableResult
    func moveTarget(_ entry: DeliveryEntry, by delta: Int) -> Bool {
        guard entry.isMovable else { return false }
        let shown = Set(shownDeliveryEntries.filter(\.isMovable).map(\.id))
        var moved = false
        deliverySource.update { moved = $0.moveTarget(entry.id, by: delta, among: shown) }
        return moved
    }

    /// ⌥↑/⌥↓ on the selected row; the selection follows it.
    func moveSelectedTarget(by delta: Int) {
        let rows = shownDeliveryEntries
        guard let i = listSelection, i < rows.count else { return }
        let id = rows[i].id
        guard moveTarget(rows[i], by: delta) else { return }
        listSelection = shownDeliveryEntries.firstIndex { $0.id == id } ?? i
    }

    /// Send key: the default row (clipboard when the list is empty).
    func deliverToDefault() {
        deliver(to: shownDeliveryEntries.first { $0.role == .defaultTarget }?.app)
    }

    /// ⌘1…⌘9: the shown row with that shortcut. False when there is none.
    @discardableResult
    func deliver(shortcut: Int) -> Bool {
        guard let entry = shownDeliveryEntries.first(where: { $0.shortcut == shortcut && $0.role != .defaultTarget })
        else { return false }
        deliver(entry)
        return true
    }

    /// Click on a row.
    func deliver(_ entry: DeliveryEntry) {
        deliver(to: entry.app)
    }

    /// ⌘C without a selection: clipboard only, whatever the default is.
    func copyOnly() {
        deliver(to: nil)
    }

    /// Writes history, then shows the learning banner (delivering once it's resolved) or delivers now.
    private func deliver(to chosen: TargetApp?) {
        guard phase == .editing, suggestions.isEmpty, !retranscribing, !deliveryPending else { return }
        let target = resolvingLastApp(chosen)
        endAutoSend()
        confirmingLanguageSwitch = false
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else {
            writeHistory(final, copied: false)
            close()
            return
        }
        let found = result.map {
            FixLearning.suggestions(original: $0.text, edited: final, terms: app.terms.terms, language: $0.language)
        } ?? []
        writeHistory(final, copied: true, deliveredTo: target?.bundleID)
        // The clipboard gets the text right away ("Panoya kopyalandı" over the banner, as before).
        if target == nil { app.delivery.copyToClipboard(final) }
        deliveryPending = true
        pendingTarget = target
        if found.isEmpty {
            finishDelivery()
        } else {
            suggestions = found
        }
    }

    /// "Son kullanılan uygulama" → the app that was in front when dictation started; the clipboard
    /// (nil) when there was none (Dikte itself, or it has quit since).
    private func resolvingLastApp(_ target: TargetApp?) -> TargetApp? {
        guard let target, target.isLastApp else { return target }
        guard let previous = previousApp, !previous.isTerminated, let id = previous.bundleIdentifier else { return nil }
        return app.delivery.resolve(bundleID: id)
            ?? TargetApp(bundleID: id, name: previous.localizedName ?? id, url: previous.bundleURL, isRunning: true)
    }

    /// Closes the panel; for an app target pastes there (no re-activating the previous app).
    private func finishDelivery() {
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard deliveryPending, let target = pendingTarget else {
            close()
            return
        }
        previousApp = nil
        close()
        let delivery = app.delivery
        let restore = app.settings.settings.restoreClipboardAfterPaste
        Task {
            do {
                try await delivery.deliver(final, to: target.bundleID, restoreClipboard: restore)
            } catch {
                let content = DeliveryToastContent.failure(error, appName: target.name)
                self.toast.show(content) {
                    if content.asksForAccessibility { delivery.requestAccessibility() }
                }
            }
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
            if retranscribing {
                stopRetranscribing()
            } else if confirmingLanguageSwitch {
                confirmingLanguageSwitch = false
            } else {
                writeHistory(text.trimmingCharacters(in: .whitespacesAndNewlines), copied: false)
                close()
            }
        case .failed:
            close()
        }
    }

    // MARK: - Language switch

    /// Badge click / ⌘L in `.editing`: transcribe the same recording again in the other language.
    /// If the user changed the text, the first call only asks (`confirmingLanguageSwitch`).
    func switchLanguage() {
        guard phase == .editing, suggestions.isEmpty, !retranscribing else { return }
        stopAutoSend()
        languageError = nil
        if !confirmingLanguageSwitch, text.trimmingCharacters(in: .whitespacesAndNewlines) != shownText {
            confirmingLanguageSwitch = true
            return
        }
        confirmingLanguageSwitch = false
        guard let id = result?.dictationId else {
            languageError = L("Kayıt artık yok")
            return
        }
        let target = otherLanguage
        let gen = generation
        retranscribing = true
        retranscribeTask = Task {
            let outcome: Result<DictationResult, Error>
            do {
                outcome = .success(try await self.app.engine.retranscribe(dictationId: id, language: target))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled, self.generation == gen, self.phase == .editing else { return }
            self.retranscribing = false
            self.retranscribeTask = nil
            switch outcome {
            case .success(var r):
                let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else {
                    self.languageError = L("Konuşma algılanmadı")
                    return
                }
                if r.dictationId == nil { r.dictationId = id }
                self.result = r
                self.setResultText(t, language: r.language)
            case .failure(let error):
                self.languageError = Self.retranscribeMessage(error)
            }
        }
    }

    /// "Vazgeç" in the confirmation row.
    func cancelLanguageSwitch() {
        confirmingLanguageSwitch = false
    }

    private func stopRetranscribing() {
        retranscribeTask?.cancel()
        retranscribeTask = nil
        retranscribing = false
    }

    private static func retranscribeMessage(_ error: Error) -> String {
        guard let e = error as? EngineAPIError else { return error.localizedDescription }
        switch e.error {
        case "dictation_expired": return L("Kayıt artık yok")
        case "busy": return L("Motor meşgul — biraz sonra tekrar dene.")
        default: return e.message.isEmpty ? L("Yeniden çevrilemedi.") : e.message
        }
    }

    private func setResultText(_ t: String, language: String) {
        text = t
        shownText = t
        editingBegan = Date()
        self.language = language
        canSwitchLanguage = result?.dictationId != nil
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
        finishDelivery()
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
        if suggestions.isEmpty { finishDelivery() }
    }

    // MARK: - Recording

    private func begin() {
        teardown(cancelSession: true)
        resetState()
        toast.hide()
        let gen = generation
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        recordingStartedAt = Date()
        recordingLimit = app.settings.settings.maxDurationSeconds
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
                    self.fail(L("Mikrofon bağlantısı kesildi."), hint: L("Mikrofonu kontrol edip tekrar dene."))
                }
            }
        )
        do {
            try capture.start(deviceUID: app.settings.settings.microphoneUID)
            self.capture = capture
        } catch {
            let message = switch error as? AudioCapture.CaptureError {
            case .noDevice: L("Mikrofon bulunamadı.")
            case .startFailed(let reason): L("Mikrofon açılamadı: %@", reason)
            case .tooManyRestarts, nil: L("Mikrofon açılamadı: %@", error.localizedDescription)
            }
            fail(message, hint: L("Kayıt sayfasında başka bir mikrofon seçmeyi dene."))
        }
    }

    private func failMicrophonePermission() {
        fail(L("Mikrofon izni yok — Sistem Ayarları › Gizlilik › Mikrofon"),
             hint: L("Dikte'ye mikrofon izni verip tekrar dene."), action: .openMicrophoneSettings)
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
                        fail(message, hint: L("Sorun sürerse Dikte'yi yeniden başlat."))
                    } else {
                        fail(L("Motor başlatılamadı."), hint: L("Sorun sürerse Dikte'yi yeniden başlat."))
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
            fail(message.isEmpty ? L("Motor hatası (%@).", code) : message, hint: hint, action: action)
        case .closed:
            sessionClosed()
        }
    }

    private func recordingDidEnd(_ reason: DictationEndReason) {
        switch reason {
        case .noSpeech:
            stopCapture()
            notice(L("Konuşma algılanmadı"))
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
            notice(L("Konuşma algılanmadı"))
            return
        }
        result = r
        setResultText(t, language: r.language)
        listSelection = nil
        phase = .editing
        panel.show()
        startAutoSend()
    }

    // MARK: - Auto-send

    /// When the result appears: count down, then send to the default target. With a wait of 0
    /// ("Hemen") it goes right away and the panel closes before the text is ever drawn.
    private func startAutoSend() {
        let settings = deliverySource.settings()
        guard settings.autoSendEnabled, phase == .editing, suggestions.isEmpty, !retranscribing,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let total = settings.autoSendSeconds
        guard total > 0 else {
            deliverToDefault()
            return
        }
        autoSend = .counting(until: Date().addingTimeInterval(total), total: total)
        let gen = generation
        autoSendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(total))
            guard let self, !Task.isCancelled, self.generation == gen, self.autoSendCounting else { return }
            self.autoSendTask = nil
            self.deliverToDefault()
        }
    }

    /// The auto-send setting, shown and changed from the panel's ⏱ (same as Metin aktarımı).
    var autoSendSetting: (enabled: Bool, seconds: Double) {
        let s = deliverySource.settings()
        return (s.autoSendEnabled, s.autoSendSeconds)
    }

    func setAutoSend(enabled: Bool) {
        deliverySource.update { $0.autoSendEnabled = enabled }
    }

    func setAutoSendSeconds(_ seconds: Double) {
        deliverySource.update { $0.autoSendSeconds = AppSettings.clampedAutoSend(seconds) }
    }

    /// A key press or click while counting: the panel stays, sending is up to the user.
    func stopAutoSend() {
        guard autoSendCounting else { return }
        autoSendTask?.cancel()
        autoSendTask = nil
        autoSend = .stopped
    }

    private func endAutoSend() {
        autoSendTask?.cancel()
        autoSendTask = nil
        autoSend = .off
    }

    /// Socket closed (or stream ended) — only an error if we were still waiting for something.
    private func sessionClosed() {
        session = nil
        guard phase == .listening || phase == .transcribing else { return }
        if recordingEnded && !speechDetected {
            notice(L("Konuşma algılanmadı"))
        } else {
            fail(L("Motorla bağlantı kesildi."), hint: L("Tekrar dene; sorun sürerse Dikte'yi yeniden başlat."))
        }
    }

    private static func hint(forEngineError code: String) -> (String?, FailureAction?) {
        switch code {
        case "model_not_downloaded", "no_model_selected":
            (L("Modeller sekmesinden bir model indirip seç."), .openModels)
        case "insufficient_ram":
            (L("Bazı uygulamaları kapatıp tekrar dene ya da daha küçük bir model seç."), .openModels)
        default:
            (L("Sorun sürerse Dikte'yi yeniden başlat."), nil)
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
        endAutoSend()
        stopRetranscribing()
        stopCapture()
        pending = []
    }

    private func resetState() {
        modelLoading = false
        speechDetected = false
        levels = []
        text = ""
        suggestions = []
        showsAllDeliveryTargets = false
        listSelection = nil
        pendingTarget = nil
        deliveryPending = false
        failureHint = nil
        failureAction = nil
        isNotice = false
        result = nil
        shownText = ""
        editingBegan = .distantPast
        language = "tr"
        canSwitchLanguage = false
        retranscribing = false
        confirmingLanguageSwitch = false
        languageError = nil
        finishRequested = false
        recordingEnded = false
        historyWritten = false
    }

    private func writeHistory(_ final: String, copied: Bool, deliveredTo: String? = nil) {
        guard let r = result, !historyWritten else { return }
        historyWritten = true
        app.history.add(HistoryEntry(rawText: r.rawText, editedText: final, copied: copied, model: r.model,
                                     audioSeconds: r.audioSeconds, transcribeSeconds: r.transcribeSeconds,
                                     language: r.language, deliveredTo: deliveredTo))
    }

    private var panel: DictationPanelController {
        if let panelController { return panelController }
        let p = DictationPanelController(controller: self)
        panelController = p
        return p
    }
}

/// What the AKTAR list reads and changes: settings, rows, icons.
struct DeliverySource {
    var settings: () -> AppSettings
    var update: ((inout AppSettings) -> Void) -> Void
    var entries: (AppSettings) -> (visible: [DeliveryEntry], more: [DeliveryEntry])
    var icon: (TargetApp) -> NSImage

    static var live: DeliverySource {
        DeliverySource(
            settings: { AppState.shared.settings.settings },
            update: { change in change(&AppState.shared.settings.settings) },
            entries: { AppState.shared.delivery.entries(for: $0) },
            icon: { AppState.shared.delivery.icon(for: $0) })
    }
}

#if DEBUG
extension DictationController {
    enum PreviewState: String, CaseIterable {
        case listening, listeningModelLoading, transcribing, editing, editingEnglish, retranscribing,
             confirmSwitch, languageError, deliveryApp, deliveryShiftEnter, deliveryExpanded,
             deliverySelected, autoSendCounting, autoSendStopped, suggestions, suggestionsApp, failed, notice
    }

    /// Controller frozen in a phase, for `#Preview` and snapshot rendering.
    static func preview(_ state: PreviewState) -> DictationController {
        let turkish = "Redis cache'ini temizledikten sonra branch'i main'e merge edip pull request açalım."
        let c = DictationController()
        let fake = PreviewDelivery()
        c.deliverySource = fake.source
        c.levels = (0..<waveformBarCount).map { i in
            let x = Float(i) / Float(waveformBarCount)
            return max(0.04, abs(sin(x * 19)) * (0.25 + 0.75 * x) * (i % 7 == 0 ? 0.5 : 1))
        }
        switch state {
        case .listening:
            c.phase = .listening
            c.speechDetected = true
            c.recordingStartedAt = Date().addingTimeInterval(-42)
        case .listeningModelLoading:
            c.phase = .listening
            c.modelLoading = true
            c.levels = c.levels.map { $0 * 0.3 }
        case .transcribing:
            c.phase = .transcribing
        case .editing, .retranscribing, .confirmSwitch, .languageError,
             .deliveryApp, .deliveryShiftEnter, .deliveryExpanded, .deliverySelected,
             .autoSendCounting, .autoSendStopped:
            c.phase = .editing
            c.result = DictationResult(rawText: turkish, text: turkish, fixes: [], audioSeconds: 6.1,
                                       transcribeSeconds: 0.9, model: "large-v3", language: "tr",
                                       dictationId: "preview")
            c.setResultText(turkish, language: "tr")
            switch state {
            case .retranscribing: c.retranscribing = true
            case .confirmSwitch:
                c.text = turkish.replacingOccurrences(of: "açalım", with: "hemen açalım")
                c.confirmingLanguageSwitch = true
            case .languageError: c.languageError = L("Kayıt artık yok")
            case .deliveryApp, .deliveryShiftEnter, .deliveryExpanded, .deliverySelected,
                 .autoSendCounting, .autoSendStopped:
                fake.settings.deliveryTargets = PreviewDelivery.targets
                if state == .deliveryShiftEnter { fake.settings.sendKey = .shiftEnter }
                fake.settings.deliveryOtherLimit = 3
                c.showsAllDeliveryTargets = state == .deliveryExpanded
                if state == .deliverySelected { c.listSelection = 2 }
                if state == .autoSendCounting { c.autoSend = .counting(until: Date().addingTimeInterval(17.5), total: 30) }
                if state == .autoSendStopped { c.autoSend = .stopped }
            default: break
            }
        case .editingEnglish:
            let english = "Let's clear the Redis cache, merge the branch into main and open a pull request."
            c.phase = .editing
            c.result = DictationResult(rawText: english, text: english, fixes: [], audioSeconds: 6.1,
                                       transcribeSeconds: 0.9, model: "large-v3", language: "en",
                                       dictationId: "preview")
            c.setResultText(english, language: "en")
        case .suggestions, .suggestionsApp:
            c.phase = .editing
            c.suggestions = [FixSuggestion(wrong: "cage", right: "cache"),
                             FixSuggestion(wrong: "get hub", right: "GitHub")]
            if state == .suggestionsApp {
                c.pendingTarget = TargetApp(bundleID: PreviewDelivery.slack, name: "Slack", url: nil, isRunning: true)
            }
        case .failed:
            c.phase = .failed(L("Seçili model indirilmemiş."))
            c.failureHint = L("Modeller sekmesinden bir model indirip seç.")
            c.failureAction = .openModels
        case .notice:
            c.phase = .failed(L("Konuşma algılanmadı"))
            c.isNotice = true
        }
        return c
    }
}

/// Fake AKTAR data for previews: its own settings (the real store is never touched) and a fixed
/// set of apps, ordered by the real `DeliveryService.entries` so star / "Varsayılan yap" / moves
/// re-sort live in `#Preview`.
@Observable
final class PreviewDelivery {
    static let slack = "com.tinyspeck.slackmacgap"
    /// Slack (default), Mail, Notes, then the clipboard.
    static let targets = [slack, "com.apple.mail", "com.apple.Notes", AppSettings.clipboard]

    var settings = AppSettings()

    let apps: [TargetApp] = [
        ("com.tinyspeck.slackmacgap", "Slack", true), ("com.apple.Notes", "Notes", false),
        ("com.apple.mail", "Mail", true), ("com.apple.Safari", "Safari", true),
        ("com.apple.Terminal", "Terminal", true), ("com.apple.TextEdit", "TextEdit", true),
        ("com.apple.iCal", "Calendar", true), ("com.apple.finder", "Finder", true),
        ("com.apple.MobileSMS", "Messages", true),
    ].map { TargetApp(bundleID: $0.0, name: $0.1, url: nil, isRunning: $0.2) }

    var source: DeliverySource {
        DeliverySource(settings: { self.settings },
                       update: { change in change(&self.settings) },
                       entries: { self.entries($0) },
                       icon: { Self.icon(for: $0) })
    }

    private func entries(_ s: AppSettings) -> (visible: [DeliveryEntry], more: [DeliveryEntry]) {
        DeliveryService.entries(targets: s.deliveryTargets, running: apps.filter(\.isRunning),
                                locale: Localizer.shared.language.locale, limit: s.deliveryOtherLimit,
                                resolve: { id in self.apps.first { $0.bundleID == id } })
    }

    /// The installed app's icon, or a coloured letter tile when it isn't installed.
    static func icon(for app: TargetApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
            let letter = NSAttributedString(string: String(app.name.prefix(1)), attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = letter.size()
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}
#endif
