import Foundation

/// Hidden headless check of the engine integration:
///
///     DIKTE_DATA_DIR=/tmp/dikte-test DIKTE_ENGINE_DIR=<repo>/app/engine \
///       dikte.app/Contents/MacOS/dikte --selftest [file.wav] [--realtime] [--no-restart]
///
/// Uses the default settings, not settings.json; for long recordings set
/// DIKTE_SELFTEST_MAX_DURATION / DIKTE_SELFTEST_SILENCE (seconds).
///
/// Starts the engine, reads the /events snapshot, pushes config + default terms, checks error
/// mapping, streams the WAV through /dictate, tests cancel and crash-restart, then stops the
/// engine. Prints one JSON object per line to stdout and exits (0 = all checks passed).
enum SelfTest {
    /// Called by AppDelegate at launch; returns true when the self-test took over the process.
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return false }
        let next = i + 1 < args.count ? args[i + 1] : nil
        let wav = next.flatMap { $0.hasPrefix("--") ? nil : $0 }
        let options = Options(wav: wav,
                              realtime: args.contains("--realtime"),
                              restart: !args.contains("--no-restart"))
        Task {
            let ok = await run(options)
            out(["step": "done", "ok": ok])
            exit(ok ? 0 : 1)
        }
        return true
    }

    struct Options {
        var wav: String?
        var realtime: Bool
        var restart: Bool
    }

    // MARK: - Flow

    private static var failures: [String] = []

    private static func check(_ ok: Bool, _ name: String, _ detail: [String: Any] = [:]) {
        var d = detail
        d["step"] = name
        d["ok"] = ok
        out(d)
        if !ok { failures.append(name) }
    }

    private static func run(_ o: Options) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        out(["step": "begin",
             "data_dir": Paths.dataDir.path,
             "engine_dir": Paths.engineDir?.path ?? NSNull(),
             "python": Paths.enginePython?.path ?? NSNull()])

        if env["DIKTE_DATA_DIR"] != nil { storeTests() } else { out(["step": "stores", "skipped": "DIKTE_DATA_DIR not set"]) }

        // engine_not_running path
        do {
            let s = DictationSession()
            s.start()
            let events = await collect(s, timeout: 2)
            check(events.count == 2 && events.last == .closed
                    && { if case .error(code: "engine_not_running", _) = events.first { true } else { false } }(),
                  "session_without_engine", ["events": events.map(describe)])
        }

        let engine = EngineController()
        var config = AppSettings().engineConfig
        config.selectedModel = env["DIKTE_SELFTEST_MODEL"] ?? config.selectedModel
        config.idleUnloadS = 900   // non-default, so config_pushed can see it in the snapshot
        if let v = env["DIKTE_SELFTEST_MAX_DURATION"].flatMap(Double.init) { config.maxDurationS = v }
        if let v = env["DIKTE_SELFTEST_SILENCE"].flatMap(Double.init) { config.silenceS = v }
        engine.pushConfig(config)
        let t0 = Date()
        engine.start()
        let started = await waitUntil(timeout: 90) { engine.isRunning || isFailed(engine.status) }
        guard started, case .running(let port) = engine.status else {
            check(false, "engine_ready", ["status": "\(engine.status)"])
            engine.stop()
            return false
        }
        check(true, "engine_ready", ["port": port, "seconds": Date().timeIntervalSince(t0)])

        let gotSnapshot = await waitUntil(timeout: 15) { !engine.models.isEmpty && engine.system != nil }
        check(gotSnapshot, "events_snapshot", [
            "models": engine.models.map { ["id": $0.id, "state": $0.state.rawValue, "size_bytes": $0.sizeBytes ?? NSNull()] as [String: Any] },
            "system": engine.system.map { ["selected_model": $0.selectedModel ?? NSNull(),
                                           "disk_free_gb": Double($0.diskFreeBytes) / 1e9,
                                           "ram_available_gb": Double($0.ramAvailableBytes) / 1e9,
                                           "idle_unload_s": $0.idleUnloadS] as [String: Any] } ?? NSNull(),
        ])
        // Config was PUT on ready; snapshot should reflect our idle_unload_s.
        let configApplied = await waitUntil(timeout: 5) { engine.system?.idleUnloadS == config.idleUnloadS }
        check(configApplied, "config_pushed", ["idle_unload_s": engine.system?.idleUnloadS ?? NSNull()])

        do {
            let terms = try await engine.defaultTerms()
            check(!terms.isEmpty, "default_terms", ["count": terms.count, "first": terms.prefix(5).map(\.term)])
            engine.pushConfig(EngineConfig(terms: terms))
        } catch {
            check(false, "default_terms", ["error": "\(error)"])
        }

        do {
            try await engine.load("selftest-missing-model")
            check(false, "api_error_mapping", ["error": "no error thrown"])
        } catch let e as EngineAPIError {
            check(true, "api_error_mapping", ["code": e.error, "message": e.message])
        } catch {
            check(false, "api_error_mapping", ["error": "\(error)"])
        }
        do {
            try await engine.delete("hf:selftest/missing")
            check(false, "custom_id_encoding", ["error": "no error thrown"])
        } catch let e as EngineAPIError {
            // Any JSON error from the engine (not a 404 HTML page / routing miss) means the id reached the handler.
            check(!e.error.hasPrefix("http_"), "custom_id_encoding", ["code": e.error, "message": e.message])
        } catch {
            check(false, "custom_id_encoding", ["error": "\(error)"])
        }
        try? await Task.sleep(for: .milliseconds(400))   // let the debounced config PUT land

        if let path = o.wav, let result = await dictationTest(engine: engine, path: path, realtime: o.realtime) {
            await retranscribeTest(engine: engine, result: result)
        }
        await cancelTest(engine: engine)

        if o.restart, let pid = engine.processIdentifier {
            kill(pid, SIGKILL)
            let wentDown = await waitUntil(timeout: 5) { !engine.isRunning }
            let back = await waitUntil(timeout: 90) { engine.isRunning && engine.processIdentifier != pid }
            let snap = await waitUntil(timeout: 15) { !engine.models.isEmpty }
            let terms = engine.config.terms?.count ?? 0
            check(wentDown && back && snap, "auto_restart",
                  ["old_pid": pid, "new_pid": engine.processIdentifier ?? NSNull(), "status": "\(engine.status)", "config_terms": terms])
        }

        let pid = engine.processIdentifier
        engine.stop()
        let gone = pid.map { kill($0, 0) != 0 } ?? true
        check(gone && engine.status == .stopped, "engine_stopped")

        if !failures.isEmpty { out(["step": "failures", "names": failures]) }
        return failures.isEmpty
    }

    @discardableResult
    private static func dictationTest(engine: EngineController, path: String, realtime: Bool) async -> DictationResult? {
        let samples: [Float]
        do {
            samples = try readWav(URL(fileURLWithPath: path))
        } catch {
            check(false, "dictation", ["error": "WAV okunamadı: \(error)"])
            return nil
        }
        let session = engine.makeDictation()
        let chunk = 1600   // 100 ms
        // A little audio before start() exercises the pre-connect buffer.
        session.send(samples: Array(samples.prefix(chunk * 5)))
        session.start()
        let t0 = Date()
        // Feeding runs at ~10× real time; long recordings also take longer to transcribe.
        let timeout = 180 + Double(samples.count) / 16000
        let collector = Task { await collect(session, timeout: timeout, t0: t0, print: true) }
        var i = min(chunk * 5, samples.count)
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            session.send(samples: Array(samples[i..<end]))
            i = end
            try? await Task.sleep(for: .milliseconds(realtime ? 100 : 10))
        }
        session.send(samples: [Float](repeating: 0, count: 8000))
        session.finish()
        let events = await collector.value
        let result = events.lazy.compactMap { if case .result(let r) = $0 { r } else { nil } }.first
        check(result != nil && events.last == .closed, "dictation", [
            "audio_s": Double(samples.count) / 16000,
            "events": events.map(describe),
            "text": result?.text ?? NSNull(),
            "raw_text": result?.rawText ?? NSNull(),
            "fixes": result?.fixes.map { [$0.wrong, $0.right] } ?? [],
            "transcribe_s": result?.transcribeSeconds ?? NSNull(),
            "model": result?.model ?? NSNull(),
            "language": result?.language ?? NSNull(),
            "dictation_id": result?.dictationId ?? NSNull(),
            "wall_s": Date().timeIntervalSince(t0),
        ])
        return result
    }

    /// POST /retranscribe in the other language, then with an unknown id (→ `dictation_expired`).
    private static func retranscribeTest(engine: EngineController, result: DictationResult) async {
        guard let id = result.dictationId else {
            out(["step": "retranscribe", "skipped": "engine sent no dictation_id (api v1)"])
            return
        }
        let target = result.language == "en" ? "tr" : "en"
        let t0 = Date()
        do {
            let r = try await engine.retranscribe(dictationId: id, language: target)
            check(r.language == target && !r.text.isEmpty, "retranscribe", [
                "language": r.language, "text": r.text, "dictation_id": r.dictationId ?? NSNull(),
                "wall_s": Date().timeIntervalSince(t0),
            ])
        } catch {
            check(false, "retranscribe", ["error": "\(error)"])
        }
        do {
            _ = try await engine.retranscribe(dictationId: "selftest-unknown", language: target)
            check(false, "retranscribe_expired", ["error": "no error thrown"])
        } catch let e as EngineAPIError {
            check(e.error == "dictation_expired", "retranscribe_expired", ["code": e.error, "message": e.message])
        } catch {
            check(false, "retranscribe_expired", ["error": "\(error)"])
        }
    }

    private static func cancelTest(engine: EngineController) async {
        let session = engine.makeDictation()
        session.start()
        session.send(samples: [Float](repeating: 0, count: 16000))
        try? await Task.sleep(for: .milliseconds(300))
        session.cancel()
        session.send(samples: [Float](repeating: 0, count: 1600))   // must be ignored
        let events = await collect(session, timeout: 15)
        let hasResult = events.contains { if case .result = $0 { true } else { false } }
        let hasError = events.contains { if case .error = $0 { true } else { false } }
        check(!hasResult && !hasError && events.last == .closed
                && events.filter({ $0 == .closed }).count == 1, "cancel", ["events": events.map(describe)])
    }

    private static func storeTests() {
        let terms = TermsStore()
        let saved = terms.terms
        terms.replaceAll([Term(term: "İstanbul", accept: [], fix: []), Term(term: "branch", accept: ["brenç"], fix: ["brenc"])])
        terms.addFix(wrong: "brenç", right: "Branch")     // existing term, case-insensitive; moves out of accept
        terms.addFix(wrong: "BRENC", right: "branch")     // duplicate fix → ignored
        terms.addFix(wrong: "istanbul", right: "İSTANBUL") // same word (Turkish fold) → ignored
        terms.addFix(wrong: "pul rikuest", right: "pull request")
        let b = terms.terms.first { $0.term == "branch" }
        let ok = b?.fix == ["brenc", "brenç"] && b?.accept == [] && terms.terms.count == 3
            && terms.terms.last == Term(term: "pull request", accept: [], fix: ["pul rikuest"])
            && terms.terms.first?.fix == []
        let reloaded = TermsStore().terms == terms.terms
        check(ok && reloaded, "terms_store", ["terms": terms.terms.map { ["term": $0.term, "accept": $0.accept, "fix": $0.fix] }])
        terms.replaceAll(saved)

        let history = HistoryStore()
        let before = history.entries
        history.clear()
        history.limit = { 2 }
        for n in 0..<3 {
            history.add(HistoryEntry(rawText: "r\(n)", editedText: "e\(n)", copied: n == 1, model: "m",
                                     audioSeconds: 1, transcribeSeconds: 0.5))
        }
        let trimmed = history.entries.map(\.raw) == ["r2", "r1"]
        let reloadedHistory = HistoryStore().entries.map(\.id) == history.entries.map(\.id)
        check(trimmed && reloadedHistory, "history_store", ["entries": history.entries.map(\.raw)])
        history.clear()
        history.limit = { 0 }
        for e in before.reversed() { history.add(e) }

        let settings = SettingsStore()
        var fired = 0
        settings.onChange = { _ in fired += 1 }
        let old = settings.settings.silenceSeconds
        settings.settings.silenceSeconds = old + 1
        settings.flush()
        let persisted = SettingsStore().settings.silenceSeconds == old + 1
        settings.settings.silenceSeconds = old
        settings.flush()
        check(fired == 2 && persisted, "settings_store", ["on_change_fired": fired])
    }

    // MARK: - Helpers

    private static func isFailed(_ s: EngineStatus) -> Bool { if case .failed = s { true } else { false } }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private static func collect(_ s: DictationSession, timeout: Double, t0: Date = Date(),
                                print: Bool = false) async -> [DictationEvent] {
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { s.cancel() }
        }
        defer { timer.cancel() }
        var events: [DictationEvent] = []
        for await e in s.events {
            events.append(e)
            if print { out(["step": "event", "t": Date().timeIntervalSince(t0), "event": describe(e)]) }
        }
        return events
    }

    private static func describe(_ e: DictationEvent) -> String {
        switch e {
        case .modelLoading: "model_loading"
        case .modelReady: "model_ready"
        case .speechStart: "speech_start"
        case .ended(let r): "end:\(r.rawValue)"
        case .transcribing: "transcribing"
        case .result: "result"
        case .error(let code, let message): "error:\(code):\(message)"
        case .closed: "closed"
        }
    }

    private static func out(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            FileHandle.standardOutput.write(Data("{\"step\":\"unserializable\"}\n".utf8))
            return
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    struct WavError: Error, CustomStringConvertible {
        var description: String
    }

    /// PCM16 / Float32 WAV → 16 kHz mono Float32 (channels averaged, linear resampling).
    static func readWav(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        guard d.count > 12, d.prefix(4) == Data("RIFF".utf8), d[8..<12] == Data("WAVE".utf8) else {
            throw WavError(description: "RIFF/WAVE değil")
        }
        var format = 0, channels = 0, rate = 0, bits = 0
        var pcm: Range<Int>?
        var o = 12
        while o + 8 <= d.count {
            let id = String(decoding: d[o..<o + 4], as: UTF8.self)
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }
            } else if id == "data" {
                pcm = body..<min(body + size, d.count)
            }
            o = body + size + (size & 1)
        }
        guard let pcm, channels > 0, rate > 0 else { throw WavError(description: "fmt/data bölümü yok") }
        var mono: [Float] = []
        let frameBytes = channels * bits / 8
        let frames = pcm.count / max(frameBytes, 1)
        mono.reserveCapacity(frames)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    let at = pcm.lowerBound + f * frameBytes + c * bits / 8
                    switch (format, bits) {
                    case (1, 16): sum += Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32768
                    case (3, 32): sum += raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                    default: break
                    }
                }
                mono.append(sum / Float(channels))
            }
        }
        guard (format == 1 && bits == 16) || (format == 3 && bits == 32) else {
            throw WavError(description: "desteklenmeyen biçim (format \(format), \(bits) bit)")
        }
        guard rate != 16000 else { return mono }
        let ratio = Double(rate) / 16000
        let count = Int(Double(mono.count) / ratio)
        return (0..<count).map { i in
            let x = Double(i) * ratio
            let j = Int(x), frac = Float(x - Double(j))
            let a = mono[j], b = j + 1 < mono.count ? mono[j + 1] : a
            return a + (b - a) * frac
        }
    }
}
