import Foundation
import Observation
import os

// Starts/stops the bundled Python engine (see app/engine/api.md "Process lifecycle"),
// keeps a live /events subscription and exposes HTTP actions.

enum EngineStatus: Equatable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)   // Turkish message for the UI
}

@Observable
final class EngineController {
    private(set) var status: EngineStatus = .stopped
    /// Latest /events snapshot (empty until connected).
    private(set) var models: [ModelInfo] = []
    private(set) var system: SystemInfo?

    /// Last config pushed (merged); re-sent automatically after (re)start.
    @ObservationIgnored var config = EngineConfig()

    @ObservationIgnored private let log = Logger(subsystem: "com.mehmetcaykara.dikte", category: "engine")
    @ObservationIgnored private let engineLog = EngineLog(url: Paths.logsDir.appendingPathComponent("engine.log"))
    @ObservationIgnored private let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdinPipe: Pipe?
    @ObservationIgnored private var token = ""
    /// Bumped on every launch/stop; callbacks from older processes are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantRunning = false
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var readyTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var stableTask: Task<Void, Never>?
    @ObservationIgnored private var configTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var eventsSocket: URLSessionWebSocketTask?

    private static let restartBackoff: [Double] = [1, 2, 5, 10, 20]
    private static let readyTimeout: Duration = .seconds(60)

    init() {}

    var loadedModel: ModelInfo? { models.first { $0.state == .loaded } }
    var isRunning: Bool { if case .running = status { true } else { false } }

    /// PID of the engine process (self-test / diagnostics).
    var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    // MARK: - Lifecycle

    /// Launch the engine process (no-op if already running). Restarts automatically if it dies.
    func start() {
        if let process, process.isRunning { return }
        if wantRunning, status == .starting { return }
        wantRunning = true
        restartAttempts = 0
        launch()
    }

    /// Terminate the engine process (app quit).
    func stop() {
        wantRunning = false
        generation += 1
        [readyTimeoutTask, restartTask, stableTask, configTask].forEach { $0?.cancel() }
        disconnectEvents()
        if let process {
            try? stdinPipe?.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            engineLog.note("engine stopped")
        }
        process = nil
        stdinPipe = nil
        status = .stopped
        models = []
        system = nil
    }

    private func launch() {
        generation += 1
        let gen = generation
        guard let python = Paths.enginePython, let dir = Paths.engineDir else {
            wantRunning = false
            status = .failed("Motor bulunamadı: Python ortamı yok. Uygulamayı yeniden kurmayı dene.")
            return
        }
        status = .starting
        token = Self.randomToken()

        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "dikte_engine", "--data-dir", Paths.dataDir.path, "--port", "0"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["DIKTE_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        // Never write .pyc into the (signed) app bundle — that breaks its code signature.
        // The package ships precompiled bytecode instead (app/package.sh).
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let engineLog = engineLog
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { engineLog.append(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in self?.processExited(gen: gen, code: code, signaled: reason == .uncaughtSignal) }
        }

        engineLog.note("starting engine: \(python.path) (data: \(Paths.dataDir.path))")
        do {
            try p.run()
        } catch {
            engineLog.note("launch failed: \(error.localizedDescription)")
            process = nil
            scheduleRestartOrFail("Motor başlatılamadı: \(error.localizedDescription)", gen: gen)
            return
        }
        process = p
        stdinPipe = inPipe

        let outHandle = outPipe.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in outHandle.bytes.lines {
                    await self?.handleStdout(line, gen: gen)
                }
            } catch {}
        }

        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.readyTimeout)
            guard !Task.isCancelled, let self, gen == self.generation, self.status == .starting else { return }
            self.engineLog.note("ready line not received within 60 s")
            self.wantRunning = false
            self.generation += 1
            self.process?.terminate()
            self.process = nil
            self.status = .failed("Motor 60 saniye içinde hazır olmadı. Ayrıntılar: logs/engine.log")
        }
    }

    private func handleStdout(_ line: String, gen: Int) {
        guard gen == generation else { return }
        if status == .starting,
           let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["event"] as? String == "ready",
           let port = (obj["port"] as? NSNumber)?.intValue {
            readyTimeoutTask?.cancel()
            status = .running(port: port)
            engineLog.note("engine ready on port \(port)")
            log.info("Engine ready on port \(port)")
            connectEvents(port: port, gen: gen)
            configTask?.cancel()
            configTask = Task { [weak self] in await self?.sendConfig() }
            stableTask?.cancel()
            stableTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, gen == self.generation else { return }
                self.restartAttempts = 0
            }
        } else {
            engineLog.append(Data("[stdout] \(line)\n".utf8))
        }
    }

    private func processExited(gen: Int, code: Int32, signaled: Bool) {
        guard gen == generation else { return }
        engineLog.note("engine exited (\(signaled ? "signal" : "code") \(code))")
        log.error("Engine exited unexpectedly (\(code))")
        process = nil
        stdinPipe = nil
        readyTimeoutTask?.cancel()
        stableTask?.cancel()
        disconnectEvents()
        models = []
        system = nil
        guard wantRunning else { status = .stopped; return }
        scheduleRestartOrFail("Motor beklenmedik şekilde durdu (\(signaled ? "sinyal" : "çıkış kodu") \(code)). Ayrıntılar: logs/engine.log", gen: gen)
    }

    private func scheduleRestartOrFail(_ message: String, gen: Int) {
        guard restartAttempts < Self.restartBackoff.count else {
            wantRunning = false
            status = .failed(message)
            return
        }
        let delay = Self.restartBackoff[restartAttempts]
        restartAttempts += 1
        status = .starting
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, gen == self.generation, self.wantRunning else { return }
            self.launch()
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - /events

    private func connectEvents(port: Int, gen: Int) {
        disconnectEvents()
        guard let url = URL(string: "ws://127.0.0.1:\(port)/events?token=\(token)") else { return }
        let ws = urlSession.webSocketTask(with: url)
        ws.maximumMessageSize = 16 * 1024 * 1024
        eventsSocket = ws
        ws.resume()
        eventsTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    self?.handleEvent(message)
                }
            } catch {}
            // Dropped while the process lives → reconnect.
            guard !Task.isCancelled, let self, gen == self.generation, self.isRunning else { return }
            self.log.notice("/events dropped; reconnecting")
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, gen == self.generation, case .running(let port) = self.status else { return }
            self.connectEvents(port: port, gen: gen)
        }
    }

    private func disconnectEvents() {
        eventsTask?.cancel()
        eventsTask = nil
        eventsSocket?.cancel(with: .goingAway, reason: nil)
        eventsSocket = nil
    }

    private struct Snapshot: Decodable {
        var type: String
        var models: [ModelInfo]?
        var system: SystemInfo?
    }

    private func handleEvent(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        do {
            let snap = try EngineJSON.decoder.decode(Snapshot.self, from: data)
            guard snap.type == "snapshot" else { return }
            if let m = snap.models, m != models { models = m }
            if let s = snap.system, s != system { system = s }
        } catch {
            log.error("Bad /events message: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Config

    /// Merge into `config` and PUT /config (if running).
    func pushConfig(_ partial: EngineConfig) {
        config.merge(partial)
        guard isRunning else { return }
        configTask?.cancel()
        configTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.sendConfig()
        }
    }

    private func sendConfig() async {
        do {
            _ = try await request("PUT", "/config", json: config)
        } catch {
            log.error("PUT /config failed: \(error.localizedDescription, privacy: .public)")
            engineLog.note("PUT /config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Model actions

    func download(_ id: String) async throws {
        _ = try await request("POST", "/models/\(Self.segment(id))/download")
    }

    func cancelDownload(_ id: String) async throws {
        _ = try await request("POST", "/models/\(Self.segment(id))/cancel")
    }

    func delete(_ id: String) async throws {
        _ = try await request("DELETE", "/models/\(Self.segment(id))")
    }

    func load(_ id: String) async throws {
        _ = try await request("POST", "/models/\(Self.segment(id))/load")
    }

    func unload() async throws {
        _ = try await request("POST", "/unload")
    }

    func addCustom(repo: String) async throws -> ModelInfo {
        let data = try await request("POST", "/models/custom", json: ["repo": repo])
        return try Self.decode(ModelInfo.self, data)
    }

    func removeCustom(_ id: String) async throws {
        _ = try await request("DELETE", "/models/custom/\(Self.segment(id))")
    }

    /// `GET /terms/default` → `{"terms": [Term]}` (a bare array is accepted too).
    /// POST /retranscribe — the last dictation's audio again, in `language` ("tr" | "en").
    func retranscribe(dictationId: String, language: String) async throws -> DictationResult {
        throw EngineAPIError(error: "not_implemented", message: "")
    }

    func defaultTerms() async throws -> [Term] {
        struct Wrapper: Decodable { var terms: [Term] }
        let data = try await request("GET", "/terms/default")
        if let w = try? EngineJSON.decoder.decode(Wrapper.self, from: data) { return w.terms }
        return try Self.decode([Term].self, data)
    }

    /// New `/dictate` session (not yet connected; call `start()` on it).
    func makeDictation() -> DictationSession {
        guard case .running(let port) = status else { return DictationSession() }
        return DictationSession(port: port, token: token, urlSession: urlSession)
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, json: some Encodable) async throws -> Data {
        try await request(method, path, body: try EngineJSON.encoder.encode(json))
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard case .running(let port) = status else {
            throw EngineAPIError(error: "engine_not_running", message: "Motor çalışmıyor")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw EngineAPIError(error: "bad_request", message: "Geçersiz istek: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw EngineAPIError(error: "network", message: "Motora ulaşılamadı: \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if let apiError = try? EngineJSON.decoder.decode(EngineAPIError.self, from: data) { throw apiError }
            throw EngineAPIError(error: "http_\(code)", message: "Motor hatası (HTTP \(code))")
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try EngineJSON.decoder.decode(T.self, from: data)
        } catch {
            throw EngineAPIError(error: "bad_response", message: "Motordan beklenmeyen yanıt")
        }
    }

    /// Path segment for a model id; custom ids contain "/" → `hf:org%2Fname`.
    static func segment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}

extension EngineConfig {
    /// Overwrite fields that are set in `other`.
    mutating func merge(_ other: EngineConfig) {
        if let v = other.selectedModel { selectedModel = v }
        if let v = other.idleUnloadS { idleUnloadS = v }
        if let v = other.minFreeBytes { minFreeBytes = v }
        if let v = other.silenceS { silenceS = v }
        if let v = other.maxDurationS { maxDurationS = v }
        if let v = other.language { language = v }
        if let v = other.terms { terms = v }
    }
}
